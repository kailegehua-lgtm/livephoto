@preconcurrency import AVFoundation
import Foundation
import ImageIO

enum MomentCaptureError: Error {
    case busy
    case captureFailed
    case photoCaptureTimedOut
    case missingPhotoData
    case invalidPhotoSize
    case videoRecordingFailed
    case videoRecordingTimedOut
    case exportTimedOut
    case insufficientPreRollSamples
    case statusUpdateFailed
}

extension MomentCaptureError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .busy:
            return "正在处理上一张拍摄，请稍后再试。"
        case .captureFailed:
            return "拍摄失败，请重试。"
        case .photoCaptureTimedOut:
            return "主图拍摄超时，请重试。"
        case .missingPhotoData:
            return "没有拿到主图数据。"
        case .invalidPhotoSize:
            return "主图尺寸解析失败。"
        case .videoRecordingFailed:
            return "动态片段录制失败。"
        case .videoRecordingTimedOut:
            return "动态片段录制超时。"
        case .exportTimedOut:
            return "动态片段导出超时。"
        case .insufficientPreRollSamples:
            return "回溯样本不足，请稍后再试。"
        case .statusUpdateFailed:
            return "拍摄结果保存失败。"
        }
    }
}

final class MomentCaptureCoordinator: NSObject, ObservableObject {
    @Published private(set) var isCapturing = false
    @Published private(set) var isBackgroundProcessing = false
    @Published private(set) var processingPhase = "idle"

    private let cameraManager: CameraSessionManager
    private let store: MomentStore
    private let postRollQueue = DispatchQueue(label: "livephoto.capture.post-roll")
    private let exportManager = VideoExportManager()

    private var photoContinuation: CheckedContinuation<Data, Error>?
    private var movieFileOutput: AVCaptureMovieFileOutput?
    private var recordingContinuation: CheckedContinuation<URL, Error>?
    private var pendingRecordingURL: URL?
    private var isCollectingExperimentalPostRoll = false
    private var pendingExperimentalPostRoll: [BufferedSample] = []
    private var backgroundHintTask: Task<Void, Never>?
    private let continuationQueue = DispatchQueue(label: "livephoto.capture.continuation")
    private let photoTimeoutSeconds: Double = 5
    private let recordingTimeoutSeconds: Double = 5
    private let exportTimeoutSeconds: Double = 12
    private let processingWatchdogSeconds: Double = 20

    init(cameraManager: CameraSessionManager, store: MomentStore) {
        self.cameraManager = cameraManager
        self.store = store
        super.init()
        self.movieFileOutput = cameraManager.movieFileOutput
        cameraManager.onVideoSampleBuffer = { [weak self] sampleBuffer in
            self?.appendExperimentalPostRollSample(sampleBuffer)
        }
    }

    func captureMoment(mode: CaptureMode) async throws -> MomentAsset {
        switch mode {
        case .stablePostRoll:
            return try await captureStablePostRollMoment()
        case .experimentalPreRoll:
            return try await captureExperimentalPreRollMoment()
        }
    }

    private func captureStablePostRollMoment() async throws -> MomentAsset {
        guard !isCapturing else {
            throw MomentCaptureError.busy
        }

        await MainActor.run {
            isCapturing = true
            isBackgroundProcessing = false
            processingPhase = "stable:start"
        }

        let movieURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")

        do {
            try startRecording(to: movieURL)
            let imageData = try await withTimeout(seconds: photoTimeoutSeconds, failure: .photoCaptureTimedOut) {
                try await self.capturePhotoData()
            }
            guard let photoSize = imageSize(from: imageData) else {
                cleanupAfterStableFailure(movieURL: movieURL)
                await MainActor.run { isCapturing = false }
                throw MomentCaptureError.invalidPhotoSize
            }

            let moment = try await store.createMoment(
                photoData: imageData,
                size: photoSize,
                captureMode: .stablePostRoll,
                status: .captured,
                preDuration: 0.0,
                postDuration: 0.0,
                coverTimestamp: 0.0
            )

            await MainActor.run {
                self.isCapturing = false
                self.showBackgroundProcessingHint()
                self.processingPhase = "stable:created"
            }

            Task { [weak self] in
                guard let self else { return }
                let watchdog = self.makeProcessingWatchdog(for: moment.id)
                defer {
                    watchdog.cancel()
                }
                do {
                    await MainActor.run { self.processingPhase = "stable:processing" }
                    _ = try await self.store.updateMomentIfCurrentStatus(
                        id: moment.id,
                        expectedStatus: .captured,
                        videoURL: nil,
                        status: .processing,
                        duration: 0.0,
                        preDuration: 0.0,
                        postDuration: 0.0,
                        coverTimestamp: 0.0
                    )
                    try await Task.sleep(for: .seconds(1))
                    await MainActor.run { self.processingPhase = "stable:stop-recording" }
                    let recordedMovieURL = try await self.withTimeout(seconds: self.recordingTimeoutSeconds, failure: .videoRecordingTimedOut) {
                        try await self.stopRecording()
                    }
                    await MainActor.run { self.processingPhase = "stable:store-ready" }
                    _ = try await self.store.updateMomentIfCurrentStatus(
                        id: moment.id,
                        expectedStatus: .processing,
                        videoURL: recordedMovieURL,
                        status: .ready,
                        duration: 1.0,
                        preDuration: 0.0,
                        postDuration: 1.0,
                        coverTimestamp: 0.0
                    )
                    await MainActor.run { self.processingPhase = "stable:done" }
                } catch {
                    await MainActor.run { self.processingPhase = "stable:failed" }
                    self.cleanupAfterStableFailure(movieURL: movieURL)
                    _ = try? await self.store.updateMomentIfCurrentStatus(
                        id: moment.id,
                        expectedStatus: .processing,
                        videoURL: nil,
                        status: .failed,
                        duration: 0.0,
                        preDuration: 0.0,
                        postDuration: 0.0,
                        coverTimestamp: 0.0
                    )
                }
            }

            return moment
        } catch {
            cleanupAfterStableFailure(movieURL: movieURL)
            cancelPhotoContinuationIfNeeded()
            await MainActor.run {
                isCapturing = false
                isBackgroundProcessing = false
                processingPhase = "stable:error"
            }
            throw error
        }
    }

    private func captureExperimentalPreRollMoment() async throws -> MomentAsset {
        guard !isCapturing else {
            throw MomentCaptureError.busy
        }

        let preRollSnapshot = cameraManager.rollingBuffer.snapshot()

        guard preRollSnapshot.videoSamples.count >= 6 else {
            throw MomentCaptureError.insufficientPreRollSamples
        }

        await MainActor.run {
            isCapturing = true
            isBackgroundProcessing = false
            processingPhase = "experimental:start"
        }

        do {
            beginExperimentalPostRollCollection()
            let imageData = try await withTimeout(seconds: photoTimeoutSeconds, failure: .photoCaptureTimedOut) {
                try await self.capturePhotoData()
            }
            guard let photoSize = imageSize(from: imageData) else {
                _ = endExperimentalPostRollCollection()
                await MainActor.run { isCapturing = false }
                throw MomentCaptureError.invalidPhotoSize
            }

            let moment = try await store.createMoment(
                photoData: imageData,
                size: photoSize,
                captureMode: .experimentalPreRoll,
                status: .captured,
                preDuration: 0.0,
                postDuration: 0.0,
                coverTimestamp: 0.0
            )

            await MainActor.run {
                self.isCapturing = false
                self.showBackgroundProcessingHint()
                self.processingPhase = "experimental:created"
            }

            Task { [weak self] in
                guard let self else { return }
                let watchdog = self.makeProcessingWatchdog(for: moment.id)
                defer {
                    watchdog.cancel()
                }
                var exportedURL: URL?
                do {
                    await MainActor.run { self.processingPhase = "experimental:processing" }
                    _ = try await self.store.updateMomentIfCurrentStatus(
                        id: moment.id,
                        expectedStatus: .captured,
                        videoURL: nil,
                        status: .processing,
                        duration: 0.0,
                        preDuration: 0.0,
                        postDuration: 0.0,
                        coverTimestamp: 0.0
                    )
                    try await Task.sleep(for: .seconds(1))
                    await MainActor.run { self.processingPhase = "experimental:collect-post" }
                    let postRollSnapshot = self.endExperimentalPostRollCollection()
                    await MainActor.run { self.processingPhase = "experimental:exporting" }
                    let exportResult = try await self.withTimeout(seconds: self.exportTimeoutSeconds, failure: .exportTimedOut) {
                        try await self.exportManager.composeExperimentalClip(
                            preRoll: preRollSnapshot,
                            postRoll: postRollSnapshot
                        )
                    }
                    exportedURL = exportResult.url
                    await MainActor.run { self.processingPhase = "experimental:store-ready" }
                    _ = try await self.store.updateMomentIfCurrentStatus(
                        id: moment.id,
                        expectedStatus: .processing,
                        videoURL: exportResult.url,
                        status: .ready,
                        duration: exportResult.duration,
                        preDuration: 3.0,
                        postDuration: 1.0,
                        coverTimestamp: 3.0
                    )
                    await MainActor.run { self.processingPhase = "experimental:done" }
                } catch {
                    await MainActor.run { self.processingPhase = "experimental:failed" }
                    if let exportedURL {
                        await MainActor.run {
                            self.store.removeTemporaryItemIfExists(at: exportedURL)
                        }
                    }
                    _ = try? await self.store.updateMomentIfCurrentStatus(
                        id: moment.id,
                        expectedStatus: .processing,
                        videoURL: nil,
                        status: .failed,
                        duration: 0.0,
                        preDuration: 0.0,
                        postDuration: 0.0,
                        coverTimestamp: 0.0
                    )
                }
            }

            return moment
        } catch {
            _ = endExperimentalPostRollCollection()
            cancelPhotoContinuationIfNeeded()
            await MainActor.run {
                isCapturing = false
                isBackgroundProcessing = false
                processingPhase = "experimental:error"
            }
            throw error
        }
    }

    @MainActor
    private func showBackgroundProcessingHint() {
        backgroundHintTask?.cancel()
        isBackgroundProcessing = true
        backgroundHintTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.isBackgroundProcessing = false
            }
        }
    }

    private func capturePhotoData() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            continuationQueue.sync {
                photoContinuation = continuation
            }
            let settings = AVCapturePhotoSettings()
            settings.maxPhotoDimensions = cameraManager.photoOutput.maxPhotoDimensions
            cameraManager.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    private func startRecording(to url: URL) throws {
        guard let movieFileOutput else {
            throw MomentCaptureError.videoRecordingFailed
        }

        if movieFileOutput.isRecording {
            movieFileOutput.stopRecording()
        }

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        pendingRecordingURL = url
        movieFileOutput.startRecording(to: url, recordingDelegate: self)
    }

    private func stopRecording() async throws -> URL {
        guard let movieFileOutput, movieFileOutput.isRecording else {
            throw MomentCaptureError.videoRecordingFailed
        }

        return try await withCheckedThrowingContinuation { continuation in
            postRollQueue.async {
                self.continuationQueue.sync {
                    self.recordingContinuation = continuation
                }
                movieFileOutput.stopRecording()
            }
        }
    }

    private func cleanupAfterStableFailure(movieURL: URL) {
        postRollQueue.async { [movieFileOutput] in
            if let movieFileOutput, movieFileOutput.isRecording {
                movieFileOutput.stopRecording()
            }
        }
        if let pendingRecordingURL, pendingRecordingURL == movieURL {
            continuationQueue.sync {
                recordingContinuation = nil
            }
        }
        Task { @MainActor [store] in
            store.removeTemporaryItemIfExists(at: movieURL)
        }
    }

    private func imageSize(from data: Data) -> CGSize? {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat
        else {
            return nil
        }

        return CGSize(width: width, height: height)
    }

    private func beginExperimentalPostRollCollection() {
        postRollQueue.sync {
            pendingExperimentalPostRoll = []
            isCollectingExperimentalPostRoll = true
        }
    }

    private func endExperimentalPostRollCollection() -> BufferedMediaSnapshot {
        postRollQueue.sync {
            isCollectingExperimentalPostRoll = false
            let snapshot = BufferedMediaSnapshot(videoSamples: pendingExperimentalPostRoll, audioSamples: [])
            pendingExperimentalPostRoll = []
            return snapshot
        }
    }

    private func appendExperimentalPostRollSample(_ sampleBuffer: CMSampleBuffer) {
        let shouldCollect = postRollQueue.sync { isCollectingExperimentalPostRoll }
        guard shouldCollect, let copied = sampleBuffer.deepCopy() else {
            return
        }

        let sample = BufferedSample(sampleBuffer: copied, timestamp: CMSampleBufferGetPresentationTimeStamp(copied))
        postRollQueue.async {
            guard self.isCollectingExperimentalPostRoll else {
                return
            }

            self.pendingExperimentalPostRoll.append(sample)
        }
    }

    private func makeProcessingWatchdog(for momentID: UUID) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.processingWatchdogSeconds))
            guard !Task.isCancelled else { return }

            _ = try? await self.store.updateMomentIfCurrentStatus(
                id: momentID,
                expectedStatus: .processing,
                videoURL: nil,
                status: .failed,
                duration: 0.0,
                preDuration: 0.0,
                postDuration: 0.0,
                coverTimestamp: 0.0
            )

            await MainActor.run {
                self.isBackgroundProcessing = false
                self.processingPhase = "watchdog:failed"
            }
        }
    }

    private func withTimeout<T: Sendable>(
        seconds: Double,
        failure: MomentCaptureError,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw failure
            }

            guard let result = try await group.next() else {
                throw failure
            }
            group.cancelAll()
            return result
        }
    }

    private func cancelPhotoContinuationIfNeeded() {
        continuationQueue.sync {
            photoContinuation = nil
        }
    }

    private func takePhotoContinuation() -> CheckedContinuation<Data, Error>? {
        continuationQueue.sync {
            let continuation = photoContinuation
            photoContinuation = nil
            return continuation
        }
    }

    private func takeRecordingContinuation() -> CheckedContinuation<URL, Error>? {
        continuationQueue.sync {
            let continuation = recordingContinuation
            recordingContinuation = nil
            return continuation
        }
    }
}

extension MomentCaptureCoordinator: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            takePhotoContinuation()?.resume(throwing: error)
            return
        }

        guard let data = photo.fileDataRepresentation() else {
            takePhotoContinuation()?.resume(throwing: MomentCaptureError.missingPhotoData)
            return
        }

        takePhotoContinuation()?.resume(returning: data)
    }
}

extension MomentCaptureCoordinator: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        defer {
            pendingRecordingURL = nil
        }

        if let error {
            takeRecordingContinuation()?.resume(throwing: error)
            return
        }

        guard let continuation = takeRecordingContinuation() else {
            Task { @MainActor [store] in
                store.removeTemporaryItemIfExists(at: outputFileURL)
            }
            return
        }

        continuation.resume(returning: outputFileURL)
    }
}

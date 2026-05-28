@preconcurrency import AVFoundation
import Foundation
import ImageIO

enum MomentCaptureError: Error {
    case busy
    case captureFailed
    case photoCaptureTimedOut
    case missingPhotoData
    case invalidPhotoSize
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
        case .exportTimedOut:
            return "动态片段导出超时。"
        case .insufficientPreRollSamples:
            return "前 3 秒回溯还没攒满，请稍等约 3 秒后再拍。"
        case .statusUpdateFailed:
            return "拍摄结果保存失败。"
        }
    }
}

final class MomentCaptureCoordinator: NSObject, ObservableObject {
    @Published private(set) var isCapturing = false
    @Published private(set) var isBackgroundProcessing = false
    @Published private(set) var processingPhase = "idle"
    @Published private(set) var availablePreRollSeconds: Double = 0.0

    private let cameraManager: CameraSessionManager
    private let store: MomentStore
    private let exportManager = VideoExportManager()

    private var photoContinuation: CheckedContinuation<Data, Error>?
    private var backgroundHintTask: Task<Void, Never>?
    private let continuationQueue = DispatchQueue(label: "livephoto.capture.continuation")
    private let photoTimeoutSeconds: Double = 5
    private let exportTimeoutSeconds: Double = 12
    private let processingWatchdogSeconds: Double = 20
    private let requiredExperimentalPreRollSeconds: Double = 2.7
    private let targetExperimentalPostRollSeconds: Double = 1.0

    init(cameraManager: CameraSessionManager, store: MomentStore) {
        self.cameraManager = cameraManager
        self.store = store
        super.init()
        cameraManager.onRollingBufferUpdated = { [weak self] duration in
            Task { @MainActor [weak self] in
                self?.availablePreRollSeconds = duration
            }
        }
    }

    func captureMoment() async throws -> MomentAsset {
        try await captureRollingReplayMoment()
    }

    private func captureRollingReplayMoment() async throws -> MomentAsset {
        guard !isCapturing else {
            throw MomentCaptureError.busy
        }

        let availablePreRollDuration = await cameraManager.rollingRecorder.availableDuration()
        guard availablePreRollDuration >= requiredExperimentalPreRollSeconds else {
            throw MomentCaptureError.insufficientPreRollSamples
        }

        await MainActor.run {
            isCapturing = true
            isBackgroundProcessing = false
            processingPhase = "rolling:start"
        }

        do {
            let postRollStartWallClockTime = ProcessInfo.processInfo.systemUptime
            let imageData = try await withTimeout(seconds: photoTimeoutSeconds, failure: .photoCaptureTimedOut) {
                try await self.capturePhotoData()
            }
            guard let photoSize = imageSize(from: imageData) else {
                await MainActor.run { isCapturing = false }
                throw MomentCaptureError.invalidPhotoSize
            }

            let moment = try await store.createMoment(
                photoData: imageData,
                size: photoSize,
                captureMode: .rollingReplay,
                status: .captured,
                preDuration: 0.0,
                postDuration: 0.0,
                coverTimestamp: 0.0
            )

            await MainActor.run {
                self.isCapturing = false
                self.showBackgroundProcessingHint()
                self.processingPhase = "rolling:created"
            }

            Task { [weak self] in
                guard let self else { return }
                let watchdog = self.makeProcessingWatchdog(for: moment.id)
                defer {
                    watchdog.cancel()
                }
                var exportedURL: URL?
                do {
                    await MainActor.run { self.processingPhase = "rolling:processing" }
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
                    await MainActor.run { self.processingPhase = "rolling:collect-post" }
                    let clipPlan = try await self.cameraManager.rollingRecorder.makeClipPlan(
                        captureWallClockTime: postRollStartWallClockTime,
                        preDuration: self.requiredExperimentalPreRollSeconds,
                        postDuration: self.targetExperimentalPostRollSeconds
                    )
                    let actualPreDuration = clipPlan.actualPreDuration
                    let actualPostDuration = clipPlan.actualPostDuration
                    await MainActor.run { self.processingPhase = "rolling:exporting" }
                    let exportResult = try await self.withTimeout(seconds: self.exportTimeoutSeconds, failure: .exportTimedOut) {
                        try await self.exportManager.composeExperimentalClip(from: clipPlan)
                    }
                    exportedURL = exportResult.url
                    await MainActor.run { self.processingPhase = "rolling:store-ready" }
                    _ = try await self.store.updateMomentIfCurrentStatus(
                        id: moment.id,
                        expectedStatus: .processing,
                        videoURL: exportResult.url,
                        status: .ready,
                        duration: exportResult.duration,
                        preDuration: actualPreDuration,
                        postDuration: actualPostDuration > 0 ? actualPostDuration : targetExperimentalPostRollSeconds,
                        coverTimestamp: actualPreDuration
                    )
                    self.cameraManager.diagnostics.recordExport(
                        url: exportResult.url,
                        sourceFrameCount: exportResult.frameCount,
                        sourceDuration: exportResult.duration
                    )
                    await MainActor.run { self.processingPhase = "rolling:done" }
                } catch {
                    let failureTag = self.rollingFailureTag(from: error)
                    await MainActor.run { self.processingPhase = "rolling:failed:\(failureTag)" }
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
            cancelPhotoContinuationIfNeeded()
            await MainActor.run {
                isCapturing = false
                isBackgroundProcessing = false
                processingPhase = "rolling:error"
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

    private func rollingFailureTag(from error: Error) -> String {
        switch error {
        case RollingEncodedRecorderError.insufficientSegments:
            return "segments"
        case ExperimentalClipAssemblerError.emptyComposition:
            return "empty"
        case ExperimentalClipAssemblerError.exportSessionCreationFailed:
            return "session"
        case MomentCaptureError.exportTimedOut:
            return "timeout"
        default:
            return "other"
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

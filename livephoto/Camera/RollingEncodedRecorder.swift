@preconcurrency import AVFoundation
import Foundation

enum RollingEncodedRecorderError: Error {
    case sessionNotStarted
    case writerSetupFailed
    case segmentMissingTrack
    case insufficientSegments
    case invalidSegmentOutput
}

final class RollingEncodedRecorder {
    private struct SegmentContext {
        let id: UUID
        let url: URL
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let startWallClockTime: TimeInterval
        let firstPTS: CMTime
        let transform: CGAffineTransform
        var lastPTS: CMTime
        var lastWallClockTime: TimeInterval
        var frameCount: Int
    }

    private let queue = DispatchQueue(label: "livephoto.rolling-encoded-recorder")
    private let segmentStore: RollingSegmentStore
    private let segmentDurationSeconds: Double
    private let targetFrameRate: Int32
    private let averageBitRate: Int
    private let retentionWindowSeconds: Double

    private var isRunning = false
    private var activeContext: SegmentContext?
    private var pendingFinalizations = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var observedWindowStartWallClockTime: TimeInterval?
    private var latestObservedWallClockTime: TimeInterval?

    var onAvailableDurationChanged: ((Double) -> Void)?

    init(
        segmentStore: RollingSegmentStore = RollingSegmentStore(),
        segmentDurationSeconds: Double = 1.0,
        targetFrameRate: Int32 = 30,
        averageBitRate: Int = 2_000_000
    ) {
        self.segmentStore = segmentStore
        self.segmentDurationSeconds = segmentDurationSeconds
        self.targetFrameRate = targetFrameRate
        self.averageBitRate = averageBitRate
        self.retentionWindowSeconds = 4.5
    }

    func startRunning() {
        queue.sync {
            do {
                if self.segmentStore.sessionDirectoryURL == nil {
                    try self.segmentStore.startNewSession()
                }
                self.isRunning = true
                self.observedWindowStartWallClockTime = nil
                self.latestObservedWallClockTime = nil
                self.publishAvailableDuration()
            } catch {
                self.isRunning = false
            }
        }
    }

    func stopRunning(removeFiles: Bool) async {
        await waitForPendingFinalizations(forceFinalizeActive: true)
        queue.async {
            self.isRunning = false
            self.activeContext = nil
            self.observedWindowStartWallClockTime = nil
            self.latestObservedWallClockTime = nil
            self.segmentStore.reset(removeFiles: removeFiles)
            self.publishAvailableDuration()
        }
    }

    @discardableResult
    func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer, wallClockTime: TimeInterval) -> Bool {
        guard CMSampleBufferDataIsReady(sampleBuffer) else {
            return false
        }

        queue.async {
            self.handleSampleBuffer(sampleBuffer, wallClockTime: wallClockTime)
        }
        return true
    }

    func availableDuration() async -> Double {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.currentAvailableDuration())
            }
        }
    }

    func availableDurationSync() -> Double {
        queue.sync {
            currentAvailableDuration()
        }
    }

    func makeClipPlan(
        captureWallClockTime: TimeInterval,
        preDuration: Double,
        postDuration: Double
    ) async throws -> RollingClipPlan {
        await waitForPendingFinalizations(forceFinalizeActive: true)

        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let range = (captureWallClockTime - preDuration)...(captureWallClockTime + postDuration)
                let segments = self.segmentStore.segments(overlapping: range)
                guard !segments.isEmpty else {
                    continuation.resume(throwing: RollingEncodedRecorderError.insufficientSegments)
                    return
                }

                let earliestStart = segments.map(\.startWallClockTime).min() ?? captureWallClockTime
                let latestEnd = segments.map(\.endWallClockTime).max() ?? captureWallClockTime
                let actualPreDuration = max(0.0, captureWallClockTime - earliestStart)
                let actualPostDuration = max(0.0, latestEnd - captureWallClockTime)

                continuation.resume(returning: RollingClipPlan(
                    segments: segments,
                    captureWallClockTime: captureWallClockTime,
                    actualPreDuration: actualPreDuration,
                    actualPostDuration: actualPostDuration
                ))
            }
        }
    }

    private func handleSampleBuffer(_ sampleBuffer: CMSampleBuffer, wallClockTime: TimeInterval) {
        guard isRunning else {
            return
        }

        updateObservedWindow(with: wallClockTime)

        if let activeContext,
           activeContext.frameCount > 0,
           (wallClockTime - activeContext.startWallClockTime) >= segmentDurationSeconds {
            finalizeActiveContext()
        }

        if activeContext == nil {
            do {
                activeContext = try makeSegmentContext(from: sampleBuffer, wallClockTime: wallClockTime)
            } catch {
                return
            }
        }

        guard var activeContext else {
            return
        }

        guard let retimedBuffer = makeRetimedSampleBuffer(sampleBuffer, firstPTS: activeContext.firstPTS) else {
            return
        }

        if activeContext.frameCount == 0 {
            activeContext.writer.startWriting()
            activeContext.writer.startSession(atSourceTime: .zero)
        }

        guard activeContext.input.isReadyForMoreMediaData else {
            self.activeContext = activeContext
            return
        }

        guard activeContext.input.append(retimedBuffer) else {
            self.activeContext = activeContext
            return
        }

        activeContext.lastPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        activeContext.lastWallClockTime = wallClockTime
        activeContext.frameCount += 1
        self.activeContext = activeContext
        publishAvailableDuration()
    }

    private func makeSegmentContext(from sampleBuffer: CMSampleBuffer, wallClockTime: TimeInterval) throws -> SegmentContext {
        let outputURL = try segmentStore.makeSegmentURL()
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        writer.shouldOptimizeForNetworkUse = false

        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw RollingEncodedRecorderError.writerSetupFailed
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)

        let compressionSettings: [String: Any] = [
            AVVideoAverageBitRateKey: averageBitRate,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoExpectedSourceFrameRateKey: Int(targetFrameRate),
            AVVideoMaxKeyFrameIntervalKey: Int(targetFrameRate)
        ]
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(dimensions.width),
                AVVideoHeightKey: Int(dimensions.height),
                AVVideoCompressionPropertiesKey: compressionSettings
            ],
            sourceFormatHint: formatDescription
        )
        input.expectsMediaDataInRealTime = true
        input.transform = CGAffineTransform(rotationAngle: .pi / 2)

        guard writer.canAdd(input) else {
            throw RollingEncodedRecorderError.writerSetupFailed
        }
        writer.add(input)

        let firstPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        return SegmentContext(
            id: UUID(),
            url: outputURL,
            writer: writer,
            input: input,
            startWallClockTime: wallClockTime,
            firstPTS: firstPTS,
            transform: input.transform,
            lastPTS: firstPTS,
            lastWallClockTime: wallClockTime,
            frameCount: 0
        )
    }

    private func finalizeActiveContext() {
        guard let context = activeContext else {
            return
        }

        activeContext = nil
        guard context.frameCount > 0 else {
            if FileManager.default.fileExists(atPath: context.url.path) {
                try? FileManager.default.removeItem(at: context.url)
            }
            publishAvailableDuration()
            return
        }

        guard context.writer.status == .writing else {
            if FileManager.default.fileExists(atPath: context.url.path) {
                try? FileManager.default.removeItem(at: context.url)
            }
            publishAvailableDuration()
            return
        }

        pendingFinalizations += 1
        context.input.markAsFinished()

        context.writer.finishWriting {
            self.queue.async {
                if context.writer.status == .completed,
                   FileManager.default.fileExists(atPath: context.url.path) {
                    let durationSeconds = max(context.lastPTS.seconds - context.firstPTS.seconds, 0)
                    let nominalFrameRate = durationSeconds > 0
                        ? Float(Double(context.frameCount) / durationSeconds)
                        : Float(self.targetFrameRate)
                    let segment = RollingSegment(
                        id: context.id,
                        url: context.url,
                        startWallClockTime: context.startWallClockTime,
                        endWallClockTime: context.lastWallClockTime,
                        frameCount: context.frameCount,
                        nominalFrameRate: nominalFrameRate,
                        isFinalized: true
                    )
                    self.segmentStore.registerFinalizedSegment(segment)
                } else if FileManager.default.fileExists(atPath: context.url.path) {
                    try? FileManager.default.removeItem(at: context.url)
                }
                self.pendingFinalizations -= 1
                self.publishAvailableDuration()
                self.resumeWaitersIfNeeded()
            }
        }
    }

    private func waitForPendingFinalizations(forceFinalizeActive: Bool) async {
        await withCheckedContinuation { continuation in
            queue.async {
                if forceFinalizeActive {
                    self.finalizeActiveContext()
                }

                if self.pendingFinalizations == 0 {
                    continuation.resume()
                } else {
                    self.waiters.append(continuation)
                }
            }
        }
    }

    private func resumeWaitersIfNeeded() {
        guard pendingFinalizations == 0, !waiters.isEmpty else {
            return
        }
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    private func publishAvailableDuration() {
        let duration = currentAvailableDuration()
        DispatchQueue.main.async {
            self.onAvailableDurationChanged?(duration)
        }
    }

    private func currentAvailableDuration() -> Double {
        guard let observedWindowStartWallClockTime,
              let latestObservedWallClockTime
        else {
            return 0.0
        }
        return max(0.0, latestObservedWallClockTime - observedWindowStartWallClockTime)
    }

    private func updateObservedWindow(with wallClockTime: TimeInterval) {
        if observedWindowStartWallClockTime == nil {
            observedWindowStartWallClockTime = wallClockTime
        }
        latestObservedWallClockTime = wallClockTime

        if let latestObservedWallClockTime,
           let observedWindowStartWallClockTime,
           (latestObservedWallClockTime - observedWindowStartWallClockTime) > retentionWindowSeconds {
            self.observedWindowStartWallClockTime = latestObservedWallClockTime - retentionWindowSeconds
        }
    }

    private func makeRetimedSampleBuffer(_ sampleBuffer: CMSampleBuffer, firstPTS: CMTime) -> CMSampleBuffer? {
        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        var timingInfo = Array(repeating: CMSampleTimingInfo(), count: sampleCount)
        let status = CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: sampleCount,
            arrayToFill: &timingInfo,
            entriesNeededOut: nil
        )
        guard status == noErr else {
            return nil
        }

        for index in timingInfo.indices {
            timingInfo[index].presentationTimeStamp = CMTimeSubtract(timingInfo[index].presentationTimeStamp, firstPTS)
            if timingInfo[index].decodeTimeStamp.isValid {
                timingInfo[index].decodeTimeStamp = CMTimeSubtract(timingInfo[index].decodeTimeStamp, firstPTS)
            }
        }

        var adjustedBuffer: CMSampleBuffer?
        let copyStatus = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: sampleCount,
            sampleTimingArray: &timingInfo,
            sampleBufferOut: &adjustedBuffer
        )
        guard copyStatus == noErr else {
            return nil
        }
        return adjustedBuffer
    }
}

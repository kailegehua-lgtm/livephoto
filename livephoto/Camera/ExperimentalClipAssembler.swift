@preconcurrency import AVFoundation
import Foundation

enum ExperimentalClipAssemblerError: Error {
    case exportSessionCreationFailed
    case missingVideoTrack
    case emptyComposition
}

final class ExperimentalClipAssembler {
    private let exportQueue = DispatchQueue(label: "livephoto.experimental-clip-assembler")

    func assembleClip(from plan: RollingClipPlan) async throws -> (url: URL, duration: Double, frameCount: Int) {
        try await withCheckedThrowingContinuation { continuation in
            exportQueue.async {
                do {
                    let outputURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension("mov")
                    let result = try self.makeClip(from: plan, outputURL: outputURL)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func makeClip(from plan: RollingClipPlan, outputURL: URL) throws -> (url: URL, duration: Double, frameCount: Int) {
        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExperimentalClipAssemblerError.missingVideoTrack
        }

        let clipStart = plan.captureWallClockTime - plan.actualPreDuration
        let clipEnd = plan.captureWallClockTime + plan.actualPostDuration
        var insertTime = CMTime.zero
        var exportFrameCount = 0
        var preferredTransform: CGAffineTransform?

        for segment in plan.segments.sorted(by: { $0.startWallClockTime < $1.startWallClockTime }) {
            let overlapStart = max(clipStart, segment.startWallClockTime)
            let overlapEnd = min(clipEnd, segment.endWallClockTime)
            guard overlapEnd > overlapStart else {
                continue
            }

            let asset = AVURLAsset(url: segment.url)
            guard let track = asset.tracks(withMediaType: .video).first else {
                continue
            }

            if preferredTransform == nil {
                preferredTransform = track.preferredTransform
            }

            let assetDurationSeconds = asset.duration.seconds.isFinite ? asset.duration.seconds : max(segment.endWallClockTime - segment.startWallClockTime, 0)
            let overlapDurationSeconds = overlapEnd - overlapStart
            let localStartSeconds = max(0.0, overlapStart - segment.startWallClockTime)
            let localEndSeconds = min(assetDurationSeconds, localStartSeconds + overlapDurationSeconds)
            let localDurationSeconds = max(0.0, localEndSeconds - localStartSeconds)
            guard localDurationSeconds > 0 else {
                continue
            }

            let timeRange = CMTimeRange(
                start: CMTime(seconds: localStartSeconds, preferredTimescale: 600),
                duration: CMTime(seconds: localDurationSeconds, preferredTimescale: 600)
            )
            try compositionTrack.insertTimeRange(timeRange, of: track, at: insertTime)
            insertTime = CMTimeAdd(insertTime, timeRange.duration)
            exportFrameCount += Int((Double(segment.nominalFrameRate) * localDurationSeconds).rounded())
        }

        guard insertTime > .zero else {
            throw ExperimentalClipAssemblerError.emptyComposition
        }

        compositionTrack.preferredTransform = preferredTransform ?? .identity

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw ExperimentalClipAssemblerError.exportSessionCreationFailed
        }
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mov
        exportSession.shouldOptimizeForNetworkUse = false

        let semaphore = DispatchSemaphore(value: 0)
        exportSession.exportAsynchronously {
            semaphore.signal()
        }
        semaphore.wait()

        if let error = exportSession.error {
            throw error
        }

        let duration = composition.duration.seconds.isFinite ? composition.duration.seconds : 0.0
        return (outputURL, duration, exportFrameCount)
    }
}

import AVFoundation
import Foundation

struct CaptureDiagnosticsSnapshot: Equatable {
    var cameraFPS: Double?
    var bufferFPS: Double?
    var exportedFPS: Float?
    var exportedFrameCount: Int?
    var exportedDuration: Double?
    var exportedSourceFrameCount: Int?
    var exportedSourceDuration: Double?

    var debugLine: String {
        let cameraText = formatted(cameraFPS)
        let bufferText = formatted(bufferFPS)
        let outputText = exportedFPS.map { String(format: "%.2f", $0) } ?? "--"
        let sourceFramesText = exportedSourceFrameCount.map(String.init) ?? "--"
        let sourceDurationText = exportedSourceDuration.map { String(format: "%.2f", $0) } ?? "--"
        let outputFramesText = exportedFrameCount.map(String.init) ?? "--"
        let outputDurationText = exportedDuration.map { String(format: "%.2f", $0) } ?? "--"
        return "cam=\(cameraText) buf=\(bufferText) out=\(outputText) src=\(sourceFramesText)/\(sourceDurationText)s file=\(outputFramesText)/\(outputDurationText)s"
    }

    private func formatted(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.1f", value)
    }
}

final class CaptureDiagnostics {
    private let queue = DispatchQueue(label: "livephoto.capture-diagnostics")

    private var snapshot = CaptureDiagnosticsSnapshot()
    private var callbackWindowStart: TimeInterval?
    private var callbackCount = 0
    private var acceptedCount = 0

    var onSnapshotUpdated: ((CaptureDiagnosticsSnapshot) -> Void)?

    func recordVideoCallback(accepted: Bool, at wallClockTime: TimeInterval) {
        queue.async {
            if self.callbackWindowStart == nil {
                self.callbackWindowStart = wallClockTime
            }

            self.callbackCount += 1
            if accepted {
                self.acceptedCount += 1
            }

            guard let callbackWindowStart = self.callbackWindowStart,
                  (wallClockTime - callbackWindowStart) >= 1.0
            else {
                return
            }

            let elapsed = max(wallClockTime - callbackWindowStart, 0.001)
            self.snapshot.cameraFPS = Double(self.callbackCount) / elapsed
            self.snapshot.bufferFPS = Double(self.acceptedCount) / elapsed
            self.callbackWindowStart = wallClockTime
            self.callbackCount = 0
            self.acceptedCount = 0
            self.publishSnapshot()
        }
    }

    func recordExport(
        url: URL,
        sourceFrameCount: Int?,
        sourceDuration: Double?
    ) {
        queue.async {
            let asset = AVURLAsset(url: url)
            let videoTrack = asset.tracks(withMediaType: .video).first
            self.snapshot.exportedFPS = videoTrack?.nominalFrameRate
            self.snapshot.exportedFrameCount = videoTrack.map { Int($0.nominalFrameRate * Float(asset.duration.seconds)) }
            self.snapshot.exportedDuration = asset.duration.seconds.isFinite ? asset.duration.seconds : nil
            self.snapshot.exportedSourceFrameCount = sourceFrameCount
            self.snapshot.exportedSourceDuration = sourceDuration
            self.publishSnapshot()
        }
    }

    private func publishSnapshot() {
        let snapshot = self.snapshot
        DispatchQueue.main.async {
            self.onSnapshotUpdated?(snapshot)
        }
    }
}

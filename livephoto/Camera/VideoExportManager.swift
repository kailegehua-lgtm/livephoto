@preconcurrency import AVFoundation
import Foundation

final class VideoExportManager {
    private let exportQueue = DispatchQueue(label: "livephoto.video-export")
    private let composer = MomentVideoComposer()

    func composeExperimentalClip(
        preRoll: BufferedMediaSnapshot,
        postRoll: BufferedMediaSnapshot
    ) async throws -> (url: URL, duration: Double) {
        try await withCheckedThrowingContinuation { continuation in
            exportQueue.async { [composer] in
                let outputURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("mov")
                do {
                    let duration = try composer.compose(snapshot: preRoll, postRoll: postRoll, outputURL: outputURL)
                    continuation.resume(returning: (outputURL, duration))
                } catch {
                    if FileManager.default.fileExists(atPath: outputURL.path) {
                        try? FileManager.default.removeItem(at: outputURL)
                    }
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

@preconcurrency import AVFoundation
import Foundation

final class VideoExportManager {
    private let experimentalAssembler = ExperimentalClipAssembler()

    func composeExperimentalClip(from plan: RollingClipPlan) async throws -> (url: URL, duration: Double, frameCount: Int) {
        try await experimentalAssembler.assembleClip(from: plan)
    }
}

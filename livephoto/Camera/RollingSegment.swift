import Foundation

struct RollingSegment: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let startWallClockTime: TimeInterval
    let endWallClockTime: TimeInterval
    let frameCount: Int
    let nominalFrameRate: Float
    let isFinalized: Bool
}

struct RollingClipPlan {
    let segments: [RollingSegment]
    let captureWallClockTime: TimeInterval
    let actualPreDuration: Double
    let actualPostDuration: Double
}

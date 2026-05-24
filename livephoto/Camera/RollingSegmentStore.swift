import Foundation

final class RollingSegmentStore {
    private let fileManager = FileManager.default
    private let retentionWindowSeconds: Double

    private(set) var sessionID = UUID()
    private(set) var sessionDirectoryURL: URL?
    private(set) var segments: [RollingSegment] = []

    init(retentionWindowSeconds: Double = 4.5) {
        self.retentionWindowSeconds = retentionWindowSeconds
    }

    func startNewSession() throws {
        reset(removeFiles: true)

        sessionID = UUID()
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rolling-cache", isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        sessionDirectoryURL = directoryURL
    }

    func makeSegmentURL() throws -> URL {
        guard let sessionDirectoryURL else {
            throw CocoaError(.fileNoSuchFile)
        }

        return sessionDirectoryURL
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
    }

    func registerFinalizedSegment(_ segment: RollingSegment) {
        segments.append(segment)
        segments.sort { $0.startWallClockTime < $1.startWallClockTime }
        trimExpiredSegments(latestWallClockTime: segment.endWallClockTime)
    }

    func segments(overlapping range: ClosedRange<TimeInterval>) -> [RollingSegment] {
        segments.filter { segment in
            segment.endWallClockTime >= range.lowerBound && segment.startWallClockTime <= range.upperBound
        }
    }

    func availableDuration(activeStart: TimeInterval?, activeLatest: TimeInterval?) -> Double {
        let finalizedStart = segments.first?.startWallClockTime
        let finalizedEnd = segments.last?.endWallClockTime

        let oldestStart: TimeInterval?
        if let finalizedStart, let activeStart {
            oldestStart = min(finalizedStart, activeStart)
        } else {
            oldestStart = finalizedStart ?? activeStart
        }

        let latestEnd: TimeInterval?
        if let finalizedEnd, let activeLatest {
            latestEnd = max(finalizedEnd, activeLatest)
        } else {
            latestEnd = finalizedEnd ?? activeLatest
        }

        guard let oldestStart, let latestEnd else {
            return 0.0
        }
        return max(0.0, latestEnd - oldestStart)
    }

    func reset(removeFiles: Bool) {
        if removeFiles, let sessionDirectoryURL, fileManager.fileExists(atPath: sessionDirectoryURL.path) {
            try? fileManager.removeItem(at: sessionDirectoryURL)
        }
        sessionDirectoryURL = nil
        segments = []
    }

    private func trimExpiredSegments(latestWallClockTime: TimeInterval) {
        let cutoff = latestWallClockTime - retentionWindowSeconds
        let expired = segments.filter { $0.endWallClockTime < cutoff }
        segments.removeAll { $0.endWallClockTime < cutoff }
        expired.forEach { expiredSegment in
            if fileManager.fileExists(atPath: expiredSegment.url.path) {
                try? fileManager.removeItem(at: expiredSegment.url)
            }
        }
    }
}

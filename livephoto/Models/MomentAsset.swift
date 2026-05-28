import Foundation

enum CaptureMode: String, Codable, Identifiable {
    case rollingReplay

    var id: String { rawValue }

    var title: String {
        "动态回溯"
    }

    var summary: String {
        "前 3 秒 + 后 1 秒滚动编码回溯"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)

        switch rawValue {
        case Self.rollingReplay.rawValue, "stablePostRoll", "experimentalPreRoll":
            self = .rollingReplay
        default:
            self = .rollingReplay
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum MomentStatus: String, Codable {
    case captured
    case processing
    case ready
    case failed

    var title: String {
        switch self {
        case .captured:
            return "已抓拍"
        case .processing:
            return "处理中"
        case .ready:
            return "可播放"
        case .failed:
            return "失败"
        }
    }
}

struct MomentAsset: Codable, Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let photoURL: URL
    let videoURL: URL
    let captureMode: CaptureMode
    let status: MomentStatus
    let preDuration: Double
    let postDuration: Double
    let coverTimestamp: Double
    let duration: Double
    let width: Int
    let height: Int

    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case photoURL
        case videoURL
        case captureMode
        case status
        case preDuration
        case postDuration
        case coverTimestamp
        case duration
        case width
        case height
    }

    init(
        id: UUID,
        createdAt: Date,
        photoURL: URL,
        videoURL: URL,
        captureMode: CaptureMode,
        status: MomentStatus,
        preDuration: Double,
        postDuration: Double,
        coverTimestamp: Double,
        duration: Double,
        width: Int,
        height: Int
    ) {
        self.id = id
        self.createdAt = createdAt
        self.photoURL = photoURL
        self.videoURL = videoURL
        self.captureMode = captureMode
        self.status = status
        self.preDuration = preDuration
        self.postDuration = postDuration
        self.coverTimestamp = coverTimestamp
        self.duration = duration
        self.width = width
        self.height = height
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        photoURL = try container.decode(URL.self, forKey: .photoURL)
        videoURL = try container.decode(URL.self, forKey: .videoURL)
        captureMode = try container.decodeIfPresent(CaptureMode.self, forKey: .captureMode) ?? .rollingReplay
        status = try container.decodeIfPresent(MomentStatus.self, forKey: .status) ?? .ready
        preDuration = try container.decode(Double.self, forKey: .preDuration)
        postDuration = try container.decode(Double.self, forKey: .postDuration)
        coverTimestamp = try container.decode(Double.self, forKey: .coverTimestamp)
        duration = try container.decode(Double.self, forKey: .duration)
        width = try container.decode(Int.self, forKey: .width)
        height = try container.decode(Int.self, forKey: .height)
    }

    var displayDurationBreakdown: (pre: Int, post: Int) {
        let totalSeconds = max(Int(duration.rounded()), 0)
        let roundedPreSeconds = max(Int(coverTimestamp.rounded()), 0)

        guard totalSeconds > 0 else {
            return (
                pre: max(Int(preDuration.rounded()), 0),
                post: max(Int(postDuration.rounded()), 0)
            )
        }

        let preSeconds = min(roundedPreSeconds, totalSeconds)
        let postSeconds = max(totalSeconds - preSeconds, 0)
        return (pre: preSeconds, post: postSeconds)
    }
}

import Foundation

enum CaptureMode: String, Codable, CaseIterable, Identifiable {
    case stablePostRoll
    case experimentalPreRoll

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stablePostRoll:
            return "稳定模式"
        case .experimentalPreRoll:
            return "实验模式"
        }
    }

    var summary: String {
        switch self {
        case .stablePostRoll:
            return "主图 + 后 1 秒片段"
        case .experimentalPreRoll:
            return "前 3 秒 + 后 1 秒低帧率回溯"
        }
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
        captureMode = try container.decodeIfPresent(CaptureMode.self, forKey: .captureMode) ?? .stablePostRoll
        status = try container.decodeIfPresent(MomentStatus.self, forKey: .status) ?? .ready
        preDuration = try container.decode(Double.self, forKey: .preDuration)
        postDuration = try container.decode(Double.self, forKey: .postDuration)
        coverTimestamp = try container.decode(Double.self, forKey: .coverTimestamp)
        duration = try container.decode(Double.self, forKey: .duration)
        width = try container.decode(Int.self, forKey: .width)
        height = try container.decode(Int.self, forKey: .height)
    }
}

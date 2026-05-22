import SwiftUI

struct MomentListView: View {
    @EnvironmentObject private var store: MomentStore

    var body: some View {
        NavigationStack {
            List(store.moments) { moment in
                NavigationLink {
                    MomentDetailView(moment: moment)
                } label: {
                    HStack(spacing: 12) {
                        Group {
                            if let image = PreviewImageLoader.loadImage(from: moment.photoURL) {
                                image
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                Color.gray.opacity(0.25)
                            }
                        }
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                        VStack(alignment: .leading, spacing: 6) {
                            Text(moment.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.headline)
                            Text(summaryText(for: moment))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                Text(modeTag(for: moment))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(moment.status.title)
                                    .font(.caption)
                                    .foregroundStyle(statusColor(for: moment.status))
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .overlay {
                if store.moments.isEmpty {
                    ContentUnavailableView(
                        "还没有动态照片",
                        systemImage: "sparkles.tv",
                        description: Text("拍摄后会在这里显示。")
                    )
                }
            }
            .navigationTitle("我的动态照片")
        }
    }

    private func summaryText(for moment: MomentAsset) -> String {
        if moment.preDuration > 0 {
            return "前 \(Int(moment.preDuration)) 秒 + 后 \(Int(moment.postDuration)) 秒"
        }

        return "主图 + 后 \(Int(moment.postDuration)) 秒片段"
    }

    private func modeTag(for moment: MomentAsset) -> String {
        switch moment.captureMode {
        case .stablePostRoll:
            return "稳定模式"
        case .experimentalPreRoll:
            return "实验模式"
        }
    }

    private func statusColor(for status: MomentStatus) -> Color {
        switch status {
        case .captured:
            return .yellow
        case .processing:
            return .orange
        case .ready:
            return .green
        case .failed:
            return .red
        }
    }
}

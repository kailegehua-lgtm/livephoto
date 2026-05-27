import AVKit
import SwiftUI

struct MomentDetailView: View {
    let moment: MomentAsset

    @State private var player: AVPlayer?
    @State private var isPressing = false

    var body: some View {
        ZStack {
            if isPressing, let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea(edges: .bottom)
            } else if let image = PreviewImageLoader.loadImage(from: moment.photoURL) {
                image
                    .resizable()
                    .scaledToFit()
                    .background(Color.black)
            } else {
                Color.black
            }
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("动态照片")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Text(footerText)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.black.opacity(0.5), in: Capsule())
                .padding(.bottom, 12)
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isPressing else { return }
                    startPlayback()
                }
                .onEnded { _ in
                    stopPlayback()
                }
        )
        .onDisappear {
            stopPlayback()
        }
    }

    private func startPlayback() {
        guard moment.status == .ready else {
            return
        }

        guard FileManager.default.fileExists(atPath: moment.videoURL.path) else {
            return
        }

        let player = AVPlayer(url: moment.videoURL)
        self.player = player
        self.isPressing = true
        player.seek(to: .zero)
        player.play()
    }

    private func stopPlayback() {
        player?.pause()
        player = nil
        isPressing = false
    }

    private var footerText: String {
        let breakdown = moment.displayDurationBreakdown

        switch moment.status {
        case .captured, .processing:
            return "动态片段处理中，完成后可长按查看"
        case .failed:
            return "动态片段导出失败，仅保留主图"
        case .ready:
            return breakdown.pre > 0
                ? "长按查看前 \(breakdown.pre) 秒 + 后 \(breakdown.post) 秒片段"
                : "长按查看拍照后的 \(breakdown.post) 秒片段"
        }
    }
}

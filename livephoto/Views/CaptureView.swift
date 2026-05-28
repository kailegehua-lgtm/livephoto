import SwiftUI

struct CaptureView: View {
    @ObservedObject var viewModel: CaptureViewModel
    @State private var isInfoPresented = false
    @State private var transientFailureMessage: String?
    @State private var failureHintTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreviewView(session: viewModel.cameraManager.session)
                .ignoresSafeArea(edges: .top)
                .overlay(alignment: .top) {
                    LinearGradient(
                        colors: [.black.opacity(0.5), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 180)
                    .allowsHitTesting(false)
                }
                .overlay(alignment: .bottom) {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.18), .black.opacity(0.72)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 240)
                    .allowsHitTesting(false)
                }

            VStack(spacing: 0) {
                topBar

                if let banner = permissionBannerText {
                    bannerView(text: banner, color: .red.opacity(0.82))
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                }

                Spacer()

                VStack(spacing: 16) {
                    if viewModel.isCapturing {
                        statusPill(
                            title: "正在拍摄",
                            message: "正在抓取当前瞬间",
                            tint: .white
                        )
                    } else if viewModel.isBackgroundProcessing {
                        statusPill(
                            title: "后台处理中",
                            message: "可切到列表继续查看，导出会继续完成",
                            tint: .orange
                        )
                    } else {
                        statusPill(
                            title: preRollReadinessTitle,
                            message: preRollReadinessMessage,
                            tint: preRollReadinessColor
                        )
                    }

                    if let transientFailureMessage {
                        bannerView(text: transientFailureMessage, color: .red.opacity(0.88))
                    }

                    if let errorMessage = viewModel.errorMessage {
                        bannerView(text: errorMessage, color: .red.opacity(0.88))
                    }

                    shutterButton
                        .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity)
                .background(
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.2), .black.opacity(0.82)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
        }
        .sheet(isPresented: $isInfoPresented) {
            infoSheet
        }
        .onAppear {
            viewModel.prepare()
        }
        .onChange(of: viewModel.latestMoment?.status) { _, newStatus in
            guard newStatus == .failed else { return }
            showTransientFailureMessage("动态片段导出失败，已保留主图")
        }
    }

    private var topBar: some View {
        HStack {
            Spacer()

            Button {
                isInfoPresented = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.black.opacity(0.38), in: Circle())
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }

    private var shutterButton: some View {
        Button(action: viewModel.capture) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.95), lineWidth: 6)
                    .frame(width: 84, height: 84)

                Circle()
                    .fill(viewModel.isCapturing ? Color.white.opacity(0.45) : Color.white)
                    .frame(width: 68, height: 68)
                    .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
            }
        }
        .disabled(
            viewModel.isCapturing ||
            viewModel.authorizationState != .authorized ||
            viewModel.availablePreRollSeconds < 2.7
        )
    }

    private func statusPill(title: String, message: String, tint: Color) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)

            Text(message)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.92))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.44), in: Capsule())
    }

    private func bannerView(text: String, color: Color) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(color, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var infoSheet: some View {
        NavigationStack {
            List {
                Section("拍摄方式") {
                    Text("点击快门后会保留主图，并导出当前瞬间前 3 秒与后 1 秒的动态片段。")
                    Text("导出开始后可以直接切到照片列表，后台处理会继续完成。")
                }

                Section("拍摄准备") {
                    Text("开始拍摄前需要先完成相机与动态片段链路预热，并积累至少 2.7 秒可导出的回溯片段，按钮才会进入可点击状态。")
                    Text("首次安装后第一次进入可能需要等待更久，这是在后台完成预热。")
                }
            }
            .navigationTitle("拍摄说明")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        isInfoPresented = false
                    }
                }
            }
        }
    }

    private var preRollReadinessTitle: String {
        viewModel.availablePreRollSeconds >= 2.7 ? "已就绪" : "预热中"
    }

    private var preRollReadinessMessage: String {
        let bufferedSeconds = String(format: "%.1f", viewModel.availablePreRollSeconds)
        if viewModel.availablePreRollSeconds >= 2.7 {
            return "已完成预热并缓存 \(bufferedSeconds) 秒，点击即可拍摄"
        }
        return "正在预热相机与动态片段链路 \(bufferedSeconds) / 2.7 秒"
    }

    private var preRollReadinessColor: Color {
        viewModel.availablePreRollSeconds >= 2.7 ? .green : .orange
    }

    private var permissionBannerText: String? {
        switch viewModel.authorizationState {
        case .denied:
            return "需要开启相机和麦克风权限后才能拍摄。"
        case .restricted:
            return "当前设备受系统限制，无法使用相机或麦克风。"
        case .unsupported:
            return "模拟器不支持这套相机采集链路，请改用真机调试。"
        case .unavailable:
            return "当前相机链路初始化失败，请重启 App 后重试。"
        case .unknown, .authorized:
            return nil
        }
    }

    private func showTransientFailureMessage(_ message: String) {
        failureHintTask?.cancel()
        transientFailureMessage = message
        failureHintTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                transientFailureMessage = nil
            }
        }
    }
}

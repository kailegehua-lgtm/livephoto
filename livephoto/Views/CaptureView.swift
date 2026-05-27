import SwiftUI

struct CaptureView: View {
    @StateObject private var viewModel: CaptureViewModel

    init(store: MomentStore) {
        _viewModel = StateObject(wrappedValue: CaptureViewModel(store: store))
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                CameraPreviewView(session: viewModel.cameraManager.session)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .allowsHitTesting(false)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 140)
                    .background(Color.black)

                VStack(spacing: 16) {
                    Picker("拍摄模式", selection: $viewModel.selectedMode) {
                        ForEach(CaptureMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .onChange(of: viewModel.selectedMode) { _, newMode in
                        viewModel.updateCaptureMode(newMode)
                    }

                    Text(viewModel.selectedMode.summary)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.82))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.45), in: Capsule())
                        .allowsHitTesting(false)

                    if viewModel.authorizationState == .denied {
                        Text("需要开启相机和麦克风权限后才能拍摄。")
                            .foregroundStyle(.white)
                            .padding()
                            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
                            .allowsHitTesting(false)
                    }

                    if viewModel.authorizationState == .restricted {
                        Text("当前设备受系统限制，无法使用相机或麦克风。")
                            .foregroundStyle(.white)
                            .padding()
                            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
                            .allowsHitTesting(false)
                    }

                    if viewModel.authorizationState == .unsupported {
                        Text("模拟器不支持这套相机采集链路，请改用真机调试。")
                            .foregroundStyle(.white)
                            .padding()
                            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
                            .allowsHitTesting(false)
                    }

                    if viewModel.authorizationState == .unavailable {
                        Text("当前相机链路初始化失败，请重启 App 后重试。")
                            .foregroundStyle(.white)
                            .padding()
                            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
                            .allowsHitTesting(false)
                    }

                    if viewModel.selectedMode == .experimentalPreRoll {
                        Text("实验模式会启用前 3 秒滚动编码缓存，并在拍摄后补齐后 1 秒片段。当前已缓存 \(viewModel.availablePreRollSeconds, specifier: "%.1f") 秒。")
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.orange.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
                            .allowsHitTesting(false)
                    }

                    if let latestMoment = viewModel.latestMoment {
                        VStack(spacing: 6) {
                            Text("拍摄成功，已保存到列表：\(latestMoment.createdAt.formatted(date: .omitted, time: .standard))")
                            Text(statusText(for: latestMoment))
                                .font(.caption)
                                .foregroundStyle(statusColor(for: latestMoment.status))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 16))
                        .allowsHitTesting(false)
                    }

                    if viewModel.isCapturing {
                        Text("正在抓取拍摄窗口...")
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.black.opacity(0.65), in: Capsule())
                            .allowsHitTesting(false)
                    }

                    if viewModel.isBackgroundProcessing {
                        Text("已加入后台处理，可继续拍摄或去列表查看结果")
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.black.opacity(0.65), in: Capsule())
                            .allowsHitTesting(false)
                    }

                    if let errorMessage = viewModel.errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
                            .allowsHitTesting(false)
                    }

                    if let stateLine = debugStateLine {
                        Text(stateLine)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.white.opacity(0.86))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.black.opacity(0.55), in: Capsule())
                            .allowsHitTesting(false)
                    }

                    Button(action: viewModel.capture) {
                        Circle()
                            .fill(viewModel.isCapturing ? Color.gray : Color.white)
                            .frame(width: 78, height: 78)
                            .overlay {
                                Circle()
                                    .stroke(Color.black.opacity(0.15), lineWidth: 6)
                            }
                    }
                    .disabled(
                        viewModel.isCapturing ||
                        viewModel.authorizationState != .authorized
                    )
                    .padding(.bottom, 28)
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("拍摄")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            viewModel.prepare()
        }
        .onDisappear {
            viewModel.stop()
        }
    }

    private func statusText(for moment: MomentAsset) -> String {
        switch moment.status {
        case .captured:
            return "主图已保存，等待后台处理"
        case .processing:
            return "后台处理中，可继续拍摄或去列表查看"
        case .ready:
            return "动态片段已就绪，可去列表查看"
        case .failed:
            return "动态片段导出失败，已保留主图"
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

    private var debugStateLine: String? {
        let statePrefix: String
        if let latestMoment = viewModel.latestMoment {
            statePrefix = "cap=\(viewModel.isCapturing ? 1 : 0) bg=\(viewModel.isBackgroundProcessing ? 1 : 0) phase=\(viewModel.processingPhase) status=\(latestMoment.status.rawValue) mode=\(latestMoment.captureMode.rawValue)"
        } else {
            statePrefix = "cap=\(viewModel.isCapturing ? 1 : 0) bg=\(viewModel.isBackgroundProcessing ? 1 : 0) phase=\(viewModel.processingPhase) latest=nil"
        }

        if let diagnosticsLine = viewModel.diagnosticsLine {
            return "\(statePrefix) \(diagnosticsLine)"
        }
        return statePrefix
    }
}

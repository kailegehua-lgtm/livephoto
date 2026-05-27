import Photos
import SwiftUI

enum PhotoLibraryExportError: LocalizedError {
    case accessDenied
    case nothingToExport

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "没有系统相册写入权限。"
        case .nothingToExport:
            return "所选内容没有可保存的照片或视频。"
        }
    }
}

struct PhotoLibraryExportResult {
    let photoCount: Int
    let videoCount: Int
}

@MainActor
final class PhotoLibraryExporter {
    func export(moments: [MomentAsset]) async throws -> PhotoLibraryExportResult {
        let authorized = await requestAddOnlyAccessIfNeeded()
        guard authorized else {
            throw PhotoLibraryExportError.accessDenied
        }

        let exportable = moments.filter { moment in
            FileManager.default.fileExists(atPath: moment.photoURL.path) ||
            (moment.status == .ready && FileManager.default.fileExists(atPath: moment.videoURL.path))
        }
        guard !exportable.isEmpty else {
            throw PhotoLibraryExportError.nothingToExport
        }

        let photoCount = exportable.reduce(into: 0) { count, moment in
            if FileManager.default.fileExists(atPath: moment.photoURL.path) {
                count += 1
            }
        }
        let videoCount = exportable.reduce(into: 0) { count, moment in
            if moment.status == .ready, FileManager.default.fileExists(atPath: moment.videoURL.path) {
                count += 1
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                for moment in exportable {
                    if FileManager.default.fileExists(atPath: moment.photoURL.path) {
                        PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: moment.photoURL)
                    }
                    if moment.status == .ready, FileManager.default.fileExists(atPath: moment.videoURL.path) {
                        PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: moment.videoURL)
                    }
                }
            } completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: PhotoLibraryExportError.nothingToExport)
                }
            }
        }

        return PhotoLibraryExportResult(photoCount: photoCount, videoCount: videoCount)
    }

    private func requestAddOnlyAccessIfNeeded() async -> Bool {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch current {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            return status == .authorized || status == .limited
        default:
            return false
        }
    }
}

struct MomentListView: View {
    @EnvironmentObject private var store: MomentStore

    @State private var isSelectionMode = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var isWorking = false
    @State private var alertMessage: String?

    private let exporter = PhotoLibraryExporter()

    var body: some View {
        NavigationStack {
            List(store.moments) { moment in
                if isSelectionMode {
                    Button {
                        toggleSelection(for: moment.id)
                    } label: {
                        selectionRow(for: moment)
                    }
                    .buttonStyle(.plain)
                } else {
                    NavigationLink {
                        MomentDetailView(moment: moment)
                    } label: {
                        contentRow(for: moment)
                    }
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
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if isSelectionMode {
                        Button("取消") {
                            exitSelectionMode()
                        }
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    if !store.moments.isEmpty {
                        Button(isSelectionMode ? "全选" : "选择") {
                            if isSelectionMode {
                                selectAll()
                            } else {
                                isSelectionMode = true
                            }
                        }
                        .disabled(isWorking)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if isSelectionMode {
                    selectionActionBar
                }
            }
            .alert("操作结果", isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(alertMessage ?? "")
            }
        }
    }

    private var selectionActionBar: some View {
        HStack(spacing: 12) {
            Text(selectedIDs.isEmpty ? "请选择要操作的项目" : "已选择 \(selectedIDs.count) 项")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer()

            Button("保存到相册") {
                saveSelectionToPhotoLibrary()
            }
            .disabled(selectedIDs.isEmpty || isWorking)

            Button("删除") {
                deleteSelection()
            }
            .foregroundStyle(.red)
            .disabled(selectedIDs.isEmpty || isWorking)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private func contentRow(for moment: MomentAsset) -> some View {
        HStack(spacing: 12) {
            thumbnail(for: moment)

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

    private func selectionRow(for moment: MomentAsset) -> some View {
        HStack(spacing: 12) {
            Image(systemName: selectedIDs.contains(moment.id) ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selectedIDs.contains(moment.id) ? .blue : .secondary)
                .font(.title3)

            contentRow(for: moment)
        }
        .contentShape(Rectangle())
    }

    private func thumbnail(for moment: MomentAsset) -> some View {
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
    }

    private func toggleSelection(for id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func selectAll() {
        if selectedIDs.count == store.moments.count {
            selectedIDs.removeAll()
        } else {
            selectedIDs = Set(store.moments.map(\.id))
        }
    }

    private func exitSelectionMode() {
        isSelectionMode = false
        selectedIDs.removeAll()
    }

    private func deleteSelection() {
        let ids = selectedIDs
        guard !ids.isEmpty else { return }

        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await store.deleteMoments(ids: ids)
                alertMessage = "已删除 \(ids.count) 项。"
                exitSelectionMode()
            } catch {
                alertMessage = "删除失败：\(error.localizedDescription)"
            }
        }
    }

    private func saveSelectionToPhotoLibrary() {
        let selectedMoments = store.moments.filter { selectedIDs.contains($0.id) }
        guard !selectedMoments.isEmpty else { return }

        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let result = try await exporter.export(moments: selectedMoments)
                alertMessage = saveResultMessage(result: result)
                exitSelectionMode()
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    private func saveResultMessage(result: PhotoLibraryExportResult) -> String {
        switch (result.photoCount, result.videoCount) {
        case let (photos, videos) where photos > 0 && videos > 0:
            return "已保存 \(photos) 张照片和 \(videos) 个视频到系统相册。"
        case let (photos, _) where photos > 0:
            return "已保存 \(photos) 张照片到系统相册。"
        case let (_, videos) where videos > 0:
            return "已保存 \(videos) 个视频到系统相册。"
        default:
            return "没有可保存的内容。"
        }
    }

    private func summaryText(for moment: MomentAsset) -> String {
        let breakdown = moment.displayDurationBreakdown

        if breakdown.pre > 0 {
            return "前 \(breakdown.pre) 秒 + 后 \(breakdown.post) 秒"
        }

        return "主图 + 后 \(breakdown.post) 秒片段"
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

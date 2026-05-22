import Foundation
import SwiftUI

enum MomentStoreError: Error {
    case momentNotFound
    case statusConflict(expected: MomentStatus, actual: MomentStatus)
}

private actor MomentFileWorker {
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
    private let decoder = JSONDecoder()

    func loadIndex(from indexURL: URL) throws -> [MomentAsset] {
        let data = try Data(contentsOf: indexURL)
        return try decoder.decode([MomentAsset].self, from: data)
    }

    func createMoment(
        asset: MomentAsset,
        photoData: Data,
        indexMoments: [MomentAsset],
        momentsDirectory: URL
    ) throws {
        let folderURL = momentsDirectory.appendingPathComponent(asset.id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)

        do {
            try photoData.write(to: asset.photoURL, options: .atomic)
            try persistIndex(indexMoments, to: momentsDirectory)
        } catch {
            try? fileManager.removeItem(at: folderURL)
            throw error
        }
    }

    func updateMoment(
        sourceVideoURL: URL?,
        destinationVideoURL: URL,
        indexMoments: [MomentAsset],
        momentsDirectory: URL
    ) throws {
        var copiedVideo = false
        if let sourceVideoURL {
            if fileManager.fileExists(atPath: destinationVideoURL.path) {
                try fileManager.removeItem(at: destinationVideoURL)
            }
            try fileManager.copyItem(at: sourceVideoURL, to: destinationVideoURL)
            copiedVideo = true
        }

        do {
            try persistIndex(indexMoments, to: momentsDirectory)
        } catch {
            if copiedVideo, fileManager.fileExists(atPath: destinationVideoURL.path) {
                try? fileManager.removeItem(at: destinationVideoURL)
            }
            throw error
        }

        if let sourceVideoURL, copiedVideo {
            try? fileManager.removeItem(at: sourceVideoURL)
        }
    }

    func removeTemporaryItemIfExists(at url: URL) {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        try? fileManager.removeItem(at: url)
    }

    private func persistIndex(_ moments: [MomentAsset], to momentsDirectory: URL) throws {
        if !fileManager.fileExists(atPath: momentsDirectory.path) {
            try fileManager.createDirectory(at: momentsDirectory, withIntermediateDirectories: true)
        }
        let data = try encoder.encode(moments)
        let indexURL = momentsDirectory.appendingPathComponent("index.json")
        try data.write(to: indexURL, options: .atomic)
    }
}

@MainActor
final class MomentStore: ObservableObject {
    @Published private(set) var moments: [MomentAsset] = []

    private let fileManager = FileManager.default
    private let fileWorker = MomentFileWorker()

    init() {
        Task { [weak self] in
            await self?.load()
        }
    }

    func createMoment(
        photoData: Data,
        size: CGSize,
        captureMode: CaptureMode,
        status: MomentStatus,
        preDuration: Double,
        postDuration: Double,
        coverTimestamp: Double
    ) async throws -> MomentAsset {
        let id = UUID()
        let folderURL = momentsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        let asset = MomentAsset(
            id: id,
            createdAt: Date(),
            photoURL: folderURL.appendingPathComponent("cover.jpg"),
            videoURL: folderURL.appendingPathComponent("motion.mov"),
            captureMode: captureMode,
            status: status,
            preDuration: preDuration,
            postDuration: postDuration,
            coverTimestamp: coverTimestamp,
            duration: 0.0,
            width: Int(size.width),
            height: Int(size.height)
        )

        let updatedMoments = [asset] + moments
        try await fileWorker.createMoment(
            asset: asset,
            photoData: photoData,
            indexMoments: updatedMoments,
            momentsDirectory: momentsDirectory
        )

        moments = updatedMoments
        return asset
    }

    func updateMoment(
        id: UUID,
        videoURL: URL?,
        status: MomentStatus,
        duration: Double,
        preDuration: Double,
        postDuration: Double,
        coverTimestamp: Double
    ) async throws -> MomentAsset {
        guard let index = moments.firstIndex(where: { $0.id == id }) else {
            throw MomentStoreError.momentNotFound
        }

        let current = moments[index]
        let updated = MomentAsset(
            id: current.id,
            createdAt: current.createdAt,
            photoURL: current.photoURL,
            videoURL: current.videoURL,
            captureMode: current.captureMode,
            status: status,
            preDuration: preDuration,
            postDuration: postDuration,
            coverTimestamp: coverTimestamp,
            duration: duration,
            width: current.width,
            height: current.height
        )

        var updatedMoments = moments
        updatedMoments[index] = updated

        try await fileWorker.updateMoment(
            sourceVideoURL: videoURL,
            destinationVideoURL: current.videoURL,
            indexMoments: updatedMoments,
            momentsDirectory: momentsDirectory
        )

        moments = updatedMoments
        return updated
    }

    func updateMomentIfCurrentStatus(
        id: UUID,
        expectedStatus: MomentStatus,
        videoURL: URL?,
        status: MomentStatus,
        duration: Double,
        preDuration: Double,
        postDuration: Double,
        coverTimestamp: Double
    ) async throws -> MomentAsset {
        guard let existing = moments.first(where: { $0.id == id }) else {
            throw MomentStoreError.momentNotFound
        }
        guard existing.status == expectedStatus else {
            throw MomentStoreError.statusConflict(expected: expectedStatus, actual: existing.status)
        }

        return try await updateMoment(
            id: id,
            videoURL: videoURL,
            status: status,
            duration: duration,
            preDuration: preDuration,
            postDuration: postDuration,
            coverTimestamp: coverTimestamp
        )
    }

    func moment(with id: UUID) -> MomentAsset? {
        moments.first(where: { $0.id == id })
    }

    func removeTemporaryItemIfExists(at url: URL) {
        Task {
            await fileWorker.removeTemporaryItemIfExists(at: url)
        }
    }

    func load() async {
        do {
            moments = try await fileWorker.loadIndex(from: indexURL)
        } catch {
            moments = []
        }
    }

    private var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private var momentsDirectory: URL {
        documentsDirectory.appendingPathComponent("Moments", isDirectory: true)
    }

    private var indexURL: URL {
        momentsDirectory.appendingPathComponent("index.json")
    }
}

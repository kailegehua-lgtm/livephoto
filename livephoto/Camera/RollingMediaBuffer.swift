import AVFoundation
import Foundation

final class RetainedPixelBuffer {
    let pixelBuffer: CVPixelBuffer

    init?(_ sampleBuffer: CMSampleBuffer) {
        guard let sourcePixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let pixelBuffer = Self.makeCopy(of: sourcePixelBuffer)
        else {
            return nil
        }
        self.pixelBuffer = pixelBuffer
    }

    private static func makeCopy(of sourcePixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(sourcePixelBuffer)
        let height = CVPixelBufferGetHeight(sourcePixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(sourcePixelBuffer)

        var copiedPixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            attributes as CFDictionary,
            &copiedPixelBuffer
        )

        guard status == kCVReturnSuccess, let copiedPixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(sourcePixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(copiedPixelBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(copiedPixelBuffer, [])
            CVPixelBufferUnlockBaseAddress(sourcePixelBuffer, .readOnly)
        }

        let planeCount = CVPixelBufferGetPlaneCount(sourcePixelBuffer)
        if planeCount == 0 {
            guard let sourceBaseAddress = CVPixelBufferGetBaseAddress(sourcePixelBuffer),
                  let destinationBaseAddress = CVPixelBufferGetBaseAddress(copiedPixelBuffer)
            else {
                return nil
            }

            let bytesPerRow = CVPixelBufferGetBytesPerRow(sourcePixelBuffer)
            memcpy(destinationBaseAddress, sourceBaseAddress, bytesPerRow * height)
            return copiedPixelBuffer
        }

        for planeIndex in 0..<planeCount {
            guard let sourceBaseAddress = CVPixelBufferGetBaseAddressOfPlane(sourcePixelBuffer, planeIndex),
                  let destinationBaseAddress = CVPixelBufferGetBaseAddressOfPlane(copiedPixelBuffer, planeIndex)
            else {
                return nil
            }

            let sourceBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(sourcePixelBuffer, planeIndex)
            let destinationBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(copiedPixelBuffer, planeIndex)
            let planeHeight = CVPixelBufferGetHeightOfPlane(sourcePixelBuffer, planeIndex)
            let bytesToCopyPerRow = min(sourceBytesPerRow, destinationBytesPerRow)

            for row in 0..<planeHeight {
                let sourceRow = sourceBaseAddress.advanced(by: row * sourceBytesPerRow)
                let destinationRow = destinationBaseAddress.advanced(by: row * destinationBytesPerRow)
                memcpy(destinationRow, sourceRow, bytesToCopyPerRow)
            }
        }

        return copiedPixelBuffer
    }
}

struct BufferedSample {
    let pixelBuffer: RetainedPixelBuffer
    let wallClockTime: TimeInterval
}

struct BufferedMediaSnapshot {
    let videoSamples: [BufferedSample]
    let audioSamples: [BufferedSample]

    var videoDuration: Double {
        guard let first = videoSamples.first?.wallClockTime,
              let last = videoSamples.last?.wallClockTime
        else {
            return 0.0
        }
        return max(0.0, last - first)
    }
}

final class RollingMediaBuffer {
    private let queue = DispatchQueue(label: "livephoto.rolling-buffer")
    private let maxDurationSeconds = 3.6
    private let minVideoFrameIntervalSeconds = 1.0 / 6.0

    private var videoSamples: [BufferedSample] = []
    private var lastAcceptedWallClockTime: TimeInterval?

    var currentVideoDuration: Double {
        queue.sync {
            guard let first = videoSamples.first?.wallClockTime,
                  let last = videoSamples.last?.wallClockTime
            else {
                return 0.0
            }
            return max(0.0, last - first)
        }
    }

    func appendVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        let wallClockTime = ProcessInfo.processInfo.systemUptime
        let shouldAccept = queue.sync { () -> Bool in
            if let lastAcceptedWallClockTime,
               (wallClockTime - lastAcceptedWallClockTime) < minVideoFrameIntervalSeconds {
                return false
            }

            lastAcceptedWallClockTime = wallClockTime
            return true
        }

        guard shouldAccept, let retainedPixelBuffer = RetainedPixelBuffer(sampleBuffer) else {
            return
        }

        queue.async {
            self.videoSamples.append(BufferedSample(pixelBuffer: retainedPixelBuffer, wallClockTime: wallClockTime))
            self.trimSamples(latestWallClockTime: wallClockTime)
        }
    }

    func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
    }

    func snapshot(targetVideoDuration: Double? = nil) -> BufferedMediaSnapshot {
        queue.sync {
            let trimmedSamples: [BufferedSample]
            if let targetVideoDuration {
                trimmedSamples = trimToLastDuration(seconds: targetVideoDuration, from: videoSamples)
            } else {
                trimmedSamples = videoSamples
            }
            return BufferedMediaSnapshot(videoSamples: trimmedSamples, audioSamples: [])
        }
    }

    func reset() {
        queue.sync {
            videoSamples = []
            lastAcceptedWallClockTime = nil
        }
    }

    private func trimToLastDuration(seconds: Double, from samples: [BufferedSample]) -> [BufferedSample] {
        guard let latestWallClockTime = samples.last?.wallClockTime else {
            return []
        }

        let cutoff = latestWallClockTime - seconds
        let trimmed = samples.filter { $0.wallClockTime >= cutoff }
        return trimmed.isEmpty ? samples : trimmed
    }

    private func trimSamples(latestWallClockTime: TimeInterval) {
        let cutoff = latestWallClockTime - maxDurationSeconds
        videoSamples.removeAll { $0.wallClockTime < cutoff }
    }
}

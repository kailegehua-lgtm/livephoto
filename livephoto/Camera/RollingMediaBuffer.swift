import AVFoundation
import Foundation

struct BufferedSample {
    let sampleBuffer: CMSampleBuffer
    let timestamp: CMTime
}

struct BufferedMediaSnapshot {
    let videoSamples: [BufferedSample]
    let audioSamples: [BufferedSample]
}

final class RollingMediaBuffer {
    private let queue = DispatchQueue(label: "livephoto.rolling-buffer")
    private let maxDuration = CMTime(seconds: 3.0, preferredTimescale: 600)
    private let minVideoFrameInterval = CMTime(seconds: 1.0 / 6.0, preferredTimescale: 600)

    private var videoSamples: [BufferedSample] = []
    private var lastAcceptedVideoTimestamp: CMTime?

    func appendVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let shouldAccept = queue.sync { () -> Bool in
            if let lastAcceptedVideoTimestamp,
               CMTimeCompare(CMTimeSubtract(timestamp, lastAcceptedVideoTimestamp), minVideoFrameInterval) < 0 {
                return false
            }

            lastAcceptedVideoTimestamp = timestamp
            return true
        }

        guard shouldAccept, let copiedBuffer = sampleBuffer.deepCopy() else {
            return
        }

        queue.async {
            self.videoSamples.append(BufferedSample(sampleBuffer: copiedBuffer, timestamp: timestamp))
            self.trimSamples(latestTimestamp: timestamp)
        }
    }

    func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
    }

    func snapshot() -> BufferedMediaSnapshot {
        queue.sync {
            BufferedMediaSnapshot(videoSamples: videoSamples, audioSamples: [])
        }
    }

    func reset() {
        queue.sync {
            videoSamples = []
            lastAcceptedVideoTimestamp = nil
        }
    }

    private func trimSamples(latestTimestamp: CMTime) {
        let cutoff = CMTimeSubtract(latestTimestamp, maxDuration)
        videoSamples.removeAll { CMTimeCompare($0.timestamp, cutoff) < 0 }
    }
}

extension CMSampleBuffer {
    func deepCopy() -> CMSampleBuffer? {
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopy(allocator: kCFAllocatorDefault, sampleBuffer: self, sampleBufferOut: &copy)
        guard status == noErr else {
            return nil
        }
        return copy
    }
}

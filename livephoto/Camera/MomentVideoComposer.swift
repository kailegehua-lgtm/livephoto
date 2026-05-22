import AVFoundation
import Foundation

enum MomentVideoComposerError: Error {
    case missingVideoFormat
    case writerSetupFailed
    case appendFailed
    case invalidPixelBuffer
}

final class MomentVideoComposer {
    func compose(snapshot: BufferedMediaSnapshot, postRoll: BufferedMediaSnapshot, outputURL: URL) throws -> Double {
        let allVideo = (snapshot.videoSamples + postRoll.videoSamples)
            .sorted { $0.wallClockTime < $1.wallClockTime }

        guard let firstVideo = allVideo.first else {
            throw MomentVideoComposerError.missingVideoFormat
        }

        let dimensions = CMVideoDimensions(
            width: Int32(CVPixelBufferGetWidth(firstVideo.pixelBuffer.pixelBuffer)),
            height: Int32(CVPixelBufferGetHeight(firstVideo.pixelBuffer.pixelBuffer))
        )
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        writer.shouldOptimizeForNetworkUse = false

        let compressionSettings: [String: Any] = [
            AVVideoAverageBitRateKey: 2_000_000,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
        ]

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(dimensions.width),
                AVVideoHeightKey: Int(dimensions.height),
                AVVideoCompressionPropertiesKey: compressionSettings
            ]
        )
        videoInput.expectsMediaDataInRealTime = false
        // Sample buffers arrive in the camera sensor's landscape coordinates.
        // The app UI is portrait-first, so write a portrait transform into the track metadata.
        videoInput.transform = CGAffineTransform(rotationAngle: .pi / 2)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                kCVPixelBufferWidthKey as String: Int(dimensions.width),
                kCVPixelBufferHeightKey as String: Int(dimensions.height)
            ]
        )

        guard writer.canAdd(videoInput) else {
            throw MomentVideoComposerError.writerSetupFailed
        }

        writer.add(videoInput)

        let startWallClockTime = firstVideo.wallClockTime
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        for sample in allVideo {
            let presentationTime = CMTime(seconds: max(0.0, sample.wallClockTime - startWallClockTime), preferredTimescale: 600)
            waitUntilReady(for: videoInput)
            guard adaptor.append(sample.pixelBuffer.pixelBuffer, withPresentationTime: presentationTime) else {
                throw writer.error ?? MomentVideoComposerError.appendFailed
            }
        }

        videoInput.markAsFinished()

        let semaphore = DispatchSemaphore(value: 0)
        var finishError: Error?
        writer.finishWriting {
            finishError = writer.error
            semaphore.signal()
        }
        semaphore.wait()

        if let finishError {
            throw finishError
        }

        let endWallClockTime = allVideo.last?.wallClockTime ?? startWallClockTime
        return max(0.0, endWallClockTime - startWallClockTime)
    }

    private func waitUntilReady(for input: AVAssetWriterInput) {
        while !input.isReadyForMoreMediaData {
            Thread.sleep(forTimeInterval: 0.002)
        }
    }
}

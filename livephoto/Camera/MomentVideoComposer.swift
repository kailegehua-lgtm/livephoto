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
            .sorted { CMTimeCompare($0.timestamp, $1.timestamp) < 0 }

        guard let firstVideo = allVideo.first,
              let videoFormatDescription = CMSampleBufferGetFormatDescription(firstVideo.sampleBuffer)
        else {
            throw MomentVideoComposerError.missingVideoFormat
        }

        let dimensions = CMVideoFormatDescriptionGetDimensions(videoFormatDescription)
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

        let startTimestamp = firstVideo.timestamp
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        for sample in allVideo {
            guard let imageBuffer = CMSampleBufferGetImageBuffer(sample.sampleBuffer) else {
                throw MomentVideoComposerError.invalidPixelBuffer
            }

            let presentationTime = CMTimeSubtract(sample.timestamp, startTimestamp)
            waitUntilReady(for: videoInput)
            guard adaptor.append(imageBuffer, withPresentationTime: presentationTime) else {
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

        let endTimestamp = allVideo.last?.timestamp ?? startTimestamp
        return max(0.0, CMTimeGetSeconds(CMTimeSubtract(endTimestamp, startTimestamp)))
    }

    private func waitUntilReady(for input: AVAssetWriterInput) {
        while !input.isReadyForMoreMediaData {
            Thread.sleep(forTimeInterval: 0.002)
        }
    }
}

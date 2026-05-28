import AVFoundation
import Foundation

final class CameraSessionManager: NSObject, ObservableObject {
    enum AuthorizationState {
        case unknown
        case denied
        case restricted
        case unsupported
        case unavailable
        case authorized
    }

    let session = AVCaptureSession()
    let photoOutput = AVCapturePhotoOutput()
    let videoOutput = AVCaptureVideoDataOutput()
    let audioOutput = AVCaptureAudioDataOutput()
    let rollingRecorder = RollingEncodedRecorder()
    let diagnostics = CaptureDiagnostics()

    @Published private(set) var authorizationState: AuthorizationState = .unknown

    private let sessionQueue = DispatchQueue(label: "livephoto.camera.session")
    private let videoOutputQueue = DispatchQueue(label: "livephoto.camera.video-output")
    private let audioOutputQueue = DispatchQueue(label: "livephoto.camera.audio-output")
    private let rollingBufferStatusUpdateInterval: TimeInterval = 0.2
    private var lastRollingBufferStatusUpdateWallClockTime: TimeInterval = 0

    var onVideoSampleBuffer: ((CMSampleBuffer) -> Void)?
    var onAudioSampleBuffer: ((CMSampleBuffer) -> Void)?
    var onRollingBufferUpdated: ((Double) -> Void)?

    override init() {
        super.init()
    }

    func requestAccessAndConfigure() {
        #if targetEnvironment(simulator)
        DispatchQueue.main.async {
            self.authorizationState = .unsupported
        }
        return
        #endif

        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)

        guard cameraStatus != .restricted, audioStatus != .restricted else {
            DispatchQueue.main.async {
                self.authorizationState = .restricted
            }
            return
        }

        guard cameraStatus != .denied, audioStatus != .denied else {
            DispatchQueue.main.async {
                self.authorizationState = .denied
            }
            return
        }

        AVCaptureDevice.requestAccess(for: .video) { cameraGranted in
            AVCaptureDevice.requestAccess(for: .audio) { audioGranted in
                DispatchQueue.main.async {
                    self.authorizationState = cameraGranted && audioGranted ? .authorized : .denied
                }

                guard cameraGranted, audioGranted else {
                    return
                }

                self.sessionQueue.async {
                    guard self.configureSessionIfNeeded() else {
                        return
                    }
                    self.session.startRunning()
                    self.rollingRecorder.startRunning()
                }
            }
        }
    }

    func stopSession() {
        sessionQueue.async {
            guard self.session.isRunning else {
                return
            }
            self.session.stopRunning()
        }
        Task {
            await self.rollingRecorder.stopRunning(removeFiles: true)
        }
    }

    @discardableResult
    private func configureSessionIfNeeded() -> Bool {
        guard session.inputs.isEmpty, session.outputs.isEmpty else {
            return true
        }

        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        } else if session.canSetSessionPreset(.vga640x480) {
            session.sessionPreset = .vga640x480
        } else {
            session.sessionPreset = .high
        }

        defer {
            session.commitConfiguration()
        }

        do {
            let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            let audioDevice = AVCaptureDevice.default(for: .audio)

            guard let videoDevice, let audioDevice else {
                DispatchQueue.main.async {
                    self.authorizationState = .unavailable
                }
                return false
            }

            let videoInput = try AVCaptureDeviceInput(device: videoDevice)
            let audioInput = try AVCaptureDeviceInput(device: audioDevice)

            try videoDevice.lockForConfiguration()
            if let format = preferredVideoFormat(for: videoDevice, dimensions: CMVideoDimensions(width: 1280, height: 720), frameRate: 30) {
                videoDevice.activeFormat = format
            }
            let targetFrameDuration = CMTime(value: 1, timescale: 30)
            videoDevice.activeVideoMinFrameDuration = targetFrameDuration
            videoDevice.activeVideoMaxFrameDuration = targetFrameDuration
            videoDevice.unlockForConfiguration()

            if session.canAddInput(videoInput) {
                session.addInput(videoInput)
            }

            if session.canAddInput(audioInput) {
                session.addInput(audioInput)
            }

            if session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
                if let format = videoDevice.activeFormat.supportedMaxPhotoDimensions.max(by: { left, right in
                    left.width * left.height < right.width * right.height
                }) {
                    photoOutput.maxPhotoDimensions = format
                }
            }

            configureOutputs()
            return true
        } catch {
            DispatchQueue.main.async {
                self.authorizationState = .unavailable
            }
            return false
        }
    }

    private func configureOutputs() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard !session.outputs.contains(videoOutput) else {
            return
        }

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        ]
        videoOutput.setSampleBufferDelegate(self, queue: videoOutputQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
            videoOutput.connection(with: .video)?.preferredVideoStabilizationMode = .off
        }
    }

    private func preferredVideoFormat(
        for device: AVCaptureDevice,
        dimensions: CMVideoDimensions,
        frameRate: Double
    ) -> AVCaptureDevice.Format? {
        device.formats
            .filter { format in
                let description = format.formatDescription
                let formatDimensions = CMVideoFormatDescriptionGetDimensions(description)
                guard formatDimensions.width == dimensions.width,
                      formatDimensions.height == dimensions.height
                else {
                    return false
                }

                return format.videoSupportedFrameRateRanges.contains { range in
                    range.minFrameRate <= frameRate && range.maxFrameRate >= frameRate
                }
            }
            .max { left, right in
                let leftRanges = left.videoSupportedFrameRateRanges
                let rightRanges = right.videoSupportedFrameRateRanges
                let leftMax = leftRanges.map(\.maxFrameRate).max() ?? 0
                let rightMax = rightRanges.map(\.maxFrameRate).max() ?? 0
                return leftMax < rightMax
            }
    }
}

extension CameraSessionManager: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput {
            let wallClockTime = ProcessInfo.processInfo.systemUptime
            let accepted = rollingRecorder.appendSampleBuffer(sampleBuffer, wallClockTime: wallClockTime)
            diagnostics.recordVideoCallback(accepted: accepted, at: wallClockTime)
            if (wallClockTime - lastRollingBufferStatusUpdateWallClockTime) >= rollingBufferStatusUpdateInterval {
                lastRollingBufferStatusUpdateWallClockTime = wallClockTime
                onRollingBufferUpdated?(rollingRecorder.availableDurationSync())
            }
            onVideoSampleBuffer?(sampleBuffer)
        } else if output === audioOutput {
            onAudioSampleBuffer?(sampleBuffer)
        }
    }
}

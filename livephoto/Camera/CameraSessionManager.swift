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
    let movieFileOutput = AVCaptureMovieFileOutput()
    let rollingBuffer = RollingMediaBuffer()

    @Published private(set) var authorizationState: AuthorizationState = .unknown

    private let sessionQueue = DispatchQueue(label: "livephoto.camera.session")
    private let videoOutputQueue = DispatchQueue(label: "livephoto.camera.video-output")
    private let audioOutputQueue = DispatchQueue(label: "livephoto.camera.audio-output")
    private var activeMode: CaptureMode = .stablePostRoll

    var onVideoSampleBuffer: ((CMSampleBuffer) -> Void)?
    var onAudioSampleBuffer: ((CMSampleBuffer) -> Void)?
    var onRollingBufferUpdated: ((Double) -> Void)?

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
    }

    func setCaptureMode(_ mode: CaptureMode) {
        sessionQueue.async {
            guard self.activeMode != mode else {
                return
            }

            self.activeMode = mode
            self.configureOutputs(for: mode)
            if mode == .stablePostRoll {
                self.rollingBuffer.reset()
            }
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

            if session.canAddOutput(movieFileOutput) {
                session.addOutput(movieFileOutput)
                movieFileOutput.movieFragmentInterval = .invalid
                let connection = movieFileOutput.connection(with: .video)
                connection?.preferredVideoStabilizationMode = .auto
            }

            configureOutputs(for: activeMode)
            return true
        } catch {
            DispatchQueue.main.async {
                self.authorizationState = .unavailable
            }
            return false
        }
    }

    private func configureOutputs(for mode: CaptureMode) {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        switch mode {
        case .stablePostRoll:
            if session.outputs.contains(videoOutput) {
                videoOutput.setSampleBufferDelegate(nil, queue: nil)
                session.removeOutput(videoOutput)
            }
        case .experimentalPreRoll:
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
    }
}

extension CameraSessionManager: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput {
            rollingBuffer.appendVideoSampleBuffer(sampleBuffer)
            onRollingBufferUpdated?(rollingBuffer.currentVideoDuration)
            onVideoSampleBuffer?(sampleBuffer)
        } else if output === audioOutput {
            rollingBuffer.appendAudioSampleBuffer(sampleBuffer)
            onAudioSampleBuffer?(sampleBuffer)
        }
    }
}

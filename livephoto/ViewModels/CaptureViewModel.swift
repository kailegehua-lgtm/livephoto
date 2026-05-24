import Combine
import Foundation

@MainActor
final class CaptureViewModel: ObservableObject {
    @Published private(set) var isCapturing = false
    @Published private(set) var isBackgroundProcessing = false
    @Published private(set) var processingPhase = "idle"
    @Published private(set) var availablePreRollSeconds: Double = 0.0
    @Published private(set) var authorizationState: CameraSessionManager.AuthorizationState = .unknown
    @Published private(set) var diagnosticsLine: String?
    @Published var selectedMode: CaptureMode = .stablePostRoll
    @Published var latestMoment: MomentAsset?
    @Published var errorMessage: String?

    let cameraManager: CameraSessionManager
    private let store: MomentStore
    private let coordinator: MomentCaptureCoordinator
    private var cancellables: Set<AnyCancellable> = []

    init(store: MomentStore) {
        self.store = store
        let cameraManager = CameraSessionManager()
        self.cameraManager = cameraManager
        self.coordinator = MomentCaptureCoordinator(cameraManager: cameraManager, store: store)
        bindState()
    }

    func prepare() {
        cameraManager.requestAccessAndConfigure()
        cameraManager.setCaptureMode(selectedMode)
    }

    func stop() {
        cameraManager.stopSession()
    }

    func capture() {
        errorMessage = nil
        Task {
            do {
                latestMoment = try await coordinator.captureMoment(mode: selectedMode)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func updateCaptureMode(_ mode: CaptureMode) {
        cameraManager.setCaptureMode(mode)
    }

    private func bindState() {
        coordinator.$isCapturing
            .receive(on: DispatchQueue.main)
            .assign(to: &$isCapturing)

        coordinator.$isBackgroundProcessing
            .receive(on: DispatchQueue.main)
            .assign(to: &$isBackgroundProcessing)

        coordinator.$processingPhase
            .receive(on: DispatchQueue.main)
            .assign(to: &$processingPhase)

        coordinator.$availablePreRollSeconds
            .receive(on: DispatchQueue.main)
            .assign(to: &$availablePreRollSeconds)

        cameraManager.$authorizationState
            .receive(on: DispatchQueue.main)
            .assign(to: &$authorizationState)

        cameraManager.diagnostics.onSnapshotUpdated = { [weak self] (snapshot: CaptureDiagnosticsSnapshot) in
            self?.diagnosticsLine = snapshot.debugLine
        }

        store.$moments
            .receive(on: DispatchQueue.main)
            .sink { [weak self] moments in
                guard let self, let latestId = self.latestMoment?.id else {
                    return
                }
                self.latestMoment = moments.first(where: { $0.id == latestId })
            }
            .store(in: &cancellables)
    }
}

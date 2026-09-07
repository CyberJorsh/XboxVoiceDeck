import Foundation
import Combine

@MainActor
final class EndpointTestModel: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var request: EndpointTestRequest?
    @Published private(set) var reading = DeckEndpointTestSnapshot()
    @Published private(set) var message = "Test one endpoint at a time while routing is stopped."
    private let engine: EndpointTesting
    private let now: () -> TimeInterval
    private var generation = 0
    private var snapshotPending = false
    private var starting = false
    private var stopping = false
    private var lastProgress: TimeInterval = 0

    init(engine: EndpointTesting, now: @escaping () -> TimeInterval) { self.engine = engine; self.now = now }
    func start(_ request: EndpointTestRequest) {
        guard !busy else { return }
        generation += 1; let token = generation
        self.request = request; reading = DeckEndpointTestSnapshot()
        busy = true; starting = true; message = "Starting \(request.role.title) test…"
        engine.start(request) { [weak self] result in
            guard let self, token == self.generation else { return }
            self.starting = false
            switch result {
            case .success:
                self.lastProgress = self.now()
                self.message = request.role.input ? "Reading input for up to 10 seconds. No playback or recording." : "Playing quiet test for up to 2 seconds."
            case .failure(let error):
                self.busy = false; self.message = "AUDIO ERROR: \(error.localizedDescription)"
            }
        }
    }
    func stop(_ reason: String = "Test stopped.") {
        guard busy, !stopping else { return }
        generation += 1; let token = generation
        stopping = true; starting = false; snapshotPending = false
        message = reason
        engine.stop { [weak self] errors in
            guard let self, token == self.generation else { return }
            self.stopping = false; self.busy = false
            self.reading.active = false
            if !errors.isEmpty { self.message = "AUDIO ERROR: " + errors.joined(separator: "\n") }
        }
    }
    func poll() {
        guard busy, !starting, !stopping, !snapshotPending else { return }
        snapshotPending = true; let token = generation
        engine.snapshot { [weak self] value in
            guard let self, token == self.generation else { return }
            self.snapshotPending = false
            guard let value else { self.stop("AUDIO ERROR: endpoint test session disappeared."); return }
            if value.callbacks != self.reading.callbacks { self.lastProgress = self.now() }
            self.reading = value
            if value.error != 0 { self.stop("AUDIO ERROR: endpoint callback/shutdown status \(value.error)."); return }
            if !value.active {
                self.stop(value.callbacks == 0 ? "AUDIO ERROR: no callbacks received from the selected device." : "Test finished. Check the measured levels or confirm what you heard; hardware acceptance remains manual.")
            } else if self.now() - self.lastProgress > 2 { self.stop("AUDIO ERROR: selected device stopped delivering callbacks.") }
        }
    }
    func validate(devices: [AudioEndpoint], configuration: RoutingConfiguration, captureAllowed: Bool) {
        guard busy, let request else { return }
        do {
            let current = try EndpointTestRequest(role: request.role, configuration: configuration, devices: devices)
            guard current == request, !request.role.input || captureAllowed else {
                stop("Test stopped: selection, device or permission changed."); return
            }
        } catch { stop("Test stopped: \(error.localizedDescription)") }
    }
    func shutdown() { engine.stopSynchronously() }
}

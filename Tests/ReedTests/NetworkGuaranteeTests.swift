import XCTest
@testable import Reed

/// The network guarantee, enforced by test. Reed has one pipeline and it never
/// uses the network; `GateURLProtocol` blocks every host outside its allowlist
/// (the model download, opt-in analytics, the update bucket). These go through
/// the real layers — URLSession → registered GateURLProtocol → trap — so a
/// regression in the gate fails here, not only in a unit check of its list.
final class NetworkGuaranteeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        NetworkTrap.reset()
        NetworkGate.shared.activity.reset()
        // URLProtocol consults the MOST RECENTLY registered class first — so
        // the trap must be registered before the gate, or the trap would
        // swallow every request and these tests would pass even with a broken
        // gate (the first draft of the sign-in version did — verified).
        URLProtocol.registerClass(NetworkTrap.self)
        URLProtocol.registerClass(GateURLProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(GateURLProtocol.self)
        URLProtocol.unregisterClass(NetworkTrap.self)
        super.tearDown()
    }

    private func send(_ urlString: String) async -> Error? {
        do {
            _ = try await URLSession.shared.data(from: URL(string: urlString)!)
            return nil
        } catch {
            return error
        }
    }

    func testAnUnlistedHostIsBlockedBeforeTheNetwork() async {
        let error = await send("https://api.groq.com/v1/audio")
        XCTAssertEqual(NetworkTrap.hits, 0, "a request to an unlisted host must never reach the network")
        XCTAssertEqual(NetworkGate.shared.activity.blockedCount, 1, "the block is recorded")
        XCTAssertNotNil(error, "the caller sees a failure, not a silent success")
    }

    func testReedsFormerBackendIsBlocked() async {
        // Nothing in the app talks to reed.w20.ai since 2026-09-15; the host
        // left the allowlist with the account and cloud features.
        _ = await send("https://reed.w20.ai/api/transcribe")
        XCTAssertEqual(NetworkTrap.hits, 0, "the old backend host must not be reachable")
        XCTAssertEqual(NetworkGate.shared.activity.blockedCount, 1)
    }

    func testTheModelDownloadHostPasses() async {
        _ = await send("https://huggingface.co/FluidInference/parakeet/resolve/main/x")
        XCTAssertGreaterThan(NetworkTrap.hits, 0, "the speech-model download must clear the gate")
        XCTAssertEqual(NetworkGate.shared.activity.blockedCount, 0)
    }

    func testTheAnalyticsAndUpdateHostsPass() async {
        _ = await send("https://eu.aptabase.com/api/v0/events")
        _ = await send("https://reed-public-551270927645.s3.us-west-2.amazonaws.com/appcast.xml")
        XCTAssertEqual(NetworkTrap.hits, 2, "opt-in analytics and the update feed must clear the gate")
        XCTAssertEqual(NetworkGate.shared.activity.blockedCount, 0)
    }
}

/// Fails any request that reaches the network. Registered process-wide, it
/// intercepts every request on `URLSession.shared` and short-circuits it, so no
/// real traffic leaves and the test can assert on `hits`.
final class NetworkTrap: URLProtocol {
    private static let lock = NSLock()
    private static var _hits = 0

    static var hits: Int {
        lock.lock(); defer { lock.unlock() }
        return _hits
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        _hits = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        NetworkTrap.lock.lock()
        NetworkTrap._hits += 1
        NetworkTrap.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}

import Foundation

/// The network guarantee: a process-wide `URLProtocol` that hard-blocks every
/// host outside the allowlist for traffic on `URLSession.shared` — most
/// importantly the Aptabase SDK. Always armed: Reed has one pipeline and it
/// never uses the network. Sentry and Sparkle own their transports and escape
/// this layer; they're gated at the SDK layer instead (Sentry by the Privacy
/// toggle, Sparkle by the user's update checks).
///
/// Not `final`: `URLProtocol` requires overriding its `class func`s (canInit /
/// canonicalRequest), which can't be expressed as `static` on a final class.
class GateURLProtocol: URLProtocol {
    /// Host *suffixes* allowed through: the pinned model-download endpoints
    /// (HuggingFace + its Xet LFS CDN serve the Parakeet model files
    /// FluidAudio fetches), the analytics ingest host (events are still
    /// opt-in per send — Analytics.isEnabled, default OFF — and content-free
    /// by construction), local hosts, and Reed's release bucket (the Sparkle
    /// appcast and update archives). Reed's former backend, reed.w20.ai, is
    /// not on the list: nothing in the app talks to it any more.
    static let allowedHostSuffixes: [String] =
        ["huggingface.co", "hf.co", "aptabase.com", "localhost", "127.0.0.1",
         "reed-public-551270927645.s3.us-west-2.amazonaws.com"]

    /// Register once at launch.
    static func register() { URLProtocol.registerClass(GateURLProtocol.self) }

    static func isAllowed(host: String) -> Bool {
        allowedHostSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return true }
        return !isAllowed(host: host)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host
        Log(category: "netgate").error("URLProtocol blocked \(host ?? "?")")
        NetworkGate.shared.activity.recordBlocked()
        client?.urlProtocol(self, didFailWithError: NetworkGate.Blocked(host: host))
    }

    override func stopLoading() {}
}

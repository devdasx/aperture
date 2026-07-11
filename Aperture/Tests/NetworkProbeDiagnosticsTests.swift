import Foundation
import Testing
@testable import Aperture

/// Rate-limit / probe failures must describe the real cause (not vanish as OSLog debug).
@Suite("Network probe diagnostics")
struct NetworkProbeDiagnosticsTests {

    @Test("rateLimited diagnosticDetail includes retry timing")
    func rateLimitedDetail() {
        let retry = Date().addingTimeInterval(45)
        let error = RPCError.rateLimited(retryAfter: retry)
        let detail = error.diagnosticDetail
        #expect(detail.contains("rateLimited"))
        #expect(detail.contains("retryInSeconds:"))
        #expect(error.diagnosticKind == "rateLimited")
        #expect(String(describing: error) == detail)
        // Shared helper path used by scanners.
        #expect(RPCError.diagnosticDetail(for: error) == detail)
        #expect(RPCError.diagnosticKind(for: error) == "rateLimited")
    }

    @Test("non-RPC errors still stringify for logs")
    func genericErrorDetail() {
        struct Dummy: Error {}
        let detail = RPCError.diagnosticDetail(for: Dummy())
        #expect(!detail.isEmpty)
        #expect(RPCError.diagnosticKind(for: Dummy()).contains("Dummy"))
    }
}

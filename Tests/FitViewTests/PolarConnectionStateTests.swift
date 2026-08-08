import FitViewCore
import Testing
@testable import FitView

/// Covers `PolarConnectionState.afterFailedRequest(current:error:)`, the pure
/// mapping FR-015's "connection lost, reconnect needed" state (data-model.md's
/// Third-Party Connection section, contracts/polar-connection-contract.md)
/// hinges on — tested directly rather than through `AppModel`, which is
/// `@MainActor`-bound and awkward to instantiate in a unit test.
@Suite("PolarConnectionState")
struct PolarConnectionStateTests {
    @Test("a connected session that gets HTTP 401 (.unauthorized) goes to connectionLost")
    func connectedPlusUnauthorizedGoesToConnectionLost() {
        let result = PolarConnectionState.afterFailedRequest(
            current: .connected,
            error: ActivitySourceError.unauthorized
        )
        #expect(result == .connectionLost)
    }

    @Test("a connected session that gets any other error stays connected")
    func connectedPlusOtherErrorStaysConnected() {
        let result = PolarConnectionState.afterFailedRequest(
            current: .connected,
            error: ActivitySourceError.underlying("Polar returned HTTP 500: server error")
        )
        #expect(result == .connected)
    }

    @Test("notConnected + .unauthorized is unchanged — only a live connected session can go stale")
    func notConnectedPlusUnauthorizedUnchanged() {
        let result = PolarConnectionState.afterFailedRequest(
            current: .notConnected,
            error: ActivitySourceError.unauthorized
        )
        #expect(result == .notConnected)
    }

    @Test("connectionLost + .unauthorized is unchanged — already the terminal state for this error")
    func connectionLostPlusUnauthorizedUnchanged() {
        let result = PolarConnectionState.afterFailedRequest(
            current: .connectionLost,
            error: ActivitySourceError.unauthorized
        )
        #expect(result == .connectionLost)
    }
}

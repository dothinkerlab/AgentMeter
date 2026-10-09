import XCTest
import AgentMeterCore
@testable import AgentMeter

final class MacPlanQueryStatusTests: XCTestCase {
    func testMiniMaxDiagnosticsNeverIncludeRawProviderError() throws {
        var status = MacPlanQueryStatus()
        status.receive(MiniMaxTokenPlanAdapter.FetchError.decode("ambiguous text plan entries secret-test"))
        XCTAssertEqual(status.issue, .ambiguous)
        XCTAssertFalse(status.message?.contains("secret-test") == true)
        status.source = "miniMaxCLI"; status.region = .china
        status.receive(ProviderRequestFailure(isRateLimited: true, retryAt: Date.distantFuture, httpStatus: 429))
        XCTAssertFalse(status.canQuery())
        let saved = try JSONEncoder().encode(status)
        let restored = try JSONDecoder().decode(MacPlanQueryStatus.self, from: saved)
        XCTAssertEqual(restored.source, "miniMaxCLI")
        XCTAssertEqual(restored.region, .china)
        XCTAssertEqual(restored.issue, .rateLimited)
        status.receive(nil)
        XCTAssertTrue(status.canQuery())
        XCTAssertNil(status.issue)
    }
}

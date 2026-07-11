import Foundation
import Testing
@testable import AgentMeterCore

struct DeepSeekBalanceAdapterTests {

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    // MARK: - parse

    @Test func parsesBalanceAndPicksPositiveCurrency() throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let balance = try DeepSeekBalanceAdapter().parse(data: try fixture("deepseek_balance_sample"), now: now)

        #expect(balance.isAvailable == true)
        // CNY total=110 > USD 0,挑 CNY。
        #expect(balance.currency == "CNY")
        #expect(balance.totalBalance == "110.00")
        #expect(balance.grantedBalance == "10.00")
        #expect(balance.toppedUpBalance == "100.00")
        #expect(balance.confidence == .fresh)
        #expect(balance.source == "deepseek_balance_endpoint")
        #expect(balance.updatedAt == now)
        #expect(balance.staleReason == nil)
    }

    @Test func allZeroBalancesPicksFirstInfo() throws {
        let json = #"""
        {
          "is_available": false,
          "balance_infos": [
            { "currency": "CNY", "total_balance": "0.00", "granted_balance": "0.00", "topped_up_balance": "0.00" },
            { "currency": "USD", "total_balance": "0.00", "granted_balance": "0.00", "topped_up_balance": "0.00" }
          ]
        }
        """#
        let balance = try DeepSeekBalanceAdapter().parse(data: Data(json.utf8))

        #expect(balance.isAvailable == false)
        #expect(balance.currency == "CNY")  // 全 0 取第一条
        #expect(balance.totalBalance == "0.00")
    }

    @Test func picksUsdWhenCnyEmpty() throws {
        let json = #"""
        {
          "is_available": true,
          "balance_infos": [
            { "currency": "CNY", "total_balance": "0.00", "granted_balance": "0.00", "topped_up_balance": "0.00" },
            { "currency": "USD", "total_balance": "12.50", "granted_balance": "2.50", "topped_up_balance": "10.00" }
          ]
        }
        """#
        let balance = try DeepSeekBalanceAdapter().parse(data: Data(json.utf8))

        #expect(balance.currency == "USD")
        #expect(balance.totalBalance == "12.50")
        #expect(balance.grantedBalance == "2.50")
        #expect(balance.toppedUpBalance == "10.00")
    }

    @Test func preservesStringPrecisionForLargeAmounts() throws {
        // 余额是浮点字符串,不能转 Double 丢精度;adapter 必须原样保留。
        let big = "9999999999.9999"
        let json = #"""
        {
          "is_available": true,
          "balance_infos": [
            { "currency": "CNY", "total_balance": "\#(big)", "granted_balance": "0", "topped_up_balance": "\#(big)" }
          ]
        }
        """#
        let balance = try DeepSeekBalanceAdapter().parse(data: Data(json.utf8))
        #expect(balance.totalBalance == big)
        #expect(balance.toppedUpBalance == big)
    }

    @Test func emptyBalanceInfosThrowsDecode() throws {
        let json = #"{"is_available": true, "balance_infos": []}"#
        #expect(throws: DeepSeekBalanceAdapter.FetchError.self) {
            try DeepSeekBalanceAdapter().parse(data: Data(json.utf8))
        }
    }

    @Test func malformedJsonThrowsDecode() throws {
        #expect(throws: DeepSeekBalanceAdapter.FetchError.self) {
            try DeepSeekBalanceAdapter().parse(data: Data("not json".utf8))
        }
    }

    @Test func invalidOrNegativeAmountsThrowDecode() {
        let invalidAmounts = [
            (total: "N/A", granted: "0", toppedUp: "0"),
            (total: "1", granted: "-1", toppedUp: "0"),
            (total: "1", granted: "0", toppedUp: "1.2x"),
        ]

        for amounts in invalidAmounts {
            let json = #"""
            {
              "is_available": true,
              "balance_infos": [
                {
                  "currency": "CNY",
                  "total_balance": "\#(amounts.total)",
                  "granted_balance": "\#(amounts.granted)",
                  "topped_up_balance": "\#(amounts.toppedUp)"
                }
              ]
            }
            """#

            #expect(throws: DeepSeekBalanceAdapter.FetchError.self) {
                try DeepSeekBalanceAdapter().parse(data: Data(json.utf8))
            }
        }
    }

    @Test func requestGateOnlyAcceptsLatestGeneration() {
        var gate = DeepSeekRequestGate()
        let first = gate.begin()
        #expect(gate.isCurrent(first))

        let second = gate.begin()
        #expect(!gate.isCurrent(first))
        #expect(gate.isCurrent(second))
    }

    // MARK: - stale / unknown 模型

    @Test func markedStaleKeepsValuesButFlipsConfidence() throws {
        let fresh = try DeepSeekBalanceAdapter().parse(data: try fixture("deepseek_balance_sample"))
        let stale = fresh.markedStale(reason: .networkFailure)

        #expect(stale.confidence == .stale)
        #expect(stale.staleReason == .networkFailure)
        // 数值与时间必须保留(铁律 2:旧数不冒新)。
        #expect(stale.totalBalance == fresh.totalBalance)
        #expect(stale.currency == fresh.currency)
        #expect(stale.updatedAt == fresh.updatedAt)
    }

    @Test func unknownPlaceholderHasZeros() {
        let unknown = DeepSeekBalance.unknown(reason: .authExpired)
        #expect(unknown.confidence == .unknown)
        #expect(unknown.staleReason == .authExpired)
        #expect(unknown.totalBalance == "0")
        #expect(unknown.isAvailable == false)
        #expect(unknown.hasKnownBalance == false)
        #expect(unknown.shouldShowUnavailable == false)
    }

    @Test func unavailableFactRequiresKnownBalance() throws {
        let json = #"""
        {
          "is_available": false,
          "balance_infos": [
            { "currency": "CNY", "total_balance": "0", "granted_balance": "0", "topped_up_balance": "0" }
          ]
        }
        """#
        let balance = try DeepSeekBalanceAdapter().parse(data: Data(json.utf8))

        #expect(balance.hasKnownBalance == true)
        #expect(balance.shouldShowUnavailable == true)
    }

    @Test func repeatedFailureKeepsUnknownInsteadOfInventingStaleZero() {
        let firstFailure = DeepSeekBalance.unknown(reason: .networkFailure)
        let repeatedFailure = DeepSeekBalance.degraded(
            from: firstFailure,
            reason: .credentialReadFailed
        )

        #expect(repeatedFailure.confidence == .unknown)
        #expect(repeatedFailure.staleReason == .credentialReadFailed)
        #expect(repeatedFailure.hasKnownBalance == false)
        #expect(repeatedFailure.shouldShowUnavailable == false)
    }

    @Test func failureWithKnownBalancePreservesValuesAsStale() throws {
        let fresh = try DeepSeekBalanceAdapter().parse(data: try fixture("deepseek_balance_sample"))
        let degraded = DeepSeekBalance.degraded(from: fresh, reason: .credentialReadFailed)

        #expect(degraded.confidence == .stale)
        #expect(degraded.staleReason == .credentialReadFailed)
        #expect(degraded.totalBalance == fresh.totalBalance)
        #expect(degraded.updatedAt == fresh.updatedAt)
        #expect(degraded.hasKnownBalance == true)
    }

    // MARK: - error category(对齐 QuotaStaleReason,由调用方降级用)

    @Test func unauthorizedMapsToAuthExpired() {
        let reason = DeepSeekBalanceAdapter.staleReason(for: DeepSeekBalanceAdapter.FetchError.unauthorized)
        #expect(reason == .authExpired)
    }

    @Test func transportMapsToNetworkFailure() {
        let reason = DeepSeekBalanceAdapter.staleReason(
            for: DeepSeekBalanceAdapter.FetchError.transport("timeout"))
        #expect(reason == .networkFailure)
    }

    @Test func httpStatusMapsToEndpointFailure() {
        let reason = DeepSeekBalanceAdapter.staleReason(for: DeepSeekBalanceAdapter.FetchError.httpStatus(500))
        #expect(reason == .endpointFailure)
    }

    @Test func decodeMapsToResponseChanged() {
        let reason = DeepSeekBalanceAdapter.staleReason(for: DeepSeekBalanceAdapter.FetchError.decode("bad"))
        #expect(reason == .responseChanged)
    }
}

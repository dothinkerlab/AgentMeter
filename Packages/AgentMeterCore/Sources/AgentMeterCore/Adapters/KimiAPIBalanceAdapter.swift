import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct KimiAPIBalanceAdapter: Sendable {
    public static let source = "kimi_api_balance_endpoint"
    public let region: ProviderRegion
    public let balanceURL: URL

    public enum FetchError: Error, Sendable, Equatable {
        case unauthorized
        case httpStatus(Int)
        case transport(String)
        case decode(String)
    }

    public init(region: ProviderRegion, balanceURL: URL? = nil) {
        self.region = region
        self.balanceURL = balanceURL ?? region.kimiAPIBalanceURL
    }

    private struct Response: Decodable {
        let code: Int
        let status: Bool
        let data: Balance
    }
    private struct Balance: Decodable {
        let available: Decimal
        let voucher: Decimal
        let cash: Decimal
        enum CodingKeys: String, CodingKey {
            case available = "available_balance"
            case voucher = "voucher_balance"
            case cash = "cash_balance"
        }
    }

    public func parse(data: Data, now: Date = Date()) throws -> KimiAPIBalance {
        let decoded: Response
        do { decoded = try JSONDecoder().decode(Response.self, from: data) }
        catch { throw FetchError.decode(String(describing: error)) }
        guard decoded.code == 0, decoded.status, decoded.data.available >= 0,
              decoded.data.voucher >= 0 else { throw FetchError.decode("invalid balance response") }
        return KimiAPIBalance(availableBalance: decoded.data.available,
                              voucherBalance: decoded.data.voucher, cashBalance: decoded.data.cash,
                              region: region, confidence: .fresh, source: Self.source, updatedAt: now)
    }

    public func fetch(apiKey: String, session: URLSession = .shared,
                      now: Date = Date()) async throws -> KimiAPIBalance {
        var request = URLRequest(url: balanceURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw FetchError.transport(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else { throw FetchError.transport("non-HTTP response") }
        if http.statusCode == 401 || http.statusCode == 403 { throw FetchError.unauthorized }
        guard (200...299).contains(http.statusCode) else { throw FetchError.httpStatus(http.statusCode) }
        return try parse(data: data, now: now)
    }

    public static func staleReason(for error: Error) -> QuotaStaleReason {
        switch error {
        case FetchError.unauthorized: .authExpired
        case FetchError.transport: .networkFailure
        case FetchError.httpStatus: .endpointFailure
        case FetchError.decode: .responseChanged
        default: .unknownFailure
        }
    }
}

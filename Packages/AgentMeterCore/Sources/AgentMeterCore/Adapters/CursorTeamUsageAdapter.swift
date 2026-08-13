import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CursorTeamUsageAdapter: Sendable {
    public static let source = "cursor_team_spend_api"
    public static let defaultSpendURL = URL(string: "https://api.cursor.com/teams/spend")!
    public static let pageSize = 100
    public static let maximumPageCount = 100

    public let spendURL: URL

    public enum FetchError: Error, Sendable, Equatable {
        case unauthorized
        case httpStatus(Int)
        case transport(String)
        case decode(String)
    }

    private struct SpendPage: Decodable {
        let teamMemberSpend: [Member]
        let subscriptionCycleStart: FlexibleDecimal
        let totalMembers: Int
        let totalPages: Int
    }

    private struct Member: Decodable {
        let spendCents: FlexibleDecimal
        let includedSpendCents: FlexibleDecimal?
        let name: String
        let email: String
        let role: String
        let totalPercentUsed: Double?
    }

    private struct FlexibleDecimal: Decodable {
        let value: Decimal

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Decimal.self) {
                self.value = value
            } else if let string = try? container.decode(String.self),
                      let value = Decimal(string: string, locale: Locale(identifier: "en_US_POSIX")) {
                self.value = value
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "invalid decimal")
            }
        }
    }

    public init(spendURL: URL = Self.defaultSpendURL) {
        self.spendURL = spendURL
    }

    public func fetch(
        adminKey: String,
        transport: (any APICostHTTPTransport)? = nil,
        now: Date = Date()
    ) async throws -> CursorTeamUsage {
        let transport = transport ?? SameOriginAPICostHTTPTransport(originURL: spendURL)
        var page = 1
        var expectedPages: Int?
        var expectedMembers: Int?
        var expectedStart: Decimal?
        var members: [CursorTeamMemberUsage] = []
        var seenEmails = Set<String>()

        repeat {
            guard page <= Self.maximumPageCount else {
                throw FetchError.decode("pagination exceeded maximum page count")
            }
            let data = try await request(page: page, adminKey: adminKey, transport: transport)
            let response: SpendPage
            do { response = try JSONDecoder().decode(SpendPage.self, from: data) }
            catch { throw FetchError.decode(String(describing: error)) }

            guard response.totalPages >= 1, response.totalPages <= Self.maximumPageCount,
                  response.totalMembers >= 0 else {
                throw FetchError.decode("invalid pagination metadata")
            }
            if let expectedPages, expectedPages != response.totalPages {
                throw FetchError.decode("totalPages changed during pagination")
            }
            if let expectedMembers, expectedMembers != response.totalMembers {
                throw FetchError.decode("totalMembers changed during pagination")
            }
            if let expectedStart, expectedStart != response.subscriptionCycleStart.value {
                throw FetchError.decode("subscriptionCycleStart changed during pagination")
            }
            expectedPages = response.totalPages
            expectedMembers = response.totalMembers
            expectedStart = response.subscriptionCycleStart.value

            for item in response.teamMemberSpend {
                guard item.spendCents.value >= 0,
                      item.includedSpendCents?.value ?? 0 >= 0,
                      !item.email.isEmpty,
                      item.totalPercentUsed.map({ $0.isFinite && $0 >= 0 }) ?? true else {
                    throw FetchError.decode("invalid member usage")
                }
                let identity = item.email.lowercased()
                guard seenEmails.insert(identity).inserted else {
                    throw FetchError.decode("duplicate team member")
                }
                members.append(CursorTeamMemberUsage(
                    name: item.name,
                    email: item.email,
                    role: item.role,
                    includedSpendCents: item.includedSpendCents?.value,
                    onDemandSpendCents: item.spendCents.value,
                    totalPercentUsed: item.totalPercentUsed.map { min(100, $0) }
                ))
            }
            page += 1
        } while page <= (expectedPages ?? 1)

        guard let totalMembers = expectedMembers,
              let cycle = expectedStart,
              cycle > 0,
              NSDecimalNumber(decimal: cycle).doubleValue.isFinite else {
            throw FetchError.decode("missing team summary")
        }
        guard members.count == totalMembers else {
            throw FetchError.decode("pagination did not return every team member")
        }
        let cycleDate = Date(timeIntervalSince1970: NSDecimalNumber(decimal: cycle).doubleValue / 1_000)
        guard cycleDate <= now.addingTimeInterval(24 * 60 * 60) else {
            throw FetchError.decode("invalid subscription cycle")
        }

        let hasCompleteIncludedSpend = members.allSatisfy { $0.includedSpendCents != nil }
        members.sort {
            let left = hasCompleteIncludedSpend ? $0.totalUsageCents : $0.onDemandSpendCents
            let right = hasCompleteIncludedSpend ? $1.totalUsageCents : $1.onDemandSpendCents
            if left == right {
                return $0.email.localizedCaseInsensitiveCompare($1.email) == .orderedAscending
            }
            return left > right
        }
        let onDemand = members.reduce(Decimal.zero) { $0 + $1.onDemandSpendCents }
        let included = hasCompleteIncludedSpend
            ? members.compactMap(\.includedSpendCents).reduce(Decimal.zero, +)
            : nil

        return CursorTeamUsage(
            members: members,
            totalMembers: totalMembers,
            subscriptionCycleStart: cycleDate,
            includedSpendCents: included,
            onDemandSpendCents: onDemand,
            confidence: .fresh,
            source: Self.source,
            updatedAt: now
        )
    }

    private func request(
        page: Int,
        adminKey: String,
        transport: any APICostHTTPTransport
    ) async throws -> Data {
        var request = URLRequest(url: spendURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "page": page,
            "pageSize": Self.pageSize,
            "sortBy": "amount",
            "sortDirection": "desc",
        ])
        let basic = Data("\(adminKey):".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let data: Data, response: URLResponse
        do { (data, response) = try await transport.data(for: request) }
        catch { throw FetchError.transport(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else {
            throw FetchError.transport("non-HTTP response")
        }
        if http.statusCode == 401 || http.statusCode == 403 { throw FetchError.unauthorized }
        guard (200...299).contains(http.statusCode) else { throw FetchError.httpStatus(http.statusCode) }
        return data
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

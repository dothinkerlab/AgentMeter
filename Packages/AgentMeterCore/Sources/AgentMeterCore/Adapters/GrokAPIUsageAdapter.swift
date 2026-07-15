import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// xAI Management API 的团队账单采集 adapter。
public struct GrokAPIUsageAdapter: Sendable {
    public static let source = "xai_management_billing"
    public static let defaultBaseURL = URL(string: "https://management-api.x.ai")!

    public let baseURL: URL

    public enum FetchError: Error, Sendable, Equatable {
        case unauthorized
        case httpStatus(Int)
        case transport(String)
        case decode(String)
    }

    public struct PeriodUsage: Sendable, Equatable {
        public let daily: Decimal
        public let weekly: Decimal
        public let monthly: Decimal
    }

    private struct UsageResponse: Decodable {
        let timeSeries: [TimeSeries]
    }

    private struct TimeSeries: Decodable {
        let dataPoints: [DataPoint]
    }

    private struct DataPoint: Decodable {
        let timestamp: Date
        let values: [Decimal]
    }

    private struct PrepaidResponse: Decodable {
        let total: MoneyValue
    }

    private struct SpendingLimitResponse: Decodable {
        let spendingLimits: SpendingLimits
    }

    private struct SpendingLimits: Decodable {
        let effectiveSl: MoneyValue
    }

    private struct MoneyValue: Decodable {
        let val: String
    }

    private struct UsageRequest: Encodable {
        let analyticsRequest: AnalyticsRequest
    }

    private struct AnalyticsRequest: Encodable {
        let timeRange: TimeRange
        let timeUnit = "TIME_UNIT_DAY"
        let values = [AnalyticsValue(name: "usd", aggregation: "AGGREGATION_SUM")]
        let groupBy: [String] = []
        let filters: [String] = []
    }

    private struct TimeRange: Encodable {
        let startTime: String
        let endTime: String
        let timezone: String
    }

    private struct AnalyticsValue: Encodable {
        let name: String
        let aggregation: String
    }

    public init(baseURL: URL = Self.defaultBaseURL) {
        self.baseURL = baseURL
    }

    public func parseUsage(
        data: Data,
        calendar: Calendar = .current,
        now: Date = Date()
    ) throws -> PeriodUsage {
        let decoded: UsageResponse
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            decoded = try decoder.decode(UsageResponse.self, from: data)
        } catch {
            throw FetchError.decode(String(describing: error))
        }

        guard let week = calendar.dateInterval(of: .weekOfYear, for: now),
              let month = calendar.dateInterval(of: .month, for: now) else {
            throw FetchError.decode("无法计算本周/本月区间")
        }
        let day = calendar.startOfDay(for: now)
        var daily: Decimal = 0
        var weekly: Decimal = 0
        var monthly: Decimal = 0
        for series in decoded.timeSeries {
            for point in series.dataPoints {
                guard point.values.allSatisfy({ $0 >= 0 }) else {
                    throw FetchError.decode("usage 包含负数")
                }
                let value = point.values.reduce(Decimal.zero, +)
                if point.timestamp >= month.start && point.timestamp < month.end { monthly += value }
                if point.timestamp >= week.start && point.timestamp < week.end { weekly += value }
                if calendar.isDate(point.timestamp, inSameDayAs: day) { daily += value }
            }
        }
        return PeriodUsage(daily: daily, weekly: weekly, monthly: monthly)
    }

    public func parsePrepaidBalance(data: Data) throws -> Decimal {
        do {
            let response = try JSONDecoder().decode(PrepaidResponse.self, from: data)
            guard let cents = Decimal(string: response.total.val), cents <= 0 else {
                throw FetchError.decode("预付余额不是有效的非正 cents 账本值")
            }
            return -cents / 100
        } catch let error as FetchError {
            throw error
        } catch {
            throw FetchError.decode(String(describing: error))
        }
    }

    public func parsePostpaidLimit(data: Data) throws -> Decimal {
        do {
            let response = try JSONDecoder().decode(SpendingLimitResponse.self, from: data)
            guard let cents = Decimal(string: response.spendingLimits.effectiveSl.val), cents >= 0 else {
                throw FetchError.decode("后付限额不是有效的非负 cents 值")
            }
            return cents / 100
        } catch let error as FetchError {
            throw error
        } catch {
            throw FetchError.decode(String(describing: error))
        }
    }

    public func fetch(
        credentials: GrokManagementCredentials,
        session: URLSession = .shared,
        calendar: Calendar = .current,
        now: Date = Date()
    ) async throws -> GrokAPIUsage {
        let teamID = credentials.teamID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? credentials.teamID
        let billingBase = baseURL
            .appendingPathComponent("v1/billing/teams")
            .appendingPathComponent(teamID)

        let usageBody: Data
        do {
            usageBody = try JSONEncoder().encode(UsageRequest(analyticsRequest: analyticsRequest(
                calendar: calendar,
                now: now
            )))
        } catch {
            throw FetchError.decode(String(describing: error))
        }

        async let usageData = request(
            url: billingBase.appendingPathComponent("usage"),
            method: "POST",
            body: usageBody,
            managementKey: credentials.managementKey,
            session: session
        )
        async let prepaidData = request(
            url: billingBase.appendingPathComponent("prepaid/balance"),
            method: "GET",
            managementKey: credentials.managementKey,
            session: session
        )
        async let limitData = request(
            url: billingBase.appendingPathComponent("postpaid/spending-limits"),
            method: "GET",
            managementKey: credentials.managementKey,
            session: session
        )
        let (usagePayload, prepaidPayload, limitPayload) = try await (usageData, prepaidData, limitData)

        let period = try parseUsage(data: usagePayload, calendar: calendar, now: now)
        return GrokAPIUsage(
            usageDaily: period.daily,
            usageWeekly: period.weekly,
            usageMonthly: period.monthly,
            prepaidBalance: try parsePrepaidBalance(data: prepaidPayload),
            postpaidMonthlyLimit: try parsePostpaidLimit(data: limitPayload),
            confidence: .fresh,
            source: Self.source,
            updatedAt: now
        )
    }

    private func analyticsRequest(calendar: Calendar, now: Date) -> AnalyticsRequest {
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? now
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return AnalyticsRequest(timeRange: TimeRange(
            startTime: formatter.string(from: min(weekStart, monthStart)),
            endTime: formatter.string(from: now),
            timezone: calendar.timeZone.identifier
        ))
    }

    private func request(
        url: URL,
        method: String,
        body: Data? = nil,
        managementKey: String,
        session: URLSession
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 15
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw FetchError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw FetchError.transport("non-HTTP response")
        }
        switch http.statusCode {
        case 200...299: return data
        case 401, 403: throw FetchError.unauthorized
        default: throw FetchError.httpStatus(http.statusCode)
        }
    }

    public static func staleReason(for error: Error) -> QuotaStaleReason {
        switch error {
        case FetchError.unauthorized: return .authExpired
        case FetchError.transport: return .networkFailure
        case FetchError.httpStatus: return .endpointFailure
        case FetchError.decode: return .responseChanged
        default: return .unknownFailure
        }
    }
}

public struct GrokRequestGate: Sendable {
    private var generation: UInt64 = 0

    public init() {}

    public mutating func begin() -> UInt64 {
        generation &+= 1
        return generation
    }

    public func isCurrent(_ requestGeneration: UInt64) -> Bool {
        requestGeneration == generation
    }
}

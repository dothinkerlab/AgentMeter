import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Anthropic organization Cost Report adapter. Amounts in the response are
/// decimal strings in cents and are converted to USD only inside this adapter.
public struct AnthropicAPICostAdapter: Sendable {
    public static let source = "anthropic_organization_cost_report"
    public static let defaultCostURL = URL(string: "https://api.anthropic.com/v1/organizations/cost_report")!
    static let maximumPageCount = 10
    static let maximumBucketCount = 100

    public let costURL: URL

    public enum FetchError: Error, Sendable, Equatable {
        case unauthorized
        case httpStatus(Int)
        case transport(String)
        case decode(String)
    }

    public struct CostBucket: Sendable, Equatable {
        public let startsAt: Date
        public let amountUSD: Decimal

        public init(startsAt: Date, amountUSD: Decimal) {
            self.startsAt = startsAt
            self.amountUSD = amountUSD
        }
    }

    public struct ParsedPage: Sendable, Equatable {
        public let buckets: [CostBucket]
        public let nextPage: String?

        public init(buckets: [CostBucket], nextPage: String?) {
            self.buckets = buckets
            self.nextPage = nextPage
        }
    }

    private struct Response: Decodable {
        let data: [Bucket]
        let hasMore: Bool
        let nextPage: String?

        enum CodingKeys: String, CodingKey {
            case data
            case hasMore = "has_more"
            case nextPage = "next_page"
        }
    }

    private struct Bucket: Decodable {
        let startingAt: String
        let results: [Result]

        enum CodingKeys: String, CodingKey {
            case startingAt = "starting_at"
            case results
        }
    }

    private struct Result: Decodable {
        let amount: String
        let currency: String
    }

    public init(costURL: URL = Self.defaultCostURL) {
        self.costURL = costURL
    }

    public func parsePage(data: Data) throws -> ParsedPage {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw FetchError.decode(String(describing: error))
        }

        var buckets: [CostBucket] = []
        for bucket in response.data {
            guard let startsAt = Self.parseISO8601(bucket.startingAt) else {
                throw FetchError.decode("invalid starting_at")
            }
            var cents: Decimal = 0
            for result in bucket.results {
                guard result.currency.uppercased() == "USD",
                      let value = Decimal(string: result.amount, locale: Locale(identifier: "en_US_POSIX")),
                      value >= 0 else {
                    throw FetchError.decode("cost amount must be non-negative USD cents")
                }
                cents += value
            }
            buckets.append(CostBucket(startsAt: startsAt, amountUSD: cents / 100))
        }

        if response.hasMore, response.nextPage?.isEmpty != false {
            throw FetchError.decode("has_more response omitted next_page")
        }
        return ParsedPage(buckets: buckets, nextPage: response.hasMore ? response.nextPage : nil)
    }

    public func aggregate(
        buckets: [CostBucket],
        calendar: Calendar = .current,
        now: Date = Date()
    ) throws -> APICostUsage {
        let reportCalendar = APICostReportCalendar.utc(basedOn: calendar)
        guard let week = reportCalendar.dateInterval(of: .weekOfYear, for: now),
              let month = reportCalendar.dateInterval(of: .month, for: now) else {
            throw FetchError.decode("unable to calculate calendar periods")
        }
        var daily: Decimal = 0
        var weekly: Decimal = 0
        var monthly: Decimal = 0
        for bucket in buckets {
            if reportCalendar.isDate(bucket.startsAt, inSameDayAs: now) { daily += bucket.amountUSD }
            if bucket.startsAt >= week.start, bucket.startsAt < week.end { weekly += bucket.amountUSD }
            if bucket.startsAt >= month.start, bucket.startsAt < month.end { monthly += bucket.amountUSD }
        }
        return APICostUsage(
            usageDaily: daily,
            usageWeekly: weekly,
            usageMonthly: monthly,
            confidence: .fresh,
            source: Self.source,
            updatedAt: now
        )
    }

    public func fetch(
        adminKey: String,
        transport: (any APICostHTTPTransport)? = nil,
        calendar: Calendar = .current,
        now: Date = Date()
    ) async throws -> APICostUsage {
        let reportCalendar = APICostReportCalendar.utc(basedOn: calendar)
        guard let week = reportCalendar.dateInterval(of: .weekOfYear, for: now),
              let month = reportCalendar.dateInterval(of: .month, for: now) else {
            throw FetchError.decode("unable to calculate calendar periods")
        }
        let start = min(week.start, month.start)
        let transport = transport ?? SameOriginAPICostHTTPTransport(originURL: costURL)
        var page: String?
        var seenPages = Set<String>()
        var buckets: [CostBucket] = []
        var pageCount = 0

        repeat {
            guard pageCount < Self.maximumPageCount else {
                throw FetchError.decode("pagination exceeded maximum page count")
            }
            pageCount += 1
            if let page, !seenPages.insert(page).inserted {
                throw FetchError.decode("pagination loop")
            }
            let data = try await request(
                adminKey: adminKey,
                start: start,
                end: now,
                page: page,
                transport: transport
            )
            let parsed = try parsePage(data: data)
            buckets.append(contentsOf: parsed.buckets)
            guard buckets.count <= Self.maximumBucketCount else {
                throw FetchError.decode("pagination exceeded maximum bucket count")
            }
            page = parsed.nextPage
        } while page != nil

        let validated = try validatedBuckets(
            buckets,
            start: start,
            end: now,
            calendar: reportCalendar
        )
        return try aggregate(buckets: validated, calendar: reportCalendar, now: now)
    }

    private func validatedBuckets(
        _ buckets: [CostBucket],
        start: Date,
        end: Date,
        calendar: Calendar
    ) throws -> [CostBucket] {
        var unique: [Date: Decimal] = [:]
        for bucket in buckets {
            guard bucket.startsAt >= start, bucket.startsAt < end else {
                throw FetchError.decode("cost bucket outside requested interval")
            }
            let dayStart = calendar.startOfDay(for: bucket.startsAt)
            guard bucket.startsAt == dayStart else {
                throw FetchError.decode("cost bucket is not aligned to UTC midnight")
            }
            if let existing = unique[dayStart] {
                guard existing == bucket.amountUSD else {
                    throw FetchError.decode("conflicting duplicate cost bucket")
                }
                continue
            }
            unique[dayStart] = bucket.amountUSD
        }
        return unique
            .map { CostBucket(startsAt: $0.key, amountUSD: $0.value) }
            .sorted { $0.startsAt < $1.startsAt }
    }

    private func request(
        adminKey: String,
        start: Date,
        end: Date,
        page: String?,
        transport: any APICostHTTPTransport
    ) async throws -> Data {
        guard var components = URLComponents(url: costURL, resolvingAgainstBaseURL: false) else {
            throw FetchError.decode("invalid cost report URL")
        }
        var items = [
            URLQueryItem(name: "starting_at", value: Self.formatISO8601(start)),
            URLQueryItem(name: "ending_at", value: Self.formatISO8601(end)),
            URLQueryItem(name: "bucket_width", value: "1d"),
        ]
        if let page { items.append(URLQueryItem(name: "page", value: page)) }
        components.queryItems = items
        guard let url = components.url else { throw FetchError.decode("invalid cost report request URL") }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(adminKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await perform(request, transport: transport)
    }

    private func perform(
        _ request: URLRequest,
        transport: any APICostHTTPTransport
    ) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
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

    private static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func formatISO8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
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

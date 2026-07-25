import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// OpenAI organization Costs API adapter. It requires an organization Admin
/// API key; a normal project API key is intentionally not treated as valid.
public struct OpenAIAPICostAdapter: Sendable {
    public static let source = "openai_organization_costs"
    public static let defaultCostsURL = URL(string: "https://api.openai.com/v1/organization/costs")!
    static let maximumPageCount = 10
    static let maximumBucketCount = 100

    public let costsURL: URL

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
        let startTime: TimeInterval
        let results: [Result]

        enum CodingKeys: String, CodingKey {
            case startTime = "start_time"
            case results
        }
    }

    private struct Result: Decodable {
        let amount: Amount
    }

    private struct Amount: Decodable {
        let value: Decimal
        let currency: String
    }

    public init(costsURL: URL = Self.defaultCostsURL) {
        self.costsURL = costsURL
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
            var total: Decimal = 0
            for result in bucket.results {
                guard result.amount.currency.lowercased() == "usd",
                      result.amount.value >= 0 else {
                    throw FetchError.decode("cost amount must be non-negative USD")
                }
                total += result.amount.value
            }
            buckets.append(CostBucket(
                startsAt: Date(timeIntervalSince1970: bucket.startTime),
                amountUSD: total
            ))
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
        let transport = transport ?? SameOriginAPICostHTTPTransport(originURL: costsURL)
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
        guard var components = URLComponents(url: costsURL, resolvingAgainstBaseURL: false) else {
            throw FetchError.decode("invalid costs URL")
        }
        var items = [
            URLQueryItem(name: "start_time", value: String(Int(start.timeIntervalSince1970))),
            URLQueryItem(name: "end_time", value: String(Int(end.timeIntervalSince1970))),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: "180"),
        ]
        if let page { items.append(URLQueryItem(name: "page", value: page)) }
        components.queryItems = items
        guard let url = components.url else { throw FetchError.decode("invalid costs request URL") }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(adminKey)", forHTTPHeaderField: "Authorization")
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

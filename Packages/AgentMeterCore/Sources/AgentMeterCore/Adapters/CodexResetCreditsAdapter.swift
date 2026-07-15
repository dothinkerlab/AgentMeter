import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Codex banked rate-limit reset credits 的只读 adapter。
///
/// 端点不是稳定公开 API；解析与网络请求拆开，调用失败由 collector 独立降级，
/// 不能污染主 Codex quota window 的 confidence。
public struct CodexResetCreditsAdapter: Sendable {
    public static let source = RateLimitResetCredits.source
    public static let defaultURL = URL(
        string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"
    )!

    public let creditsURL: URL

    public enum FetchError: Error, Sendable, Equatable {
        case unauthorized
        case httpStatus(Int)
        case transport(String)
        case decode(String)
    }

    public init(creditsURL: URL = Self.defaultURL) {
        self.creditsURL = creditsURL
    }

    public func parse(data: Data, now: Date = Date()) throws -> RateLimitResetCredits {
        let decoder = JSONDecoder()
        let raw: Response
        do {
            raw = try decoder.decode(Response.self, from: data)
        } catch {
            throw FetchError.decode(String(describing: error))
        }

        guard raw.availableCount >= 0 else {
            throw FetchError.decode("available_count 不能为负数")
        }

        let available = raw.credits.compactMap { credit -> RateLimitResetCredit? in
            guard credit.status.lowercased() == "available" else { return nil }
            return RateLimitResetCredit(
                grantedAt: credit.grantedAt,
                expiresAt: credit.expiresAt
            )
        }

        return RateLimitResetCredits(
            availableCount: raw.availableCount,
            credits: available,
            confidence: .fresh,
            source: Self.source,
            updatedAt: now
        )
    }

    public func fetch(
        accessToken: String,
        accountID: String? = nil,
        session: URLSession = .shared,
        now: Date = Date()
    ) async throws -> RateLimitResetCredits {
        var request = URLRequest(url: creditsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")

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
        case 200...299:
            break
        case 401, 403:
            throw FetchError.unauthorized
        default:
            throw FetchError.httpStatus(http.statusCode)
        }

        return try parse(data: data, now: now)
    }
}

private extension CodexResetCreditsAdapter {
    struct Response: Decodable {
        let availableCount: Int
        let credits: [Credit]

        enum CodingKeys: String, CodingKey {
            case availableCount = "available_count"
            case credits
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            availableCount = try container.decode(Int.self, forKey: .availableCount)
            credits = try container.decodeIfPresent([Credit].self, forKey: .credits) ?? []
        }
    }

    struct Credit: Decodable {
        let status: String
        let grantedAt: Date
        let expiresAt: Date?

        enum CodingKeys: String, CodingKey {
            case status
            case grantedAt = "granted_at"
            case expiresAt = "expires_at"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try container.decode(String.self, forKey: .status)
            grantedAt = try Self.decodeDate(container, key: .grantedAt)
            expiresAt = try Self.decodeOptionalDate(container, key: .expiresAt)
        }

        private static func decodeDate(
            _ container: KeyedDecodingContainer<CodingKeys>,
            key: CodingKeys
        ) throws -> Date {
            guard let value = try decodeOptionalDate(container, key: key) else {
                throw DecodingError.valueNotFound(
                    Date.self,
                    .init(codingPath: container.codingPath + [key], debugDescription: "日期不能为空")
                )
            }
            return value
        }

        private static func decodeOptionalDate(
            _ container: KeyedDecodingContainer<CodingKeys>,
            key: CodingKeys
        ) throws -> Date? {
            if try container.decodeNil(forKey: key) { return nil }
            if let string = try? container.decode(String.self, forKey: key) {
                let fractional = ISO8601DateFormatter()
                fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let plain = ISO8601DateFormatter()
                plain.formatOptions = [.withInternetDateTime]
                guard let date = fractional.date(from: string) ?? plain.date(from: string) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: key, in: container, debugDescription: "无法解析 ISO8601 日期: \(string)"
                    )
                }
                return date
            }
            if let epoch = try? container.decode(Double.self, forKey: key) {
                return Date(timeIntervalSince1970: epoch > 10_000_000_000 ? epoch / 1_000 : epoch)
            }
            if let epoch = try? container.decode(Int64.self, forKey: key) {
                let seconds = epoch > 10_000_000_000 ? Double(epoch) / 1_000 : Double(epoch)
                return Date(timeIntervalSince1970: seconds)
            }
            throw DecodingError.typeMismatch(
                Date.self,
                .init(codingPath: container.codingPath + [key], debugDescription: "日期必须是 ISO8601 或 epoch")
            )
        }
    }
}

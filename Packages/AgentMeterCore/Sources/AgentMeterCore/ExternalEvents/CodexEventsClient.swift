import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ExternalResetEventsClient: Sendable {
    public enum ClientError: Error, Equatable {
        case missingBaseURL
        case invalidResponse
        case httpStatus(Int)
        case decode(String)
    }

    public static let defaultBaseURLString = "https://dothinker.org/api/agentmeter/codex-reset"

    public let baseURL: URL?
    public let session: URLSession

    public init(
        baseURL: URL? = ExternalResetEventsClient.bundleConfiguredBaseURL(),
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    public func fetchEvents(limit: Int = 20) async throws -> [ExternalResetEvent] {
        guard let baseURL else { throw ClientError.missingBaseURL }
        var components = URLComponents(
            url: baseURL.appendingPathComponent("v2/events"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "limit", value: "\(limit)")]
        guard let url = components?.url else { throw ClientError.missingBaseURL }

        let data = try await requestData(URLRequest(url: url))
        let decoder = Self.makeDecoder()
        do {
            return try decoder.decode(ExternalResetEventsResponse.self, from: data).events
        } catch {
            throw ClientError.decode(String(describing: error))
        }
    }

    private func requestData(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw ClientError.httpStatus(http.statusCode)
        }
        return data
    }

    public static func bundleConfiguredBaseURL() -> URL? {
        let external = Bundle.main.object(forInfoDictionaryKey: "AgentMeterExternalEventsBaseURL") as? String
        let legacy = Bundle.main.object(forInfoDictionaryKey: "AgentMeterCodexEventsBaseURL") as? String
        let configured = external?.isEmpty == false ? external : legacy
        let raw = configured?.isEmpty == false ? configured : defaultBaseURLString
        return raw.flatMap(URL.init(string:))
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: string) ?? plain.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date: \(string)")
        }
        return decoder
    }
}

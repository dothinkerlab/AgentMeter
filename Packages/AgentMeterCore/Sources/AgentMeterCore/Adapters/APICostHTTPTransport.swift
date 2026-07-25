import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol APICostHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

enum APICostReportCalendar {
    static func utc(basedOn calendar: Calendar) -> Calendar {
        var result = calendar
        result.timeZone = TimeZone(secondsFromGMT: 0)!
        return result
    }
}

public struct APICostRequestOrigin: Sendable, Equatable {
    public let scheme: String
    public let host: String
    public let port: Int?

    public init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else { return nil }
        self.scheme = scheme
        self.host = host
        self.port = url.port ?? Self.defaultPort(for: scheme)
    }

    public func permits(_ url: URL?) -> Bool {
        guard let url, let candidate = APICostRequestOrigin(url: url) else { return false }
        return candidate == self
    }

    private static func defaultPort(for scheme: String) -> Int? {
        switch scheme {
        case "https": 443
        case "http": 80
        default: nil
        }
    }
}

/// Production transport for organization-level billing credentials. Redirects
/// may stay on the exact origin but can never move an Admin key to another
/// scheme, host, or port.
public final class SameOriginAPICostHTTPTransport: APICostHTTPTransport, @unchecked Sendable {
    public let origin: APICostRequestOrigin
    private let redirectDelegate: SameOriginRedirectDelegate
    private let session: URLSession

    public convenience init(originURL: URL) {
        self.init(originURL: originURL, configuration: .ephemeral)
    }

    init(originURL: URL, configuration: URLSessionConfiguration) {
        guard let origin = APICostRequestOrigin(url: originURL) else {
            preconditionFailure("APICost origin URL must contain a scheme and host")
        }
        let redirectDelegate = SameOriginRedirectDelegate(origin: origin)
        self.origin = origin
        self.redirectDelegate = redirectDelegate
        self.session = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    deinit {
        session.invalidateAndCancel()
    }
}

/// Test/custom transport. Production adapters default to
/// `SameOriginAPICostHTTPTransport`; callers must opt in explicitly to supplying
/// another session.
public struct URLSessionAPICostHTTPTransport: APICostHTTPTransport {
    public let session: URLSession

    public init(session: URLSession) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

private final class SameOriginRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let origin: APICostRequestOrigin

    init(origin: APICostRequestOrigin) {
        self.origin = origin
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(origin.permits(request.url) ? request : nil)
    }
}

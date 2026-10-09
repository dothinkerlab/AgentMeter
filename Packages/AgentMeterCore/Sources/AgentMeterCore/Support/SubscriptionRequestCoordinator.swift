import CryptoKit
import Foundation
import OSLog

/// Coalesces subscription HTTP queries without changing their successful polling cadence.
/// Only a credential digest and cooldown are persisted locally; response bodies are never stored here.
public actor SubscriptionRequestCoordinator {
    public static let shared = SubscriptionRequestCoordinator()
    public typealias Sender = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private struct State: Codable {
        let identity: String
        var failures: Int = 0
        var failure: ProviderRequestFailure?
    }
    private struct Flight {
        let id: UUID
        let task: Task<(Data, URLResponse), Error>
    }
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private var flights: [String: Flight] = [:]
    private static let logger = Logger(subsystem: "com.dothinker.app.agentmeter", category: "SubscriptionRequest")

    public init(defaults: UserDefaults = .standard, now: @escaping @Sendable () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
    }

    public func data(for request: URLRequest, service: String, credentialIdentity: String? = nil, session: URLSession = .shared) async throws -> (Data, URLResponse) {
        try await data(for: request, service: service, credentialIdentity: credentialIdentity, send: { try await session.data(for: $0) })
    }

    public func data(for request: URLRequest, service: String, credentialIdentity: String? = nil, send: @escaping Sender) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        let headers = (request.allHTTPHeaderFields ?? [:]).sorted { $0.key < $1.key }
            .map { "\($0.key.lowercased()):\($0.value)" }.joined(separator: "\n")
        let material = "\(request.url?.absoluteString ?? "")\n\(credentialIdentity ?? headers)"
        let identity = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
        let flightKey = service + identity
        if let flight = flights[flightKey] {
            Self.logger.notice("service=\(service, privacy: .public) event=joined")
            let result = try await flight.task.value
            try Task.checkCancellation()
            return result
        }
        let state = load(service: service, identity: identity)
        if let failure = state.failure, let retryAt = failure.retryAt, retryAt > now() {
            Self.logger.notice("service=\(service, privacy: .public) event=cooldown http=\(failure.httpStatus) retryAt=\(retryAt.timeIntervalSince1970)")
            throw failure
        }
        save(state, service: service)
        let id = UUID()
        let task = Task { try await self.perform(request, service: service, state: state, send: send) }
        flights[flightKey] = Flight(id: id, task: task)
        defer { if flights[flightKey]?.id == id { flights[flightKey] = nil } }
        let result = try await task.value
        try Task.checkCancellation()
        return result
    }

    private func perform(_ request: URLRequest, service: String, state initial: State,
                         send: Sender) async throws -> (Data, URLResponse) {
        var state = initial
        do {
            let (data, response) = try await send(request)
            if let http = response as? HTTPURLResponse {
                try ProviderRequestFailure.check(http, data: data, service: service, now: now())
                if (200...299).contains(http.statusCode) { state.failures = 0; state.failure = nil }
                Self.logger.notice("service=\(service, privacy: .public) event=response http=\(http.statusCode)")
            }
            commit(state, service: service)
            return (data, response)
        } catch let failure as ProviderRequestFailure {
            if failure.isRateLimited {
                state.failures = min(state.failures + 1, 5)
                let delay = [60.0, 120, 240, 480, 900][state.failures - 1]
                state.failure = ProviderRequestFailure(isRateLimited: true,
                    retryAt: max(failure.retryAt ?? now(), now().addingTimeInterval(delay)),
                    httpStatus: failure.httpStatus, reason: failure.reason)
            } else { state.failure = failure }
            commit(state, service: service)
            let result = state.failure ?? failure
            Self.logger.notice("service=\(service, privacy: .public) event=failed http=\(result.httpStatus) retryAt=\(result.retryAt?.timeIntervalSince1970 ?? 0)")
            throw result
        }
    }

    private func load(service: String, identity: String) -> State {
        if let data = defaults.data(forKey: "subscriptionRequest.v1.\(service)") {
            do {
                let state = try JSONDecoder().decode(State.self, from: data)
                if state.identity == identity { return state }
            } catch { Self.logger.error("service=\(service, privacy: .public) event=cache_decode_failed") }
        }
        return State(identity: identity)
    }

    private func commit(_ state: State, service: String) {
        // A completion for a replaced credential must not restore its old cooldown.
        guard let data = defaults.data(forKey: "subscriptionRequest.v1.\(service)") else { return }
        do {
            guard try JSONDecoder().decode(State.self, from: data).identity == state.identity else { return }
            save(state, service: service)
        } catch { Self.logger.error("service=\(service, privacy: .public) event=cache_decode_failed") }
    }

    private func save(_ state: State, service: String) {
        do { defaults.set(try JSONEncoder().encode(state), forKey: "subscriptionRequest.v1.\(service)") }
        catch { Self.logger.error("service=\(service, privacy: .public) event=cache_encode_failed") }
    }
}

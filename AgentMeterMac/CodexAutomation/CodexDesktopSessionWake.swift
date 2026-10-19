import AppKit
import OSLog

/// Use Desktop's wake-only deep link, which checks the existing queue and resumes
/// the session without navigating a window. This sends no input and starts no
/// independent app-server; Desktop retains ownership of queue dispatch.
@MainActor
enum CodexDesktopSessionWake {
    private static let log = Logger(subsystem: "com.dothinker.app.agentmeter.mac", category: "CodexResume")
    struct Host {
        let bundleURL: URL
        let executable: URL
        let processID: pid_t
    }
    struct Destination: Equatable {
        let application: URL
        let threadURL: URL
        let processID: pid_t
    }
    enum Failure: Error { case invalidThread, hostUnavailable, timedOut }

    static func destination(executable: URL, threadID: String, hosts: [Host]) throws -> Destination {
        guard UUID(uuidString: threadID) != nil else { throw Failure.invalidThread }
        let matches = hosts.filter { $0.processID > 0 &&
            $0.executable.resolvingSymlinksInPath() == executable.resolvingSymlinksInPath() }
        guard matches.count == 1, let host = matches.first,
              let url = URL(string: "codex://threads/wake/" + threadID) else { throw Failure.hostUnavailable }
        return .init(application: host.bundleURL, threadURL: url, processID: host.processID)
    }

    static func wake(executable: URL, threadID: String) async throws {
        let hosts = NSWorkspace.shared.runningApplications.compactMap { app -> Host? in
            guard !app.isTerminated, let bundle = app.bundleURL,
                  let cli = try? CodexRuntimeReadProbe.hostExecutable(in: [bundle]) else { return nil }
            return .init(bundleURL: bundle, executable: cli, processID: app.processIdentifier)
        }
        let target = try destination(executable: executable, threadID: threadID, hosts: hosts)
        guard let app = NSRunningApplication(processIdentifier: target.processID), !app.isTerminated else {
            throw Failure.hostUnavailable
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = false
        configuration.promptsUserIfNeeded = false
        log.info("Requesting queued session wake thread=\(threadID, privacy: .public) hostPID=\(target.processID)")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion = Completion(continuation)
            NSWorkspace.shared.open([target.threadURL], withApplicationAt: target.application,
                                    configuration: configuration) { application, error in
                Task { @MainActor in
                    if let error { completion.finish(.failure(error)) }
                    else if application?.processIdentifier == target.processID {
                        log.info("Queued session wake delivered thread=\(threadID, privacy: .public) hostPID=\(target.processID)")
                        completion.finish(.success(()))
                    } else { completion.finish(.failure(Failure.hostUnavailable)) }
                }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                completion.finish(.failure(Failure.timedOut))
            }
        }
    }

    @MainActor
    private final class Completion {
        private var continuation: CheckedContinuation<Void, Error>?
        init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
        func finish(_ result: Result<Void, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(with: result)
        }
    }
}

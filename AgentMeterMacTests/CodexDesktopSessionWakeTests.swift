import XCTest
@testable import AgentMeter

@MainActor
final class CodexDesktopSessionWakeTests: XCTestCase {
    private let executable = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
    private let bundle = URL(fileURLWithPath: "/Applications/ChatGPT.app")
    private let thread = "01a14e2d-0987-7c22-91c8-1336eb6a2a6f"

    func testRoutesOnlyToHostThatAcceptedQueue() throws {
        let other = URL(fileURLWithPath: "/Applications/Other.app/Contents/Resources/codex")
        let destination = try CodexDesktopSessionWake.destination(executable: executable, threadID: thread,
            hosts: [.init(bundleURL: URL(fileURLWithPath: "/Applications/Other.app"), executable: other, processID: 1),
                    .init(bundleURL: bundle, executable: executable, processID: 42)])
        XCTAssertEqual(destination.application, bundle)
        XCTAssertEqual(destination.processID, 42)
        XCTAssertEqual(destination.threadURL.absoluteString, "codex://threads/wake/" + thread)
        XCTAssertNil(URLComponents(url: destination.threadURL, resolvingAgainstBaseURL: false)?.query)
    }

    func testInvalidThreadMissingOrAmbiguousHostCannotLaunchAnything() throws {
        let host = CodexDesktopSessionWake.Host(bundleURL: bundle, executable: executable, processID: 42)
        for id in ["", "../new", thread + "?prompt=continue", "https://example.com"] {
            XCTAssertThrowsError(try CodexDesktopSessionWake.destination(executable: executable, threadID: id, hosts: [host]))
        }
        for hosts in [[], [host, host], [.init(bundleURL: bundle, executable: executable, processID: 0)]] {
            XCTAssertThrowsError(try CodexDesktopSessionWake.destination(executable: executable, threadID: thread, hosts: hosts))
        }
    }
}

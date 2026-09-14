import Foundation
import XCTest
import AgentMeterCore
@testable import AgentMeter

final class CodexRuntimeReadProbeTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/private/tmp/agentmeter-runtime-test")

    func testHandshakeOnlyRequestsQuotaAndMetadata() throws {
        var state = CodexRuntimeReadProtocol(home: home, threadID: "target")
        XCTAssertEqual(try json(state.initialRequest())["method"] as? String, "initialize")
        let hello = try state.receive(frame(id: 1, result: ["codexHome": home.path, "platformOs": "macos", "userAgent": "test"]))
        XCTAssertEqual(try hello.outgoing.map { try json($0)["method"] as? String }, ["initialized", "account/rateLimits/read"])
        let quota = try state.receive(frame(id: 2, result: quotaResponse()))
        let read = try XCTUnwrap(quota.outgoing.first)
        let params = try XCTUnwrap(json(read)["params"] as? [String: Any])
        XCTAssertEqual(try json(read)["method"] as? String, "thread/read")
        XCTAssertEqual(params["includeTurns"] as? Bool, false)
        XCTAssertEqual(params["threadId"] as? String, "target")
        let done = try state.receive(frame(id: 3, result: ["thread": ["id": "target", "status": ["type": "idle"], "preview": "do not retain"]]))
        XCTAssertEqual(done.result?.thread?.status.type, "idle")
        XCTAssertFalse(try XCTUnwrap(done.result).canAutomaticallyResume)
    }

    func testWrongHomeWrongIDsAndServerRequestsFailClosed() throws {
        var wrongHome = CodexRuntimeReadProtocol(home: home, threadID: nil)
        XCTAssertThrowsError(try wrongHome.receive(frame(id: 1, result: ["codexHome": "/different", "platformOs": "macos", "userAgent": "test"]))) {
            XCTAssertEqual($0 as? CodexRuntimeProbeError, .homeMismatch)
        }
        var wrongID = CodexRuntimeReadProtocol(home: home, threadID: nil)
        XCTAssertThrowsError(try wrongID.receive(frame(id: 2, result: [:])))
        var request = CodexRuntimeReadProtocol(home: home, threadID: nil)
        XCTAssertThrowsError(try request.receive(data(["id": 5, "method": "item/commandExecution/requestApproval"]))) {
            XCTAssertEqual($0 as? CodexRuntimeProbeError, .serverRequest)
        }
        var booleanID = CodexRuntimeReadProtocol(home: home, threadID: nil)
        XCTAssertThrowsError(try booleanID.receive(data(["id": true, "result": [:]])))
    }

    func testNotificationsAreIgnoredAndWrongThreadIsRejected() throws {
        var state = CodexRuntimeReadProtocol(home: home, threadID: "target")
        XCTAssertTrue(try state.receive(data(["method": "turn/started", "params": [:]])).outgoing.isEmpty)
        _ = try state.receive(frame(id: 1, result: ["codexHome": home.path, "platformOs": "macos", "userAgent": "test"]))
        _ = try state.receive(frame(id: 2, result: quotaResponse()))
        XCTAssertThrowsError(try state.receive(frame(id: 3, result: ["thread": ["id": "other", "status": ["type": "idle"]]])))
    }

    func testBucketIdentityAndOptionalWindowsRemainUnknown() throws {
        let snapshot = try decode(quotaResponse())
        let evidence = try XCTUnwrap(snapshot.evidence(for: "codex", at: Date()))
        XCTAssertEqual(evidence.accountID, "account")
        XCTAssertEqual(evidence.windows.count, 2)
        XCTAssertEqual(evidence.blockingState, .clear)
        XCTAssertNil(snapshot.evidence(for: "other", at: Date()))
        var missingAccount = quotaResponse(); missingAccount.removeValue(forKey: "accountId")
        XCTAssertNil(try decode(missingAccount).evidence(for: "codex", at: Date()))
        var emptyBuckets = quotaResponse(); emptyBuckets["rateLimitsByLimitId"] = [String: Any]()
        XCTAssertNil(try decode(emptyBuckets).evidence(for: "codex", at: Date()))
        var mismatch = bucket(); mismatch["limitId"] = "different"
        XCTAssertNil(try decode(quotaResponse(bucket: mismatch)).evidence(for: "codex", at: Date()))
        var missingReset = bucket(); missingReset["primary"] = ["usedPercent": 0]
        XCTAssertNil(try decode(quotaResponse(bucket: missingReset)).evidence(for: "codex", at: Date()))
    }

    func testSpendRestrictionsAndSparseResponsesAreNotClear() throws {
        var restricted = bucket(); restricted["spendControlReached"] = true
        XCTAssertEqual(try decode(quotaResponse(bucket: restricted)).evidence(for: "codex", at: Date())?.blockingState, .accountRestriction)
        var sparse = bucket(); sparse.removeValue(forKey: "spendControlReached")
        XCTAssertEqual(try decode(quotaResponse(bucket: sparse)).evidence(for: "codex", at: Date())?.blockingState, .unknown)
        var unknown = bucket(); unknown["rateLimitReachedType"] = "future_restriction"
        XCTAssertEqual(try decode(quotaResponse(bucket: unknown)).evidence(for: "codex", at: Date())?.blockingState, .unknown)
        var reached = bucket(); reached["rateLimitReachedType"] = "rate_limit_reached"
        XCTAssertEqual(try decode(quotaResponse(bucket: reached)).evidence(for: "codex", at: Date())?.blockingState, .windowLimit)
    }

    func testProcessHandlesFragmentedJSONAndStopsAfterReadOnlyFlow() async throws {
        let folder = try temporaryFolder()
        let script = folder.appendingPathComponent("server.py")
        let code = #"""
import json, sys, os
def respond(i, result):
    line = json.dumps({'id': i, 'result': result}) + '\n'
    sys.stdout.write(line[:8]); sys.stdout.flush()
    sys.stdout.write(line[8:]); sys.stdout.flush()
assert json.loads(sys.stdin.readline())['method'] == 'initialize'
respond(1, {'codexHome': os.environ['CODEX_HOME'], 'platformOs': 'macos', 'userAgent': 'test'})
assert json.loads(sys.stdin.readline())['method'] == 'initialized'
assert json.loads(sys.stdin.readline())['method'] == 'account/rateLimits/read'
respond(2, {'accountId': 'test', 'rateLimits': {'limitId': 'codex'}})
msg = json.loads(sys.stdin.readline())
assert msg['method'] == 'thread/read'
assert msg['params']['includeTurns'] is False
respond(3, {'thread': {'id': msg['params']['threadId'], 'status': {'type': 'active'}}})
"""#
        try code.write(to: script, atomically: true, encoding: .utf8)
        let result = try await CodexRuntimeProbeProcess().run(executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [script.path], home: folder, threadID: "test-thread", timeoutSeconds: 3)
        XCTAssertEqual(result.thread?.status.type, "active")
        XCTAssertFalse(result.canAutomaticallyResume)
    }

    func testProcessTimeoutAndCancellationDoNotHang() async throws {
        let folder = try temporaryFolder()
        let executable = URL(fileURLWithPath: "/usr/bin/python3")
        do {
            _ = try await CodexRuntimeProbeProcess().run(executable: executable, arguments: ["-c", "import sys; sys.stdin.read()"],
                home: folder, threadID: nil, timeoutSeconds: 0.1)
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual(error as? CodexRuntimeProbeError, .timedOut) }
        let task = Task {
            try await CodexRuntimeProbeProcess().run(executable: executable, arguments: ["-c", "import sys; sys.stdin.read()"],
                home: folder, threadID: nil)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertEqual(error as? CodexRuntimeProbeError, .cancelled) }
    }

    func testEarlyExitAndOutputLimitFailClosed() async throws {
        let folder = try temporaryFolder()
        for (script, expected) in [("pass", CodexRuntimeProbeError.connectionClosed),
            ("import sys; sys.stdout.write('x' * (2*1024*1024)); sys.stdout.flush()", .outputLimit)] {
            do {
                _ = try await CodexRuntimeProbeProcess().run(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                    arguments: ["-c", script], home: folder, threadID: nil, timeoutSeconds: 3)
                XCTFail("Expected failure")
            } catch { XCTAssertEqual(error as? CodexRuntimeProbeError, expected) }
        }
    }

    func testMissingSocketDoesNotLaunchCLI() async throws {
        do {
            _ = try await CodexRuntimeReadProbe.read(executable: URL(fileURLWithPath: "/does-not-exist"), home: temporaryFolder(), threadID: nil)
            XCTFail("Expected missing socket")
        } catch { XCTAssertEqual(error as? CodexRuntimeProbeError, .missingSocket) }
    }

    private func bucket() -> [String: Any] {
        ["limitId": "codex", "primary": ["usedPercent": 0, "resetsAt": 2_000_003_600, "windowDurationMins": 300],
         "secondary": ["usedPercent": 0, "resetsAt": 2_000_604_800, "windowDurationMins": 10_080], "spendControlReached": false]
    }
    private func quotaResponse(bucket value: [String: Any]? = nil) -> [String: Any] {
        let b = value ?? bucket()
        return ["accountId": "account", "rateLimits": b, "rateLimitsByLimitId": ["codex": b]]
    }
    private func decode(_ object: [String: Any]) throws -> CodexRuntimeQuotaSnapshot {
        try JSONDecoder().decode(CodexRuntimeQuotaSnapshot.self, from: data(object))
    }
    private func frame(id: Int, result: [String: Any]) throws -> Data { try data(["id": id, "result": result]) }
    private func data(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    private func json(_ data: Data) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]) }
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: folder) }
        return folder
    }
}

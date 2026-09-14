import Foundation
import AppKit
import Darwin

enum CodexRuntimeReadProbe {
    /// Select the CLI bundled with one running host, never an unrelated CLI on PATH.
    @MainActor
    static func runningHostExecutable() throws -> URL {
        let executables = Set(NSWorkspace.shared.runningApplications.compactMap { app -> URL? in
            guard let bundle = app.bundleURL else { return nil }
            let executable = bundle.appendingPathComponent("Contents/Resources/codex")
            return FileManager.default.isExecutableFile(atPath: executable.path) ? executable : nil
        })
        guard executables.count == 1, let executable = executables.first else { throw CodexRuntimeProbeError.unsupportedHost }
        return executable
    }

    static func read(executable: URL, home: URL, threadID: String?) async throws -> CodexRuntimeProbeResult {
        let socket = home.appendingPathComponent("app-server-control/app-server-control.sock")
        let attributes = try? FileManager.default.attributesOfItem(atPath: socket.path)
        guard attributes?[.type] as? FileAttributeType == .typeSocket,
              (attributes?[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw CodexRuntimeProbeError.missingSocket
        }
        // Proxy attaches to an existing server. Never start/restart a daemon or load/resume a thread.
        return try await CodexRuntimeProbeProcess().run(
            executable: executable, arguments: ["app-server", "proxy", "--sock", socket.path],
            home: home, threadID: threadID
        )
    }
}

/// All mutable state and pipe I/O belong to queue. Only this short-lived proxy process is terminated.
final class CodexRuntimeProbeProcess: @unchecked Sendable {
    private let queue = DispatchQueue(label: "AgentMeter.codex.read-probe", qos: .utility)
    private let process = Process()
    private var stdin: Pipe?
    private var stdout: Pipe?
    private var stderr: Pipe?
    private var outputSource: DispatchSourceRead?
    private var errorSource: DispatchSourceRead?
    private var timeout: DispatchWorkItem?
    private var continuation: CheckedContinuation<CodexRuntimeProbeResult, Error>?
    private var protocolState: CodexRuntimeReadProtocol?
    private var buffer = Data()
    private var totalOutput = 0
    private var finished = false
    private var cancelledBeforeStart = false

    func run(executable: URL, arguments: [String], home: URL, threadID: String?,
             timeoutSeconds: Double = 8) async throws -> CodexRuntimeProbeResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { self.start(executable: executable, arguments: arguments, home: home,
                                         threadID: threadID, timeoutSeconds: timeoutSeconds, continuation: continuation) }
            }
        } onCancel: {
            self.queue.async {
                if self.continuation == nil { self.cancelledBeforeStart = true }
                else { self.finish(.failure(CodexRuntimeProbeError.cancelled)) }
            }
        }
    }

    private func start(executable: URL, arguments: [String], home: URL, threadID: String?, timeoutSeconds: Double,
                       continuation: CheckedContinuation<CodexRuntimeProbeResult, Error>) {
        guard self.continuation == nil, !finished else {
            continuation.resume(throwing: CodexRuntimeProbeError.unexpectedResponse); return
        }
        self.continuation = continuation
        guard !cancelledBeforeStart else { finish(.failure(CodexRuntimeProbeError.cancelled)); return }
        guard threadID.map({ !$0.isEmpty && $0.utf8.count <= 256 }) != false else {
            finish(.failure(CodexRuntimeProbeError.invalidResponse)); return
        }
        protocolState = CodexRuntimeReadProtocol(home: home, threadID: threadID)
        let input = Pipe(), output = Pipe(), errors = Pipe()
        stdin = input; stdout = output; stderr = errors
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = home.path
        process.environment = environment
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        do {
            try process.run()
            try input.fileHandleForReading.close()
            try output.fileHandleForWriting.close()
            try errors.fileHandleForWriting.close()
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            outputSource = source(for: output.fileHandleForReading, isError: false)
            errorSource = source(for: errors.fileHandleForReading, isError: true)
            let deadline = DispatchWorkItem { [weak self] in self?.finish(.failure(CodexRuntimeProbeError.timedOut)) }
            timeout = deadline
            queue.asyncAfter(deadline: .now() + max(0.05, min(timeoutSeconds, 10)), execute: deadline)
            try input.fileHandleForWriting.write(contentsOf: protocolState!.initialRequest())
        } catch { finish(.failure(CodexRuntimeProbeError.connectionClosed)) }
    }

    private func source(for handle: FileHandle, isError: Bool) -> DispatchSourceRead {
        let source = DispatchSource.makeReadSource(fileDescriptor: handle.fileDescriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.read(handle, isError: isError) }
        source.setCancelHandler { try? handle.close() }
        source.resume()
        return source
    }

    private func read(_ handle: FileHandle, isError: Bool) {
        guard !finished else { return }
        var bytes = [UInt8](repeating: 0, count: 16 * 1024)
        let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
        if count < 0 {
            if errno != EINTR { finish(.failure(CodexRuntimeProbeError.connectionClosed)) }
            return
        }
        if count == 0 {
            if isError { errorSource?.cancel() }
            else { finish(.failure(CodexRuntimeProbeError.connectionClosed)) }
            return
        }
        totalOutput += count
        guard totalOutput <= 2 * 1024 * 1024 else { finish(.failure(CodexRuntimeProbeError.outputLimit)); return }
        guard !isError else { return } // Drain stderr without collecting/logging possibly private details.
        buffer.append(contentsOf: bytes.prefix(count))
        while !finished, let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer.prefix(upTo: newline))
            buffer = Data(buffer.suffix(from: buffer.index(after: newline)))
            guard line.count <= 1024 * 1024 else { finish(.failure(CodexRuntimeProbeError.outputLimit)); return }
            do {
                guard let update = try protocolState?.receive(line) else { throw CodexRuntimeProbeError.invalidResponse }
                for message in update.outgoing { try stdin?.fileHandleForWriting.write(contentsOf: message) }
                if let result = update.result { finish(.success(result)); return }
            } catch { finish(.failure(error)); return }
        }
        if buffer.count > 1024 * 1024 { finish(.failure(CodexRuntimeProbeError.outputLimit)) }
    }

    private func finish(_ result: Result<CodexRuntimeProbeResult, Error>) {
        guard !finished else { return }
        finished = true
        timeout?.cancel(); timeout = nil
        if let outputSource { outputSource.cancel() } else { try? stdout?.fileHandleForReading.close() }
        if let errorSource { errorSource.cancel() } else { try? stderr?.fileHandleForReading.close() }
        try? stdin?.fileHandleForWriting.close()
        try? stdin?.fileHandleForReading.close()
        try? stdout?.fileHandleForWriting.close()
        try? stderr?.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        buffer.removeAll()
        protocolState = nil
        continuation?.resume(with: result)
        continuation = nil
    }
}

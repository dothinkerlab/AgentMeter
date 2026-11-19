import AgentMeterCore
import Darwin
import CoreFoundation
import Foundation

struct MacAntigravityQuota: Equatable, Sendable {
    struct Group: Equatable, Sendable {
        let name: String
        let buckets: [Bucket]
    }

    struct Bucket: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let remainingFraction: Double
        let resetsAt: Date?
    }

    static let source = "antigravity_cli_usage"

    let groups: [Group]
    let updatedAt: Date

    var snapshot: QuotaSnapshot {
        let windows: [QuotaWindow] = groups.flatMap { group -> [QuotaWindow] in
            group.buckets.map { bucket in
                QuotaWindow(
                    usedPercent: (1 - bucket.remainingFraction) * 100,
                    resetsAt: bucket.resetsAt,
                    kind: .antigravityBucket,
                    antigravityBucket: .init(id: bucket.id, group: group.name, label: bucket.name)
                )
            }
        }
        return QuotaSnapshot(tool: .antigravity, plan: nil, windows: windows, confidence: .fresh,
                             collectedBy: .mac, source: Self.source, updatedAt: updatedAt)
    }

    static func parse(_ data: Data, now: Date) throws -> Self {
        guard let report = try? JSONDecoder().decode(Report.self, from: data),
              report.status == "SUCCESS", report.numTurns == 0, report.command.name == "usage" else {
            throw MacAntigravityFailure.invalidReport
        }

        let iso = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var seen = Set<String>()
        let groups = report.command.data.groups.compactMap { group -> Group? in
            let buckets = group.buckets.compactMap { value -> Bucket? in
                guard let id = value.id, !id.isEmpty,
                      let fraction = value.remainingFraction, fraction.isFinite, (0...1).contains(fraction),
                      seen.insert(id).inserted else { return nil }
                let reset = value.resetTime.flatMap { iso.date(from: $0) ?? fractional.date(from: $0) }
                return Bucket(id: id, name: value.name.flatMap { $0.isEmpty ? nil : $0 } ?? id,
                              remainingFraction: fraction, resetsAt: reset)
            }
            return buckets.isEmpty ? nil : Group(name: group.name, buckets: buckets)
        }
        guard !groups.isEmpty else { throw MacAntigravityFailure.invalidReport }
        return Self(groups: groups, updatedAt: now)
    }

    private struct Report: Decodable {
        let status: String
        let numTurns: Int
        let command: Command

        enum CodingKeys: String, CodingKey {
            case status, command
            case numTurns = "num_turns"
        }

        struct Command: Decodable {
            let name: String
            let data: Payload
        }

        struct Payload: Decodable {
            let groups: [WireGroup]
        }

        struct WireGroup: Decodable {
            let name: String
            let buckets: [WireBucket]
        }

        struct WireBucket: Decodable {
            let id: String?
            let name: String?
            let remainingFraction: Double?
            let resetTime: String?

            enum CodingKeys: String, CodingKey {
                case id, name
                case remainingFraction = "remaining_fraction"
                case resetTime = "reset_time"
            }

            init(from decoder: Decoder) throws {
                let values = try? decoder.container(keyedBy: CodingKeys.self)
                id = try? values?.decode(String.self, forKey: .id)
                name = try? values?.decode(String.self, forKey: .name)
                remainingFraction = try? values?.decode(Double.self, forKey: .remainingFraction)
                resetTime = try? values?.decode(String.self, forKey: .resetTime)
            }
        }
    }
}

enum MacAntigravityFailure: Error, Equatable {
    case missingCLI, unsupportedCLI, signInRequired
    case slashCommandsDisabled, unverifiedSettings
    case timedOut, commandFailed, invalidReport
}

struct MacAntigravityCommandResult: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data
}

struct MacAntigravityCLI: Sendable {
    typealias Run = @Sendable (URL, [String], URL, [String: String]) async throws -> MacAntigravityCommandResult
    static let usageArguments = ["-p", "/usage", "--output-format", "json"]

    var home = FileManager.default.homeDirectoryForCurrentUser
    var systemPaths = ["/opt/homebrew/bin/agy", "/usr/local/bin/agy"]
    var isExecutable: @Sendable (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) }
    var run: Run = { executable, arguments, directory, environment in
        try await MacAntigravityProcess().run(executable, arguments, directory, environment)
    }

    func fetch(now: @Sendable () -> Date = { Date() }) async throws -> MacAntigravityQuota {
        try Task.checkCancellation()
        let paths = [home.appendingPathComponent(".local/bin/agy")] + systemPaths.map { URL(fileURLWithPath: $0) }
        let candidates = paths.filter(isExecutable)
        guard !candidates.isEmpty else { throw MacAntigravityFailure.missingCLI }

        // A fresh directory avoids loading any workspace settings, rules or plugins.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentMeter-agy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        var probeFailure: MacAntigravityFailure = .unsupportedCLI
        for candidate in candidates {
            let executable = candidate.resolvingSymlinksInPath()
            guard !executable.pathComponents.contains(where: { $0.lowercased().hasSuffix(".app") }) else { continue }
            do {
                try Task.checkCancellation()
                let help = try await run(executable, ["--help"], directory, environment)
                let helpText = String(decoding: help.stdout + help.stderr, as: UTF8.self)
                guard help.status == 0, helpText.contains("--output-format"), helpText.contains("--print"),
                      helpText.contains("--disable-slash-commands") else { continue }
                try Task.checkCancellation()
                let version = try await run(executable, ["--version"], directory, environment)
                guard version.status == 0, Self.supportsUsage(String(decoding: version.stdout, as: UTF8.self)) else { continue }
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as MacAntigravityFailure {
                probeFailure = failure
                continue
            }

            try Self.checkSettings(home.appendingPathComponent(".gemini/antigravity-cli/settings.json"))
            try Task.checkCancellation()
            let result = try await run(executable, Self.usageArguments, directory, environment)
            try Task.checkCancellation()
            guard result.status == 0 else { throw Self.commandFailure(result) }
            return try MacAntigravityQuota.parse(result.stdout, now: now())
        }
        throw probeFailure
    }

    static func supportsUsage(_ output: String) -> Bool {
        // Match the version line, not an arbitrary dotted number in a diagnostic.
        let firstLine = output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let pattern = #"(?i)^\s*(?:(?:agy|antigravity(?: cli)?)(?: version)?\s+|version\s+)?v?([0-9]+)\.([0-9]+)\.([0-9]+)(-[0-9a-z.-]+)?(?:\+[0-9a-z.-]+)?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: firstLine, range: NSRange(firstLine.startIndex..., in: firstLine)) else { return false }
        let numbers = (1...3).compactMap { index in Range(match.range(at: index), in: firstLine).flatMap { Int(firstLine[$0]) } }
        return numbers.count == 3 && (match.range(at: 4).location == NSNotFound)
            && !numbers.lexicographicallyPrecedes([1, 1, 11])
    }

    static func checkSettings(_ file: URL) throws {
        let fd = open(file.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return } // The documented default is enabled.
            throw MacAntigravityFailure.unverifiedSettings
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            let capacity = 256 * 1024
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= capacity,
                  let data = try handle.read(upToCount: capacity + 1), data.count <= capacity,
                  let settings = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MacAntigravityFailure.unverifiedSettings
            }
            for (key, value) in settings where key.caseInsensitiveCompare("disableSlashCommands") == .orderedSame {
                guard let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else {
                    throw MacAntigravityFailure.unverifiedSettings
                }
                if flag.boolValue { throw MacAntigravityFailure.slashCommandsDisabled }
            }
        } catch let failure as MacAntigravityFailure {
            throw failure
        } catch {
            throw MacAntigravityFailure.unverifiedSettings
        }
    }

    private static func commandFailure(_ result: MacAntigravityCommandResult) -> MacAntigravityFailure {
        // Classify locally, then discard all of the CLI's output.
        let diagnostic = String(decoding: result.stderr, as: UTF8.self).lowercased()
        if ["authentication required", "not authenticated", "not logged in", "not signed in", "please log in",
            "please sign in", "unauthenticated"].contains(where: { diagnostic.contains($0) }) {
            return .signInRequired
        }
        return .commandFailed
    }
}

/// A single invocation. One serial queue owns the pipes, deadline and continuation.
final class MacAntigravityProcess: @unchecked Sendable {
    private let queue = DispatchQueue(label: "AgentMeter.agy", qos: .utility)
    private let child = Process()
    private let timeout: TimeInterval
    private let outputLimit: Int
    private var deadline: DispatchWorkItem?
    private var outputSource: DispatchSourceRead?
    private var errorSource: DispatchSourceRead?
    private var stdout = Data()
    private var stderr = Data()
    private var exitStatus: Int32?
    private var failure: Error?
    private var continuation: CheckedContinuation<MacAntigravityCommandResult, Error>?

    init(timeout: TimeInterval = 10, outputLimit: Int = 512 * 1024) {
        self.timeout = timeout
        self.outputLimit = outputLimit
    }

    func run(_ executable: URL, _ arguments: [String], _ directory: URL,
             _ environment: [String: String]) async throws -> MacAntigravityCommandResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    self.continuation = continuation
                    if let failure = self.failure {
                        self.complete(.failure(failure))
                    } else {
                        self.start(executable, arguments, directory, environment)
                    }
                }
            }
        } onCancel: {
            self.queue.async { self.stop(CancellationError()) }
        }
    }

    private func start(_ executable: URL, _ arguments: [String], _ directory: URL,
                       _ environment: [String: String]) {
        let output = Pipe(), errors = Pipe()
        child.executableURL = executable
        child.arguments = arguments
        child.currentDirectoryURL = directory
        child.environment = environment
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = output
        child.standardError = errors
        child.terminationHandler = { [weak self] child in
            let status = child.terminationStatus
            guard let self else { return }
            self.queue.async {
                self.exitStatus = status
                self.completeIfReady()
            }
        }
        do {
            try child.run()
        } catch {
            complete(.failure(MacAntigravityFailure.commandFailed))
            return
        }
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        outputSource = readSource(output.fileHandleForReading, isError: false)
        errorSource = readSource(errors.fileHandleForReading, isError: true)
        let deadline = DispatchWorkItem { [weak self] in self?.stop(MacAntigravityFailure.timedOut) }
        self.deadline = deadline
        queue.asyncAfter(deadline: .now() + timeout, execute: deadline)
    }

    private func readSource(_ handle: FileHandle, isError: Bool) -> DispatchSourceRead {
        let source = DispatchSource.makeReadSource(fileDescriptor: handle.fileDescriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.drain(handle, isError: isError) }
        source.setCancelHandler { try? handle.close() }
        source.resume()
        return source
    }

    private func drain(_ handle: FileHandle, isError: Bool) {
        guard failure == nil else { return }
        var bytes = [UInt8](repeating: 0, count: 16 * 1024)
        let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
        if count == 0 {
            if isError { errorSource?.cancel(); errorSource = nil }
            else { outputSource?.cancel(); outputSource = nil }
            completeIfReady()
        } else if count < 0 {
            if errno != EINTR { stop(MacAntigravityFailure.commandFailed) }
        } else if stdout.count + stderr.count + count > outputLimit {
            stop(MacAntigravityFailure.invalidReport)
        } else if isError {
            stderr.append(contentsOf: bytes.prefix(count))
        } else {
            stdout.append(contentsOf: bytes.prefix(count))
        }
    }

    private func stop(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        outputSource?.cancel(); outputSource = nil
        errorSource?.cancel(); errorSource = nil
        // Reap the child before returning so a subsequent refresh cannot overlap.
        if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        completeIfReady()
    }

    private func completeIfReady() {
        guard let exitStatus, outputSource == nil, errorSource == nil else { return }
        if let failure { complete(.failure(failure)) }
        else { complete(.success(.init(status: exitStatus, stdout: stdout, stderr: stderr))) }
    }

    private func complete(_ result: Result<MacAntigravityCommandResult, Error>) {
        deadline?.cancel()
        continuation?.resume(with: result)
        continuation = nil
    }
}

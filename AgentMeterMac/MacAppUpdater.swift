import Foundation
import Combine
import CryptoKit
import AgentMeterCore

struct MacUpdateRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
    }
    let tag_name: String
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
}

enum MacUpdateError: Error, LocalizedError {
    case invalidVersion, missingAsset, invalidResponse, rateLimited, checksum, save

    var errorDescription: String? {
        let key: String
        switch self {
        case .invalidVersion: key = "无法读取更新版本信息。"
        case .missingAsset: key = "新版本缺少安装包或校验文件。"
        case .invalidResponse: key = "更新服务器响应异常，请稍后重试。"
        case .rateLimited: key = "更新请求受限，请稍后重试。"
        case .checksum: key = "安装包校验失败，请重新下载。"
        case .save: key = "无法保存安装包到下载文件夹，请检查空间和权限。"
        }
        return L10n.string(key)
    }
}

struct MacUpdateCandidate {
    let version: String
    let build: Int
    let installer: MacUpdateRelease.Asset
    let checksums: MacUpdateRelease.Asset

    static func versionParts(_ value: String) throws -> [Int] {
        let value = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              parts.allSatisfy({ Int($0) != nil }) else { throw MacUpdateError.invalidVersion }
        return parts.map { Int($0)! } + Array(repeating: 0, count: 3 - parts.count)
    }

    static func select(_ release: MacUpdateRelease, currentVersion: String, currentBuild: String) throws -> Self? {
        guard !release.draft, !release.prerelease else { return nil }
        let remote = try versionParts(release.tag_name)
        let local = try versionParts(currentVersion)
        guard let localBuild = Int(currentBuild), localBuild >= 0 else { throw MacUpdateError.invalidVersion }
        if remote.lexicographicallyPrecedes(local) { return nil }
        let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        let prefix = "AgentMeter-\(version)-"
        let installers = release.assets.compactMap { asset -> (MacUpdateRelease.Asset, Int)? in
            guard asset.name.hasPrefix(prefix), asset.name.hasSuffix(".dmg") else { return nil }
            let number = asset.name.dropFirst(prefix.count).dropLast(4)
            guard !number.isEmpty, number.allSatisfy({ $0.isASCII && $0.isNumber }), let build = Int(number) else { return nil }
            return (asset, build)
        }
        guard let (installer, build) = installers.max(by: { $0.1 < $1.1 }) else { throw MacUpdateError.missingAsset }
        if remote == local && build <= localBuild { return nil }
        guard let checksums = release.assets.first(where: { $0.name == "SHA256SUMS.txt" }) else { throw MacUpdateError.missingAsset }
        return Self(version: version, build: build, installer: installer, checksums: checksums)
    }
}

protocol MacUpdateTransport {
    func data(from url: URL) async throws -> Data
    func download(from url: URL, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL
}

private final class MacDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (Double?) -> Void
    init(_ progress: @escaping @Sendable (Double?) -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesExpectedToWrite > 0 ? min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) : nil)
    }
}

struct MacUpdateHTTPTransport: MacUpdateTransport {
    private func request(_ url: URL) throws -> URLRequest {
        guard url.scheme == "https" else { throw MacUpdateError.invalidResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("AgentMeter", forHTTPHeaderField: "User-Agent")
        return request
    }
    private func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw MacUpdateError.invalidResponse }
        if response.statusCode == 403 || response.statusCode == 429 { throw MacUpdateError.rateLimited }
        guard (200...299).contains(response.statusCode) else { throw MacUpdateError.invalidResponse }
    }
    func data(from url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request(url))
        try validate(response)
        return data
    }
    func download(from url: URL, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        let (file, response) = try await URLSession.shared.download(for: request(url), delegate: MacDownloadProgress(progress))
        do { try validate(response) } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        return file
    }
}

protocol MacUpdateFileStore {
    func verifyAndSave(temporaryFile: URL, filename: String, checksums: Data) throws -> URL
    func removeTemporaryFile(_ url: URL)
}

struct MacUpdateDownloadsStore: MacUpdateFileStore {
    var directory: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    func removeTemporaryFile(_ url: URL) { try? FileManager.default.removeItem(at: url) }
    func verifyAndSave(temporaryFile: URL, filename: String, checksums: Data) throws -> URL {
        guard let text = String(data: checksums, encoding: .utf8) else { throw MacUpdateError.checksum }
        let hashes = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let columns = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard columns.count == 2 else { return nil }
            let name = columns[1].trimmingCharacters(in: .whitespaces)
            guard name == filename || name == "*" + filename else { return nil }
            return String(columns[0]).lowercased()
        }
        guard hashes.count == 1, let expected = hashes.first, expected.count == 64 else { throw MacUpdateError.checksum }
        let handle = try FileHandle(forReadingFrom: temporaryFile)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == expected else { throw MacUpdateError.checksum }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var destination = directory.appendingPathComponent(filename)
            var suffix = 1
            while true {
                do {
                    // moveItem refuses to overwrite, including if another process wins the race.
                    try FileManager.default.moveItem(at: temporaryFile, to: destination)
                    return destination
                } catch {
                    guard FileManager.default.fileExists(atPath: destination.path) else { throw error }
                    destination = directory.appendingPathComponent(String(filename.dropLast(4)) + " (\(suffix)).dmg")
                    suffix += 1
                }
            }
        } catch { throw MacUpdateError.save }
    }
}

actor MacUpdateService {
    let transport: any MacUpdateTransport
    let files: any MacUpdateFileStore
    init(transport: any MacUpdateTransport = MacUpdateHTTPTransport(), files: any MacUpdateFileStore = MacUpdateDownloadsStore()) {
        self.transport = transport
        self.files = files
    }
    func check(version: String, build: String) async throws -> MacUpdateCandidate? {
        let url = URL(string: "https://api.github.com/repos/dothinkerlab/AgentMeter/releases/latest")!
        let data = try await transport.data(from: url)
        let release: MacUpdateRelease
        do { release = try JSONDecoder().decode(MacUpdateRelease.self, from: data) }
        catch { throw MacUpdateError.invalidResponse }
        return try MacUpdateCandidate.select(release, currentVersion: version, currentBuild: build)
    }
    func download(_ candidate: MacUpdateCandidate, progress: @escaping @Sendable (Double?) -> Void, verifying: @escaping @Sendable () -> Void) async throws -> URL {
        let checksums = try await transport.data(from: candidate.checksums.browser_download_url)
        let temporaryFile = try await transport.download(from: candidate.installer.browser_download_url, progress: progress)
        defer { files.removeTemporaryFile(temporaryFile) }
        verifying()
        return try files.verifyAndSave(temporaryFile: temporaryFile, filename: candidate.installer.name, checksums: checksums)
    }
}

@MainActor
final class MacAppUpdater: ObservableObject {
    enum State {
        case idle, checking, upToDate, downloading(Double?), verifying, completed(URL), failed(String)
    }
    @Published private(set) var state: State = .idle
    private let service: MacUpdateService
    private let version: String
    private let build: String
    private var task: Task<Void, Never>?
    var isBusy: Bool { task != nil }

    init(service: MacUpdateService = MacUpdateService(), version: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "", build: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") {
        self.service = service
        self.version = version
        self.build = build
    }
    func checkForUpdates() {
        guard task == nil else { return }
        state = .checking
        task = Task {
            var result: State
            do {
                if let candidate = try await service.check(version: version, build: build) {
                    state = .downloading(nil)
                    let file = try await service.download(candidate, progress: { [weak self] progress in
                        Task { @MainActor in
                            guard let self, case .downloading = self.state else { return }
                            self.state = .downloading(progress)
                        }
                    }, verifying: { [weak self] in
                        Task { @MainActor in
                            guard let self, case .downloading = self.state else { return }
                            self.state = .verifying
                        }
                    })
                    result = .completed(file)
                } else { result = .upToDate }
            } catch { result = .failed(error.localizedDescription) }
            task = nil
            state = result
        }
    }
}

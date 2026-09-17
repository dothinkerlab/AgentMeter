import XCTest
import CryptoKit
@testable import AgentMeter

final class MacAppUpdaterTests: XCTestCase {
    private func release(_ version: String, build: Int = 22, draft: Bool = false, prerelease: Bool = false) -> MacUpdateRelease {
        MacUpdateRelease(tag_name: "v\(version)", draft: draft, prerelease: prerelease, assets: [
            .init(name: "AgentMeter-\(version)-\(build).dmg", browser_download_url: URL(string: "https://example.com/app.dmg")!),
            .init(name: "SHA256SUMS.txt", browser_download_url: URL(string: "https://example.com/SHA256SUMS.txt")!)
        ])
    }

    func testNumericVersionOrderingAndMajorVersions() throws {
        for (local, remote) in [("1.9", "1.10"), ("1.10", "1.11"), ("1.11", "2.0"), ("1.9", "1.9.1")] {
            XCTAssertNotNil(try MacUpdateCandidate.select(release(remote), currentVersion: local, currentBuild: "99"))
            XCTAssertNil(try MacUpdateCandidate.select(release(local, build: 999), currentVersion: remote, currentBuild: "1"))
        }
    }

    func testEqualVersionsUseBuildNumber() throws {
        XCTAssertNotNil(try MacUpdateCandidate.select(release("2.0.0", build: 22), currentVersion: "2.0", currentBuild: "21"))
        XCTAssertNil(try MacUpdateCandidate.select(release("2.0", build: 21), currentVersion: "2.0.0", currentBuild: "21"))
        XCTAssertNil(try MacUpdateCandidate.select(release("2.0", build: 20), currentVersion: "2.0", currentBuild: "21"))
    }

    func testIgnoresUnpublishedAndPrerelease() throws {
        XCTAssertNil(try MacUpdateCandidate.select(release("2.0", draft: true), currentVersion: "1.9", currentBuild: "21"))
        XCTAssertNil(try MacUpdateCandidate.select(release("2.0", prerelease: true), currentVersion: "1.9", currentBuild: "21"))
    }

    func testInvalidMetadataAndMissingAssets() {
        for version in ["", "2", "2.x", "2..0", "2.0-beta"] {
            XCTAssertThrowsError(try MacUpdateCandidate.versionParts(version))
        }
        let missing = MacUpdateRelease(tag_name: "v2.0", draft: false, prerelease: false, assets: [])
        XCTAssertThrowsError(try MacUpdateCandidate.select(missing, currentVersion: "1.9", currentBuild: "21"))
        let withoutChecksum = MacUpdateRelease(tag_name: "v2.0", draft: false, prerelease: false, assets: [release("2.0").assets[0]])
        XCTAssertThrowsError(try MacUpdateCandidate.select(withoutChecksum, currentVersion: "1.9", currentBuild: "21"))
    }

    func testVerifiedDownloadPreservesExistingFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = MacUpdateDownloadsStore(directory: root.appendingPathComponent("Downloads"))
        let data = Data("installer contents".utf8)
        let filename = "AgentMeter-2.0-22.dmg"
        let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let sums = Data("\(checksum)  \(filename)\n".utf8)
        for expected in [filename, "AgentMeter-2.0-22 (1).dmg"] {
            let temp = root.appendingPathComponent(UUID().uuidString)
            try data.write(to: temp)
            let saved = try store.verifyAndSave(temporaryFile: temp, filename: filename, checksums: sums)
            XCTAssertEqual(saved.lastPathComponent, expected)
            XCTAssertEqual(try Data(contentsOf: saved), data)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).count, 2)
    }

    func testChecksumMismatchAndSaveFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let temp = root.appendingPathComponent("installer")
        let data = Data("installer".utf8)
        try data.write(to: temp)
        let store = MacUpdateDownloadsStore(directory: temp) // A file cannot be the destination directory.
        XCTAssertThrowsError(try store.verifyAndSave(temporaryFile: temp, filename: "app.dmg", checksums: Data("bad  app.dmg".utf8))) {
            guard case MacUpdateError.checksum = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertThrowsError(try store.verifyAndSave(temporaryFile: temp, filename: "app.dmg", checksums: Data("\(hash)  app.dmg".utf8))) {
            guard case MacUpdateError.save = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
    }

    func testServiceCleansUpOnVerificationFailure() async throws {
        let transport = StubTransport()
        let files = StubFiles(failure: MacUpdateError.checksum)
        let service = MacUpdateService(transport: transport, files: files)
        let candidate = try XCTUnwrap(MacUpdateCandidate.select(release("2.0"), currentVersion: "1.9", currentBuild: "21"))
        do {
            _ = try await service.download(candidate, progress: { _ in }, verifying: {})
            XCTFail("Expected verification failure")
        } catch { XCTAssertTrue(error is MacUpdateError) }
        XCTAssertEqual(files.removed, [transport.temporaryFile])
    }

    @MainActor
    func testAutomaticDownloadAndDuplicateClickProtection() async throws {
        let transport = StubTransport()
        let files = StubFiles()
        let updater = MacAppUpdater(service: MacUpdateService(transport: transport, files: files), version: "1.9", build: "21")
        updater.checkForUpdates()
        updater.checkForUpdates()
        XCTAssertTrue(updater.isBusy)
        for _ in 0..<1000 {
            if !updater.isBusy { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        guard case .completed(let file) = updater.state else { return XCTFail("Expected completed state") }
        XCTAssertEqual(file, files.saved)
        XCTAssertEqual(transport.downloadCount, 1)
        XCTAssertEqual(files.removed, [transport.temporaryFile])
    }

    @MainActor
    func testNetworkFailureCanBeRetried() async throws {
        let transport = StubTransport()
        transport.failure = URLError(.notConnectedToInternet)
        let updater = MacAppUpdater(service: MacUpdateService(transport: transport, files: StubFiles()), version: "1.9", build: "21")
        updater.checkForUpdates()
        for _ in 0..<1000 {
            if !updater.isBusy { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        guard case .failed = updater.state else { return XCTFail("Expected failure") }
        transport.failure = nil
        updater.checkForUpdates()
        for _ in 0..<1000 {
            if !updater.isBusy { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        guard case .completed = updater.state else { return XCTFail("Expected successful retry") }
    }

    @MainActor
    func testUpToDateDoesNotDownload() async throws {
        let transport = StubTransport()
        let updater = MacAppUpdater(service: MacUpdateService(transport: transport, files: StubFiles()), version: "2.0", build: "22")
        updater.checkForUpdates()
        for _ in 0..<1000 {
            if !updater.isBusy { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        guard case .upToDate = updater.state else { return XCTFail("Expected up-to-date state") }
        XCTAssertEqual(transport.downloadCount, 0)
    }
}

private final class StubTransport: MacUpdateTransport {
    var failure: Error?
    var downloadCount = 0
    let temporaryFile = URL(fileURLWithPath: "/tmp/mock-installer.dmg")
    func data(from url: URL) async throws -> Data {
        if let failure { throw failure }
        if url.lastPathComponent == "latest" {
            return Data(#"{"tag_name":"v2.0","draft":false,"prerelease":false,"assets":[{"name":"AgentMeter-2.0-22.dmg","browser_download_url":"https://example.com/app.dmg"},{"name":"SHA256SUMS.txt","browser_download_url":"https://example.com/SHA256SUMS.txt"}]}"#.utf8)
        }
        return Data()
    }
    func download(from url: URL, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        downloadCount += 1
        progress(0.5)
        return temporaryFile
    }
}

private final class StubFiles: MacUpdateFileStore {
    var removed: [URL] = []
    let failure: Error?
    let saved = URL(fileURLWithPath: "/tmp/Downloads/AgentMeter-2.0-22.dmg")
    init(failure: Error? = nil) { self.failure = failure }
    func verifyAndSave(temporaryFile: URL, filename: String, checksums: Data) throws -> URL {
        if let failure { throw failure }
        return saved
    }
    func removeTemporaryFile(_ url: URL) { removed.append(url) }
}

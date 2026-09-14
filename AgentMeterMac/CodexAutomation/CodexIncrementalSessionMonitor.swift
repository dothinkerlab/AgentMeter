import Foundation
import AgentMeterCore
import CryptoKit

struct CodexMonitorScan: Sendable {
    var checkpoint: CodexMonitorCheckpoint
    var filesRead = 0
    var bytesRead = 0
    var incomplete = false
    var directoryAvailable = false
}

struct CodexIncrementalSessionMonitor: Sendable {
    var bytesPerFile = 512 * 1024
    var bytesPerPoll = 4 * 1024 * 1024
    var entryLimit = 20_000

    func scan(_ checkpoint: CodexMonitorCheckpoint, now: Date) -> CodexMonitorScan {
        var result = CodexMonitorScan(checkpoint: checkpoint)
        let manager = FileManager.default
        let directory = URL(fileURLWithPath: checkpoint.homePath).appendingPathComponent("sessions")
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let root = try? directory.resourceValues(forKeys: keys), root.isDirectory == true,
              root.isSymbolicLink != true else {
            for cursor in checkpoint.cursors.values {
                result.checkpoint.queue.invalidate(threadID: cursor.threadID, at: now)
            }
            return result
        }
        result.directoryAvailable = true
        guard let enumerator = manager.enumerator(at: directory, includingPropertiesForKeys: Array(keys),
                                                  options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                  errorHandler: { _, _ in result.incomplete = true; return true }) else {
            result.incomplete = true
            return result
        }
        var files: [(URL, Date)] = []
        var count = 0
        for case let file as URL in enumerator {
            count += 1
            if count > entryLimit || Task.isCancelled { result.incomplete = true; break }
            guard let values = try? file.resourceValues(forKeys: keys) else { result.incomplete = true; continue }
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard values.isRegularFile == true, file.pathExtension == "jsonl" else { continue }
            files.append((file, values.contentModificationDate ?? .distantPast))
            files.sort { $0.1 == $1.1 ? $0.0.path < $1.0.path : $0.1 > $1.1 }
            if files.count > 200 { files.removeLast(); result.incomplete = true }
        }
        let selected = Set(files.map { $0.0.path })
        // Missing/archived/unobserved sources cannot retain a live candidate.
        for (path, cursor) in checkpoint.cursors where !selected.contains(path) {
            result.checkpoint.queue.invalidate(threadID: cursor.threadID, at: now)
            result.checkpoint.cursors.removeValue(forKey: path)
        }
        for (file, _) in files {
            if Task.isCancelled || result.bytesRead + bytesPerFile > bytesPerPoll {
                result.incomplete = true
                break
            }
            do {
                let attributes = try manager.attributesOfItem(atPath: file.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else {
                    result.incomplete = true; continue
                }
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                let size = try handle.seekToEnd()
                var cursor = result.checkpoint.cursors[file.path]
                var replaced = cursor.map { $0.fileID != inode || size < $0.offset } ?? false
                if !replaced, let previous = cursor, let digest = previous.anchorDigest {
                    let observed = try anchor(handle, offset: previous.offset)
                    result.bytesRead += observed.bytes
                    replaced = observed.digest != digest
                }
                if replaced, let previous = cursor {
                    result.checkpoint.queue.invalidate(threadID: previous.threadID, at: now)
                    cursor = nil
                }
                if cursor == nil {
                    try handle.seek(toOffset: 0)
                    let header = try handle.read(upToCount: 64 * 1024) ?? Data()
                    result.bytesRead += header.count
                    guard let metadata = CodexSessionEventParser.header(header) else {
                        // Unknown origins/oversized metadata aren't suitable monitoring sources.
                        result.incomplete = true
                        continue
                    }
                    let baseline = !checkpoint.baselineComplete || replaced
                    var discard = false
                    if baseline && size > 0 {
                        try handle.seek(toOffset: size - 1)
                        discard = try handle.read(upToCount: 1)?.last != 10
                    }
                    cursor = .init(fileID: inode, offset: baseline ? size : 0, discardUntilNewline: discard,
                                   threadID: metadata.threadID, projectName: metadata.projectName)
                }
                guard var current = cursor else { continue }
                if current.offset < size {
                    let readLimit = min(bytesPerFile, bytesPerPoll - result.bytesRead - 64)
                    guard readLimit > 0 else { result.incomplete = true; break }
                    try handle.seek(toOffset: current.offset)
                    let data = try handle.read(upToCount: readLimit) ?? Data()
                    result.bytesRead += data.count
                    result.filesRead += 1
                    consume(data, cursor: &current, result: &result, now: now)
                    if current.offset < size { result.incomplete = true }
                }
                let savedAnchor = try anchor(handle, offset: current.offset)
                result.bytesRead += savedAnchor.bytes
                current.anchorDigest = savedAnchor.digest
                result.checkpoint.cursors[file.path] = current
            } catch {
                result.incomplete = true
                if let cursor = result.checkpoint.cursors[file.path] {
                    result.checkpoint.queue.invalidate(threadID: cursor.threadID, at: now)
                }
            }
        }
        // Files omitted by the bounded baseline are still timestamp-filtered on later discovery.
        result.checkpoint.baselineComplete = true
        return result
    }

    private func consume(_ data: Data, cursor: inout CodexMonitorCheckpoint.Cursor,
                         result: inout CodexMonitorScan, now: Date) {
        var start = data.startIndex
        if cursor.discardUntilNewline {
            guard let end = data.firstIndex(of: 10) else {
                cursor.offset += UInt64(data.count)
                result.incomplete = true
                return
            }
            start = data.index(after: end)
            cursor.offset += UInt64(start)
            cursor.discardUntilNewline = false
        }
        while start < data.endIndex, let end = data[start...].firstIndex(of: 10) {
            let line = Data(data[start..<end])
            if let event = CodexSessionEventParser.parse(line, cursor: cursor,
                                                        since: result.checkpoint.monitoringSince, now: now) {
                switch event {
                case .quotaBlocked(let candidate):
                    if cursor.lastProgressAt.map({ candidate.detectedAt <= $0 }) != true {
                        if result.checkpoint.queue.candidates.count < 500 {
                            result.checkpoint.queue.insert(candidate)
                        } else { result.incomplete = true }
                    }
                case .progressed(let thread, let at):
                    cursor.lastProgressAt = max(cursor.lastProgressAt ?? .distantPast, at)
                    result.checkpoint.queue.invalidate(threadID: thread, at: at)
                }
            } else if !line.isEmpty && (try? JSONSerialization.jsonObject(with: line)) == nil {
                result.incomplete = true
            }
            let next = data.index(after: end)
            cursor.offset += UInt64(next - start)
            start = next
        }
        // Keep the offset at a partial line, without persisting its potentially private contents.
        // Overlong lines are skipped incrementally until newline, bounding memory and restart state.
        if start == data.startIndex && data.count == bytesPerFile {
            cursor.offset += UInt64(data.count)
            cursor.discardUntilNewline = true
            result.incomplete = true
        }
    }

    private func anchor(_ handle: FileHandle, offset: UInt64) throws -> (digest: String, bytes: Int) {
        let size = Int(min(64, offset))
        try handle.seek(toOffset: offset - UInt64(size))
        let data = try handle.read(upToCount: size) ?? Data()
        return (SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), data.count)
    }
}

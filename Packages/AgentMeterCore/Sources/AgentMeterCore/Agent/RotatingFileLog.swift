import Foundation

/// 大小封顶的滚动文件日志。后台 agent 用它把日志写到 `~/Library/Logs/AgentMeter/`,
/// 超过上限就轮转一份(`agent.log` → `agent.log.1`,只留 1 份备份),避免日志只增不减。
///
/// 写入失败一律静默 —— 记不上日志不该影响采集主流程(铁律 2:容错优先)。
public struct RotatingFileLog: Sendable {
    public let fileURL: URL
    public let maxBytes: Int

    public init(fileURL: URL, maxBytes: Int = 512 * 1024) {
        self.fileURL = fileURL
        self.maxBytes = maxBytes
    }

    /// 写入 `addingBytes` 之前是否需要轮转。空文件(currentSize == 0)永不轮转,
    /// 保证哪怕单行超限也至少写得进去。抽成纯函数便于单测。
    public static func shouldRotate(currentSize: Int, addingBytes: Int, maxBytes: Int) -> Bool {
        currentSize > 0 && currentSize + addingBytes > maxBytes
    }

    /// 追加一行(自动补换行)。必要时先轮转,再 append。
    public func append(_ line: String) {
        let data = Data((line + "\n").utf8)
        let fm = FileManager.default
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true)

        let attrs = try? fm.attributesOfItem(atPath: fileURL.path)
        let currentSize = (attrs?[.size] as? Int) ?? 0
        if Self.shouldRotate(currentSize: currentSize, addingBytes: data.count, maxBytes: maxBytes) {
            rotate()
        }

        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            // 文件还不存在(首写或刚轮转走):直接建。
            try? data.write(to: fileURL)
        }
    }

    private func rotate() {
        let fm = FileManager.default
        let backup = fileURL.appendingPathExtension("1")
        try? fm.removeItem(at: backup)
        try? fm.moveItem(at: fileURL, to: backup)
    }
}

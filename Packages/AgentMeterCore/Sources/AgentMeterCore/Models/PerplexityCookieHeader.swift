import Foundation

public enum PerplexityCookieHeader {
    public static let sessionNames = ["__Secure-authjs.session-token", "authjs.session-token",
                                      "__Secure-next-auth.session-token", "next-auth.session-token"]

    /// Returns only session cookies. Unrelated cookies never leave the collecting Mac.
    /// A bare token has four candidates; explicit names and chunked headers have one.
    public static func candidates(_ raw: String) throws -> [String] {
        guard !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              raw.utf8.count <= 64 * 1024 else { throw PerplexityFailure.invalidCookie }
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.lowercased().hasPrefix("cookie:") { text = String(text.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        guard !text.isEmpty else { throw PerplexityFailure.missingCookie }
        if !text.contains("="), !text.contains(";") {
            guard !text.contains(where: { $0.isWhitespace }) else { throw PerplexityFailure.invalidCookie }
            return sessionNames.map { "\($0)=\(text)" }
        }
        var pairs: [String: String] = [:]
        for part in text.split(separator: ";", omittingEmptySubsequences: false) {
            let pair = part.trimmingCharacters(in: .whitespaces)
            guard let equals = pair.firstIndex(of: "="), equals != pair.startIndex else { throw PerplexityFailure.invalidCookie }
            let name = pair[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = pair[pair.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(where: { $0.isWhitespace }), !value.isEmpty,
                  !value.contains(where: { $0.isWhitespace }), pairs[name] == nil else { throw PerplexityFailure.invalidCookie }
            pairs[name] = value
        }
        for name in sessionNames {
            let key = name.lowercased()
            if let value = pairs[key] { return ["\(name)=\(value)"] }
            let chunks = pairs.filter { $0.key.hasPrefix(key + ".") }
            if !chunks.isEmpty {
                var numbered: [Int: String] = [:]
                for (chunk, value) in chunks {
                    let suffix = chunk.dropFirst(key.count + 1)
                    guard !suffix.isEmpty, suffix.allSatisfy({ $0.isASCII && $0.isNumber }),
                          let index = Int(suffix), index < 128, numbered[index] == nil
                    else { throw PerplexityFailure.invalidCookie }
                    numbered[index] = value
                }
                guard let last = numbered.keys.max(), numbered.count == last + 1 else { throw PerplexityFailure.invalidCookie }
                return ["\(name)=\((0...last).map { numbered[$0]! }.joined())"]
            }
        }
        throw PerplexityFailure.invalidCookie
    }

    public static func normalize(_ raw: String) throws -> String {
        let headers = try candidates(raw)
        // Preserve bare-token ambiguity so authentication can try all supported names.
        return headers.count == 1 ? headers[0] : String(headers[0].dropFirst(sessionNames[0].count + 1))
    }
}

import Foundation

/// Finds OSC 52 clipboard writes in a terminal's output that SwiftTerm
/// ignores: it handles only the `c` selection, while tmux (with
/// `set-clipboard on`) sends an empty one, `ESC ] 52 ; ; <base64> BEL`. A
/// sequence split across two reads is still found.
public struct ClipboardRequests: Sendable {
    private var carry: [UInt8] = []
    /// Longest sequence kept across reads: a large copy is still caught.
    private static let limit = 8 * 1024 * 1024

    public init() {}

    /// The text of each clipboard write in `bytes` whose selection is not
    /// `c` (SwiftTerm already handles that one).
    public mutating func scan<S: Sequence>(_ bytes: S) -> [String] where S.Element == UInt8 {
        var data = carry
        data.append(contentsOf: bytes)
        carry.removeAll(keepingCapacity: true)
        var found: [String] = []
        let prefix: [UInt8] = [0x1b, 0x5d, 0x35, 0x32, 0x3b] // ESC ] 5 2 ;
        var i = 0
        while i < data.count {
            guard data[i] == 0x1b else { i += 1; continue }
            // Not enough bytes yet to tell: keep the tail for the next read.
            let available = min(prefix.count, data.count - i)
            if Array(data[i..<(i + available)]) != Array(prefix[0..<available]) { i += 1; continue }
            if available < prefix.count { carry = Array(data[i...]); break }
            var j = i + prefix.count
            var end: Int?
            var terminatorLength = 0
            while j < data.count {
                if data[j] == 0x07 { end = j; terminatorLength = 1; break }
                if data[j] == 0x1b, j + 1 < data.count, data[j + 1] == 0x5c { end = j; terminatorLength = 2; break }
                if data[j] == 0x1b, j + 1 == data.count { break }
                j += 1
            }
            guard let stop = end else {
                if data.count - i <= Self.limit { carry = Array(data[i...]) }
                break
            }
            let body = data[(i + prefix.count)..<stop]
            if let semicolon = body.firstIndex(of: 0x3b) {
                let selection = String(decoding: body[body.startIndex..<semicolon], as: UTF8.self)
                let payload = Data(body[(semicolon + 1)...])
                // "?" is a query, not a write; "c" is SwiftTerm's own.
                if selection != "c", payload != Data("?".utf8),
                   let decoded = Data(base64Encoded: payload), let text = String(data: decoded, encoding: .utf8) {
                    found.append(text)
                }
            }
            i = stop + terminatorLength
        }
        return found
    }
}

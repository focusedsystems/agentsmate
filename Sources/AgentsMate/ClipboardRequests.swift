import Foundation

/// Finds OSC 52 clipboard writes in a terminal's output,
/// `ESC ] 52 ; <selection> ; <base64> BEL` (or `ESC \` in place of BEL).
///
/// SwiftTerm 1.11 parses the sequence but its macOS view never passes the
/// write on, so every one is found here: the `c` selection Claude Code and
/// Codex send, the empty one tmux sends with `set-clipboard on`, and `p`,
/// `q`, `s` and the cut buffers `0`–`7`. A write wrapped in tmux's
/// passthrough, `ESC P tmux; … ESC \` with each inner ESC doubled, is
/// unwrapped first. A sequence split across reads is still found.
///
/// Only writes are returned. A `?` payload asks the terminal to send the
/// clipboard back to the program; that is never answered, so nothing a
/// lane runs can read the clipboard.
public struct ClipboardRequests: Sendable {
    private var carry: [UInt8] = []
    /// Longest sequence kept across reads: a large copy is still caught.
    static let limit = 8 * 1024 * 1024

    public init() {}

    private static let oscPrefix: [UInt8] = [0x1b, 0x5d, 0x35, 0x32, 0x3b] // ESC ] 5 2 ;
    private static let tmuxPrefix: [UInt8] = [0x1b, 0x50, 0x74, 0x6d, 0x75, 0x78, 0x3b] // ESC P t m u x ;
    private static let selectionCharacters = Set("cpqs01234567".utf8)

    /// The text of each clipboard write in `bytes`, oldest first.
    public mutating func scan<S: Sequence>(_ bytes: S) -> [String] where S.Element == UInt8 {
        var data = carry
        data.append(contentsOf: bytes)
        carry.removeAll(keepingCapacity: true)
        let (found, rest) = Self.writes(in: data, final: false)
        if let rest, data.count - rest <= Self.limit { carry = Array(data[rest...]) }
        return found
    }

    /// The writes in `data`, and where an unfinished sequence starts when
    /// `data` may continue in a later read.
    private static func writes(in data: [UInt8], final: Bool) -> ([String], Int?) {
        var found: [String] = []
        var i = 0
        while i < data.count {
            guard data[i] == 0x1b else { i += 1; continue }
            let osc = match(oscPrefix, in: data, at: i)
            let tmux = osc == .no ? match(tmuxPrefix, in: data, at: i) : .no
            if osc == .partial || tmux == .partial { return (found, final ? nil : i) }
            if osc == .yes {
                guard let (stop, length) = stringTerminator(in: data, from: i + oscPrefix.count) else {
                    return (found, final ? nil : i)
                }
                // A sequence cut short by another escape writes nothing.
                if length > 0, let text = write(in: data[(i + oscPrefix.count)..<stop]) { found.append(text) }
                i = stop + length
            } else if tmux == .yes {
                guard let (inner, next) = passthrough(in: data, from: i + tmuxPrefix.count) else {
                    return (found, final ? nil : i)
                }
                found += writes(in: inner, final: true).0
                i = next
            } else {
                i += 1
            }
        }
        return (found, nil)
    }

    private enum Match { case yes, partial, no }

    /// Whether `prefix` starts at `index`, or could once more bytes arrive.
    private static func match(_ prefix: [UInt8], in data: [UInt8], at index: Int) -> Match {
        let available = min(prefix.count, data.count - index)
        for k in 0..<available where data[index + k] != prefix[k] { return .no }
        return available < prefix.count ? .partial : .yes
    }

    /// Where the OSC body that starts at `from` ends (BEL or ESC \), and
    /// the terminator's length; nil while it has not arrived.
    private static func stringTerminator(in data: [UInt8], from: Int) -> (Int, Int)? {
        var j = from
        while j < data.count {
            if data[j] == 0x07 { return (j, 1) }
            if data[j] == 0x1b {
                guard j + 1 < data.count else { return nil }
                return data[j + 1] == 0x5c ? (j, 2) : (j, 0)
            }
            j += 1
        }
        return nil
    }

    /// The inner bytes of a tmux passthrough whose body starts at `from`,
    /// with doubled ESCs made single, and the index after its closing
    /// ESC \; nil while it has not arrived.
    private static func passthrough(in data: [UInt8], from: Int) -> ([UInt8], Int)? {
        var inner: [UInt8] = []
        var j = from
        while j < data.count {
            if data[j] == 0x1b {
                guard j + 1 < data.count else { return nil }
                if data[j + 1] == 0x1b { inner.append(0x1b); j += 2; continue }
                if data[j + 1] == 0x5c { return (inner, j + 2) }
            }
            inner.append(data[j])
            j += 1
        }
        return nil
    }

    /// The text an OSC 52 body `<selection>;<base64>` writes, or nil for a
    /// query, an unknown selection or a payload that does not decode.
    private static func write(in body: ArraySlice<UInt8>) -> String? {
        guard let semicolon = body.firstIndex(of: 0x3b) else { return nil }
        let selection = body[body.startIndex..<semicolon]
        guard selection.allSatisfy(selectionCharacters.contains) else { return nil }
        let payload = Data(body[(semicolon + 1)...])
        // "?" asks for the clipboard back; that is never answered.
        guard payload != Data("?".utf8),
              let decoded = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) else { return nil }
        // An empty write would only wipe what is on the clipboard.
        guard let text = String(data: decoded, encoding: .utf8), !text.isEmpty else { return nil }
        return text
    }
}

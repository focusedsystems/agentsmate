import Foundation

/// The title a person gave an agent's session: a Claude `/rename`, or a Codex
/// thread's name. A row takes it as its name when it changes, and a row's rename goes back to it.
public enum SessionTitle {
    /// The separator some agents put between a row's name and the title.
    static let separator = "·"

    /// `title` as a row named `rowName` shows it: with a leading
    /// "<row name> · " removed, since the row already says that. Nil when
    /// nothing is left, or when the title is just the row's name.
    public static func subtitle(_ title: String?, rowName: String) -> String? {
        guard var text = title?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let name = rowName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            if text.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame { return nil }
            if let range = text.range(of: name, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) {
                var rest = text[range.upperBound...].drop(while: { $0.isWhitespace })
                if rest.hasPrefix(separator) {
                    rest = rest.dropFirst(separator.count)
                    text = rest.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return text.isEmpty ? nil : text
    }

    /// Where Codex keeps its thread names: `$CODEX_HOME/session_index.jsonl`
    /// (default `~/.codex`), one JSON line per name given, the last for a
    /// thread being the current one.
    public static func codexIndex(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let home = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        return home.appendingPathComponent("session_index.jsonl", isDirectory: false)
    }

    /// The current name of every thread in the last `bytes` of a Codex name
    /// index, by thread id.
    public static func codexNames(in url: URL, bytes: UInt64 = 1024 * 1024) -> [String: String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        // One byte before the window says whether it starts on a line.
        let start = size > bytes ? size - bytes - 1 : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return [:] }
        return codexNames(parsing: data, droppingFirstLine: start > 0 && data.first != 0x0A)
    }

    static func codexNames(parsing data: Data, droppingFirstLine: Bool = false) -> [String: String] {
        var names: [String: String] = [:]
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if droppingFirstLine, !lines.isEmpty { lines.removeFirst() }
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = object["id"] as? String else { continue }
            let name = (object["thread_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            names[id] = name.isEmpty ? nil : String(name.prefix(200))
        }
        return names
    }
}

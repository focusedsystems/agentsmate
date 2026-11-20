import Foundation

/// Finding the link under a ⌘-click in a lane's terminal, and deciding
/// which links the system may open.
public enum TerminalLinks {
    /// The schemes opened with the default app when the app's hook does
    /// not take a link. Anything else (`file:`, custom schemes) goes to the
    /// hook only.
    public static let systemSchemes: Set<String> = ["http", "https", "mailto"]

    /// Whether `url` may be handed to the system when the app leaves it.
    public static func opensInSystem(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), systemSchemes.contains(scheme) else { return false }
        if scheme == "mailto" { return true }
        return !(url.host ?? "").isEmpty
    }

    /// The link of an OSC 8 hyperlink as SwiftTerm stores it on a cell:
    /// `params;uri`, where params are `key=value` pairs joined by `:`.
    public static func hyperlinkURL(fromPayload payload: String) -> URL? {
        guard let separator = payload.firstIndex(of: ";") else { return nil }
        return url(from: String(payload[payload.index(after: separator)...]))
    }

    /// A link string as a program wrote it, percent-encoding what URL
    /// would otherwise reject. Nil for an empty string or one with no scheme.
    public static func url(from link: String) -> URL? {
        let link = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { return nil }
        let parsed = URL(string: link)
            ?? link.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed).flatMap { URL(string: $0) }
        guard let parsed, let scheme = parsed.scheme, !scheme.isEmpty else { return nil }
        return parsed
    }

    /// The plain http or https URL printed at `column` of a row, one
    /// character per cell. Only an explicit `http://` or `https://` counts;
    /// the URL ends at whitespace, quotes or angle brackets, and loses
    /// trailing punctuation and closing brackets it did not open. A URL that
    /// wraps onto the next row is cut at the row's end; use
    /// `detectedURL(inWrappedRows:row:column:)` for a soft-wrapped line.
    public static func detectedURL(in row: [Character], at column: Int) -> URL? {
        guard row.indices.contains(column), isURLCharacter(row[column]) else { return nil }
        var start = column
        while start > row.startIndex, isURLCharacter(row[start - 1]) { start -= 1 }
        var end = column + 1
        while end < row.endIndex, isURLCharacter(row[end]) { end += 1 }
        let run = String(row[start..<end])

        // The last scheme that starts at or before the click.
        let offset = column - start
        var best: Range<String.Index>?
        for scheme in ["https://", "http://"] {
            var from = run.startIndex
            while let found = run.range(of: scheme, options: .caseInsensitive, range: from..<run.endIndex) {
                if run.distance(from: run.startIndex, to: found.lowerBound) > offset { break }
                if best == nil || found.lowerBound > best!.lowerBound { best = found }
                from = found.upperBound
            }
        }
        guard let best else { return nil }
        // A second URL run on without a space ends this one.
        var stop = run.endIndex
        for scheme in ["https://", "http://"] {
            if let next = run.range(of: scheme, options: .caseInsensitive, range: best.upperBound..<run.endIndex),
               next.lowerBound < stop { stop = next.lowerBound }
        }
        let candidate = trimmed(String(run[best.lowerBound..<stop]))
        let candidateStart = run.distance(from: run.startIndex, to: best.lowerBound)
        guard offset < candidateStart + candidate.count,
              let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// The plain URL at `column` of `rows[row]`, where `rows` are the
    /// screen rows of one logical line: every row after the first is a soft
    /// wrap of the one before it, so the rows join without a break. Callers
    /// pass only rows the terminal marked as wrapped, never a hard break.
    public static func detectedURL(inWrappedRows rows: [[Character]], row: Int, column: Int) -> URL? {
        guard rows.indices.contains(row), rows[row].indices.contains(column) else { return nil }
        let offset = rows[..<row].reduce(0) { $0 + $1.count } + column
        return detectedURL(in: Array(rows.joined()), at: offset)
    }

    /// Characters a printed URL may hold: printable ASCII but space,
    /// quotes, angle brackets, backtick and backslash.
    static func isURLCharacter(_ character: Character) -> Bool {
        guard let ascii = character.asciiValue, ascii > 0x20, ascii < 0x7f else { return false }
        return !"\"'<>`\\{}|^".contains(character)
    }

    private static func trimmed(_ candidate: String) -> String {
        var text = candidate
        let pairs: [Character: Character] = [")": "(", "]": "["]
        while let last = text.last {
            if ".,;:!?*".contains(last) {
                text.removeLast()
            } else if let open = pairs[last], text.filter({ $0 == last }).count > text.filter({ $0 == open }).count {
                text.removeLast()
            } else {
                break
            }
        }
        return text
    }
}

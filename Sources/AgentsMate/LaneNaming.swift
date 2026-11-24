import Foundation

/// What an agent's terminal title says: the task it is on, without the
/// spinner or idle glyph Claude Code and Codex put in front of it. Used to
/// name a row, never as its status, which comes from the agent's reports.
public enum TerminalTitle {
    /// Leading glyphs agents draw as a spinner or an idle mark.
    static let glyphs: Set<Character> = [
        "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏", "⠂", "⠐",
        "✳", "✻", "✽", "✶", "✢", "·", "•", "*", "◐", "◓", "◑", "◒",
    ]

    /// The task named by `title`, or nil for a title that names no task:
    /// empty, only a glyph, or a shell's `user@host: path` / bare program name.
    public static func task(from title: String) -> String? {
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = text.first, glyphs.contains(first) || first.unicodeScalars.allSatisfy({ (0x2800...0x28FF).contains($0.value) }) {
            text.removeFirst()
            text = text.trimmingCharacters(in: .whitespaces)
        }
        guard !text.isEmpty else { return nil }
        if text.range(of: #"^[\w.-]+@[\w.-]+[: ]"#, options: .regularExpression) != nil { return nil }
        if ["zsh", "bash", "fish", "sh", "tmux", "claude", "codex", "-zsh", "-bash"].contains(text.lowercased()) { return nil }
        if text.hasPrefix("~") || text.hasPrefix("/") { return nil }
        return String(text.prefix(120))
    }
}

/// A label the agent in a lane writes for its row: `{"title": …, "section": …}`
/// in the file named by `$AGENTSMATE_SESSION`. Both are optional.
public struct LaneSessionMetadata: Codable, Equatable, Sendable {
    public var title: String?
    public var section: String?

    public init(title: String? = nil, section: String? = nil) {
        self.title = title
        self.section = section
    }

    /// Read and tidy a metadata file: control characters stripped, each
    /// value cut to 120 characters, blanks dropped.
    public static func read(_ url: URL) -> LaneSessionMetadata? {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode(LaneSessionMetadata.self, from: data) else { return nil }
        func clean(_ s: String?) -> String? {
            guard let s else { return nil }
            let flat = String(String.UnicodeScalarView(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
                .trimmingCharacters(in: .whitespaces)
            return flat.isEmpty ? nil : String(flat.prefix(120))
        }
        return LaneSessionMetadata(title: clean(raw.title), section: clean(raw.section))
    }
}

extension String {
    /// "Name" → "Name 2"; "Name 2" → "Name 3", skipping names in `taken`,
    /// whatever their case.
    func nextCopyName(taken: Set<String>) -> String {
        var base = self, n = 2
        if let match = range(of: #" (\d+)$"#, options: .regularExpression), let number = Int(self[match].dropFirst()) {
            base = String(self[..<match.lowerBound])
            n = number + 1
        }
        let lowered = Set(taken.map { $0.lowercased() })
        while lowered.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }
}

import Foundation
import SwiftTerm

/// Claude Code's refusal to resume a conversation that is still running in the
/// background:
///
///     "<name>" is running in the background (7bd28ac9). Run claude attach
///     7bd28ac9 to open it, or claude stop 7bd28ac9 first to resume it here.
///
/// A lane's terminal is where the person sees it, and they cannot run
/// `claude attach` from there, so the app opens that session for them. The
/// terminal's own screen is read, as ``HeadlessAgentRename`` reads it, and
/// nothing is run: `claude stop` is never sent on anyone's behalf.
enum BackgroundSessionRefusal {
    /// The session id the screen's refusal names, or nil when none is showing.
    static func sessionID(onScreen terminal: Terminal) -> String? {
        sessionID(in: HeadlessAgentRename.rows(of: terminal))
    }

    /// The session id a refusal names in `rows` (a screen's rows, or any text
    /// split in lines). The newest refusal wins.
    static func sessionID(in rows: [String]) -> String? {
        sessionID(in: rows.joined(separator: "\n"))
    }

    /// Whitespace is dropped before matching: the message wraps wherever the
    /// terminal is narrow, even in the middle of an id, and a wrapped line
    /// may or may not carry padding. The id in the second sentence must be
    /// the one in the first, so a name or other text cannot stand in for it.
    static func sessionID(in text: String) -> String? {
        let squashed = String(text.lowercased().unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && $0 != "\u{2502}" && $0 != "\u{2503}"
        })
        let pattern = #"isrunninginthebackground\(([0-9a-f]{4,32})\)\.runclaudeattach\1"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let whole = NSRange(squashed.startIndex..., in: squashed)
        guard let match = regex.matches(in: squashed, range: whole).last,
              let range = Range(match.range(at: 1), in: squashed) else { return nil }
        let id = String(squashed[range])
        return HostSessions.isValidAgentID(id) ? id : nil
    }
}

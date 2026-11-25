import Foundation
import SwiftTerm
import AgentsMateStatus

/// Renaming the agent's own session when the person renames its lane.
public enum LaneRename {
    /// Claude Code's and Codex's command: `/rename <name>`.
    public static let slashRename = "/rename %@"

    /// The rename command for a backend's agent: `/rename %@` for Claude
    /// Code and Codex, found by the status agent or the command's program,
    /// and nil for anything else.
    public static func defaultCommand(statusAgent: String?, command: String) -> String? {
        let program = command.split(separator: " ", omittingEmptySubsequences: true).first
            .map { ($0 as NSString).lastPathComponent.lowercased() }
        let agent = statusAgent?.lowercased() ?? program
        return agent == "claude" || agent == "codex" ? slashRename : nil
    }

    /// The name as one plain line: control characters and line breaks
    /// become spaces, runs of spaces collapse, and it is cut to 100
    /// characters, so typing it can never submit or edit anything early.
    public static func cleanName(_ name: String) -> String {
        let flat = String(String.UnicodeScalarView(name.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? " " : $0
        }))
        let words = flat.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(words.prefix(100))
    }

    /// The text to type: `format` with its `%@` replaced by the cleaned
    /// name, or nil when the name is empty or the format has no `%@`.
    public static func command(format: String, name: String) -> String? {
        let clean = cleanName(name)
        guard !clean.isEmpty, format.contains("%@") else { return nil }
        return format.replacingOccurrences(of: "%@", with: clean)
    }

    /// How long after typing the command its Return is sent. A remote pane
    /// (tmux over ssh) drops a Return that arrives in the same write as the
    /// text.
    public static let returnDelay: TimeInterval = 0.15
}

/// What happened to the agent's session when its lane was renamed.
public enum AgentRenameOutcome: Equatable, Sendable {
    /// The rename command was typed into the agent.
    case sent
    /// The backend's agent has no rename command, or no name was given.
    case notSupported
    /// The person turned the setting off.
    case disabled
    /// The lane's terminal is not attached in this app.
    case notAttached
    /// The agent is not the program in the foreground of the terminal.
    case agentNotInForeground
    /// The agent is running a turn.
    case busy
    /// The agent is asking for permission; its dialog owns the input.
    case askingPermission
    /// Something is typed in the agent's input line.
    case inputNotEmpty
    /// The input line could not be read with confidence.
    case inputUnknown

    /// A short line for the lane's row, or nil when nothing needs saying.
    public var notice: String? {
        switch self {
        case .sent, .notSupported, .disabled, .notAttached: nil
        case .agentNotInForeground: "Agent rename waits: it isn’t running here"
        case .busy: "Agent rename waits: it is working"
        case .askingPermission: "Agent rename waits: it is asking permission"
        case .inputNotEmpty: "Agent rename waits: its input has text"
        case .inputUnknown: "Agent rename waits: input line unclear"
        }
    }

    /// Whether to type the command, from what is known about the lane. The
    /// input line is read last and only when everything else allows a send.
    static func decide(command: String?, enabled: Bool, attached: Bool, agentInForeground: Bool,
                       state: LaneState?, input: () -> AgentPromptLine.Reading) -> AgentRenameOutcome {
        guard command != nil else { return .notSupported }
        guard enabled else { return .disabled }
        guard attached else { return .notAttached }
        guard agentInForeground else { return .agentNotInForeground }
        if state == .running { return .busy }
        if state == .permissionRequested { return .askingPermission }
        switch input() {
        case .empty: return .sent
        case .typed: return .inputNotEmpty
        case .unknown: return .inputUnknown
        }
    }
}

/// Reads an agent's input line off its terminal screen, to tell whether
/// anything is typed in it. It knows these layouts, with the cursor just
/// after the marker:
///
/// - Claude Code: `❯ ` between two horizontal rules (`───`).
/// - Claude Code's older box: `│ > ` between `╭───╮` and `╰───╯`.
/// - Codex: `› ` with a blank line above and below.
///
/// Dim text after the marker is the agent's placeholder, not input. Any
/// other layout reads as ``Reading/unknown``, so nothing is typed into it.
public enum AgentPromptLine {
    public enum Reading: Equatable, Sendable {
        /// The input line is empty.
        case empty
        /// Something is typed there, on this line or the next.
        case typed
        /// Not a layout known well enough to say.
        case unknown
    }

    /// One screen cell: its character and whether it is drawn dim.
    public struct Cell: Equatable, Sendable {
        public var character: Character
        public var isDim: Bool

        public init(_ character: Character, dim: Bool = false) {
            self.character = character
            self.isDim = dim
        }

        var isBlank: Bool { character == " " || character == "\u{00A0}" || character == "\0" }
    }

    static let markers: Set<Character> = ["❯", ">", "›"]
    static let borders: Set<Character> = ["│", "┃", "|"]
    /// What the line above an input line starts with.
    static let tops: Set<Character> = ["─", "━", "╭", "┌"]
    /// What the line below an input line starts with.
    static let bottoms: Set<Character> = ["─", "━", "╰", "└"]

    /// Read the cursor's row, with the rows above and below it (nil off the
    /// screen) and the cursor's column.
    public static func read(above: [Cell]?, row: [Cell], below: [Cell]?, cursorColumn: Int) -> Reading {
        guard let marker = markerColumn(row) else { return .unknown }
        guard let above, isEdge(above, starts: tops) else { return .unknown }
        let inputStart = marker + 2
        guard row.count > marker + 1, row[marker + 1].isBlank else { return .unknown }
        let typed = row[inputStart...].dropLast(trailingBorder(row, after: inputStart))
            .contains { !$0.isBlank && !$0.isDim }
        if typed { return .typed }
        guard cursorColumn == inputStart else { return .unknown }
        guard let below else { return .unknown }
        // A second line of input sits below the first, inside the box.
        return isEdge(below, starts: bottoms) ? .empty : .typed
    }

    /// Read the input line under a terminal's cursor, on the screen the
    /// program draws (not one scrolled back into history).
    static func read(_ terminal: Terminal) -> Reading {
        let cursor = terminal.getCursorLocation()
        func cells(_ y: Int) -> [Cell]? {
            guard let line = terminal.getLine(row: y) else { return nil }
            return (0..<min(line.count, terminal.cols)).map { x in
                let data = line[x]
                return Cell(terminal.getCharacter(for: data), dim: data.attribute.style.contains(.dim))
            }
        }
        guard let row = cells(cursor.y) else { return .unknown }
        return read(above: cells(cursor.y - 1), row: row, below: cells(cursor.y + 1), cursorColumn: cursor.x)
    }

    /// The column of the prompt marker: first on the row, or after a box's
    /// left border, with at most three columns before it.
    static func markerColumn(_ row: [Cell]) -> Int? {
        var column = 0
        var sawBorder = false
        while column < min(row.count, 4) {
            let cell = row[column]
            if markers.contains(cell.character) && !cell.isDim { return column }
            if cell.isBlank { column += 1; continue }
            if borders.contains(cell.character), !sawBorder { sawBorder = true; column += 1; continue }
            return nil
        }
        return nil
    }

    /// A row that is blank, or starts (after spaces) with one of `starts`.
    static func isEdge(_ row: [Cell], starts: Set<Character>) -> Bool {
        guard let first = row.first(where: { !$0.isBlank }) else { return true }
        return starts.contains(first.character)
    }

    /// How many cells at the end of the row are a box's right border and
    /// the blanks after it.
    static func trailingBorder(_ row: [Cell], after start: Int) -> Int {
        var index = row.count - 1
        while index >= start, row[index].isBlank { index -= 1 }
        guard index >= start, borders.contains(row[index].character) else { return 0 }
        return row.count - index
    }
}

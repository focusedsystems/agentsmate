import AppKit

/// Keys a terminal handles itself while it has focus, ahead of the app's
/// menus, the way Terminal and iTerm do. A store answers only the ones it has
/// switched on; the rest reach the menu bar as usual.
public enum TerminalShortcut: Hashable, Sendable {
    case newLane, closeLane, split, clear, next, previous, select(Int), maximize
    /// ⌃` — show or hide the lanes, even while a terminal has the keyboard.
    case togglePanel
    /// ⌘+ / ⌘- / ⌘0 — the terminals' text size.
    case biggerFont, smallerFont, resetFont

    /// Which shortcuts a store takes from a focused terminal.
    public struct Set: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let newLane = Set(rawValue: 1 << 0)
        public static let closeLane = Set(rawValue: 1 << 1)
        public static let split = Set(rawValue: 1 << 2)
        public static let clear = Set(rawValue: 1 << 3)
        /// ⇧⌘] / ⇧⌘[ and ⌃Tab / ⌃⇧Tab.
        public static let cycle = Set(rawValue: 1 << 4)
        /// ⌘1–⌘9.
        public static let numbers = Set(rawValue: 1 << 5)
        public static let maximize = Set(rawValue: 1 << 6)
        public static let togglePanel = Set(rawValue: 1 << 7)
        public static let fontSize = Set(rawValue: 1 << 8)

        /// A fixed list of lanes, as in a window that is all lanes.
        public static let fixedLanes: Set = [.clear, .cycle, .numbers, .fontSize]
        /// Lanes the person opens and closes, in a panel.
        public static let all: Set = [.newLane, .closeLane, .split, .clear, .cycle, .numbers, .maximize, .togglePanel, .fontSize]
    }

    public var member: Set {
        switch self {
        case .newLane: .newLane
        case .closeLane: .closeLane
        case .split: .split
        case .clear: .clear
        case .next, .previous: .cycle
        case .select: .numbers
        case .maximize: .maximize
        case .togglePanel: .togglePanel
        case .biggerFont, .smallerFont, .resetFont: .fontSize
        }
    }

    public init?(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .control, .option, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (flags, key) {
        case (.control, "`"): self = .togglePanel
        case (.command, "t"): self = .newLane
        case (.command, "w"): self = .closeLane
        case (.command, "d"): self = .split
        case (.command, "k"): self = .clear
        case (.command, "="), (.command, "+"), ([.command, .shift], "="), ([.command, .shift], "+"): self = .biggerFont
        case (.command, "-"): self = .smallerFont
        case (.command, "0"): self = .resetFont
        case ([.command, .shift], "\r"): self = .maximize
        case ([.command, .shift], "]"), ([.command, .shift], "}"): self = .next
        case ([.command, .shift], "["), ([.command, .shift], "{"): self = .previous
        case (.command, _) where Int(key).map({ (1...9).contains($0) }) == true:
            self = .select(Int(key)! - 1)
        default:
            if event.keyCode == 50, flags == .control { // ` on any layout's key
                self = .togglePanel
            } else if event.keyCode == 48, flags.contains(.control) { // Tab
                self = flags.contains(.shift) ? .previous : .next
            } else {
                return nil
            }
        }
    }
}

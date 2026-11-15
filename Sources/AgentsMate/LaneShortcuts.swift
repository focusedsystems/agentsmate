import SwiftUI
import AppKit

/// A command in the lanes that has a keyboard shortcut a person can change.
public enum LaneShortcutAction: String, CaseIterable, Codable, Sendable, Identifiable {
    case next, previous, clear, newLane, closeLane, split, maximize, togglePanel
    case biggerFont, smallerFont, resetFont, jumpToUnread, goToLane, back, forward, reattach

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .next: "Next Lane"
        case .previous: "Previous Lane"
        case .clear: "Clear Screen"
        case .newLane: "New Lane"
        case .closeLane: "Close Lane"
        case .split: "Split"
        case .maximize: "Fill Window"
        case .togglePanel: "Show or Hide Lanes"
        case .biggerFont: "Bigger Text"
        case .smallerFont: "Smaller Text"
        case .resetFont: "Actual Size"
        case .jumpToUnread: "Jump to Unread"
        case .goToLane: "Go to Lane"
        case .back: "Back"
        case .forward: "Forward"
        case .reattach: "Reattach"
        }
    }

    /// The terminal shortcut this action is, for those a focused terminal answers.
    var terminalShortcut: TerminalShortcut? {
        switch self {
        case .next: .next
        case .previous: .previous
        case .clear: .clear
        case .newLane: .newLane
        case .closeLane: .closeLane
        case .split: .split
        case .maximize: .maximize
        case .togglePanel: .togglePanel
        case .biggerFont: .biggerFont
        case .smallerFont: .smallerFont
        case .resetFont: .resetFont
        default: nil
        }
    }
}

/// A key and its modifiers, saved as text: a single character, or one of
/// `return`, `tab`, `space`, `delete`, `escape`, `left`, `right`, `up`, `down`.
public struct LaneKeyBinding: Codable, Hashable, Sendable {
    public var key: String
    public var command = false
    public var shift = false
    public var option = false
    public var control = false

    public init(_ key: String, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.key = key.lowercased()
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    static let specialKeys: [String: UInt16] = [
        "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]

    /// The binding a key press makes, or nil for a press with no ⌘, ⌃ or ⌥
    /// (those are typing, not shortcuts).
    public init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option) else { return nil }
        if let name = Self.specialKeys.first(where: { $0.value == event.keyCode })?.key {
            key = name
        } else if let chars = event.charactersIgnoringModifiers?.lowercased(), let first = chars.first, !chars.isEmpty {
            key = String(first)
        } else {
            return nil
        }
        command = flags.contains(.command)
        shift = flags.contains(.shift)
        option = flags.contains(.option)
        control = flags.contains(.control)
    }

    public func matches(_ event: NSEvent) -> Bool {
        guard let pressed = LaneKeyBinding(event: event) else { return false }
        if pressed == self { return true }
        // ⇧⌘] reports "}" on many layouts; accept the shifted form too.
        let shifted: [String: String] = ["}": "]", "{": "[", "+": "="]
        if let base = shifted[pressed.key] { var alt = pressed; alt.key = base; return alt == self }
        return false
    }

    public var keyEquivalent: KeyEquivalent {
        switch key {
        case "return": .return
        case "tab": .tab
        case "space": .space
        case "delete": .delete
        case "escape": .escape
        case "left": .leftArrow
        case "right": .rightArrow
        case "up": .upArrow
        case "down": .downArrow
        default: KeyEquivalent(Character(key))
        }
    }

    public var modifiers: EventModifiers {
        var m: EventModifiers = []
        if command { m.insert(.command) }
        if shift { m.insert(.shift) }
        if option { m.insert(.option) }
        if control { m.insert(.control) }
        return m
    }

    /// "⇧⌘]" as a menu shows it.
    public var display: String {
        var s = ""
        if control { s += "⌃" }
        if option { s += "⌥" }
        if shift { s += "⇧" }
        if command { s += "⌘" }
        let names = ["return": "↩", "tab": "⇥", "space": "Space", "delete": "⌫", "escape": "⎋",
                     "left": "←", "right": "→", "up": "↑", "down": "↓"]
        return s + (names[key] ?? key.uppercased())
    }
}

/// Every action's shortcut: the defaults, with the person's changes on top.
/// An action set to nil has no shortcut.
public struct LaneShortcutBindings: Codable, Equatable, Sendable {
    public var overrides: [LaneShortcutAction: LaneKeyBinding?] = [:]

    public init() {}

    public static let defaults: [LaneShortcutAction: LaneKeyBinding] = [
        .next: .init("]", command: true, shift: true),
        .previous: .init("[", command: true, shift: true),
        .clear: .init("k", command: true),
        .newLane: .init("t", command: true),
        .closeLane: .init("w", command: true),
        .split: .init("d", command: true),
        .maximize: .init("return", command: true, shift: true),
        .togglePanel: .init("`", control: true),
        .biggerFont: .init("=", command: true),
        .smallerFont: .init("-", command: true),
        .resetFont: .init("0", command: true),
        .jumpToUnread: .init("u", command: true, shift: true),
        .goToLane: .init("o", command: true, shift: true),
        .back: .init("left", command: true, option: true),
        .forward: .init("right", command: true, option: true),
        .reattach: .init("r", command: true, shift: true),
    ]

    public func binding(for action: LaneShortcutAction) -> LaneKeyBinding? {
        if let override = overrides[action] { return override }
        return Self.defaults[action]
    }

    public mutating func set(_ binding: LaneKeyBinding?, for action: LaneShortcutAction) {
        if binding == Self.defaults[action] { overrides.removeValue(forKey: action) } else { overrides[action] = .some(binding) }
    }

    /// The other action already using `binding`, if any.
    public func conflict(for binding: LaneKeyBinding, excluding action: LaneShortcutAction) -> LaneShortcutAction? {
        LaneShortcutAction.allCases.first { $0 != action && self.binding(for: $0) == binding }
    }

    /// The terminal shortcut a key press is under these bindings: the
    /// rebindable ones, then ⌘1–⌘9 and ⌃Tab, which stay fixed.
    public func terminalShortcut(for event: NSEvent) -> TerminalShortcut? {
        for action in LaneShortcutAction.allCases {
            if let shortcut = action.terminalShortcut, let binding = binding(for: action), binding.matches(event) { return shortcut }
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).intersection([.command, .control, .option, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command, let n = Int(key), (1...9).contains(n) { return .select(n - 1) }
        if event.keyCode == 48, flags.contains(.control) { return flags.contains(.shift) ? .previous : .next }
        return nil
    }
}

extension View {
    /// A menu item's shortcut from the person's bindings, or none.
    @ViewBuilder
    func laneShortcut(_ binding: LaneKeyBinding?) -> some View {
        if let binding { keyboardShortcut(binding.keyEquivalent, modifiers: binding.modifiers) } else { self }
    }
}

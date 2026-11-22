import AppKit
import SwiftTerm

/// SwiftTerm's view with what a lane list needs: the app's light or dark
/// appearance followed and reported to the program, the list's shortcuts
/// caught while it has focus, Terminal's editing keys, and drops typed in.
open class AgentTerminalView: LocalProcessTerminalView {
    /// Answers a shortcut pressed while the terminal has focus. Returns
    /// whether it was handled; an unhandled one goes on to the menus.
    public var onShortcut: ((TerminalShortcut) -> Bool)?
    /// Turns a key press into a shortcut under the person's bindings; nil
    /// uses the built-in keys.
    public var shortcutResolver: ((NSEvent) -> TerminalShortcut?)?
    /// Called after each chunk of output is drawn.
    public var onOutput: (() -> Void)?
    /// Cleans text before it is typed in as a paste. The default keeps
    /// newlines and tabs and drops every other control character.
    public var pasteSanitizer: (String) -> String = ShellQuote.pasteSafe
    /// Answers a ⌘-clicked link: an OSC 8 hyperlink, or a plain http or
    /// https URL printed in the terminal. Returns whether it was handled;
    /// an unhandled http, https or mailto link opens in the default app,
    /// and any other scheme is dropped.
    public var onOpenLink: ((URL) -> Bool)?
    /// Where Copy, Paste and a program's clipboard writes go. Tests use a
    /// pasteboard of their own.
    public var pasteboard: NSPasteboard = .general

    private var colorRequests = TerminalColorSchemeRequests()
    private var clipboardRequests = ClipboardRequests()
    private var flagsMonitor: Any?
    private var reportsColorScheme = false
    public private(set) var colorScheme: TerminalColorScheme?
    private var appAppearanceObservation: NSKeyValueObservation?
    private var inputMonitor: Any?

    open override func dataReceived(slice: ArraySlice<UInt8>) {
        let requests = colorRequests.scan(slice)
        // OSC 52 writes go on the clipboard here: SwiftTerm 1.11's macOS
        // view drops them. Reading the clipboard back is never answered.
        for text in clipboardRequests.scan(slice) { writeClipboard(text) }
        // The caret stays out of sight while output streams and comes back
        // once it settles: an agent redraws many times a second, hiding and
        // moving the cursor each time, which made the caret flicker.
        if caretShown {
            super.hideCursor(source: getTerminal())
            caretShown = false
        }
        super.dataReceived(slice: slice)
        for request in requests { handleColorRequest(request) }
        scheduleCaretReveal()
        onOutput?()
    }

    /// Whether the program wants the cursor shown (DECTCEM).
    private var programWantsCursor = true
    private var caretShown = true
    private var caretReveal: DispatchWorkItem?
    static let caretSettleDelay: TimeInterval = 0.15

    private func scheduleCaretReveal() {
        caretReveal?.cancel()
        let reveal = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.revealCaret() }
        }
        caretReveal = reveal
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.caretSettleDelay, execute: reveal)
    }

    private func revealCaret() {
        guard programWantsCursor, !caretShown else { return }
        caretShown = true
        super.showCursor(source: getTerminal())
    }

    open override func showCursor(source: Terminal) {
        programWantsCursor = true
        scheduleCaretReveal()
    }

    open override func hideCursor(source: Terminal) {
        programWantsCursor = false
        caretReveal?.cancel()
        if caretShown {
            caretShown = false
            super.hideCursor(source: source)
        }
    }

    /// The cursor is a steady block, whatever the program asks for. Agent
    /// TUIs request a blinking cursor and repaint often, which made the
    /// caret flicker; Terminal and other terminals draw it solid.
    open override func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {
        let steady: CursorStyle
        switch newStyle {
        case .blinkBlock: steady = .steadyBlock
        case .blinkBar: steady = .steadyBar
        case .blinkUnderline: steady = .steadyUnderline
        default: steady = newStyle
        }
        super.cursorStyleChanged(source: source, newStyle: steady)
    }

    /// Draw in the app's appearance and follow it from now on.
    public func followAppearance() {
        cursorStyleChanged(source: getTerminal(), newStyle: .steadyBlock)
        getTerminal().ansi256PaletteStrategy = .xterm
        applyColorScheme()
        appAppearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.applyColorScheme() }
        }
    }

    open override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColorScheme()
    }

    open override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColorScheme()
    }

    public func applyColorScheme() {
        let appearance = window?.effectiveAppearance ?? NSApp.effectiveAppearance
        let scheme: TerminalColorScheme = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        guard scheme != colorScheme else { return }
        let changed = colorScheme != nil
        colorScheme = scheme
        var background = NSColor.white, foreground = NSColor.black
        appearance.performAsCurrentDrawingAppearance {
            background = NSColor.textBackgroundColor.usingColorSpace(.deviceRGB) ?? background
            foreground = NSColor.textColor.usingColorSpace(.deviceRGB) ?? foreground
        }
        nativeBackgroundColor = background
        nativeForegroundColor = foreground
        // A dark grey block (light grey in dark mode), with the character
        // under it in the background colour, as Ghostty-based terminals draw
        // it, not the accent blue and not full black.
        caretColor = scheme == .dark ? NSColor(white: 0.72, alpha: 1) : NSColor(white: 0.38, alpha: 1)
        caretTextColor = background
        layer?.backgroundColor = background.cgColor
        installColors(scheme.ansiPalette.map {
            SwiftTerm.Color(red: UInt16($0.red) * 257, green: UInt16($0.green) * 257, blue: UInt16($0.blue) * 257)
        })
        if changed, reportsColorScheme { send(txt: scheme.report) }
        needsDisplay = true
    }

    private func handleColorRequest(_ request: TerminalColorSchemeRequests.Request) {
        switch request {
        case .subscribe: reportsColorScheme = true
        case .unsubscribe: reportsColorScheme = false
        case .query: if let colorScheme { send(txt: colorScheme.report) }
        }
    }

    /// Terminal-style editing keys SwiftTerm leaves to the host, the scroll
    /// wheel and trackpad, and plain pointer movement.
    ///
    /// Plain movement is not passed on: a program that asks for every mouse
    /// event (mode 1003) otherwise hears each pixel the pointer crosses, and
    /// agent TUIs redraw hover states as it passes over them. Clicks, drags
    /// and the wheel still reach it, and ⌘ keeps link previews. A ⌘-click
    /// opens the link under the pointer through `onOpenLink`.
    public func installInputHandling() {
        removeInputHandling()
        installSelectionOverride()
        // Local monitors run on the main thread, inside the app's event loop.
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel, .mouseMoved, .leftMouseDown, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseDown || event.type == .leftMouseUp {
                let dropCommand = MainActor.assumeIsolated { () -> Bool in
                    guard event.window === self.window else { return false }
                    if event.type == .leftMouseDown { self.selectsOnShift(event) }
                    return self.handleLinkClick(event)
                }
                return dropCommand ? Self.withoutCommand(event) ?? event : event
            }
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard event.window === self.window else { return false }
                if event.type == .keyDown {
                    return self.window?.firstResponder === self && self.handleKeyDown(event)
                }
                guard !self.isHiddenOrHasHiddenAncestor,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return false }
                if event.type == .mouseMoved {
                    return !event.modifierFlags.contains(.command)
                }
                return self.handleScrollWheel(event)
            }
            return handled ? nil : event
        }
    }

    /// While Shift is held, a drag selects text in the terminal itself even
    /// when the program (tmux, an agent's TUI) has taken the mouse, as in
    /// other Mac terminals; ⌘C then copies it.
    func installSelectionOverride() {
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let shift = event.modifierFlags.contains(.shift)
            MainActor.assumeIsolated {
                guard let self, event.window === self.window else { return }
                self.allowMouseReporting = !shift
            }
            return event
        }
    }

    /// Shift as the press finds it, in case its change was missed while
    /// another app was active: held, the drag selects here.
    func selectsOnShift(_ event: NSEvent) {
        allowMouseReporting = !event.modifierFlags.contains(.shift)
    }

    public func removeInputHandling() {
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        flagsMonitor = nil
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
    }

    /// Keys the terminal answers before the menu bar or any SwiftUI view
    /// sees them, while it has focus.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        // ⌘C and ⌘V act here rather than waiting for Edit › Copy and Paste
        // to reach the terminal through the menus, which an app's own menus
        // or views can intercept. Without a selection ⌘C goes on as before.
        if flags == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c" where hasSelection:
                copy(self)
                return true
            case "v":
                paste(self)
                return true
            default: break
            }
        }
        // Reopen As keys win over the app's own uses of them while the
        // terminal has focus.
        if let shortcut = shortcutResolver?(event), case .reopen = shortcut, onShortcut?(shortcut) == true {
            return true
        }
        if flags == .command, event.keyCode == 51 {
            send([0x15]) // ⌘⌫ deletes to the start of the line, as in Terminal.
            return true
        }
        if flags == .shift, event.keyCode == 36 || event.keyCode == 76 {
            send([0x0a]) // ⇧↩ is a newline in Claude Code's and Codex's prompts.
            return true
        }
        if flags == .shift {
            // ⇧ with Page Up, Page Down, Home and End browses the scrollback.
            switch event.keyCode {
            case 116: pageUp(); return true
            case 121: pageDown(); return true
            case 115: scroll(toPosition: 0); return true
            case 119: scroll(toPosition: 1); return true
            default: break
            }
        }
        return false
    }

    /// How far the terminal scrolls for a given trackpad travel or wheel
    /// turn; 1 is a line per row height of travel and a step per notch.
    public var scrollSensitivity: CGFloat {
        get { scrollAccumulator.sensitivity }
        set { scrollAccumulator.sensitivity = max(0.1, newValue) }
    }
    private var scrollAccumulator = ScrollStepAccumulator()
    /// Lines the local history moves for each wheel notch, as in Terminal.
    static let wheelLinesPerNotch = 3

    /// The wheel and trackpad, here rather than in SwiftTerm, which turns
    /// each event into one to a screenful of lines and so flies past on a
    /// trackpad. Travel is gathered into steps by `scrollAccumulator`.
    ///
    /// A full-screen program (an agent's TUI, tmux) has no scrollback of its
    /// own here, so the steps go to it: a mouse wheel report each when it
    /// reports the mouse, else an arrow key each. Otherwise, and always with
    /// ⇧, they move the local history.
    private func handleScrollWheel(_ event: NSEvent) -> Bool {
        let terminal = getTerminal()
        let shift = event.modifierFlags.contains(.shift)
        var delta = event.scrollingDeltaY
        // The system turns a ⇧-scrolled mouse wheel sideways.
        if delta == 0, shift, !event.hasPreciseScrollingDeltas { delta = event.scrollingDeltaX }
        let input = ScrollStepAccumulator.Input(event, delta: delta)
        let rowHeight = bounds.height / CGFloat(max(terminal.rows, 1))
        let steps = scrollAccumulator.steps(for: input, rowHeight: rowHeight)
        guard steps != 0 else { return true }
        let count = abs(steps)
        guard terminal.isCurrentBufferAlternate, !shift else {
            let lines = input.isPrecise ? count : count * Self.wheelLinesPerNotch
            if steps > 0 { scrollUp(lines: lines) } else { scrollDown(lines: lines) }
            return true
        }
        if allowMouseReporting, terminal.mouseMode != .off {
            let point = convert(event.locationInWindow, from: nil)
            let column = min(terminal.cols - 1, max(0, Int(point.x / max(bounds.width, 1) * CGFloat(terminal.cols))))
            let row = min(terminal.rows - 1, max(0, Int((bounds.height - point.y) / max(bounds.height, 1) * CGFloat(terminal.rows))))
            for _ in 0..<count {
                terminal.sendEvent(buttonFlags: steps > 0 ? 64 : 65,
                                   x: column, y: row, pixelX: Int(point.x), pixelY: Int(bounds.height - point.y))
            }
        } else {
            let sequence = steps > 0 ? "\u{1b}[A" : "\u{1b}[B"
            for _ in 0..<count { send(txt: sequence) }
        }
        return true
    }

    // MARK: Links

    /// Whether the last left press landed in this view, so its release,
    /// wherever it happens, belongs to it.
    private var pressedHere = false
    private var linkClickCell: (column: Int, row: Int)?

    /// A ⌘-click opens the link under it here rather than in SwiftTerm,
    /// which does not see plain URLs. Every release of a press in this view
    /// goes on without ⌘, wherever it ends, so SwiftTerm does not open the
    /// link again; a program that takes the mouse still hears it. Any open
    /// SwiftTerm still asks for goes through `openLink(_:)` as well.
    /// Returns whether the event should go on without ⌘.
    private func handleLinkClick(_ event: NSEvent) -> Bool {
        if event.type == .leftMouseDown {
            pressedHere = !isHiddenOrHasHiddenAncestor && bounds.contains(convert(event.locationInWindow, from: nil))
            linkClickCell = pressedHere && event.modifierFlags.contains(.command) && event.clickCount == 1 ? cell(at: event) : nil
            return false
        }
        guard pressedHere else { return false }
        pressedHere = false
        let down = linkClickCell
        linkClickCell = nil
        guard event.modifierFlags.contains(.command) else { return false }
        if let down, let up = cell(at: event), down == up, let url = link(atColumn: up.column, row: up.row) {
            openLink(url)
        }
        return true
    }

    /// Give `url` to the app, and open it in the default app when the app
    /// leaves it and it is http, https or mailto.
    public func openLink(_ url: URL) {
        if onOpenLink?(url) == true { return }
        if TerminalLinks.opensInSystem(url) { openInSystem(url) }
    }

    /// Opens a link the app left, after the scheme check. Tests replace it.
    var openInSystem: (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// Stands in as SwiftTerm's terminal delegate so its own link opener
    /// (an OSC 8 link on a ⌘-release) comes through `openLink(_:)` rather
    /// than straight to NSWorkspace. Everything else goes to the view.
    private lazy var linkDelegate = TerminalLinkDelegate(view: self)

    /// Route SwiftTerm's link requests through `openLink(_:)`. Called from
    /// the initialisers; safe to call again.
    func routeSwiftTermLinks() {
        terminalDelegate = linkDelegate
    }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        routeSwiftTermLinks()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        routeSwiftTermLinks()
    }

    /// The link at a visible cell: the cell's OSC 8 hyperlink, else a plain
    /// http or https URL printed across it.
    public func link(atColumn column: Int, row: Int) -> URL? {
        let terminal = getTerminal()
        guard let line = terminal.getLine(row: row), column >= 0, column < min(terminal.cols, line.count) else { return nil }
        if let payload = line[column].getPayload() as? String {
            return TerminalLinks.hyperlinkURL(fromPayload: payload)
        }
        // Join the visible rows of the soft-wrapped line around the click,
        // so a URL that runs past the right edge is found whole from either
        // row. A hard line break is never joined.
        var first = row, last = row
        while first > 0, isWrapped(line: terminal.getLine(row: first)) { first -= 1 }
        while let next = terminal.getLine(row: last + 1), isWrapped(line: next) { last += 1 }
        let rows = (first...last).map { index -> [Character] in
            guard let line = terminal.getLine(row: index) else { return [] }
            return (0..<min(terminal.cols, line.count)).map { terminal.getCharacter(for: line[$0]) }
        }
        return TerminalLinks.detectedURL(inWrappedRows: rows, row: row - first, column: column)
    }

    /// Whether `line` continues the row above it because the text before it
    /// ran past the right edge. SwiftTerm 1.11 keeps that flag internal on
    /// `BufferLine`, so it is read by reflection; without it a row counts as
    /// its own line, as before.
    private func isWrapped(line: BufferLine?) -> Bool {
        guard let line else { return false }
        return Mirror(reflecting: line).children.first { $0.label == "isWrapped" }?.value as? Bool ?? false
    }

    /// The visible cell under the pointer, measured the way SwiftTerm sizes
    /// its cells.
    private func cell(at event: NSEvent) -> (column: Int, row: Int)? {
        let terminal = getTerminal()
        let point = convert(event.locationInWindow, from: nil)
        let glyph = font.glyph(withName: "W")
        let width = max(1, font.advancement(forGlyph: glyph).width)
        let height = max(1, ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)))
        let column = Int(point.x / width), row = Int((frame.height - point.y) / height)
        guard point.x >= 0, column < terminal.cols, row >= 0, row < terminal.rows else { return nil }
        return (column, row)
    }

    private nonisolated static func withoutCommand(_ event: NSEvent) -> NSEvent? {
        NSEvent.mouseEvent(with: event.type, location: event.locationInWindow,
                           modifierFlags: event.modifierFlags.subtracting(.command), timestamp: event.timestamp,
                           windowNumber: event.windowNumber, context: nil, eventNumber: event.eventNumber,
                           clickCount: event.clickCount, pressure: event.pressure)
    }

    open override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, let shortcut = shortcutResolver?(event) ?? TerminalShortcut(event),
           onShortcut?(shortcut) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Whether some of the terminal's text is selected.
    public var hasSelection: Bool { getSelection()?.isEmpty == false }

    /// Edit › Copy: the selected text, onto ``pasteboard``.
    open override func copy(_ sender: Any) {
        guard let text = getSelection(), !text.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Edit › Paste: what ``pasteboard`` holds, typed in the way Terminal
    /// does it. See ``PasteContent`` for the order.
    open override func paste(_ sender: Any) {
        guard let bytes = pasteInput() else { return }
        send(bytes)
    }

    /// The bytes ⌘V sends for what ``pasteboard`` holds now, or nil when
    /// there is nothing to send.
    func pasteInput() -> [UInt8]? {
        let bracketed = getTerminal().bracketedPasteMode
        switch PasteContent(pasteboard) {
        case .files(let paths):
            return Array(pasteInputText(paths.map(ShellQuote.quote).joined(separator: " ") + " ", bracketed: bracketed).utf8)
        case .text(let text):
            // A shell without bracketed paste takes a paste line by line, as in Terminal.
            return Array((bracketed ? pasteInputText(text, bracketed: true) : text).utf8)
        case .image:
            // Claude Code and Codex read an image off the clipboard
            // themselves when they see Ctrl+V.
            return [0x16]
        case .none:
            return nil
        }
    }

    /// A clipboard write a program asked for (OSC 52), onto ``pasteboard``.
    func writeClipboard(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Clear the screen and scrollback, then ask the program to redraw.
    public func clearScreen() {
        feed(text: "\u{1b}[2J\u{1b}[3J\u{1b}[H")
        send([0x0c])
    }

    // MARK: Drop

    /// Text dropped on the terminal is typed in; files arrive as quoted
    /// paths, the way Terminal does it.
    public static let droppedTypes: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .string]

    open override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.availableType(from: Self.droppedTypes) == nil ? [] : .copy
    }

    open override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    open override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        let text: String
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            text = urls.map { ShellQuote.quote($0.path) }.joined(separator: " ") + " "
        } else if let string = pasteboard.string(forType: .string), !string.isEmpty {
            text = string
        } else if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            text = urls.map(\.absoluteString).joined(separator: " ")
        } else {
            return false
        }
        pasteText(text)
        window?.makeFirstResponder(self)
        return true
    }

    /// Type `text` in as a paste, never followed by Return. Control
    /// characters are stripped so the text cannot end the paste early or
    /// drive the terminal.
    /// Whether the program takes a paste as one block.
    public var acceptsBracketedPaste: Bool { getTerminal().bracketedPasteMode }

    public func pasteText(_ text: String) {
        send(txt: pasteInputText(text, bracketed: getTerminal().bracketedPasteMode))
    }

    private func pasteInputText(_ text: String, bracketed: Bool) -> String {
        let cleaned = pasteSanitizer(text)
        return bracketed ? "\u{1b}[200~" + cleaned + "\u{1b}[201~" : cleaned.replacingOccurrences(of: "\n", with: " ")
    }
}

/// SwiftTerm's terminal delegate for an `AgentTerminalView`: the view's own
/// handling for everything but link requests, which go to `openLink(_:)`.
/// Bells and other unhandled requests keep SwiftTerm's defaults, as they
/// did with the view as its own delegate.
final class TerminalLinkDelegate: TerminalViewDelegate {
    private unowned let view: AgentTerminalView

    init(view: AgentTerminalView) { self.view = view }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        view.sizeChanged(source: source, newCols: newCols, newRows: newRows)
    }
    func setTerminalTitle(source: TerminalView, title: String) { view.setTerminalTitle(source: source, title: title) }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        view.hostCurrentDirectoryUpdate(source: source, directory: directory)
    }
    func send(source: TerminalView, data: ArraySlice<UInt8>) { view.send(source: source, data: data) }
    func scrolled(source: TerminalView, position: Double) { view.scrolled(source: source, position: position) }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) { view.rangeChanged(source: source, startY: startY, endY: endY) }
    /// OSC 52 writes are taken from the output in `dataReceived(slice:)`,
    /// so one coming here as well would be written twice.
    func clipboardCopy(source: TerminalView, content: Data) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = TerminalLinks.url(from: link) else { return }
        view.openLink(url)
    }
}

/// What ⌘V pastes, in the order a Mac terminal looks: copied files
/// become their quoted paths (Finder also puts the file names and icons
/// on the pasteboard, which would otherwise win), then text, then an image
/// alone, which the agent reads from the clipboard itself on Ctrl+V.
enum PasteContent: Equatable {
    case files([String])
    case text(String)
    case image
    case none

    init(_ pasteboard: NSPasteboard) {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            self = .files(urls.map(\.path))
        } else if let text = pasteboard.string(forType: .string), !text.isEmpty {
            self = .text(text)
        } else if pasteboard.canReadObject(forClasses: [NSImage.self], options: nil) {
            self = .image
        } else {
            self = .none
        }
    }
}

/// Quoting for the one shell line a lane starts with.
public enum ShellQuote {
    public static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Text with every control character but newline and tab removed.
    public static func pasteSafe(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter {
            $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0)
        }))
    }
}

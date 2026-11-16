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

    private var colorRequests = TerminalColorSchemeRequests()
    private var clipboardRequests = ClipboardRequests()
    private var flagsMonitor: Any?
    private var reportsColorScheme = false
    public private(set) var colorScheme: TerminalColorScheme?
    private var appAppearanceObservation: NSKeyValueObservation?
    private var inputMonitor: Any?

    open override func dataReceived(slice: ArraySlice<UInt8>) {
        let requests = colorRequests.scan(slice)
        for text in clipboardRequests.scan(slice) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
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
    /// wheel for full-screen programs, and plain pointer movement.
    ///
    /// Plain movement is not passed on: a program that asks for every mouse
    /// event (mode 1003) otherwise hears each pixel the pointer crosses, and
    /// agent TUIs redraw hover states as it passes over them. Clicks, drags
    /// and the wheel still reach it, and ⌘ keeps link previews.
    public func installInputHandling() {
        removeInputHandling()
        installSelectionOverride()
        // Local monitors run on the main thread, inside the app's event loop.
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel, .mouseMoved]) { [weak self] event in
            guard let self else { return event }
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

    public func removeInputHandling() {
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        flagsMonitor = nil
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
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

    /// A full-screen program (an agent's TUI) has no scrollback of its own
    /// here, so the wheel goes to it: as mouse wheel events when it reports
    /// the mouse, else as arrow keys. ⇧ always scrolls the local history.
    private func handleScrollWheel(_ event: NSEvent) -> Bool {
        let terminal = getTerminal()
        guard terminal.isCurrentBufferAlternate, !event.modifierFlags.contains(.shift) else { return false }
        guard event.scrollingDeltaY != 0 else { return true }
        let count = min(10, max(1, Int(abs(event.scrollingDeltaY))))
        if allowMouseReporting, terminal.mouseMode != .off {
            let point = convert(event.locationInWindow, from: nil)
            let column = min(terminal.cols - 1, max(0, Int(point.x / max(bounds.width, 1) * CGFloat(terminal.cols))))
            let row = min(terminal.rows - 1, max(0, Int((bounds.height - point.y) / max(bounds.height, 1) * CGFloat(terminal.rows))))
            for _ in 0..<count {
                terminal.sendEvent(buttonFlags: event.scrollingDeltaY > 0 ? 64 : 65,
                                   x: column, y: row, pixelX: Int(point.x), pixelY: Int(bounds.height - point.y))
            }
        } else {
            let sequence = event.scrollingDeltaY > 0 ? "\u{1b}[A" : "\u{1b}[B"
            for _ in 0..<count { send(txt: sequence) }
        }
        return true
    }

    open override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, let shortcut = shortcutResolver?(event) ?? TerminalShortcut(event),
           onShortcut?(shortcut) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
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
        let cleaned = pasteSanitizer(text)
        if getTerminal().bracketedPasteMode {
            send(txt: "\u{1b}[200~" + cleaned + "\u{1b}[201~")
        } else {
            send(txt: cleaned.replacingOccurrences(of: "\n", with: " "))
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

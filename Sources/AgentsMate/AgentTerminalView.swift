import AppKit
import SwiftTerm

/// SwiftTerm's view with what a lane list needs: the app's light or dark
/// appearance followed and reported to the program, the list's shortcuts
/// caught while it has focus, Terminal's editing keys, and drops typed in.
open class AgentTerminalView: LocalProcessTerminalView {
    /// Answers a shortcut pressed while the terminal has focus. Returns
    /// whether it was handled; an unhandled one goes on to the menus.
    public var onShortcut: ((TerminalShortcut) -> Bool)?
    /// Called after each chunk of output is drawn.
    public var onOutput: (() -> Void)?
    /// Cleans text before it is typed in as a paste. The default keeps
    /// newlines and tabs and drops every other control character.
    public var pasteSanitizer: (String) -> String = ShellQuote.pasteSafe

    private var colorRequests = TerminalColorSchemeRequests()
    private var reportsColorScheme = false
    public private(set) var colorScheme: TerminalColorScheme?
    private var appAppearanceObservation: NSKeyValueObservation?
    private var inputMonitor: Any?

    open override func dataReceived(slice: ArraySlice<UInt8>) {
        let requests = colorRequests.scan(slice)
        super.dataReceived(slice: slice)
        for request in requests { handleColorRequest(request) }
        onOutput?()
    }

    /// Draw in the app's appearance and follow it from now on.
    public func followAppearance() {
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

    /// Terminal-style editing keys SwiftTerm leaves to the host, and the
    /// scroll wheel for full-screen programs.
    public func installInputHandling() {
        removeInputHandling()
        // Local monitors run on the main thread, inside the app's event loop.
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard event.window === self.window else { return false }
                if event.type == .keyDown {
                    return self.window?.firstResponder === self && self.handleKeyDown(event)
                }
                guard !self.isHiddenOrHasHiddenAncestor,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return false }
                return self.handleScrollWheel(event)
            }
            return handled ? nil : event
        }
    }

    public func removeInputHandling() {
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
        if window?.firstResponder === self, let shortcut = TerminalShortcut(event), onShortcut?(shortcut) == true {
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

import AppKit
import SwiftTerm

/// SwiftTerm's view with what a lane list needs: the app's light or dark
/// appearance followed and reported to the program, the list's shortcuts
/// caught while it has focus, Terminal's editing keys, and drops typed in.
public final class AgentTerminalView: LocalProcessTerminalView {
    /// Answers a shortcut pressed while the terminal has focus. Returns
    /// whether it was handled; an unhandled one goes on to the menus.
    var onShortcut: ((TerminalShortcut) -> Bool)?

    private var colorRequests = TerminalColorSchemeRequests()
    private var reportsColorScheme = false
    public private(set) var colorScheme: TerminalColorScheme?
    private var appAppearanceObservation: NSKeyValueObservation?
    private var inputMonitor: Any?

    public override func dataReceived(slice: ArraySlice<UInt8>) {
        let requests = colorRequests.scan(slice)
        super.dataReceived(slice: slice)
        for request in requests { handleColorRequest(request) }
    }

    /// Draw in the app's appearance and follow it from now on.
    func followAppearance() {
        getTerminal().ansi256PaletteStrategy = .xterm
        applyColorScheme()
        appAppearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.applyColorScheme() }
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColorScheme()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColorScheme()
    }

    func applyColorScheme() {
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

    /// Terminal-style editing keys SwiftTerm leaves to the host.
    func installInputHandling() {
        removeInputHandling()
        // Local monitors run on the main thread, inside the app's event loop.
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard event.window === self.window, self.window?.firstResponder === self else { return false }
                return self.handleKeyDown(event)
            }
            return handled ? nil : event
        }
    }

    func removeInputHandling() {
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
        return false
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
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
    static let droppedTypes: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .string]

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.availableType(from: Self.droppedTypes) == nil ? [] : .copy
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
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
    public func pasteText(_ text: String) {
        let cleaned = ShellQuote.pasteSafe(text)
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

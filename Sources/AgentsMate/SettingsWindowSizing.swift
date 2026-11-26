import SwiftUI
import AppKit

public extension View {
    /// Lets a Settings window be resized, with a minimum and a first size, and
    /// remembers the size the person leaves it at. Put it on the Settings
    /// scene's root view, in place of a fixed or capped frame.
    func resizableSettingsWindow(minWidth: CGFloat = 520, idealWidth: CGFloat? = nil,
                                 minHeight: CGFloat = 420, idealHeight: CGFloat = 640,
                                 autosaveName: String = "SettingsWindow") -> some View {
        frame(minWidth: minWidth, idealWidth: idealWidth, maxWidth: .infinity,
              minHeight: minHeight, idealHeight: idealHeight, maxHeight: .infinity)
            .background(SettingsWindowSizer(autosaveName: autosaveName))
    }
}

private struct SettingsWindowSizer: NSViewRepresentable {
    let autosaveName: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in configure(view?.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { [weak view] in configure(view?.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.styleMask.insert(.resizable)
        if window.frameAutosaveName != autosaveName { window.setFrameAutosaveName(autosaveName) }
    }
}

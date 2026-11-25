import AppKit
import SwiftUI

/// The system's search field, wrapped. On macOS 27 `NSSearchField` draws as the
/// borderless glass capsule that Mail's search has, so nothing here draws a
/// background, a border or a magnifier of its own.
///
/// Escape clears the field and gives up the cursor, and the clear button does
/// the same; the owner hears about either through `onClear`.
public struct AgentsSearchField: NSViewRepresentable {
    private let text: Binding<String>
    private let prompt: String
    private let isFocused: Binding<Bool>?
    private let focusRequest: Int
    private let fontScale: Double
    private let controlSize: NSControl.ControlSize
    private let scope: AgentsToolbarSearchScope?
    private let identifier: String?
    private let onSubmit: () -> Void
    private let onClear: () -> Void
    private let onFocusChange: (Bool) -> Void
    private let onMoveDown: (() -> Void)?
    private let onMoveUp: (() -> Void)?

    /// `isFocused` follows the cursor both ways; `focusRequest` puts the cursor
    /// in the field whenever it changes. `scope` becomes the item in the
    /// magnifier's menu.
    public init(text: Binding<String>, prompt: String, isFocused: Binding<Bool>? = nil, focusRequest: Int = 0,
                fontScale: Double = 1, controlSize: NSControl.ControlSize = .regular,
                scope: AgentsToolbarSearchScope? = nil, identifier: String? = nil,
                onSubmit: @escaping () -> Void = {}, onClear: (() -> Void)? = nil,
                onFocusChange: @escaping (Bool) -> Void = { _ in }, onMoveDown: (() -> Void)? = nil, onMoveUp: (() -> Void)? = nil) {
        self.text = text
        self.prompt = prompt
        self.isFocused = isFocused
        self.focusRequest = focusRequest
        self.fontScale = fontScale
        self.controlSize = controlSize
        self.scope = scope
        self.identifier = identifier
        self.onSubmit = onSubmit
        self.onClear = onClear ?? { text.wrappedValue = "" }
        self.onFocusChange = onFocusChange
        self.onMoveDown = onMoveDown
        self.onMoveUp = onMoveUp
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.fieldAction(_:))
        field.sendsWholeSearchString = true
        field.sendsSearchStringImmediately = false
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    public func updateNSView(_ field: NSSearchField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        field.placeholderString = prompt
        field.controlSize = controlSize
        field.font = .systemFont(ofSize: NSFont.systemFontSize(for: controlSize) * fontScale)
        if let identifier { field.setAccessibilityIdentifier(identifier) }
        field.setAccessibilityLabel(prompt)
        if field.stringValue != text.wrappedValue, !coordinator.isComposing(field) {
            field.stringValue = text.wrappedValue
            coordinator.lastText = text.wrappedValue
        }
        coordinator.applyScope(scope, to: field)
        if coordinator.lastFocusRequest != focusRequest {
            coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
        if let isFocused {
            let editing = coordinator.isEditing(field)
            if isFocused.wrappedValue != editing {
                DispatchQueue.main.async {
                    if isFocused.wrappedValue { field.window?.makeFirstResponder(field) }
                    else if coordinator.isEditing(field) { field.window?.makeFirstResponder(nil) }
                }
            }
        }
    }

    @MainActor
    public final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: AgentsSearchField?
        var lastText = ""
        var lastFocusRequest = 0
        private weak var scopeItem: NSMenuItem?

        func isEditing(_ field: NSSearchField) -> Bool {
            field.currentEditor() != nil && field.window?.firstResponder === field.currentEditor()
        }

        func isComposing(_ field: NSSearchField) -> Bool {
            (field.currentEditor() as? NSTextView)?.hasMarkedText() ?? false
        }

        func applyScope(_ scope: AgentsToolbarSearchScope?, to field: NSSearchField) {
            guard let scope else {
                field.searchMenuTemplate = nil
                return
            }
            if field.searchMenuTemplate == nil {
                let menu = NSMenu()
                let item = NSMenuItem(title: scope.help, action: #selector(scopeAction(_:)), keyEquivalent: "")
                item.target = self
                menu.addItem(item)
                field.searchMenuTemplate = menu
            }
            field.searchMenuTemplate?.items.first?.title = scope.help
        }

        @objc private func scopeAction(_ sender: Any?) { parent?.scope?.action() }

        public func controlTextDidBeginEditing(_ notification: Notification) {
            parent?.isFocused?.wrappedValue = true
            parent?.onFocusChange(true)
        }

        public func controlTextDidEndEditing(_ notification: Notification) {
            parent?.isFocused?.wrappedValue = false
            parent?.onFocusChange(false)
        }

        public func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            lastText = field.stringValue
            parent?.text.wrappedValue = field.stringValue
        }

        @objc func fieldAction(_ sender: NSSearchField) {
            // The clear button empties the field and sends the action.
            if sender.stringValue.isEmpty {
                let wasFilled = !lastText.isEmpty
                lastText = ""
                parent?.text.wrappedValue = ""
                if wasFilled {
                    sender.window?.makeFirstResponder(nil)
                    parent?.onClear()
                }
            } else {
                lastText = sender.stringValue
                parent?.text.wrappedValue = sender.stringValue
                parent?.onSubmit()
            }
        }

        public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.moveDown(_:)), let down = parent?.onMoveDown {
                down()
                return true
            }
            if selector == #selector(NSResponder.moveUp(_:)), let up = parent?.onMoveUp {
                up()
                return true
            }
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            control.stringValue = ""
            lastText = ""
            parent?.text.wrappedValue = ""
            control.window?.makeFirstResponder(nil)
            parent?.onClear()
            return true
        }
    }
}

import SwiftUI

/// Names what the field searches; choosing it in the magnifier's menu switches the scope.
public struct AgentsToolbarSearchScope {
    public var title: String
    public var help: String
    public var action: () -> Void

    public init(title: String, help: String, action: @escaping () -> Void) {
        self.title = title
        self.help = help
        self.action = action
    }
}

/// The window's one search field, in the toolbar's right: the system's search
/// field, with what it searches and the shortcut that reaches it in its prompt. What it searches and what it finds belong to the app, which
/// supplies the text, the results and their popover.
public struct AgentsToolbarSearchField<Results: View>: View {
    private let text: Binding<String>
    private let prompt: String
    private let hint: String
    private let help: String
    private let width: CGFloat
    private let isSearching: Bool
    private let scope: AgentsToolbarSearchScope?
    private let focusRequest: Int
    private let showResults: Binding<Bool>
    private let fontScale: Double
    private let identifier: String
    private let onSubmit: () -> Void
    private let onClear: () -> Void
    private let onFocusChange: (Bool) -> Void
    private let results: () -> Results
    /// Off only offscreen, where a popover cannot show.
    private var showsPopover = true

    @State private var focused = false

    /// `focusRequest` puts the cursor in the field whenever it changes, which
    /// is how ⌘K and ⌘F reach it from anywhere in the window.
    public init(text: Binding<String>, prompt: String, hint: String = "⌘K", help: String? = nil,
                width: CGFloat = 300, isSearching: Bool = false, scope: AgentsToolbarSearchScope? = nil, focusRequest: Int = 0,
                showResults: Binding<Bool> = .constant(false), fontScale: Double = 1,
                identifier: String = "AgentsToolbarSearchField",
                onSubmit: @escaping () -> Void = {}, onClear: (() -> Void)? = nil,
                onFocusChange: @escaping (Bool) -> Void = { _ in },
                @ViewBuilder results: @escaping () -> Results) {
        self.text = text
        self.prompt = prompt
        self.hint = hint
        self.help = help ?? "\(prompt) (\(hint))"
        self.width = width
        self.isSearching = isSearching
        self.scope = scope
        self.focusRequest = focusRequest
        self.showResults = showResults
        self.fontScale = fontScale
        self.identifier = identifier
        self.onSubmit = onSubmit
        self.onClear = onClear ?? { text.wrappedValue = "" }
        self.onFocusChange = onFocusChange
        self.results = results
    }

    /// A field drawn without its popover, for offscreen checks.
    init(offscreen text: Binding<String>, prompt: String, hint: String = "⌘K", width: CGFloat = 300,
         scope: AgentsToolbarSearchScope? = nil, fontScale: Double = 1) where Results == EmptyView {
        self.init(text: text, prompt: prompt, hint: hint, width: width, scope: scope, fontScale: fontScale) { EmptyView() }
        showsPopover = false
    }

    public var body: some View {
        // `hint` rides in the prompt: the field is the system's search field,
        // which has no room for a badge of its own.
        AgentsSearchField(text: text, prompt: "\(prompt)  \(hint)", isFocused: $focused, focusRequest: focusRequest,
                          fontScale: fontScale, scope: scope, identifier: identifier,
                          onSubmit: onSubmit, onClear: onClear, onFocusChange: onFocusChange)
            .overlay(alignment: .trailing) {
                if isSearching {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 30)
                        .accessibilityLabel("Searching")
                }
            }
            .frame(width: width)
            .fixedSize(horizontal: true, vertical: false)
            .help(help)
            .popover(isPresented: showsPopover ? showResults : .constant(false), arrowEdge: .bottom) {
                results()
            }
    }
}

/// One thing a search found, for apps whose results are a plain list.
public struct AgentsSearchHit: Identifiable, Hashable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var systemImage: String
    /// What the hit is, such as a repository or a session.
    public var category: String

    public init(id: String, title: String, subtitle: String? = nil, systemImage: String, category: String) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.category = category
    }
}

/// The popover under the search field for a list of ``AgentsSearchHit``s.
public struct AgentsSearchHitList: View {
    private let hits: [AgentsSearchHit]
    private let isSearching: Bool
    private let open: (AgentsSearchHit) -> Void

    public init(hits: [AgentsSearchHit], isSearching: Bool = false, open: @escaping (AgentsSearchHit) -> Void) {
        self.hits = hits
        self.isSearching = isSearching
        self.open = open
    }

    public var body: some View {
        ScrollView {
            if hits.isEmpty {
                HStack(spacing: 8) {
                    if isSearching { ProgressView().controlSize(.small) }
                    Text(isSearching ? "Searching…" : "No matches.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(hits) { hit in
                        Button { open(hit) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: hit.systemImage)
                                    .frame(width: 18)
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(hit.title).lineLimit(1)
                                    if let subtitle = hit.subtitle {
                                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 8)
                                Text(hit.category).font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(width: 440)
        .frame(maxHeight: 420)
    }
}

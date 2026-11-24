import SwiftUI

/// Names what the field searches; clicking it switches the scope.
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

/// The window's one search field, in the toolbar's right: a magnifier, an
/// optional chip naming what it searches, the text, and the shortcut that
/// reaches it. What it searches and what it finds belong to the app, which
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

    @FocusState private var focused: Bool

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
        HStack(spacing: 6) {
            if isSearching {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
                    .accessibilityLabel("Searching")
            } else {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(focused ? Color.accentColor : .secondary)
                    .onTapGesture { focused = true }
            }
            if let scope {
                Button(action: scope.action) {
                    Text(scope.title)
                        .font(.system(size: 11 * fontScale, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .help(scope.help)
            }
            if showsPopover {
                TextField("", text: text, prompt: Text(prompt).foregroundStyle(.secondary))
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(onSubmit)
                    .onExitCommand {
                        onClear()
                        focused = false
                    }
            } else {
                // Offscreen a text field draws as a placeholder box.
                Text(prompt)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if text.wrappedValue.isEmpty {
                Text(hint)
                    .font(.system(size: 10 * fontScale, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            } else {
                Button {
                    onClear()
                    focused = false
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .font(.system(size: 13 * fontScale))
        .padding(.horizontal, 10)
        .frame(width: width, height: 28)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityIdentifier(identifier)
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(focused ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: focused ? 1.5 : 1)
        )
        .help(help)
        .onChange(of: focusRequest) { _, _ in focused = true }
        .onChange(of: focused) { _, now in onFocusChange(now) }
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

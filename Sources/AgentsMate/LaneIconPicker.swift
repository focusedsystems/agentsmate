import SwiftUI

/// Choose an icon and colour for a lane: a search field, SF Symbols or the
/// bundled set, a grid, and a row of colours. Show it in a sheet or popover.
///
/// The grid takes the arrow keys, and Return picks the highlighted icon.
/// `onChoose` gets the icon and the colour as `#RRGGBB` (nil is the accent
/// colour); `onReset` goes back to the app's own icon and colour.
public struct LaneIconPicker: View {
    public enum Kind: String, CaseIterable, Identifiable {
        case symbols = "SF Symbols"
        case bundled = "Icons"
        public var id: String { rawValue }
    }

    private let laneTitle: String?
    private let canReset: Bool
    private let onChoose: (LaneIcon, String?) -> Void
    private let onReset: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var kind: Kind
    @State private var query = ""
    @State private var selection: LaneIcon
    @State private var highlighted = 0
    @State private var tintHex: String?
    @State private var customColor: Color
    @FocusState private var focus: Field?

    private enum Field: Hashable { case search, grid }

    private static let columns = 10
    private static let cell: CGFloat = 36
    private static let margin: CGFloat = 20
    /// Ten icon cells wide, so the grid's adaptive columns come to exactly `columns`.
    private static let contentWidth: CGFloat = cell * CGFloat(columns) + 20

    public init(icon: LaneIcon, tintHex: String?, laneTitle: String? = nil, canReset: Bool = false,
                onReset: (() -> Void)? = nil, onChoose: @escaping (LaneIcon, String?) -> Void) {
        self.laneTitle = laneTitle
        self.canReset = canReset
        self.onReset = onReset
        self.onChoose = onChoose
        _selection = State(initialValue: icon)
        _kind = State(initialValue: { if case .bundled = icon { .bundled } else { .symbols } }())
        _tintHex = State(initialValue: LaneIconColors.normalised(tintHex))
        _customColor = State(initialValue: tintHex.flatMap(Color.init(laneHex:)) ?? .accentColor)
    }

    private var names: [String] {
        let all = kind == .symbols ? LaneIconLibrary.symbolNames : LaneIconLibrary.bundledNames
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return all }
        return all.filter { name in
            let text = name.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "-", with: " ")
            return words.allSatisfy { text.contains($0) }
        }
    }

    private func icon(_ name: String) -> LaneIcon { kind == .symbols ? .symbol(name) : .bundled(name) }

    private var tint: Color { tintHex.flatMap(Color.init(laneHex:)) ?? .accentColor }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            AgentsSearchField(text: $query, prompt: "Search icons",
                              isFocused: Binding(get: { focus == .search },
                                                 set: { if $0 { focus = .search } else if focus == .search { focus = nil } }),
                              onSubmit: { pickHighlighted() }, onMoveDown: { focus = .grid })
            Picker("Icon set", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Icon set")
            grid
            colourRow
            Divider()
            footer
        }
        .padding(Self.margin)
        .frame(width: Self.contentWidth + Self.margin * 2)
        .onAppear { focus = .search }
        .onChange(of: kind) { _, _ in highlighted = 0 }
        .onChange(of: query) { _, _ in highlighted = 0 }
        .onChange(of: customColor) { _, new in tintHex = LaneIconColors.hex(from: new) }
        .onExitCommand { dismiss() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            LaneIconView(icon: selection, tint: tint, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(laneTitle.map { "Icon for \($0)" } ?? "Choose an Icon").font(.headline)
                Text(selection.title).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private var grid: some View {
        let shown = names
        return ScrollViewReader { proxy in
            ScrollView {
                if shown.isEmpty {
                    ContentUnavailableView.search(text: query).frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.cell, maximum: Self.cell), spacing: 0)],
                              spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.element) { index, name in
                            cellView(name, index: index)
                        }
                    }
                }
            }
            .frame(height: Self.cell * 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            .focusable()
            .focused($focus, equals: .grid)
            .focusEffectDisabled()
            .onKeyPress(phases: [.down, .repeat]) { press in handleKey(press, count: shown.count, names: shown) }
            .onChange(of: highlighted) { _, new in
                if shown.indices.contains(new) { proxy.scrollTo(shown[new]) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Icons")
        }
    }

    private func cellView(_ name: String, index: Int) -> some View {
        let candidate = icon(name)
        let isSelected = candidate == selection
        let isHighlighted = index == highlighted && focus == .grid
        return LaneIconView(icon: candidate, tint: isSelected ? tint : Color.primary, size: 20)
            .frame(width: Self.cell, height: Self.cell)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? tint.opacity(0.18) : .clear)
                    .padding(2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(2)
                    .opacity(isHighlighted ? 1 : 0)
            )
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { selection = candidate; highlighted = index; commit() }
            .onTapGesture { selection = candidate; highlighted = index; focus = .grid }
            .help(candidate.title)
            .id(name)
            .accessibilityElement()
            .accessibilityLabel(candidate.title)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { selection = candidate; highlighted = index }
    }

    private func handleKey(_ press: KeyPress, count: Int, names shown: [String]) -> KeyPress.Result {
        guard count > 0 else { return .ignored }
        let step: Int
        switch press.key {
        case .leftArrow: step = -1
        case .rightArrow: step = 1
        case .upArrow:
            if highlighted < Self.columns { focus = .search; return .handled }
            step = -Self.columns
        case .downArrow: step = Self.columns
        case .return:
            pickHighlighted()
            return .handled
        case .space:
            selection = icon(shown[min(highlighted, count - 1)])
            return .handled
        default: return .ignored
        }
        highlighted = min(max(highlighted + step, 0), count - 1)
        selection = icon(shown[highlighted])
        return .handled
    }

    private func pickHighlighted() {
        let shown = names
        guard shown.indices.contains(highlighted) else { return }
        selection = icon(shown[highlighted])
        commit()
    }

    private var colourRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Colour").font(.subheadline).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 8) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 26, maximum: 26), spacing: 4)],
                          alignment: .leading, spacing: 4) {
                    swatch(name: "Default", hex: nil, color: .accentColor)
                    ForEach(LaneIconColors.presets, id: \.hex) { preset in
                        swatch(name: preset.name, hex: preset.hex, color: Color(laneHex: preset.hex) ?? .gray)
                    }
                }
                ColorPicker("Custom colour", selection: $customColor, supportsOpacity: false)
                    .labelsHidden()
                    .fixedSize()
                    .help("Choose any colour")
                    .accessibilityLabel("Custom colour")
            }
        }
    }

    private func swatch(name: String, hex: String?, color: Color) -> some View {
        let isSelected = tintHex == hex
        return Button {
            tintHex = hex
            if let hex, let c = Color(laneHex: hex) { customColor = c }
        } label: {
            Circle()
                .fill(color)
                .frame(width: 18, height: 18)
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.6), radius: 1)
                    }
                }
                .overlay(Circle().strokeBorder(Color.primary.opacity(isSelected ? 0.9 : 0.25), lineWidth: isSelected ? 2 : 1))
                .padding(2)
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var footer: some View {
        HStack {
            if let onReset {
                Button("Use Default") { onReset(); dismiss() }
                    .disabled(!canReset)
                    .help("Go back to the icon and colour the app gave this lane")
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Choose") { commit() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func commit() {
        onChoose(selection, tintHex)
        dismiss()
    }
}

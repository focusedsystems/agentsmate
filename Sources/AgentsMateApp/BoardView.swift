import SwiftUI
import AgentsMateStatus

/// Every agent on every Mac, a column each for Needs You, Working and Idle &
/// Done (and Not Running under All). Clicking a card opens its lane in the
/// app it belongs to.
struct BoardView: View {
    @ObservedObject var model: BoardModel
    @Binding var selection: AgentBoard.Card.ID?
    @AppStorage("showsAll") private var showsAll = false
    @State private var query = ""
    @State private var confirmingStop: AgentBoard.Card?

    private var filtered: [AgentBoard.Card] {
        let text = query.trimmingCharacters(in: .whitespaces)
        return model.cards.filter { card in
            guard showsAll || card.isRunning else { return false }
            guard !text.isEmpty else { return true }
            let fields = [card.title, card.sessionTitle, card.summary, card.section, card.folder, card.host,
                          AppInfo.name(card.app)]
            return fields.contains { $0?.localizedCaseInsensitiveContains(text) == true }
        }
    }

    private var columns: [AgentBoard.Column] {
        showsAll ? AgentBoard.Column.allCases : [.needsYou, .working, .idleOrDone]
    }

    var body: some View {
        let cards = filtered
        VStack(spacing: 0) {
            header(cards)
            Divider()
            HStack(alignment: .top, spacing: 12) {
                ForEach(columns) { column in
                    ColumnView(column: column, cards: cards.filter { $0.column == column }, model: model,
                               selection: $selection, confirmingStop: $confirmingStop)
                }
            }
            .padding(12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .searchable(text: $query, placement: .toolbar, prompt: "Filter")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $showsAll) {
                    Text("Active").tag(false)
                    Text("All Lanes").tag(true)
                }
                .pickerStyle(.segmented)
                .help("Active shows running sessions; All Lanes adds stopped ones")
            }
            ToolbarItem {
                Button { model.refresh(remote: true) } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Ask every Mac again (⌘R)")
            }
        }
        .confirmationDialog(confirmingStop.map { "Stop “\($0.title)”?" } ?? "",
                            isPresented: Binding(get: { confirmingStop != nil }, set: { if !$0 { confirmingStop = nil } }),
                            presenting: confirmingStop) { card in
            Button("Stop Agent", role: .destructive) { model.stop(card) }
            Button("Cancel", role: .cancel) {}
        } message: { card in
            Text("Ends the session on \(card.host). Its conversation is kept and can be resumed.")
        }
        .alert("Stop failed", isPresented: Binding(get: { model.stopMessage != nil }, set: { if !$0 { model.stopMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(model.stopMessage ?? "")
        }
        .focusedSceneValue(\.stopRequest, StopRequest { confirmingStop = $0 })
    }

    private func header(_ cards: [AgentBoard.Card]) -> some View {
        HStack(spacing: 18) {
            total(cards.filter { $0.column == .needsYou }.count, "need you", "hand.raised.fill", .orange)
            total(cards.filter { $0.column == .working }.count, "working", "bolt.fill", .blue)
            total(cards.filter { $0.column == .idleOrDone }.count, "idle or done", "moon.fill", .secondary)
            Spacer()
            ForEach([model.localHost] + model.remoteHosts, id: \.self) { host in
                HostBadge(host: host, state: model.hostStates[host] ?? .asking)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func total(_ count: Int, _ label: String, _ symbol: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).foregroundStyle(color)
            Text("\(count)").fontWeight(.semibold).monospacedDigit()
            Text(label).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct HostBadge: View {
    let host: String
    let state: BoardModel.HostState

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(host).font(.caption).foregroundStyle(.secondary)
        }
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(host): \(help)")
    }

    private var color: Color {
        switch state {
        case .asking: .yellow
        case .answered: .green
        case .unreachable: .red
        }
    }

    private var help: String {
        switch state {
        case .asking: "Asking"
        case .answered(let at): "Answered \(at.formatted(date: .omitted, time: .standard))"
        case .unreachable: "Did not answer; showing what it last said"
        }
    }
}

private struct ColumnView: View {
    let column: AgentBoard.Column
    let cards: [AgentBoard.Card]
    @ObservedObject var model: BoardModel
    @Binding var selection: AgentBoard.Card.ID?
    @Binding var confirmingStop: AgentBoard.Card?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(column.title).font(.headline)
                Text("\(cards.count)").font(.headline).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 4)
            ScrollView {
                LazyVStack(spacing: 8) {
                    if cards.isEmpty {
                        Text("None").foregroundStyle(.secondary).padding(.top, 20)
                    }
                    ForEach(cards) { card in
                        CardView(card: card, selected: selection == card.id, isLocal: model.isLocal(card.host))
                            .onTapGesture {
                                selection = card.id
                                model.open(card)
                            }
                            .contextMenu { CardMenu(card: card, model: model, confirmingStop: $confirmingStop) }
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.2)))
    }
}

struct CardMenu: View {
    let card: AgentBoard.Card
    @ObservedObject var model: BoardModel
    @Binding var confirmingStop: AgentBoard.Card?

    var body: some View {
        Button(card.app == nil ? "Open (no app lists it)" : "Open in \(AppInfo.name(card.app))") { model.open(card) }
            .disabled(card.app == nil)
        Button("Close (Keep Running)") { model.close(card) }
            .disabled(!model.canClose(card))
        Divider()
        Button("Stop Agent…", role: .destructive) { confirmingStop = card }
            .disabled(model.stopTarget(card) == nil)
        Divider()
        if let id = card.sessionID ?? card.conversationID {
            Button("Copy Session ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(id, forType: .string)
            }
        }
        Button("Show Folder in Finder") { model.revealFolder(card) }
            .disabled(card.folder == nil || !model.isLocal(card.host))
    }
}

private struct CardView: View {
    let card: AgentBoard.Card
    let selected: Bool
    let isLocal: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(stateColor).frame(width: 8, height: 8)
                    .accessibilityLabel(card.column.title)
                Text(card.title).font(.headline).lineLimit(1)
                Spacer(minLength: 4)
                if let at = card.updatedAt {
                    Text(at, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let title = card.sessionTitle, !title.isEmpty {
                Text(title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            if let summary = card.summary, !summary.isEmpty {
                Text(summary).font(.callout).lineLimit(3)
            }
            HStack(spacing: 5) {
                if let icon = AppInfo.icon(card.app) {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16).accessibilityHidden(true)
                }
                Text(AppInfo.name(card.app)).font(.caption)
                if let section = card.section, !section.isEmpty {
                    Text("· \(section)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Label(card.host, systemImage: isLocal ? "desktopcomputer" : "network")
                    .font(.caption).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
            }
            HStack(spacing: 5) {
                Text(stateText).font(.caption).foregroundStyle(.secondary)
                if let agent = card.agent { Text("· \(agent)").font(.caption).foregroundStyle(.secondary) }
                if let folder = card.folder {
                    Text("· \((folder as NSString).lastPathComponent)").font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor).opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(borderColor, lineWidth: borderWidth))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(helpText)
    }

    private var borderColor: Color { selected ? Color.accentColor : Color.secondary.opacity(0.25) }
    private var borderWidth: CGFloat { selected ? 2 : 1 }
    private var helpText: String {
        guard card.app != nil else { return "No app lists this session" }
        return "Open in " + AppInfo.name(card.app)
    }

    private var stateColor: Color {
        switch card.column {
        case .needsYou: .orange
        case .working: .blue
        case .idleOrDone: .gray
        case .notRunning: .gray.opacity(0.4)
        }
    }

    private var stateText: String {
        switch card.state {
        case .needsYou: "Needs you"
        case .working: "Working"
        case .active: card.attached ? "Attached" : "Running"
        case .idle: "Idle"
        case .notAttached: "Not attached"
        case .stopped: "Stopped"
        }
    }
}

struct StopRequest {
    let ask: (AgentBoard.Card) -> Void
}

private struct StopRequestKey: FocusedValueKey { typealias Value = StopRequest }

extension FocusedValues {
    var stopRequest: StopRequest? {
        get { self[StopRequestKey.self] }
        set { self[StopRequestKey.self] = newValue }
    }
}

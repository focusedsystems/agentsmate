import SwiftUI
import AgentsMateStatus

/// The Ask field and, under it, what came back: a search field with a
/// spinner and Cancel while it runs, then one row per lane with Open.
struct AskBar: View {
    @ObservedObject var ask: AskModel
    @ObservedObject var model: BoardModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            field
            if ask.hasPanel {
                Divider()
                AskPanel(ask: ask, model: model)
            }
        }
        .onChange(of: ask.wantsFocus, initial: true) { _, wants in
            guard wants else { return }
            focused = true
            ask.wantsFocus = false
        }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle.magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("Ask about your lanes…", text: $ask.question)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { ask.submit() }
                .onKeyPress(.escape) {
                    if ask.hasPanel { ask.cancelOrDismiss() } else { focused = false }
                    return .handled
                }
                .accessibilityLabel("Ask about your lanes")
                .help("Ask where you worked on something, such as “which lane was I fixing the login bug in?” (⌘K)")
            if ask.isSearching {
                ProgressView().controlSize(.small)
                Button("Cancel") { ask.cancelOrDismiss() }
                    .keyboardShortcut(.cancelAction)
                    .help("Stop the search")
            } else if !ask.question.isEmpty {
                Button("Ask") { ask.submit() }
                    .help("Search every Mac's lanes and transcripts for the answer")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(focused ? 0.6 : 0.3)))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

private struct AskPanel: View {
    @ObservedObject var ask: AskModel
    @ObservedObject var model: BoardModel

    var body: some View {
        Group {
            switch ask.state {
            case .idle:
                EmptyView()
            case .searching:
                note("Searching every Mac’s lanes and transcripts…", symbol: nil)
            case .noMatch(let skipped):
                note("No lane matches that question." + skippedText(skipped), symbol: "questionmark.circle")
            case .missingCommand(let name):
                note("Ask needs a command named \(name), which was not found on your PATH or in ~/.local/bin. "
                     + "Install it and ask again.", symbol: "exclamationmark.triangle")
            case .failed(let message):
                note(message, symbol: "exclamationmark.triangle")
            case .answers(let response):
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(response.answers.enumerated()), id: \.element.id) { index, answer in
                            AnswerRow(answer: answer, model: model, isTop: index == 0)
                            if index < response.answers.count - 1 { Divider() }
                        }
                        if !response.hostsSkipped.isEmpty {
                            Text(skippedText(response.hostsSkipped).trimmingCharacters(in: .whitespaces))
                                .font(.caption).foregroundStyle(.secondary).padding(8)
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func skippedText(_ hosts: [String]) -> String {
        hosts.isEmpty ? "" : " Not reachable: " + hosts.joined(separator: ", ") + "."
    }

    private func note(_ text: String, symbol: String?) -> some View {
        HStack(spacing: 8) {
            if let symbol { Image(systemName: symbol).foregroundStyle(.secondary).accessibilityHidden(true) }
            Text(text).foregroundStyle(.secondary)
            Spacer()
            Button("Dismiss") { ask.cancelOrDismiss() }.disabled(ask.isSearching)
        }
        .padding(12)
        .accessibilityElement(children: .combine)
    }
}

private struct AnswerRow: View {
    let answer: LaneAsk.Answer
    @ObservedObject var model: BoardModel
    let isTop: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(answer.title ?? "Untitled session").font(.headline).lineLimit(1)
                    if let app = answer.app, answer.laneID != nil {
                        Text("· " + AppInfo.name(app)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    Label(answer.host, systemImage: model.isLocal(answer.host) ? "desktopcomputer" : "server.rack")
                        .labelStyle(.titleAndIcon)
                    if let folder = answer.folder { Text("· " + abbreviated(folder)).lineLimit(1).truncationMode(.head) }
                    if let at = answer.lastActive {
                        Text("· " + at.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                    }
                    Text("· " + answer.agent)
                }
                .font(.caption).foregroundStyle(.secondary)
                if !answer.why.isEmpty { Text(answer.why).font(.callout).lineLimit(3) }
                if !answer.workItems.isEmpty {
                    Text(answer.workItems.joined(separator: "  ")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button("Open") { model.open(answer) }
                .keyboardShortcut(isTop ? KeyEquivalent.return : KeyEquivalent("\u{0}"), modifiers: isTop ? .command : [])
                .disabled(!model.canOpen(answer))
                .help(helpText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if model.canOpen(answer) { model.open(answer) } }
        .contextMenu {
            Button("Open") { model.open(answer) }.disabled(!model.canOpen(answer))
            Button("Resume in Terminal") { model.openInTerminal(answer) }
                .disabled(LaneAsk.resumeCommand(for: answer, isLocal: model.isLocal(answer.host)) == nil)
            Divider()
            if let id = answer.sessionID {
                Button("Copy Session ID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(id, forType: .string)
                }
            }
            if let folder = answer.folder {
                Button("Copy Folder Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(folder, forType: .string)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Open") { model.open(answer) }
    }

    private var helpText: String {
        let base = "Select this lane in its app, or resume the conversation if no app lists it"
        return isTop ? base + " (⌘↩)" : base
    }

    private func abbreviated(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
}

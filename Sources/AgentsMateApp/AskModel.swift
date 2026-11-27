import AppKit
import AgentsMate
import AgentsMateStatus

/// The Ask field's state: the question, the one search in flight, and its
/// answers. The search is `LaneAsk.run`, so cancelling ends it.
@MainActor
final class AskModel: ObservableObject {
    enum State: Equatable {
        case idle
        case searching
        case answers(LaneAsk.Response)
        case noMatch(skipped: [String])
        case missingCommand(String)
        case failed(String)
    }

    @Published var question = ""
    @Published private(set) var state: State = .idle
    /// Set by the menu command; the field takes focus and clears it.
    @Published var wantsFocus = false

    private var task: Task<Void, Never>?

    /// The command's name: a setting, then the environment, then the default.
    private var command: String {
        let set = UserDefaults.standard.string(forKey: "askCommand")
            ?? ProcessInfo.processInfo.environment["AGENTSMATE_ASK_COMMAND"]
        return set.flatMap { LaneAsk.isValidCommandName($0) ? $0 : nil } ?? LaneAsk.defaultCommand
    }

    var isSearching: Bool { state == .searching }

    var hasPanel: Bool { state != .idle }

    func focus() { wantsFocus = true }

    func submit() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        task?.cancel()
        state = .searching
        let command = command
        task = Task {
            let outcome = await LaneAsk.run(question: text, command: command)
            guard !Task.isCancelled else { return }
            switch outcome {
            case .answers(let response): state = .answers(response)
            case .noMatch(let response): state = .noMatch(skipped: response.hostsSkipped)
            case .missingCommand(let name): state = .missingCommand(name)
            case .failed(let message): state = .failed(message)
            case .cancelled: state = .idle
            }
        }
    }

    /// End the search in flight, or close the answers.
    func cancelOrDismiss() {
        task?.cancel()
        task = nil
        state = .idle
    }
}

extension BoardModel {
    /// Open an answer the way the board opens a card: select its lane when an
    /// app on this Mac lists it (starting the app if it is closed, and letting
    /// the app reattach or resume the lane), and otherwise resume the
    /// conversation in Terminal on the Mac it belongs to.
    func open(_ answer: LaneAsk.Answer) {
        if let card = LaneAsk.card(for: answer, in: cards) {
            open(card)
            return
        }
        if let app = answer.app, answer.laneID != nil,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) {
            let conversation = answer.sessionID.flatMap { LaneAsk.isValidSessionID($0) ? $0 : nil }
            LaneRequest(action: .show, app: app, laneID: answer.laneID, conversationID: conversation,
                        host: answer.host).send()
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return
        }
        openInTerminal(answer)
    }

    func canOpen(_ answer: LaneAsk.Answer) -> Bool {
        if LaneAsk.card(for: answer, in: cards) != nil { return true }
        if let app = answer.app, answer.laneID != nil,
           NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) != nil { return true }
        return LaneAsk.resumeCommand(for: answer, isLocal: isLocal(answer.host)) != nil
    }

    func openInTerminal(_ answer: LaneAsk.Answer) {
        guard let line = LaneAsk.resumeCommand(for: answer, isLocal: isLocal(answer.host)) else { NSSound.beep(); return }
        runInTerminal(line, title: answer.title ?? "Session")
    }
}

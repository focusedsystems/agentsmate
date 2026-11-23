import SwiftUI

/// A New Sessions section for an app's Agent settings: which agent a new
/// session starts on here, Claude or Codex, in a persistent session or run
/// directly, and whether it moves to the other agent when the chosen one is
/// near its usage limit. Saved per Mac under the app's ``AgentsModeKeys``.
/// Shows nothing when the app runs neither agent. Sessions already open
/// keep their agent. ``AgentsLaunchSettingsSection`` brings it with it.
public struct AgentNewSessionsSettingsSection: View {
    @ObservedObject var store: AgentLaneStore

    public init(store: AgentLaneStore) { self.store = store }

    private static let thresholds: [Double] = [50, 60, 70, 75, 80, 85, 90, 95, 100]

    private var agent: Binding<String> {
        Binding(get: { store.newSessionAgent?.rawValue ?? "" },
                set: { store.newSessionAgent = LaneReopenChoice.Kind(rawValue: $0) })
    }

    /// The app's default, by the agent it runs when that is Claude or Codex.
    private var appDefaultTitle: String {
        let id = store.configuredNewLaneBackendID
        let name = store.agentKind(ofBackend: id)?.title ?? store.backend(id: id)?.displayName ?? "Shell"
        return "App Default (\(name))"
    }

    private var footer: String {
        var text = "Applies to new sessions on this Mac; sessions already open keep their agent."
        if store.configuration.agentAllowedForFolder != nil {
            text += " This app allows each agent only in some folders; elsewhere a new session starts on the app’s default."
        }
        if !store.canSwitchAgents {
            return text
        } else if store.usage == nil {
            text += " This app reads no usage figures, so new sessions always start on the chosen agent."
        } else {
            text += " Near the limit, a new session starts on the other agent in the same mode, unless it is as full. Unknown usage keeps the chosen agent."
        }
        return text
    }

    public var body: some View {
        let kinds = store.availableAgentKinds
        if !kinds.isEmpty {
            Section {
                Picker("Agent", selection: agent) {
                    Text(appDefaultTitle).tag("")
                    Divider()
                    ForEach(kinds, id: \.self) { kind in
                        Text(kind.title).tag(kind.rawValue)
                    }
                }
                .help("What a new session runs: Claude or Codex, in a session that outlives the window (remote) or run in the folder (direct).")
                if store.canSwitchAgents { switchControls }
                if let reason = store.newSessionPlan().reason {
                    LabeledContent("Now", value: reason)
                }
            } header: {
                Text("New Sessions")
            } footer: {
                Text(footer).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var switchControls: some View {
                Toggle("Switch agents near the usage limit", isOn: Binding(get: { store.switchesAgentNearLimit },
                                                                         set: { store.switchesAgentNearLimit = $0 }))
                    .disabled(store.usage == nil)
                    .help("Start a new session on the other agent when the chosen one has used the threshold of any limit.")
                Picker("Switch at", selection: Binding(get: { store.agentSwitchThreshold },
                                                       set: { store.agentSwitchThreshold = $0 })) {
                    ForEach(Self.thresholds, id: \.self) { value in
                        Text("\(Int(value))% used").tag(value)
                    }
                    if !Self.thresholds.contains(store.agentSwitchThreshold) {
                        Text("\(Int(store.agentSwitchThreshold))% used").tag(store.agentSwitchThreshold)
                    }
                }
                .disabled(store.usage == nil || !store.switchesAgentNearLimit)
    }
}

/// The first items of a New Session menu: the agent a new session starts on
/// now, headed by why when usage moved it ("Claude at 93%, using Codex").
/// `start` runs it: it asks for the folder, and the agent is settled for
/// that folder. Nothing when no agent is in play.
struct NewSessionDefaultItems: View {
    @ObservedObject var store: AgentLaneStore
    let start: () -> Void

    var body: some View {
        let plan = store.newSessionPlan()
        if let kind = plan.kind {
            Section {
                Button("Default Agent: \(kind.title)…") { start() }
            } header: {
                if let reason = plan.reason { Text(reason) }
            }
            Divider()
        }
    }
}

import SwiftUI

/// A Launch section for an app's Agent settings: whether the app opens in
/// Agents mode, saved under ``AgentsModeKeys/agentsModeAtLaunch`` and read by
/// ``AgentsLaunch``. On unless the person turns it off. Put it first in a
/// grouped `Form`; ``AgentLaneSettingsSection`` already leads with it.
public struct AgentsLaunchSettingsSection: View {
    let store: AgentLaneStore

    public init(store: AgentLaneStore) { self.store = store }

    public var body: some View {
        Section {
            AgentsLaunchToggle(store: store)
        } header: {
            Text("Launch")
        }
    }
}

/// The Open in Agents mode at launch toggle on its own, for an app whose
/// Agent settings are not a grouped `Form`.
public struct AgentsLaunchToggle: View {
    @AppStorage private var isOn: Bool

    public init(store: AgentLaneStore) {
        _isOn = AppStorage(wrappedValue: true, store.keys.agentsModeAtLaunch)
    }

    public var body: some View {
        Toggle("Open in Agents mode at launch", isOn: $isOn)
            .help("Open the window with the Agents view filling it. A change applies at the next launch.")
    }
}

/// A Settings section for the lanes the person opens: what a new lane runs
/// (an installed backend or a command of their own), whether one opens at
/// launch, whether the lanes open at quit come back, whether renaming a lane
/// renames its agent's session too, and, when the app turned summaries on,
/// whether each lane gets a one-line summary. It brings the Launch and
/// Sidebar sections with it. Put it in a grouped `Form`.
public struct AgentLaneSettingsSection: View {
    @ObservedObject var store: AgentLaneStore
    let title: String
    @AppStorage private var backendID: String
    @AppStorage private var customCommand: String
    @AppStorage private var openAtLaunch: Bool
    @AppStorage private var reopenLast: Bool

    public init(store: AgentLaneStore, title: String = "New Lanes") {
        self.store = store
        self.title = title
        let keys = store.keys
        _backendID = AppStorage(wrappedValue: "", keys.newLaneBackend)
        _customCommand = AppStorage(wrappedValue: "", keys.newLaneCommand)
        _openAtLaunch = AppStorage(wrappedValue: false, keys.openAtLaunch)
        _reopenLast = AppStorage(wrappedValue: true, keys.reopenLast)
    }

    private var footer: String {
        var text = "Lanes start in a login shell, so your PATH and tools are there. Reopened lanes resume their last conversation when you first show them."
        if store.agentRenameAvailable {
            text += " Renaming a lane types the agent’s rename command only when its input line is empty and it isn’t working."
        }
        if store.summariesAvailable {
            text += " Summaries are written by each lane's own agent, a short call on your account when a new prompt arrives."
        }
        return text
    }

    public var body: some View {
        AgentsLaunchSettingsSection(store: store)
        AgentSidebarSettingsSection(store: store)
        Section {
            Picker("Runs", selection: $backendID) {
                ForEach(store.installedBackends, id: \.id) { backend in
                    Text(backend.displayName).tag(backend.id)
                }
                Divider()
                Text("Custom Command").tag(AgentLaneStore.customBackendID)
            }
            if backendID == AgentLaneStore.customBackendID {
                TextField("Command", text: $customCommand, prompt: Text("claude --model opus"))
                    .font(.body.monospaced())
            }
            Toggle("Open a lane at launch", isOn: $openAtLaunch)
            Toggle("Reopen the lanes open at quit", isOn: $reopenLast)
                .disabled(store.configuration.workspaceFile == nil)
            if store.agentRenameAvailable {
                Toggle("Rename the agent’s session too", isOn: Binding(get: { store.renamesAgentSession },
                                                                       set: { store.renamesAgentSession = $0 }))
            }
            if store.summariesAvailable {
                Toggle("Summarize sessions", isOn: Binding(get: { store.summariesEnabled },
                                                          set: { store.summariesEnabled = $0 }))
            }
        } header: {
            Text(title)
        } footer: {
            Text(footer).foregroundStyle(.secondary)
        }
        .onAppear {
            if backendID.isEmpty { backendID = store.newLaneBackendID }
        }
    }
}

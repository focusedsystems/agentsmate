import SwiftUI

/// A Settings section for the lanes the person opens: what a new lane runs
/// (an installed backend or a command of their own), whether one opens at
/// launch, and whether the lanes open at quit come back. Put it in a
/// grouped `Form`.
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

    public var body: some View {
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
        } header: {
            Text(title)
        } footer: {
            Text("Lanes start in a login shell, so your PATH and tools are there. Reopened lanes resume their last conversation when you first show them.")
                .foregroundStyle(.secondary)
        }
        .onAppear {
            if backendID.isEmpty { backendID = store.newLaneBackendID }
        }
    }
}

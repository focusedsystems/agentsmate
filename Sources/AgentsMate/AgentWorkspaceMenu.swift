import SwiftUI
import AppKit

/// The workspaces menu, for an app's View menu and the lane list: save the
/// lanes the person opened under a name, open or delete a saved set, pick one
/// to open at launch, and edit the file by hand. Re-reads the file each time
/// it is shown, so hand edits appear without a restart.
public struct AgentWorkspaceMenu: View {
    @ObservedObject var store: AgentLaneStore
    let requestSave: () -> Void

    /// `requestSave` asks the person for a name, then calls
    /// ``AgentLaneStore/saveWorkspace(named:)``.
    public init(store: AgentLaneStore, requestSave: @escaping () -> Void) {
        self.store = store
        self.requestSave = requestSave
    }

    public var body: some View {
        Button("Save Lanes as Workspace…", action: requestSave)
            .disabled(!store.lanes.contains(where: \.isClosable))
        Menu("Open Workspace") {
            ForEach(store.workspaces.workspaces) { workspace in
                Button(workspace.name) { store.open(workspace: workspace) }
            }
            if store.workspaces.workspaces.isEmpty { Text("No Saved Workspaces") }
        }
        Menu("Delete Workspace") {
            ForEach(store.workspaces.workspaces) { workspace in
                Button(workspace.name) { store.deleteWorkspace(named: workspace.name) }
            }
        }
        .disabled(store.workspaces.workspaces.isEmpty)
        Picker("Open at Launch", selection: Binding(get: { store.workspaces.openAtLaunch ?? "" },
                                                    set: { store.setOpenAtLaunch($0.isEmpty ? nil : $0) })) {
            Text("None").tag("")
            ForEach(store.workspaces.workspaces) { Text($0.name).tag($0.name) }
        }
        Divider()
        Button("Edit Workspaces File") {
            guard let url = store.configuration.workspaceFile else { return }
            if !FileManager.default.fileExists(atPath: url.path) { try? LaneWorkspaceFile().save(url) }
            NSWorkspace.shared.open(url)
        }
        .disabled(store.configuration.workspaceFile == nil)
        Button("Show Workspaces File in Finder") {
            if let url = store.configuration.workspaceFile { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        .disabled(store.configuration.workspaceFile.map { !FileManager.default.fileExists(atPath: $0.path) } ?? true)
        if let error = store.workspaceError { Text(error) }
    }
}

import DevMateCore
import DevMateUI
import SwiftUI

/// One of the DevMate views over every app's repos, with a GitHub or Azure
/// DevOps switch in its own header row when both have repos.
public struct DevelopmentTabView: View {
    @ObservedObject var hub: DevelopmentHub
    let tab: AgentsTab
    @AppStorage("developmentHost") private var hostRaw = DevelopmentHost.github.rawValue

    public init(hub: DevelopmentHub, tab: AgentsTab) {
        self.hub = hub
        self.tab = tab
    }

    private var host: DevelopmentHost {
        let saved = DevelopmentHost(rawValue: hostRaw) ?? .github
        return hub.hosts.contains(saved) ? saved : (hub.hosts.first ?? .github)
    }

    public var body: some View {
        VStack(spacing: 0) {
            if hub.hosts.count > 1, tab != .repos {
                HStack {
                    Picker("Host", selection: Binding(get: { host }, set: { hostRaw = $0.rawValue })) {
                        ForEach(hub.hosts) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Which host's repositories to list")
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                Divider()
            }
            content
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                hub.reloadUnion()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            hub.reloadUnion()
        }
        .onAppear(perform: note)
        .onChange(of: tab) { _, _ in note() }
        .onChange(of: hostRaw) { _, _ in note() }
    }

    private func note() {
        hub.currentTab = tab
        hub.currentHost = host
    }

    @ViewBuilder
    private var content: some View {
        if tab == .projects {
            if let model = hub.projects[host] {
                ProjectsView(model: model).id(host)
            } else {
                empty
            }
        } else if let model = hub.model(for: host), let segment = tab.segment {
            DevelopmentView(model: model, showsNavigation: false)
                .id(host)
                .onAppear { model.segment = segment }
                .onChange(of: tab) { _, _ in model.segment = segment }
        } else {
            empty
        }
    }

    private var empty: some View {
        ContentUnavailableView("No Repositories", systemImage: "tray",
                               description: Text("No app lists a repository on this host yet."))
    }
}

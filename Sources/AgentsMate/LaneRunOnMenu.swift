import SwiftUI

/// Run On ▸ for one lane: the hub and every lane host in the hosts registry,
/// the one the lane runs on checked. Picking another restarts the lane's
/// terminal there. Shown only when the registry lists somewhere to run it,
/// and disabled with no lane; the lane menu and the Agent menu both use it.
public struct LaneRunOnMenu: View {
    @ObservedObject var store: AgentLaneStore
    let id: AgentLane.ID?
    let reveal: () -> Void

    public init(store: AgentLaneStore, id: AgentLane.ID?, reveal: @escaping () -> Void = {}) {
        self.store = store
        self.id = id
        self.reveal = reveal
    }

    public var body: some View {
        if store.agentHosts != nil {
            let hosts = id.map { store.runOnHosts(for: $0) } ?? []
            Picker("Run On", selection: Binding(
                get: { id.flatMap { store.host(of: $0) } ?? "" },
                set: { name in
                    guard let id else { return }
                    reveal()
                    store.setHost(id, to: name)
                })) {
                ForEach(hosts) { host in
                    Text(host.role == .hub ? "\(host.name) (Hub)" : host.name).tag(host.name)
                }
            }
            .pickerStyle(.menu)
            .disabled(hosts.count < 2)
            .help("Choose the Mac this lane's session runs on")
        }
    }
}

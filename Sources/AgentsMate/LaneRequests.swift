import AppKit
import AgentsMateStatus

/// Carries out ``LaneRequest``s another process (a dashboard) sends this
/// app: show a lane, or close it. Only those two, and only for a lane this
/// app has; stopping a session is never done on request.
extension AgentLaneStore {
    func startLaneRequests() {
        guard let bundle = Bundle.main.bundleIdentifier, Bundle.main.bundleURL.pathExtension == "app" else { return }
        laneRequestObserver = DistributedNotificationCenter.default().addObserver(
            forName: LaneRequest.notificationName, object: bundle, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.takeLaneRequest(bundleID: bundle) }
        }
        // A request made while the app was closed: once its lanes have loaded.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.takeLaneRequest(bundleID: bundle)
        }
    }

    private func takeLaneRequest(bundleID: String) {
        guard let request = LaneRequest.take(bundleID: bundleID) else { return }
        carryOut(request, attempt: 0)
    }

    /// Lanes and detached sessions fill in after launch, so a lane not
    /// found yet is looked for again for a few seconds.
    func carryOut(_ request: LaneRequest, attempt: Int) {
        guard let id = laneID(for: request) else {
            guard attempt < 15 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.carryOut(request, attempt: attempt + 1)
            }
            return
        }
        switch request.action {
        case .show: showFromNotification(id)
        case .close: close(id)
        }
    }

    /// The row a request names: its lane id when this app has that row, else
    /// the one row holding the same session (short id, conversation, or tmux
    /// name on the same host). Nil when none does, or several do.
    func laneID(for request: LaneRequest) -> AgentLane.ID? {
        if let id = request.laneID, sessions[id] != nil { return id }
        let found = sessions.values.filter { session in
            let lane = session.lane
            if let short = request.sessionID, !short.isEmpty,
               lane.agentSessionID == short || session.record?.agentID == short { return true }
            if let conversation = request.conversationID?.lowercased(), !conversation.isEmpty,
               lane.agentConversationID?.lowercased() == conversation
                || session.record?.sessionID?.lowercased() == conversation { return true }
            if let name = request.sessionName, !name.isEmpty, session.backend.sessionName(for: lane) == name,
               Self.sameHost(lane.host, request.host) { return true }
            return false
        }
        return found.count == 1 ? found[0].id : nil
    }

    private static func sameHost(_ a: String?, _ b: String?) -> Bool {
        let local = AgentHosts.thisMacNames.union(AgentHosts.load().map { [$0.selfName] } ?? []).map { $0.lowercased() }
        func norm(_ h: String?) -> String {
            guard let h, !h.isEmpty, !local.contains(h.lowercased()) else { return "" }
            return h.lowercased()
        }
        return norm(a) == norm(b)
    }
}

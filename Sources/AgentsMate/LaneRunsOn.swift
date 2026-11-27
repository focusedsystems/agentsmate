import SwiftUI

/// Which Mac a lane's agent runs on, when that is worth saying. A lane on
/// another Mac names it; a lane on this Mac names this Mac unless this Mac is
/// the hub, where lanes are meant to run and the sidebar stays clean. When
/// the lane's registry host is somewhere else than it runs, the marker also
/// says where it was meant to run.
public struct LaneRunsOn: Equatable, Sendable {
    public enum Kind: String, Sendable { case thisMac = "this_mac", remote }

    public var kind: Kind
    /// The host the agent runs on, without any `user@` prefix.
    public var hostName: String
    /// The registry host the lane belongs on, only when it is not where it runs.
    public var meantFor: String?

    public init(kind: Kind, hostName: String, meantFor: String? = nil) {
        self.kind = kind
        self.hostName = hostName
        self.meantFor = meantFor
    }

    /// The marker for a lane, or nil when it needs none.
    /// - Parameters:
    ///   - runsOn: the host the agent runs on, when known.
    ///   - isThisMac: whether that host is this Mac.
    ///   - thisMacName: this Mac's name, for a lane here with no host.
    ///   - isHub: whether this Mac is the registry's hub; true when there is no registry.
    ///   - meantFor: the lane's registry host, when there is a registry.
    ///   - meantIsRunHost: whether `meantFor` is the host the agent runs on.
    public static func decide(runsOn: String?, isThisMac: Bool, thisMacName: String?, isHub: Bool,
                              meantFor: String?, meantIsRunHost: Bool) -> LaneRunsOn? {
        let meant = meantIsRunHost ? nil : meantFor.map(bare).flatMap { $0.isEmpty ? nil : $0 }
        if isThisMac {
            guard !isHub else { return nil }
            let name = [runsOn, thisMacName].lazy.compactMap { $0.map(bare) }.first { !$0.isEmpty } ?? "This Mac"
            return LaneRunsOn(kind: .thisMac, hostName: name, meantFor: meant)
        }
        guard let host = runsOn.map(bare), !host.isEmpty else { return nil }
        return LaneRunsOn(kind: .remote, hostName: host, meantFor: meant)
    }

    /// A host name without a leading `user@`.
    static func bare(_ host: String) -> String {
        host.split(separator: "@").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// What the row and header say: "This Mac" for a lane here, the host's name otherwise.
    public var label: String { kind == .thisMac ? "This Mac" : hostName }

    var symbol: String { kind == .thisMac ? "laptopcomputer" : "network" }

    /// The tooltip and the spoken label.
    public var help: String {
        var text = kind == .thisMac ? "Runs on this Mac (\(hostName))" : "Runs on \(hostName)"
        if let meantFor { text += ". Meant to run on \(meantFor)" }
        return text
    }
}

/// The marker as a row's or header's small label: a network glyph and the
/// host for another Mac, a quiet capsule for this Mac. Primary text on a
/// light fill keeps its contrast whether or not the row is selected.
struct LaneRunsOnChip: View {
    let marker: LaneRunsOn

    var body: some View {
        Label {
            Text(marker.label).lineLimit(1).truncationMode(.tail)
        } icon: {
            Image(systemName: marker.symbol)
        }
        .labelStyle(.titleAndIcon)
        .font(.caption)
        .foregroundStyle(marker.kind == .thisMac ? Color.primary : Color.secondary)
        .padding(.horizontal, marker.kind == .thisMac ? 6 : 0)
        .padding(.vertical, marker.kind == .thisMac ? 1 : 0)
        .background {
            if marker.kind == .thisMac { Capsule().fill(Color.primary.opacity(0.12)) }
        }
        .fixedSize()
        .help(marker.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(marker.help)
    }
}

extension AgentLaneStore {
    /// The marker for a lane's row and terminal header.
    func laneRunsOn(for lane: AgentLane) -> LaneRunsOn? {
        let badges = laneBadges(for: lane)
        let registry = listingHosts ?? configuration.hostSessions?.hosts ?? agentHosts
        let meant = registry.flatMap { lane.host ?? $0.hub?.name }
        let meantIsRunHost: Bool = {
            guard let meant else { return true }
            return badges.hostKind == .local
                ? isThisMac(LaneRunsOn.bare(meant))
                : badges.hostName.map { LaneRunsOn.bare($0).lowercased() == LaneRunsOn.bare(meant).lowercased() } ?? true
        }()
        return LaneRunsOn.decide(runsOn: badges.hostName, isThisMac: badges.hostKind == .local, thisMacName: liveSelfName,
                                 isHub: registry?.isHub ?? true, meantFor: meant, meantIsRunHost: meantIsRunHost)
    }
}

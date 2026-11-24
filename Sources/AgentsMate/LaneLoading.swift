import SwiftUI

/// What a lane is waiting on while the window fills in. Each case is a step
/// the store is really on; nil means the lane's state is known.
public enum LaneLoadStage: Equatable, Sendable {
    /// Its host has been asked what it runs and has not answered.
    case checkingHost(String)
    /// The first look for running sessions has not come back.
    case findingSession
    /// Launch is attaching the session this lane holds.
    case attaching
    /// Its host did not answer, so whether its session runs is unknown.
    case unreachable(String)

    public var title: String {
        switch self {
        case .checkingHost(let host): "Checking \(host)…"
        case .findingSession: "Looking for session…"
        case .attaching: "Attaching…"
        case .unreachable(let host): "\(host) unreachable"
        }
    }

    /// Still in progress; an unreachable host has finished, with a failure.
    public var isInProgress: Bool {
        if case .unreachable = self { return false }
        return true
    }

    public var unreachableHost: String? {
        if case .unreachable(let host) = self { return host }
        return nil
    }
}

/// How many of the lanes have finished loading.
public struct LaneLoadProgress: Equatable, Sendable {
    public var finished: Int
    public var total: Int
    public var isLoading: Bool { finished < total }

    public init(finished: Int, total: Int) {
        self.finished = finished
        self.total = total
    }

    public init(stages: some Sequence<LaneLoadStage?>) {
        var finished = 0, total = 0
        for stage in stages {
            total += 1
            if stage?.isInProgress != true { finished += 1 }
        }
        self.init(finished: finished, total: total)
    }

    public var title: String { "\(finished) of \(total) loaded" }

    /// A count for a header while lanes are still loading: a dash until
    /// anything is known, then the count so far, marked as partial.
    public func display(_ count: Int) -> String {
        guard isLoading else { return "\(count)" }
        return count == 0 ? "–" : "\(count)+"
    }

    public func accessibleCount(_ count: Int) -> String {
        guard isLoading else { return "\(count)" }
        return count == 0 ? "not known yet" : "at least \(count)"
    }
}

extension AgentLaneStore {
    /// Every lane's stage, worked out once for a whole list.
    public var laneLoadStages: [AgentLane.ID: LaneLoadStage] {
        var stages: [AgentLane.ID: LaneLoadStage] = [:]
        let asked = listingHosts.map { Set(HostSessions.askedHosts($0).map(\.name)) } ?? []
        let finding = configuration.findsDetachedSessions && !firstSweepFinished
        for lane in lanes {
            guard let session = sessions[lane.id], !session.isAttached else { continue }
            if launchAttachPending == lane.id {
                stages[lane.id] = .attaching
                continue
            }
            if configuration.hostSessions != nil, let host = sessionHost(for: lane), asked.contains(host),
               hostListings[host] == nil {
                stages[lane.id] = unknownHosts.contains(host) ? .unreachable(host) : .checkingHost(host)
            } else if finding {
                stages[lane.id] = .findingSession
            }
        }
        return stages
    }

    /// How far the lanes have got, from ``laneLoadStages``.
    public func laneLoadProgress(_ stages: [AgentLane.ID: LaneLoadStage]) -> LaneLoadProgress {
        LaneLoadProgress(stages: lanes.map { stages[$0.id] })
    }
}

/// A row's mark while it loads: a small spinner, or a still mark with Reduce
/// Motion on, and a warning once its host has failed to answer.
struct LaneLoadIndicator: View {
    let stage: LaneLoadStage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if !stage.isInProgress {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else if reduceMotion {
                Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.mini)
            }
        }
        .font(.caption)
        .accessibilityHidden(true)
    }
}

/// All Agents while the window fills in: every lane at once, grouped as the
/// sidebar groups them, each row on its own stage.
struct AgentHomeLoadingList: View {
    @ObservedObject var store: AgentLaneStore
    let stages: [AgentLane.ID: LaneLoadStage]
    let open: (AgentLane.ID) -> Void

    var body: some View {
        let snapshot = store.listSnapshot
        let flat = !store.configuration.showsSectionHeadings || snapshot.regularGroupCount <= 1
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(snapshot.groups) { group in
                    if !flat, let title = group.title {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .padding(.top, 10)
                            .padding(.bottom, 2)
                            .accessibilityAddTraits(.isHeader)
                    }
                    ForEach(group.lanes) { lane in
                        if let session = store.sessions[lane.id] {
                            AgentHomeLoadingRow(session: session, stage: stages[lane.id],
                                                retry: { stages[lane.id]?.unreachableHost.map(store.retryHost) },
                                                open: { open(lane.id) })
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sessions loading")
    }
}

struct AgentHomeLoadingRow: View {
    @ObservedObject var session: AgentLaneSession
    let stage: LaneLoadStage?
    let retry: () -> Void
    let open: () -> Void

    private var stageTitle: String { stage?.title ?? session.status.title }

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let stage {
                    LaneLoadIndicator(stage: stage)
                } else {
                    AgentHomeStatusDot(session: session)
                }
            }
            .frame(width: 16)
            Button(action: open) {
                HStack(spacing: 8) {
                    Text(session.title).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(stageTitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(session.title)
            .accessibilityValue(stageTitle)
            .accessibilityHint("Opens the session")
            if stage?.unreachableHost != nil {
                Button("Retry", action: retry)
                    .controlSize(.small)
                    .accessibilityLabel("Retry \(session.title)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

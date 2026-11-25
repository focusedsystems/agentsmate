import SwiftUI
import AgentsMateStatus

/// Reads each usage source every minute, at background priority so the
/// read runs on the efficiency cores, on a timer the system may coalesce
/// and that slows while the app is out of use.
@MainActor
public final class AgentUsageModel: ObservableObject {
    @Published public private(set) var usages: [AgentUsage] = []
    public let sources: [any AgentUsageSource]
    private var timer: CadenceTimer?

    public init(sources: [any AgentUsageSource]) {
        self.sources = sources
    }

    public func start() {
        guard timer == nil else { return }
        refresh()
        timer = CadenceTimer(interval: 60) { [weak self] in self?.refresh() }
    }

    private var refreshing = false

    /// Read every source once, skipped while the last read is still going.
    /// A window whose reset has passed is dropped whichever source gave it,
    /// so a figure for a period that is over is never shown.
    public func refresh() {
        guard !refreshing else { return }
        refreshing = true
        let sources = sources
        // A source may run a helper and wait for it, so the reads go on a
        // background queue rather than Swift's concurrency pool.
        DispatchQueue.global(qos: .background).async {
            let now = Date()
            // A source that reads nothing still gets its agent's row, as
            // unknown, so both meters show whichever agent the app runs.
            let read = sources.compactMap { source -> AgentUsage? in
                if let usage = source.read() { return usage.current(at: now) }
                return source.unknownAgent.map {
                    AgentUsage(agent: $0, windows: [], note: AgentUsage.unknownNote, readAt: now)
                }
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshing = false
                if self.usages != read { self.usages = read }
            }
        }
    }
}

/// Usage in the `KEY=VALUE` form ``KeyValueUsageFileSource`` reads, from
/// the output of a command, such as `ssh` to the Mac whose status line
/// writes the file when this one runs no agent of its own. The app supplies
/// the command; nothing here knows any host.
///
/// The command runs at most once per ``interval``, at background QoS
/// through the shared helper slots, with a timeout. A run that fails or
/// gives nothing doubles the wait, up to ``maxInterval``; the next good one
/// resets it. Between runs the last text is read again, so a reset that
/// passes still takes its window away.
public final class KeyValueUsageCommandSource: AgentUsageSource, @unchecked Sendable {
    public let agent: String
    public var unknownAgent: String? { agent }
    public let command: [String]
    public let interval: TimeInterval
    public let maxInterval: TimeInterval
    public let timeout: TimeInterval
    public let maxAge: TimeInterval?
    let runner: @Sendable ([String], TimeInterval) -> String
    let clock: @Sendable () -> Date

    private let lock = NSLock()
    private var text: String?
    private var nextRun = Date.distantPast
    private var wait: TimeInterval

    /// `command` is `argv`: an absolute executable, then its arguments.
    public convenience init(agent: String, command: [String], interval: TimeInterval = 300,
                            maxInterval: TimeInterval = 3600, timeout: TimeInterval = 15,
                            maxAge: TimeInterval? = KeyValueUsageFileSource.defaultMaxAge) {
        self.init(agent: agent, command: command, interval: interval, maxInterval: maxInterval, timeout: timeout,
                  maxAge: maxAge, runner: { argv, timeout in
                      LaneRowMetadataReader.run(argv[0], Array(argv.dropFirst()), timeout: timeout)
                  }, clock: { Date() })
    }

    init(agent: String, command: [String], interval: TimeInterval, maxInterval: TimeInterval, timeout: TimeInterval,
         maxAge: TimeInterval?, runner: @escaping @Sendable ([String], TimeInterval) -> String,
         clock: @escaping @Sendable () -> Date) {
        self.agent = agent
        self.command = command
        self.interval = interval
        self.maxInterval = max(maxInterval, interval)
        self.timeout = timeout
        self.maxAge = maxAge
        self.runner = runner
        self.clock = clock
        self.wait = interval
    }

    /// Blocks while the command runs; call it off the main thread.
    public func read() -> AgentUsage? {
        guard let executable = command.first, executable.hasPrefix("/") else { return nil }
        let now = clock()
        lock.lock()
        let due = now >= nextRun
        if due { nextRun = now.addingTimeInterval(wait) }
        lock.unlock()
        if due {
            let output = runner(command, timeout)
            let good = KeyValueUsageFileSource.usage(from: output, agent: agent, now: now, maxAge: nil) != nil
            lock.lock()
            if good {
                text = output
                wait = interval
            } else {
                wait = min(wait * 2, maxInterval)
            }
            nextRun = now.addingTimeInterval(good ? interval : wait)
            lock.unlock()
        }
        lock.lock()
        let last = text
        lock.unlock()
        return last.flatMap { KeyValueUsageFileSource.usage(from: $0, agent: agent, now: now, maxAge: maxAge) }
    }
}

/// A compact meter for a sidebar's foot: one bar per agent, showing its
/// fullest window, with every window and its reset time in the tooltip. An
/// agent that has run out shows a full grey bar.
public struct AgentUsageMeter: View {
    @ObservedObject var model: AgentUsageModel

    public init(model: AgentUsageModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.usages, id: \.agent) { usage in
                if usage.isDepleted {
                    // Spent: the same row, with a full grey bar and when it
                    // comes back, if the agent says.
                    row(usage, percent: 100, tint: .gray, reset: usage.depletedUntil, unknownReset: true)
                } else if let window = usage.fullest {
                    row(usage, percent: min(window.percent, 100),
                        tint: window.percent >= 90 ? .red : window.percent >= 70 ? .orange : .accentColor,
                        reset: window.resetsAt)
                } else if let note = usage.note {
                    Text("\(usage.agent): \(note)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { model.start() }
    }

    /// One agent: its name, a bar, and the reset time on the right. No
    /// percentage beside the bar: the bar says it, and the width goes to the
    /// bar. The figure is in the tooltip.
    /// `unknownReset` shows a dash where the time would be, for a spent
    /// agent that gave no reset.
    private func row(_ usage: AgentUsage, percent: Double, tint: Color, reset: Date?,
                     unknownReset: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(usage.agent).font(.caption).frame(width: 44, alignment: .leading)
            ProgressView(value: percent, total: 100)
                .tint(tint)
            if let reset {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(Self.shortReset(reset, now: context.date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            } else if unknownReset {
                Text("—")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .help(Self.describe(usage))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(usage.agent) usage")
        .accessibilityValue(Self.describe(usage))
    }

    /// The bar's own reset label: the time alone when it is today ("14:00"),
    /// the weekday too when it is later ("Tue 14:00").
    static func shortReset(_ reset: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        calendar.isDate(reset, inSameDayAs: now)
            ? reset.formatted(.dateTime.hour().minute())
            : reset.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    /// "Resets Tue 14:00 · in 2 days, 5 hours".
    static func resetLine(_ reset: Date, now: Date = Date()) -> String {
        let when = reset.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        return "Resets \(when) · in \(delta(from: now, to: reset))"
    }

    /// "2 days, 5 hours", "3 hours, 20 minutes", "under a minute".
    static func delta(from now: Date, to reset: Date) -> String {
        let seconds = reset.timeIntervalSince(now)
        guard seconds >= 60 else { return "under a minute" }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 2
        formatter.allowedUnits = [.day, .hour, .minute]
        return formatter.string(from: seconds) ?? ""
    }

    static func describe(_ usage: AgentUsage) -> String {
        var lines = usage.windows.map { w -> String in
            let reset = w.resetsAt.map { " · resets " + $0.formatted(date: .abbreviated, time: .shortened)
                + " (in " + delta(from: Date(), to: $0) + ")" } ?? ""
            return "\(w.label): \(Int(w.percent.rounded()))%\(reset)"
        }
        if let note = usage.note { lines.append(note) }
        if usage.isDepleted {
            lines.append(usage.depletedUntil.map { resetLine($0) } ?? "No reset time reported")
        }
        return lines.joined(separator: "\n")
    }
}

/// The foot of the Agents sidebar: a divider over the Claude and Codex
/// meters. The lane list insets it at its bottom edge, so every app built on
/// AgentsMate carries the same one.
public struct AgentUsageFooter: View {
    @ObservedObject var model: AgentUsageModel
    var barBackground: Bool

    /// `barBackground` backs the footer with the bar material, for a dock
    /// whose list sits on its own panel.
    public init(model: AgentUsageModel, barBackground: Bool = false) {
        self.model = model
        self.barBackground = barBackground
    }

    public var body: some View {
        VStack(spacing: 0) {
            Divider()
            AgentUsageMeter(model: model)
                .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .background(barBackground ? AnyShapeStyle(.bar) : AnyShapeStyle(.clear))
    }
}

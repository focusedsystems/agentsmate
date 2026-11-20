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

    public func refresh() {
        let sources = sources
        Task.detached(priority: .background) {
            let read = sources.compactMap { $0.read() }
            await MainActor.run { [weak self] in if self?.usages != read { self?.usages = read } }
        }
    }
}

/// A compact meter for a sidebar's foot: one bar per agent, showing its
/// fullest window, with every window and its reset time in the tooltip.
public struct AgentUsageMeter: View {
    @ObservedObject var model: AgentUsageModel

    public init(model: AgentUsageModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.usages, id: \.agent) { usage in
                if let window = usage.fullest {
                    VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(usage.agent).font(.caption).frame(width: 44, alignment: .leading)
                        ProgressView(value: min(window.percent, 100), total: 100)
                            .tint(window.percent >= 90 ? .red : window.percent >= 70 ? .orange : .accentColor)
                        // No percentage beside the bar: the bar says it, and the
                        // width goes to the bar. The figure is in the tooltip.
                        if let reset = window.resetsAt {
                            TimelineView(.periodic(from: .now, by: 60)) { context in
                                Text(Self.shortReset(reset, now: context.date))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                        }
                    }
                    // Spent: say when it comes back, and how long that is.
                    if window.percent >= 100, let reset = window.resetsAt {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            Text(Self.resetLine(reset, now: context.date))
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    }
                    .help(Self.describe(usage))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(usage.agent) usage")
                    .accessibilityValue(Self.describe(usage))
                } else if let note = usage.note {
                    Text("\(usage.agent): \(note)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { model.start() }
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
        return lines.joined(separator: "\n")
    }
}

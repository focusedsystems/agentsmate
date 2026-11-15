import SwiftUI
import AgentsMateStatus

/// Reads each usage source every minute, off the main thread.
@MainActor
public final class AgentUsageModel: ObservableObject {
    @Published public private(set) var usages: [AgentUsage] = []
    public let sources: [any AgentUsageSource]
    private var timer: Timer?

    public init(sources: [any AgentUsageSource]) {
        self.sources = sources
    }

    public func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    public func refresh() {
        let sources = sources
        Task.detached(priority: .utility) {
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
                    HStack(spacing: 6) {
                        Text(usage.agent).font(.caption).frame(width: 44, alignment: .leading)
                        ProgressView(value: min(window.percent, 100), total: 100)
                            .tint(window.percent >= 90 ? .red : window.percent >= 70 ? .orange : .accentColor)
                        Text("\(Int(window.percent.rounded()))%").font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
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

    static func describe(_ usage: AgentUsage) -> String {
        var lines = usage.windows.map { w -> String in
            let reset = w.resetsAt.map { " · resets " + $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
            return "\(w.label): \(Int(w.percent.rounded()))%\(reset)"
        }
        if let note = usage.note { lines.append(note) }
        return lines.joined(separator: "\n")
    }
}

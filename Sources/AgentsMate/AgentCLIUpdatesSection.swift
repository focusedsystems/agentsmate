import AgentsMateUpdates
import AppKit
import SwiftUI

/// A Settings section showing each agent CLI's version and update state. Place it inside a `Form`.
public struct AgentCLIUpdatesSection: View {
    @ObservedObject private var model: AgentCLIUpdateModel

    public init(model: AgentCLIUpdateModel) {
        self.model = model
    }

    public var body: some View {
        Section("Agent CLIs") {
            Toggle("Keep agent CLIs current", isOn: $model.keepCurrent)
            ForEach(model.clis) { cli in
                row(for: cli)
            }
            HStack {
                Button("Update Now") { Task { await model.updateNow() } }
                    .disabled(model.isRunning)
                if model.isRunning { ProgressView().controlSize(.small) }
                Spacer()
                Menu("Copy Install Command") {
                    ForEach(model.clis) { cli in
                        Button(cli.displayName) { copy(model.copyableCommand(for: cli)) }
                    }
                }
                .fixedSize()
            }
        }
    }

    private func row(for cli: AgentCLI) -> some View {
        let status = model.status(for: cli)
        return LabeledContent(cli.displayName) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(status?.installed == true ? (status?.version ?? "Version unknown") : "Not installed")
                if status?.installed == true {
                    Text(status?.method.displayName ?? "")
                        .foregroundStyle(.secondary)
                }
                Text(status?.message ?? "Not checked yet")
                    .foregroundStyle(.secondary)
                if let checked = status?.lastChecked {
                    Text("Checked \(checked.formatted(date: .abbreviated, time: .shortened))")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .multilineTextAlignment(.trailing)
            .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

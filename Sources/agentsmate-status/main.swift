import Foundation
import AgentsMateStatus

// agentsmate-status — writes lane status records for apps using AgentsMate.
//
//   agentsmate-status claude
//       A Claude Code hook. Reads the hook's JSON on stdin.
//   agentsmate-status codex [--then <program> [args…]] <payload-json>
//       A Codex `notify` program. Codex appends the JSON payload as the last
//       argument; `--then` runs another notify program with the same payload,
//       because Codex takes only one.
//   agentsmate-status list
//       Print every record as JSON.
//
// A hook must never block or fail its agent, so every error is swallowed
// and the exit status is always 0.

let args = Array(CommandLine.arguments.dropFirst())
let directory = LaneStatusDirectory.default()

/// The tmux session this agent runs in, if any: the lane's name.
func tmuxLane() -> String? {
    let env = ProcessInfo.processInfo.environment
    if let key = env["CODEX_LANE_KEY"], !key.isEmpty { return key }
    guard let tmux = env["TMUX"], !tmux.isEmpty else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    var arguments = ["tmux", "display-message", "-p"]
    if let pane = env["TMUX_PANE"], !pane.isEmpty { arguments += ["-t", pane] }
    arguments.append("#S")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let name = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? nil : name
}

switch args.first {
case "claude":
    let input = FileHandle.standardInput.readDataToEndOfFile()
    if let status = StatusEvents.claude(hookInput: input, lane: tmuxLane()) {
        try? directory.write(status)
    }

case "codex":
    var rest = Array(args.dropFirst())
    guard let payload = rest.popLast() else { break }
    if let status = StatusEvents.codex(notifyPayload: Data(payload.utf8), lane: tmuxLane()) {
        try? directory.write(status)
    }
    if rest.first == "--then", rest.count > 1 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = Array(rest.dropFirst()) + [payload]
        try? process.run()
    }

case "list":
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    if let data = try? encoder.encode(directory.readAll()) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

default:
    FileHandle.standardError.write(Data("usage: agentsmate-status claude | codex [--then <program> …] <json> | list\n".utf8))
}
exit(0)

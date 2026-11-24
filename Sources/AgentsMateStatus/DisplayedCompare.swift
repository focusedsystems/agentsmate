import Foundation

/// A shown list set against what the live snapshot says is running.
public struct DisplayedComparison: Equatable, Sendable {
    /// Snapshot sessions that are not done and match no row or card.
    public var notShown: [LiveSessionSnapshot.Session]
    /// Rows or cards that say a session is running which the snapshot does not list.
    public var shownButNotLive: [DisplayedExport.Row]
    /// Whether `notShown` was limited to a scope. Without one it is every
    /// snapshot session with no matching row, whichever app it belongs to.
    public var scopeEvaluated: Bool

    public var isClean: Bool { notShown.isEmpty && shownButNotLive.isEmpty }

    /// Whether a row is the snapshot's session: the app lane id the watcher
    /// recorded, the short id, or the tmux name, and on the same host when
    /// both name one. A folder never matches.
    public static func matches(_ row: DisplayedExport.Row, _ session: LiveSessionSnapshot.Session) -> Bool {
        if let lane = session.lane, lane == row.laneID { return true }
        if let host = row.host, let other = session.host, host != other { return false }
        if let id = row.sessionID ?? row.attachedSessionID, id == session.agentID || id == session.sessionID { return true }
        if let attached = row.attachedSessionID, attached == session.agentID || attached == session.sessionID { return true }
        if let name = row.sessionName, session.kind == "tmux", session.name == name { return true }
        return false
    }

    /// `scopeFolders` nil means the scope cannot be evaluated here (an app's
    /// scope is code, not data), so every unmatched session is listed.
    public static func compare(_ export: DisplayedExport, snapshot: LiveSessionSnapshot,
                               scopeFolders: [String]? = nil) -> DisplayedComparison {
        let shown = export.rows + export.allAgents
        let sessions = snapshot.allSessions
        var scopeRoots: [[String]]?
        if let scopeFolders, !scopeFolders.isEmpty {
            scopeRoots = scopeFolders.map { URL(fileURLWithPath: LaneStatusMatch.normalizedPath($0)).pathComponents }
        }
        let notShown = sessions.filter { session in
            guard session.state != .done else { return false }
            if let scopeRoots {
                guard let folder = session.folder else { return false }
                let parts = URL(fileURLWithPath: LaneStatusMatch.normalizedPath(folder)).pathComponents
                guard scopeRoots.contains(where: { parts.count >= $0.count && Array(parts.prefix($0.count)) == $0 }) else { return false }
            }
            return !shown.contains { matches($0, session) }
        }
        var seen = Set<String>()
        let notLive = shown.filter { row in
            row.state.claimsRunning && !sessions.contains { matches(row, $0) }
        }.filter { seen.insert($0.laneID).inserted }
        return DisplayedComparison(notShown: notShown, shownButNotLive: notLive, scopeEvaluated: scopeRoots != nil)
    }
}

/// `agentsmate-status displayed`: read an app's `displayed.json`, and
/// optionally set it against a live snapshot.
public enum DisplayedCommand {
    /// Exit status: 0 clean, 1 differences found, 2 could not be read.
    public static func run(_ args: [String], environment: [String: String] = ProcessInfo.processInfo.environment,
                           out: (String) -> Void, err: (String) -> Void) -> Int32 {
        var app: String?, file: String?, compare: String?, json = false
        var scope: [String] = []
        var rest = args
        while !rest.isEmpty {
            let flag = rest.removeFirst()
            func value() -> String? { rest.isEmpty ? nil : rest.removeFirst() }
            switch flag {
            case "--app": app = value()
            case "--file": file = value()
            case "--compare": compare = value()
            case "--scope": if let v = value() { scope.append(v) }
            case "--json": json = true
            default:
                err("agentsmate-status displayed: unknown option \(flag)\n")
                return 2
            }
        }
        let url: URL
        if let file {
            url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
        } else if let app {
            url = DisplayedExport.standardURL(bundleID: app, environment: environment)
        } else {
            let root = DisplayedExport.agentsMateStateDirectory(environment: environment)
            let found = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted().filter {
                FileManager.default.fileExists(atPath: root.appendingPathComponent($0).appendingPathComponent("displayed.json").path)
            }
            guard found.count == 1 else {
                err(found.isEmpty ? "agentsmate-status displayed: no displayed.json under \(root.path)\n"
                    : "agentsmate-status displayed: several apps have one; pass --app <bundle id>: \(found.joined(separator: ", "))\n")
                return 2
            }
            url = DisplayedExport.standardURL(bundleID: found[0], environment: environment)
        }
        guard let export = DisplayedExport.load(url) else {
            err("agentsmate-status displayed: cannot read \(url.path)\n")
            return 2
        }
        var comparison: DisplayedComparison?
        if let compare {
            guard let snapshot = LiveSessionSnapshot.load(URL(fileURLWithPath: (compare as NSString).expandingTildeInPath)) else {
                err("agentsmate-status displayed: cannot read the live snapshot \(compare) (missing, older than 30 minutes, another schema, or not private)\n")
                return 2
            }
            comparison = DisplayedComparison.compare(export, snapshot: snapshot, scopeFolders: scope.isEmpty ? nil : scope)
        }
        out(json ? jsonText(export, comparison) : text(export, comparison))
        return comparison?.isClean == false ? 1 : 0
    }

    static func jsonText(_ export: DisplayedExport, _ comparison: DisplayedComparison?) -> String {
        guard let comparison else { return ((try? export.encoded()).map { String(decoding: $0, as: UTF8.self) } ?? "{}") + "\n" }
        let encoder = DisplayedExport.encoder
        var object: [String: Any] = [:]
        if let data = try? encoder.encode(export), let value = try? JSONSerialization.jsonObject(with: data) { object["displayed"] = value }
        let sessions = comparison.notShown.map { s -> [String: Any] in
            ["id": s.id, "kind": s.kind ?? NSNull(), "name": s.name, "host": s.host ?? NSNull(),
             "folder": s.folder ?? NSNull(), "state": s.state.rawValue]
        }
        let rows = comparison.shownButNotLive.compactMap { row -> Any? in
            (try? encoder.encode(row)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        }
        object["compare"] = ["scope_evaluated": comparison.scopeEvaluated, "not_shown": sessions, "shown_but_not_live": rows] as [String: Any]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    static func line(_ row: DisplayedExport.Row) -> String {
        var parts = [row.section.map { "[\($0)] " } ?? "", row.title, "  ", row.state.rawValue, "  ", row.backend]
        if let id = row.sessionID ?? row.sessionName { parts.append(" " + id) }
        if let attached = row.attachedSessionID, attached != row.sessionID { parts.append(" (running \(attached))") }
        if let host = row.host { parts.append(" @" + host) }
        if let folder = row.folder { parts.append("  " + folder) }
        if row.selected { parts.append("  selected") }
        return parts.joined()
    }

    static func text(_ export: DisplayedExport, _ comparison: DisplayedComparison?) -> String {
        var lines: [String] = []
        let app = export.app
        lines.append("\(app.bundleID) \(app.version ?? "?") (\(app.build ?? "?"))\(app.agentsMateCommit.map { " agentsmate " + $0 } ?? "")")
        let f = export.filter
        lines.append("filter: show \(f.show)\(f.statuses.isEmpty ? "" : ", " + f.statuses.joined(separator: "+"))"
                     + (f.search.map { ", search \"\($0)\"" } ?? "") + (f.sidebarSearch.map { ", sidebar search \"\($0)\"" } ?? ""))
        lines.append("counts: \(export.counts.needsYou) need you, \(export.counts.working) working, \(export.counts.idleOrDone) idle or done")
        lines.append("rows (\(export.rows.count)):")
        lines += export.rows.map { "  " + line($0) }
        lines.append("all agents (\(export.allAgents.count)):")
        lines += export.allAgents.map { "  " + line($0) + ($0.column.map { "  <\($0)>" } ?? "") }
        if let comparison {
            lines.append(comparison.scopeEvaluated ? "not shown, in scope (\(comparison.notShown.count)):"
                         : "in the snapshot with no matching row, scope not evaluated (\(comparison.notShown.count)):")
            lines += comparison.notShown.map {
                "  \($0.id)  \($0.state.rawValue)  \($0.name)" + ($0.host.map { " @" + $0 } ?? "") + ($0.folder.map { "  " + $0 } ?? "")
            }
            lines.append("shown as running, not in the snapshot (\(comparison.shownButNotLive.count)):")
            lines += comparison.shownButNotLive.map { "  " + line($0) }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

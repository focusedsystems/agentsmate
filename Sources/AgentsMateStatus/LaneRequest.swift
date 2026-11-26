import Foundation

/// A request from another process, such as a dashboard, that an app show
/// one of its lanes or close it (hide it and end its terminal; the session
/// keeps running).
///
/// The request is written to `<state home>/agentsmate/<bundle id>/request.json`
/// (private, mode 600) and announced with a distributed notification named
/// ``notificationName`` whose object is the bundle id. The app reads the
/// file when told, and once at launch, so a request made while it was
/// closed is still carried out. A request older than ``maximumAge`` is
/// ignored.
///
/// Anything running as the person can post such a notification, so the
/// actions are deliberately harmless: showing a lane and closing its
/// terminal. Nothing here stops a session or types into one.
public struct LaneRequest: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable {
        /// Bring the app forward with this lane selected.
        case show
        /// Close the lane's terminal and row; the session keeps running.
        case close
    }

    public static let notificationName = Notification.Name("agentsmate.lane-request")
    public static let maximumAge: TimeInterval = 120

    public var action: Action
    /// The bundle id of the app the request is for.
    public var app: String
    /// The row's lane id in that app.
    public var laneID: String?
    /// A background session's short id.
    public var sessionID: String?
    /// The conversation id.
    public var conversationID: String?
    /// The tmux session name.
    public var sessionName: String?
    /// The Mac the session runs on.
    public var host: String?
    public var at: Date

    public init(action: Action, app: String, laneID: String? = nil, sessionID: String? = nil,
                conversationID: String? = nil, sessionName: String? = nil, host: String? = nil, at: Date = Date()) {
        self.action = action
        self.app = app
        self.laneID = laneID
        self.sessionID = sessionID
        self.conversationID = conversationID
        self.sessionName = sessionName
        self.host = host
        self.at = at
    }

    enum CodingKeys: String, CodingKey {
        case action, app, laneID = "lane_id", sessionID = "session_id", conversationID = "conversation_id",
             sessionName = "session_name", host, at
    }

    /// `<state home>/agentsmate/<bundle id>/request.json`.
    public static func url(bundleID: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        DisplayedExport.directory(bundleID: bundleID, environment: environment)
            .appendingPathComponent("request.json", isDirectory: false)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Write the request for its app and announce it.
    @discardableResult
    public func send(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let data = try? Self.encoder.encode(self) else { return false }
        do { try DisplayedExport.write(data, to: Self.url(bundleID: app, environment: environment)) } catch { return false }
        DistributedNotificationCenter.default().postNotificationName(
            Self.notificationName, object: app, userInfo: nil, deliverImmediately: true)
        return true
    }

    /// The pending request for `bundleID`, taken (the file is removed), or
    /// nil when there is none, it is for another app, or it is too old.
    public static func take(bundleID: String, now: Date = Date(),
                            environment: [String: String] = ProcessInfo.processInfo.environment) -> LaneRequest? {
        let url = url(bundleID: bundleID, environment: environment)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.size] as? Int ?? 0) <= 64 * 1024,
              let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        guard let request = try? decoder.decode(LaneRequest.self, from: data), request.app == bundleID,
              now.timeIntervalSince(request.at) <= maximumAge, request.at.timeIntervalSince(now) <= 60 else { return nil }
        return request
    }
}

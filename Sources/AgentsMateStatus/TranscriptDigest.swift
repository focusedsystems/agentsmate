import Foundation

/// The end of a Claude Code conversation file: the person's last few prompts
/// and the assistant's last reply, for a one-line summary of the lane.
public struct TranscriptDigest: Equatable, Sendable {
    public var prompts: [String]
    public var lastReply: String?

    public static func read(path: String, prompts limit: Int = 3, bytes: Int = 512 * 1024) -> TranscriptDigest? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        return parse(String(decoding: data, as: UTF8.self), prompts: limit)
    }

    static func parse(_ text: String, prompts limit: Int = 3) -> TranscriptDigest? {
        var prompts: [String] = []
        var reply: String?
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String,
                  let message = object["message"] as? [String: Any] else { continue }
            let content = message["content"]
            switch type {
            case "user":
                // Tool results also arrive as user messages; only typed text counts.
                if let text = content as? String { prompts.append(text) }
                else if let blocks = content as? [[String: Any]], !blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
                    let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: " ")
                    if !text.isEmpty { prompts.append(text) }
                }
            case "assistant":
                if let blocks = content as? [[String: Any]] {
                    let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: " ")
                    if !text.isEmpty { reply = text }
                }
            default: break
            }
        }
        let tidy = { (s: String) in String(s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces).prefix(600)) }
        let recent = prompts.filter { !$0.hasPrefix("<") }.suffix(limit).map(tidy)
        guard !recent.isEmpty || reply != nil else { return nil }
        return TranscriptDigest(prompts: Array(recent), lastReply: reply.map(tidy))
    }
}

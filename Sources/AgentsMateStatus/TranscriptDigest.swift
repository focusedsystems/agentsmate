import Foundation

/// The end of an agent's conversation file: the person's last few prompts
/// and the assistant's last reply, for a one-line summary of the lane.
/// A snapshot of ``LaneTranscript``.
public struct TranscriptDigest: Equatable, Sendable {
    public var prompts: [String]
    public var lastReply: String?

    public init(prompts: [String], lastReply: String?) {
        self.prompts = prompts
        self.lastReply = lastReply
    }

    public static func read(path: String, prompts limit: Int = 3, bytes: Int = 512 * 1024) -> TranscriptDigest? {
        guard let transcript = LaneTranscript.tail(path: path, bytes: UInt64(max(bytes, 0))) else { return nil }
        return TranscriptDigest(transcript, prompts: limit)
    }

    /// The digest of a transcript already read, or nil when it holds neither
    /// a prompt nor a reply.
    public init?(_ transcript: LaneTranscript, prompts limit: Int = 3) {
        let tidy = { (s: String) in String(s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces).prefix(600)) }
        let recent = transcript.prompts.suffix(limit).map(tidy)
        guard !recent.isEmpty || transcript.lastReply != nil else { return nil }
        self.init(prompts: Array(recent), lastReply: transcript.lastReply.map(tidy))
    }

    static func parse(_ text: String, prompts limit: Int = 3) -> TranscriptDigest? {
        var transcript = LaneTranscript(path: "", window: nil)
        transcript.consume(Data((text + "\n").utf8))
        return TranscriptDigest(transcript, prompts: limit)
    }
}

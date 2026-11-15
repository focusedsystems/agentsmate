import XCTest
@testable import AgentsMateChat

final class ClaudeStreamParserTests: XCTestCase {
    func testParsesTheStreamShapes() {
        XCTAssertEqual(ClaudeStreamParser.parse(line: #"{"type":"system","subtype":"init","session_id":"s","cwd":"/w"}"#),
                       [.sessionStarted(sessionID: "s", cwd: "/w")])
        XCTAssertEqual(ClaudeStreamParser.parse(line: #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"hi"}}}"#),
                       [.textDelta("hi")])
        XCTAssertEqual(ClaudeStreamParser.parse(line: #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}"#),
                       [.toolUse(name: "Bash", summary: "ls")])
        XCTAssertEqual(ClaudeStreamParser.parse(line: #"{"type":"result","subtype":"success","is_error":false}"#),
                       [.turnComplete(isError: false)])
        XCTAssertEqual(ClaudeStreamParser.parse(line: "garbage"), [])
    }
}

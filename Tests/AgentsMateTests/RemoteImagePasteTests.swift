import XCTest
import AppKit
@testable import AgentsMate

@MainActor
final class RemoteImagePasteTests: XCTestCase {
    func testAnImageToARemoteLaneIsUploaded() {
        XCTAssertEqual(RemoteImagePaste.decide(host: "hub", content: .image), .upload)
    }

    func testLocalLanesAndOtherContentPassThrough() {
        XCTAssertEqual(RemoteImagePaste.decide(host: nil, content: .image), .passthrough)
        XCTAssertEqual(RemoteImagePaste.decide(host: "hub", content: .text("hi")), .passthrough)
        XCTAssertEqual(RemoteImagePaste.decide(host: "hub", content: .files(["/tmp/a"])), .passthrough)
        XCTAssertEqual(RemoteImagePaste.decide(host: "hub", content: .none), .passthrough)
    }

    func testAnUnsafeHostPassesThrough() {
        XCTAssertEqual(RemoteImagePaste.decide(host: "-oProxyCommand=x", content: .image), .passthrough)
        XCTAssertEqual(RemoteImagePaste.decide(host: "a b", content: .image), .passthrough)
    }

    func testTheUploadCommandIsBatchModeWithAShortTimeout() throws {
        let name = UUID().uuidString.lowercased() + ".png"
        let command = try XCTUnwrap(RemoteImagePaste.uploadCommand(host: "hub", fileName: name))
        XCTAssertEqual(command.executable, "/usr/bin/ssh")
        XCTAssertEqual(Array(command.arguments.prefix(4)), ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5"])
        XCTAssertTrue(command.arguments.contains("--"))
        let separator = try XCTUnwrap(command.arguments.firstIndex(of: "--"))
        XCTAssertEqual(command.arguments[separator + 1], "hub")
        let script = command.arguments[separator + 2]
        XCTAssertTrue(script.contains("umask 077"))
        XCTAssertTrue(script.contains("chmod 700 \"$d\""))
        XCTAssertTrue(script.contains("Library/Caches/agentsmate-paste"))
        XCTAssertTrue(script.contains("-mtime +1 -delete"))
        XCTAssertTrue(script.contains("cat > \"$d/\(name)\""))
    }

    func testTheUploadCommandRefusesWhatCannotBePassedSafely() {
        let name = UUID().uuidString + ".png"
        XCTAssertNil(RemoteImagePaste.uploadCommand(host: "-bad", fileName: name))
        XCTAssertNil(RemoteImagePaste.uploadCommand(host: "hub", fileName: "x; rm -rf ~.png"))
        XCTAssertNil(RemoteImagePaste.uploadCommand(host: "hub", fileName: "../a.png"))
    }

    func testOnlyTheFileJustWrittenIsAccepted() {
        let name = "0b5f3f0e-1111-2222-3333-444455556666.png"
        XCTAssertEqual(RemoteImagePaste.remotePath(fromOutput: "/Users/me/Library/Caches/agentsmate-paste/\(name)\n", fileName: name),
                       "/Users/me/Library/Caches/agentsmate-paste/\(name)")
        XCTAssertNil(RemoteImagePaste.remotePath(fromOutput: "relative/\(name)", fileName: name))
        XCTAssertNil(RemoteImagePaste.remotePath(fromOutput: "/tmp/other.png", fileName: name))
        XCTAssertNil(RemoteImagePaste.remotePath(fromOutput: "", fileName: name))
    }

    private func imagePasteboard() -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("agentsmate.test." + UUID().uuidString))
        board.clearContents()
        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }
        board.writeObjects([image])
        return board
    }

    func testARemoteTerminalTypesTheQuotedRemotePathAfterAnUpload() async throws {
        let view = AgentTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.pasteboard = imagePasteboard()
        view.remoteHost = "hub"
        let uploaded = expectation(description: "uploaded")
        view.imageUploader = { data, host in
            XCTAssertEqual(host, "hub")
            XCTAssertTrue(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
            uploaded.fulfill()
            return .uploaded("/Users/me/Library/Caches/agentsmate-paste/a b.png")
        }
        XCTAssertTrue(view.pasteRemoteImageIfNeeded())
        await fulfillment(of: [uploaded], timeout: 5)
    }

    func testALocalTerminalLeavesTheImagePasteAlone() {
        let view = AgentTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.pasteboard = imagePasteboard()
        XCTAssertFalse(view.pasteRemoteImageIfNeeded())
        XCTAssertEqual(view.pasteInput(), [0x16])
    }

    func testATextPasteInARemoteTerminalIsUntouched() {
        let view = AgentTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let board = NSPasteboard(name: NSPasteboard.Name("agentsmate.test." + UUID().uuidString))
        board.clearContents(); board.setString("hello", forType: .string)
        view.pasteboard = board
        view.remoteHost = "hub"
        XCTAssertFalse(view.pasteRemoteImageIfNeeded())
    }
}

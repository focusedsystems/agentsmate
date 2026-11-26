import AppKit
import AgentsMateStatus
import os

/// Pasting a screenshot into a lane that runs on another Mac. The agent
/// there reads that Mac's clipboard, not this one, so ⌘V and Ctrl+V find no
/// image. Instead the image is saved as a PNG, sent to a private folder on
/// that Mac over ssh, and its path is typed in, which the agent attaches as
/// an image.
enum RemoteImagePaste {
    enum Decision: Equatable {
        case upload
        case passthrough
    }

    enum Outcome: Equatable {
        case uploaded(String)
        case failed(String)
    }

    /// A paste goes to the other Mac only when the lane is on one with a
    /// host ssh can be handed, and the pasteboard holds an image alone:
    /// copied files and text keep their usual paste.
    static func decide(host: String?, content: PasteContent) -> Decision {
        guard let host, AgentSessionStop.isValidHost(host), content == .image else { return .passthrough }
        return .upload
    }

    /// The folder on the other Mac, under its user's caches, and how long a
    /// pasted image is kept there.
    static let remoteFolder = "Library/Caches/agentsmate-paste"
    static let keepDays = 1
    static let connectTimeout = 5
    static let uploadTimeout: TimeInterval = 30

    /// The ssh command that writes standard input to `fileName` in the
    /// private folder, prunes old files, and prints the file's full path.
    /// Nil when the host or file name cannot be passed safely.
    static func uploadCommand(host: String, fileName: String, ssh: String = "/usr/bin/ssh") -> (executable: String, arguments: [String])? {
        guard AgentSessionStop.isValidHost(host), isSafeFileName(fileName) else { return nil }
        let script = [
            "umask 077",
            "d=\"$HOME/\(remoteFolder)\"",
            "mkdir -p \"$d\" && chmod 700 \"$d\"",
            "find \"$d\" -type f -name '*.png' -mtime +\(keepDays) -delete 2>/dev/null",
            "cat > \"$d/\(fileName)\" && printf '%s\\n' \"$d/\(fileName)\"",
        ].joined(separator: "; ")
        return (ssh, ["-o", "BatchMode=yes", "-o", "ConnectTimeout=\(connectTimeout)", "-T", "--", host, script])
    }

    /// A UUID and `.png`, so nothing in the name needs quoting.
    static func isSafeFileName(_ name: String) -> Bool {
        guard name.hasSuffix(".png"), UUID(uuidString: String(name.dropLast(4))) != nil else { return false }
        return true
    }

    /// The path the other Mac printed, when it is the file just written.
    static func remotePath(fromOutput output: String, fileName: String) -> String? {
        let line = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("/"), line.hasSuffix("/" + fileName), !line.contains("\n"),
              !line.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return line
    }

    /// The image on the pasteboard as the data it holds: PNG as it is, or
    /// TIFF, which ``pngData(_:)`` converts.
    static func imageData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        if let tiff = pasteboard.data(forType: .tiff) { return tiff }
        return (NSImage(pasteboard: pasteboard))?.tiffRepresentation
    }

    /// PNG bytes for `data`, converting off the main thread.
    static func pngData(_ data: Data) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return data }
            return NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
        }.value
    }

    /// Sends `png` to `host`. Runs ssh off the main thread and gives up after
    /// ``uploadTimeout``; never throws.
    static func upload(png: Data, host: String) async -> Outcome {
        let fileName = UUID().uuidString.lowercased() + ".png"
        guard let command = uploadCommand(host: host, fileName: fileName) else { return .failed("the host cannot be used") }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runUpload(command, png: png, fileName: fileName))
            }
        }
    }

    private final class Captured: @unchecked Sendable { var data = Data() }

    private static func runUpload(_ command: (executable: String, arguments: [String]), png: Data, fileName: String) -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return .failed("ssh did not start: \(error.localizedDescription)") }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + uploadTimeout, execute: killer)
        // Read while writing, so a reply can never fill the pipe.
        let printed = Captured()
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global().async {
            printed.data = output.fileHandleForReading.readDataToEndOfFile()
            reader.leave()
        }
        try? input.fileHandleForWriting.write(contentsOf: png)
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        killer.cancel()
        reader.wait()
        guard process.terminationStatus == 0 else { return .failed("ssh ended with status \(process.terminationStatus)") }
        guard let path = remotePath(fromOutput: String(decoding: printed.data, as: UTF8.self), fileName: fileName) else {
            return .failed("the other Mac did not report the saved file")
        }
        return .uploaded(path)
    }

    private static let logger = Logger(subsystem: "systems.focused.agentsmate", category: "remote-image-paste")
    static func log(_ message: String) { logger.error("\(message, privacy: .public)") }
}

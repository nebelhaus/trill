import Foundation

/// Sends messages by driving Messages.app over Apple Events (osascript).
/// This never touches chat.db — Messages.app does its own persistence.
/// Requires the Automation permission, which macOS prompts for on first send.
struct MessagesSender: Sendable {
    struct SendFailure: Error {
        let message: String
    }

    /// `chatGUID` is chat.db's `chat.guid` (e.g. "iMessage;-;+15551234567"),
    /// which Messages.app accepts as `chat id`. Falls back to addressing the
    /// participant directly for 1:1 chats where the chat id lookup fails.
    func send(text: String, chatGUID: String, directHandle: String?) throws {
        let byChatID = """
        on run argv
            set chatGuid to item 1 of argv
            set messageText to item 2 of argv
            tell application "Messages"
                send messageText to chat id chatGuid
            end tell
        end run
        """
        do {
            try run(script: byChatID, arguments: [chatGUID, text])
            return
        } catch let firstError as SendFailure {
            guard let directHandle else { throw firstError }
            let service = chatGUID.hasPrefix("iMessage") ? "iMessage" : "SMS"
            let byParticipant = """
            on run argv
                set handleId to item 1 of argv
                set messageText to item 2 of argv
                tell application "Messages"
                    set targetService to 1st account whose service type = \(service)
                    send messageText to participant handleId of targetService
                end tell
            end run
            """
            do {
                try run(script: byParticipant, arguments: [directHandle, text])
            } catch {
                throw firstError
            }
        }
    }

    private func run(script: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script] + arguments
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw SendFailure(message: detail?.nonEmpty ?? "osascript exited with status \(process.terminationStatus)")
        }
    }
}

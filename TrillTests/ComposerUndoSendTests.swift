import Foundation
import XCTest
@testable import Trill

/// Covers the undo-send window: a just-sent message is held for a few seconds
/// so an accidental send can be cancelled, and the `undoSend` setting turns the
/// whole thing off.
@MainActor
final class ComposerUndoSendTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrillTests-\(UUID().uuidString)", isDirectory: true)
        UserDefaults.standard.removeObject(forKey: "undoSend")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removeObject(forKey: "undoSend")
        super.tearDown()
    }

    /// Records how many times the send closure actually fired, and with what.
    private final class Recorder {
        var sends: [String] = []
    }

    private func makeModel(_ recorder: Recorder) async throws -> ComposerModel {
        let database = try AppDatabase(url: root.appendingPathComponent("app.sqlite3"))
        let snippets = SnippetStore(database: database)
        let model = ComposerModel(database: database, snippets: snippets)
        var health = ProviderHealth.fixture
        health.sending = .ready
        model.select(
            ConversationID(provider: ProviderID(rawValue: "test"), externalGUID: "c1"),
            capabilities: ProviderCapabilities([.sendText]),
            health: health
        ) { text, _ in
            recorder.sends.append(text)
            return .accepted(operationID: UUID())
        }
        // Let the (empty) draft restore settle so it doesn't clobber our text.
        try await Task.sleep(for: .milliseconds(50))
        return model
    }

    func testEnabledHoldsSendUntilFlushed() async throws {
        UserDefaults.standard.set(true, forKey: "undoSend")
        let recorder = Recorder()
        let model = try await makeModel(recorder)

        model.text = "on my way"
        await model.send()

        // Held, not dispatched: the message is still in the box and counting down.
        XCTAssertEqual(recorder.sends, [])
        XCTAssertNotNil(model.undoSecondsRemaining)
        XCTAssertEqual(model.text, "on my way")

        // Flushing dispatches it now and clears the composer.
        await model.flushPendingSend()
        XCTAssertEqual(recorder.sends, ["on my way"])
        XCTAssertNil(model.undoSecondsRemaining)
        XCTAssertEqual(model.text, "")
    }

    func testUndoCancelsSendAndKeepsText() async throws {
        UserDefaults.standard.set(true, forKey: "undoSend")
        let recorder = Recorder()
        let model = try await makeModel(recorder)

        model.text = "oops wrong chat"
        await model.send()
        XCTAssertNotNil(model.undoSecondsRemaining)

        model.undoPendingSend()

        // Nothing sent; the draft is handed back untouched and editable.
        XCTAssertEqual(recorder.sends, [])
        XCTAssertNil(model.undoSecondsRemaining)
        XCTAssertEqual(model.text, "oops wrong chat")
    }

    func testDisabledSendsImmediately() async throws {
        UserDefaults.standard.set(false, forKey: "undoSend")
        let recorder = Recorder()
        let model = try await makeModel(recorder)

        model.text = "ship it"
        await model.send()

        // No window: dispatched on the spot, no undo state, box cleared.
        XCTAssertEqual(recorder.sends, ["ship it"])
        XCTAssertNil(model.undoSecondsRemaining)
        XCTAssertEqual(model.text, "")
    }

    func testSwitchingConversationFlushesHeldSend() async throws {
        UserDefaults.standard.set(true, forKey: "undoSend")
        let recorder = Recorder()
        let model = try await makeModel(recorder)

        model.text = "don't lose me"
        await model.send()
        XCTAssertNotNil(model.undoSecondsRemaining)

        // Navigating away dispatches the held send in the background.
        model.select(
            ConversationID(provider: ProviderID(rawValue: "test"), externalGUID: "c2"),
            capabilities: ProviderCapabilities([.sendText]),
            health: {
                var h = ProviderHealth.fixture
                h.sending = .ready
                return h
            }()
        ) { _, _ in .accepted(operationID: UUID()) }

        XCTAssertNil(model.undoSecondsRemaining)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(recorder.sends, ["don't lose me"])
    }
}

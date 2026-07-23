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

        // Held, not dispatched: the box clears immediately and the message rides
        // in the toast, counting down.
        XCTAssertEqual(recorder.sends, [])
        XCTAssertNotNil(model.pendingSendPresentation)
        XCTAssertEqual(model.pendingSendPresentation?.preview, "on my way")
        XCTAssertEqual(model.text, "")

        // Flushing dispatches it now and drops the toast.
        await model.flushPendingSend()
        XCTAssertEqual(recorder.sends, ["on my way"])
        XCTAssertNil(model.pendingSendPresentation)
        XCTAssertEqual(model.text, "")
    }

    func testUndoCancelsSendAndKeepsText() async throws {
        UserDefaults.standard.set(true, forKey: "undoSend")
        let recorder = Recorder()
        let model = try await makeModel(recorder)

        model.text = "oops wrong chat"
        await model.send()
        XCTAssertNotNil(model.pendingSendPresentation)
        XCTAssertEqual(model.text, "")

        model.undoPendingSend()

        // Nothing sent; the message is handed back into the box, editable again.
        XCTAssertEqual(recorder.sends, [])
        XCTAssertNil(model.pendingSendPresentation)
        XCTAssertEqual(model.text, "oops wrong chat")
    }

    func testDisabledSendsImmediately() async throws {
        UserDefaults.standard.set(false, forKey: "undoSend")
        let recorder = Recorder()
        let model = try await makeModel(recorder)

        model.text = "ship it"
        await model.send()

        // No window: dispatched on the spot, no toast, box cleared.
        XCTAssertEqual(recorder.sends, ["ship it"])
        XCTAssertNil(model.pendingSendPresentation)
        XCTAssertEqual(model.text, "")
    }

    func testFlushDraftPersistsImmediatelyWithoutWaitingForDebounce() async throws {
        let recorder = Recorder()
        let database = try AppDatabase(url: root.appendingPathComponent("app.sqlite3"))
        let snippets = SnippetStore(database: database)
        let model = ComposerModel(database: database, snippets: snippets)
        let conversation = ConversationID(provider: ProviderID(rawValue: "test"), externalGUID: "c1")
        var health = ProviderHealth.fixture
        health.sending = .ready
        model.select(
            conversation,
            capabilities: ProviderCapabilities([.sendText]),
            health: health
        ) { text, _ in
            recorder.sends.append(text)
            return .accepted(operationID: UUID())
        }
        try await Task.sleep(for: .milliseconds(50))

        // Type, then flush right away — no time for the 250ms debounce to fire.
        model.text = "typed right before quitting"
        model.flushDraft()

        // The draft is already on disk, exactly as it would be after a quit.
        let stored = try await database.draft(conversationID: conversation)
        XCTAssertEqual(stored, "typed right before quitting")
    }

    func testSwitchingConversationFlushesHeldSend() async throws {
        UserDefaults.standard.set(true, forKey: "undoSend")
        let recorder = Recorder()
        let model = try await makeModel(recorder)

        model.text = "don't lose me"
        await model.send()
        XCTAssertNotNil(model.pendingSendPresentation)

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

        XCTAssertNil(model.pendingSendPresentation)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(recorder.sends, ["don't lose me"])
    }
}

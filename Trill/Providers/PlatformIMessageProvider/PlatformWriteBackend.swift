import ApplicationServices
import Foundation
import IMessage

/// Write-only backend that activates platform-imessage's `PlatformAPI` for the
/// richer, write-backed actions the read-only native path structurally can't do.
/// First (and so far only) action: **sending tapbacks**.
///
/// This never serves reads — `LiveIMessageProvider` remains the vetted read-only
/// `chat.db` baseline, and `CompositeMessagesProvider` routes only `react(_:)`
/// here. The tapback itself is Accessibility UI-automation of Messages.app, *not*
/// a `chat.db` write; the only database write in this path is `PlatformAPI`'s own
/// `IMDatabase(createIndexes: true)` index creation at construction — the
/// sanctioned vetted-library exception (see `docs/security.md`, ADR 0001).
///
/// The whole backend is dormant unless explicitly enabled: `PlatformAPI` is
/// constructed lazily on the first write, and the composite only wires this in
/// when the hidden `platformWritesEnabled` flag is set on a signed, vetted host
/// (see `InboxModel.makeProvider`). Until then nothing here ever runs.
///
/// Pinned to `@MainActor`: `PlatformAPI` is a non-`Sendable` class whose tapback
/// path drives Messages.app through Accessibility/AppKit, so it must stay on one
/// isolation domain — the main actor is its correct home, and it keeps this type
/// implicitly `Sendable` for the composite to hold.
@MainActor
final class PlatformWriteBackend {
    /// Opaque multi-account namespace tag the library weaves into `asset://` URLs
    /// of DTOs we never consume on the write path. It is not a key into the
    /// reaction operation (which targets by thread+message GUID), so any stable,
    /// non-empty value is correct for a single-host client.
    private static let accountID = "trill-imessage"

    /// The live `PlatformAPI`, wrapped so it can be awaited without tripping
    /// region-based isolation (see `PlatformAPIBox`).
    ///
    /// Held at **process scope**, not per-instance: `PlatformAPI` enforces a single
    /// instance per process, so switching providers (which replaces the backend)
    /// must reuse the one already constructed rather than try — and fail — to build
    /// a second. Main-actor-isolated (the whole type is), so access is serialized.
    /// It lives for the process lifetime, matching the library's own singleton.
    private static var shared: PlatformAPIBox?

    /// Nonisolated so the composite can default-construct a backend from any
    /// context; the process-wide `PlatformAPI` isn't built until the first `react`
    /// on the main actor.
    nonisolated init() {}

    /// Whether macOS Accessibility is authorized for this process. Tapbacks drive
    /// Messages.app via `AXUIElement`, so without it the operation can't run. This
    /// is a non-prompting public probe — it never triggers a TCC dialog.
    nonisolated func accessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Readiness of the advanced-actions surface, for `ProviderHealth.advancedActions`.
    /// Keyed to Accessibility authorization — a permission dimension distinct from
    /// the Apple Events automation `LiveIMessageProvider` uses for text send.
    func advancedActionsHealth() -> HealthState {
        guard accessibilityTrusted() else {
            return HealthState(
                availability: .limited,
                reason: .permissionMissing,
                recoverySuggestion: "Grant Trill Accessibility access in System Settings › Privacy & Security › Accessibility to send tapbacks."
            )
        }
        return HealthState(availability: .available, reason: .ready, recoverySuggestion: nil)
    }

    /// Send a tapback on `messageGUID` in `threadGUID` (both raw `chat.db` GUIDs
    /// as produced by `LiveIMessageProvider` — the library uses them directly).
    ///
    /// Send-once, never auto-retried:
    /// - not Accessibility-trusted → `.rejected(.permissionDenied)` (nothing runs);
    /// - unmappable reaction kind → `.rejected(.unsupported)`;
    /// - `addReaction` returns → `.confirmed` (it confirms the tapback landed);
    /// - `addReaction` throws after a trusted attempt → `.unknown` (the UI
    ///   automation ran; the tapback may already have applied, so it must be
    ///   reconciled rather than retried).
    func react(threadGUID: String, messageGUID: String, kind: ReactionKind, operationID: UUID) async -> ReactionOutcome {
        guard accessibilityTrusted() else {
            return .rejected(operationID: operationID, reason: .permissionDenied)
        }
        guard let reactionKey = Self.reactionKey(for: kind) else {
            return .rejected(operationID: operationID, reason: .unsupported)
        }
        do {
            let api = try activeAPI()
            try await api.addReaction(threadID: threadGUID, messageID: messageGUID, reactionKey: reactionKey)
            AppLog.provider.info("Tapback confirmed operation=\(operationID, privacy: .public)")
            return .confirmed(operationID: operationID)
        } catch {
            AppLog.provider.error("Tapback failed operation=\(operationID, privacy: .public) error=\(String(describing: type(of: error)), privacy: .public)")
            return .unknown(operationID: operationID, diagnosticCode: "reaction-automation-failed")
        }
    }

    /// Lazily construct the process-wide `PlatformAPI` on first write, reusing it
    /// across every backend instance for the process lifetime.
    private func activeAPI() throws -> PlatformAPIBox {
        if let shared = Self.shared { return shared }
        let created = try PlatformAPIBox(api: PlatformAPI(accountID: Self.accountID))
        Self.shared = created
        return created
    }

    /// Map Trill's `ReactionKind` to platform-imessage's `reactionKey` string
    /// (the keys `Reaction(platformSDKReactionKey:)` accepts). `.custom` glyphs
    /// aren't wired for send yet (they need the macOS 15 emoji-picker automation
    /// path), so they map to `nil` and reject as unsupported.
    nonisolated static func reactionKey(for kind: ReactionKind) -> String? {
        switch kind {
        case .love: "heart"
        case .like: "like"
        case .dislike: "dislike"
        case .laugh: "laugh"
        case .emphasis: "emphasize"
        case .question: "question"
        case .custom: nil
        }
    }
}

/// `@unchecked Sendable` wrapper around the non-`Sendable`, non-isolation-aware
/// `PlatformAPI`. Because the *box* is `Sendable`, awaiting these forwarding
/// methods sends a `Sendable` value across the boundary rather than the raw
/// `PlatformAPI` reference, satisfying Swift 6 region isolation. The safety
/// promise: `PlatformWriteBackend` only ever constructs and touches the box on
/// `@MainActor`, and `PlatformAPI` serializes its own Messages.app operations, so
/// no two accesses actually race.
private struct PlatformAPIBox: @unchecked Sendable {
    let api: PlatformAPI

    func addReaction(threadID: String, messageID: String, reactionKey: String) async throws {
        try await api.addReaction(threadID: threadID, messageID: messageID, reactionKey: reactionKey)
    }

    func dispose() async throws {
        try await api.dispose()
    }
}

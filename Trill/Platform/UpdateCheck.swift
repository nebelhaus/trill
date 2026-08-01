import AppKit
import Foundation
import UserNotifications

// MARK: - Update check (hourly release poll + cohort-aware nudge)
//
// Trill ships through four doors — the rice (a Nix-built, notarized bundle the
// activation script copies to /Applications), a Homebrew cask, a drag-install
// from the release ZIP, and a bare `nix run` store path — and only two of them
// own their own bytes. So the nudge's one job is to name the RIGHT next step for
// THIS install: a drag-install can swap itself, a cask defers to `brew`, and the
// two Nix cohorts must be told to update their flake instead of being handed a
// button that would be reverted by the next rebuild.
//
// Ported from pounce's `UpdateNudge` (pkgs/pounce/UpdateCheck.swift) — same
// hourly poll, same per-version dismissal, same once-a-day banner ceiling — with
// three deliberate differences, all of them because trill is a windowed app and
// pounce is a daemon behind a palette:
//
//   surface   pounce pins a palette row; trill shows a card at the bottom of the
//             sidebar, which is always visible and needs no keystroke to find.
//   banner    posted through UNUserNotificationCenter (trill already asks for
//             notification permission), not `osascript display notification` —
//             so it is attributed to Trill and honours the user's Focus. The
//             detached updater script still uses osascript: by then the app is
//             gone and there is nothing left to post from.
//   apply     pounce shells out to `update-pounce.sh`, a file shipped alongside
//             the palette's other commands. Trill has no command directory, so
//             the same work happens in the scripts below, spawned detached.
//
// Network: one unauthenticated GitHub API call per hour, carrying nothing but an
// IP and a user-agent, off by a Settings toggle. Never runs in DEBUG builds.

// MARK: - InstallKind

/// How THIS install takes an update — decides the hint, the button, and whether
/// the app is allowed to replace its own bytes.
enum InstallKind: String, Codable, Equatable, CaseIterable {
    /// Homebrew cask — `brew` owns the version, so the update runs `brew upgrade`.
    case homebrew
    /// Dragged out of the release ZIP — the app swaps itself in place.
    case direct
    /// The nebelhaus rice's activation copy — `haus update`.
    case rice
    /// A bare Nix store path (`nix run`, someone else's flake) — flake update.
    case nix
    case unknown

    /// Whether `performUpdate()` will actually install. The Nix cohorts get the
    /// command to run instead: their bundle is immutable (`/nix/store`) or
    /// restored by the next activation, so a self-swap would be undone.
    var canSelfUpdate: Bool { self == .homebrew || self == .direct }

    /// The card's subtitle: what to DO, in this install's own vocabulary.
    var actionHint: String {
        switch self {
        case .homebrew: return "Update through Homebrew and restart"
        case .direct: return "Download and restart into the new version"
        case .rice: return "Run haus update in a terminal to pick it up"
        case .nix: return "Update your trill flake input to pick it up"
        case .unknown: return "Open the release page to download it"
        }
    }

    /// The same instruction as a notification sentence.
    var bannerHint: String {
        switch self {
        case .homebrew: return "Open Trill and click Update, or run 'brew upgrade --cask trill'."
        case .direct: return "Open Trill and click Update to install it."
        case .rice: return "Run 'haus update' in a terminal to pick it up."
        case .nix: return "Update your trill flake input to pick it up."
        case .unknown: return "See github.com/nebelhaus/trill/releases to download it."
        }
    }

    /// What the card's action button says.
    var buttonLabel: String {
        switch self {
        case .homebrew, .direct: return "Update & Restart"
        case .rice, .nix: return "Copy Command"
        case .unknown: return "Open Releases"
        }
    }

    // MARK: Detection
    //
    // Path prefixes alone can't tell trill's cohorts apart, and that is the trap
    // this replaces: the rice copies the bundle to `/Applications/Trill.app`
    // (modules/trill, postActivation) and a cask's `app` stanza MOVES it to the
    // same path — so rice, cask, and drag-install are byte-identical locations.
    // Two out-of-band receipts break the tie, and both are plain file
    // existence checks needing no permission:
    //
    //   rice   /Library/Application Support/nebelhaus/trill.installed-from —
    //          written by the activation script with the store path it copied.
    //   cask   <brew prefix>/Caskroom/trill — brew's own staging directory,
    //          which survives the app being moved to /Applications.

    /// Where the rice records the store path it installed from.
    static let riceMarkerPath = "/Library/Application Support/nebelhaus/trill.installed-from"

    /// Homebrew's per-cask staging directory, on both Apple Silicon and Intel.
    static let caskReceiptPaths = [
        "/opt/homebrew/Caskroom/trill",
        "/usr/local/Caskroom/trill",
    ]

    /// Pure so the suite can exercise every cohort without a bundle or a Mac in
    /// that state. Symlinks are resolved by the caller.
    static func detect(
        bundlePath: String,
        home: String,
        hasRiceMarker: Bool,
        hasCaskReceipt: Bool
    ) -> InstallKind {
        if bundlePath.hasPrefix("/nix/store/") { return .nix }
        if bundlePath.hasPrefix(home + "/.local/state/trill") { return .rice }
        // Still honoured if a cask is ever run straight out of the Caskroom.
        if bundlePath.contains("/Caskroom/trill") { return .homebrew }

        let installed = bundlePath.hasPrefix("/Applications/")
            || bundlePath.hasPrefix(home + "/Applications/")
        guard installed else { return .unknown }

        // The rice reinstalls on every activation, so its marker outranks a
        // leftover cask receipt from a machine that has been both.
        if hasRiceMarker, bundlePath == "/Applications/Trill.app" { return .rice }
        if hasCaskReceipt { return .homebrew }
        return .direct
    }

    static func detectLive(fileManager: FileManager = .default) -> InstallKind {
        detect(
            bundlePath: Bundle.main.bundleURL.resolvingSymlinksInPath().path,
            home: fileManager.homeDirectoryForCurrentUser.path,
            hasRiceMarker: fileManager.fileExists(atPath: riceMarkerPath),
            hasCaskReceipt: caskReceiptPaths.contains { fileManager.fileExists(atPath: $0) }
        )
    }
}

// MARK: - UpdateCheck

@MainActor
final class UpdateCheck: ObservableObject {
    static let shared = UpdateCheck()

    /// Newer-than-running release ("2026.07.31", no leading v), or nil.
    @Published private(set) var availableVersion: String?
    /// The version the user waved off, persisted. Per-version on purpose:
    /// dismissing 2026.07.31 says nothing about 2026.08.01.
    @Published private(set) var dismissedVersion: String?
    @Published private(set) var isUpdating = false
    /// Transient line shown in the card — a user-initiated check's answer, or
    /// update progress. Nil most of the time.
    @Published private(set) var statusNote: String?

    private var fetching = false
    private var didStart = false
    private var timer: Timer?
    private var noteTask: Task<Void, Never>?

    nonisolated static let endpoint = URL(string: "https://api.github.com/repos/nebelhaus/trill/releases/latest")!
    /// Hourly: the nudge should show up the day a release is cut, not a day late.
    nonisolated static let maxAge: TimeInterval = 3600
    /// …but the BANNER is the invasive surface, so it repeats at most daily
    /// while the same version stays pending. The card carries it in between.
    nonisolated static let renotify: TimeInterval = 24 * 3600
    nonisolated static let releasesURL = URL(string: "https://github.com/nebelhaus/trill/releases/latest")!

    /// Settings toggle (`Updates` section). Defaults on; user-initiated checks
    /// ignore it, because asking is consent.
    static var automaticChecksEnabled: Bool {
        UserDefaults.standard.object(forKey: Key.automatic) as? Bool ?? true
    }

    var trillVersion: String {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           !version.isEmpty,
           version != "$(MARKETING_VERSION)" {
            return version
        }
        return "dev"
    }

    lazy var installKind: InstallKind = .detectLive()

    // MARK: Pure rules

    nonisolated static func shouldPin(available: String?, dismissed: String?) -> Bool {
        guard let available else { return false }
        return available != dismissed
    }

    var pendingVersion: String? {
        Self.shouldPin(available: availableVersion, dismissed: dismissedVersion)
            ? availableVersion : nil
    }

    /// A build that isn't a release: the Xcode/`bench try` builds, which carry
    /// either no substituted `MARKETING_VERSION` or a `-dev` suffix. They must
    /// never be nudged — the "update" would replace a branch build with the
    /// last release, which is the opposite of what feel-testing wants.
    nonisolated static func isDevVersion(_ version: String) -> Bool {
        version == "dev" || version.isEmpty || version.hasSuffix("-dev")
    }

    /// CalVer ordering. The zero-padded date compares lexicographically
    /// ("2026.07.29" < "2026.07.30"); the same-day `-N` suffix must compare
    /// NUMERICALLY — a string compare would put "-10" before "-2", which is
    /// exactly the silent-never-nudge bug the tests pin.
    nonisolated static func isNewer(_ candidate: String, than running: String) -> Bool {
        guard !isDevVersion(running) else { return false }
        let c = split(candidate), r = split(running)
        return c.date == r.date ? c.repeatN > r.repeatN : c.date > r.date
    }

    private nonisolated static func split(_ version: String) -> (date: String, repeatN: Int) {
        guard let dash = version.firstIndex(of: "-") else { return (version, 0) }
        return (
            String(version[..<dash]),
            Int(version[version.index(after: dash)...]) ?? 0
        )
    }

    // MARK: Lifecycle

    /// Called once from `TrillApp.init`. Checks now, then hourly, then whenever
    /// the app comes forward — a client left open for a week would otherwise
    /// never notice a release, which is the gap `maxAge` alone can't close.
    func start() {
        guard !didStart else { return }
        didStart = true
        checkForUpdates()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.maxAge, repeats: true) { _ in
            Task { @MainActor in UpdateCheck.shared.checkForUpdates() }
        }
        timer.tolerance = 300
        self.timer = timer
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            // Cheap: a cached answer inside the hour never touches the network.
            MainActor.assumeIsolated { UpdateCheck.shared.checkForUpdates() }
        }
    }

    func dismiss() {
        guard let v = availableVersion else { return }
        dismissedVersion = v
        var state = Self.readState()
        state.latest = state.latest ?? v
        state.dismissed = v
        Self.writeState(state)
    }

    /// Clears the transient note (the card's ✕ when nothing is pending).
    func clearNote() {
        noteTask?.cancel()
        statusNote = nil
    }

    func checkForUpdates(userInitiated: Bool = false) {
        if !userInitiated {
            // A debug build is either unversioned or a branch build; nudging it
            // would offer to overwrite the thing being tested.
            #if DEBUG
            return
            #else
            guard Self.automaticChecksEnabled, !Self.isDevVersion(trillVersion) else { return }
            #endif
        }
        guard !fetching else { return }

        let cached = Self.readState()
        if !userInitiated, let checkedAt = cached.checkedAt,
           Date().timeIntervalSince1970 - checkedAt < Self.maxAge {
            // Fresh enough: surface the cached answer, skip the network. Keeps
            // the ORIGINAL checkedAt — restamping here would push the next fetch
            // out by an hour on every launch and, for someone who restarts
            // often, mean the check never actually runs.
            apply(latest: cached.latest, previous: cached, checkedAt: checkedAt, userInitiated: false)
            return
        }

        fetching = true
        if userInitiated { note("Checking for updates…", transient: false) }

        var req = URLRequest(url: Self.endpoint)
        req.setValue("trill-update-check", forHTTPHeaderField: "user-agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "accept")

        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            var latest: String?
            if let data,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = obj["tag_name"] as? String {
                let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                // The tag reaches a shell one-liner (the updater's download URL)
                // and the UI — accept nothing beyond CalVer-shaped characters.
                if version.range(of: "^[0-9][0-9.\\-]*$", options: .regularExpression) != nil {
                    latest = version
                }
            }
            let message = error?.localizedDescription

            Task { @MainActor in
                guard let self else { return }
                self.fetching = false
                guard let latest else {
                    // Network/API miss: stamp nothing, so the next check retries
                    // instead of sitting out the hour on a failure.
                    if userInitiated {
                        self.note(message ?? "Couldn't reach GitHub to check for updates")
                    }
                    return
                }
                self.apply(
                    latest: latest,
                    previous: Self.readState(),
                    checkedAt: Date().timeIntervalSince1970,
                    userInitiated: userInitiated
                )
            }
        }.resume()
    }

    // MARK: Applying

    func performUpdate() {
        guard let version = availableVersion, !isUpdating else { return }

        switch installKind {
        case .direct:
            runDirectSelfUpdate(version: version)
        case .homebrew:
            runHomebrewSelfUpdate()
        case .rice:
            copyCommand("haus update")
        case .nix:
            copyCommand("nix flake update trill")
        case .unknown:
            NSWorkspace.shared.open(Self.releasesURL)
        }
    }

    private func copyCommand(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        note("Copied '\(text)' — run it in a terminal")
    }

    /// Swap this bundle for the release ZIP's, in a process that outlives us.
    ///
    /// The app quits itself immediately afterwards: the script waits for this
    /// PID to exit before touching the bundle (never replacing a live app) and
    /// reopens whichever version ends up installed, so a failed download leaves
    /// the user exactly where they were. Quitting through `NSApp.terminate` —
    /// rather than being killed — is also what flushes the composer draft.
    private func runDirectSelfUpdate(version: String) {
        isUpdating = true
        note("Downloading Trill \(version)…", transient: false)
        let app = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let spawned = runDetachedScript(
            Self.directUpdateScript,
            args: [app, "v\(version)", String(ProcessInfo.processInfo.processIdentifier)]
        )
        finishHandoff(spawned: spawned)
    }

    private func runHomebrewSelfUpdate() {
        isUpdating = true
        note("Handing off to Homebrew…", transient: false)
        let app = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let spawned = runDetachedScript(
            Self.homebrewUpdateScript,
            args: [app, String(ProcessInfo.processInfo.processIdentifier)]
        )
        finishHandoff(spawned: spawned)
    }

    private func finishHandoff(spawned: Bool) {
        guard spawned else {
            isUpdating = false
            note("Couldn't start the updater — see github.com/nebelhaus/trill/releases")
            return
        }
        // A beat so the card's "Downloading…" line paints before the window goes.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            NSApp.terminate(nil)
        }
    }

    /// `perl` (every macOS has it) gives us `setsid()` — which macOS has no
    /// binary for — so the worker lands in its own session and survives the app
    /// it was spawned from terminating a moment later. Arguments are passed as
    /// argv, never interpolated into the script text: a path is not a literal.
    @discardableResult
    private func runDetachedScript(_ script: String, args: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [
            "-e",
            "use POSIX qw(setsid); setsid(); exec('/bin/bash', '-c', $ARGV[0], 'trill-update', @ARGV[1..$#ARGV])",
            script,
        ] + args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return true
        } catch {
            AppLog.ui.error("update: could not spawn the updater process")
            return false
        }
    }

    /// Reconcile one answer (cached or freshly fetched) into the in-memory
    /// nudge, the banner, and the stored state.
    private func apply(latest: String?, previous: State, checkedAt: TimeInterval, userInitiated: Bool) {
        guard let latest else { return }
        let now = Date().timeIntervalSince1970
        // Rehydrate the dismissal before deciding anything: a relaunch must not
        // resurrect a nudge the user already waved off.
        dismissedVersion = previous.dismissed

        var state = previous
        state.checkedAt = checkedAt
        state.latest = latest

        guard Self.isNewer(latest, than: trillVersion) else {
            // Up to date, or ahead of the last tag (a branch build). Clear any
            // stale nudge and remember the answer so the next hour is a no-op.
            availableVersion = nil
            Self.writeState(state)
            if userInitiated {
                note(Self.isDevVersion(trillVersion)
                    ? "Latest release is \(latest) — this is a dev build"
                    : "Trill \(trillVersion) is the latest ✅")
            }
            return
        }

        availableVersion = latest
        // A dismissal silences the banner too — waving the card away and being
        // notified about the same version tomorrow is the nag this is not.
        let firstSighting = previous.notified != latest
        let staleReminder = previous.notifiedAt.map { now - $0 >= Self.renotify } ?? true
        let due = Self.shouldPin(available: latest, dismissed: dismissedVersion)
            && (firstSighting || staleReminder)

        if due {
            Self.postBanner(title: "Trill \(latest) is out", body: installKind.bannerHint)
        }
        if userInitiated {
            clearNote()
            // The card itself carries the version and the action; a note on top
            // of it would just repeat them.
        }

        state.notified = latest
        state.notifiedAt = due ? now : previous.notifiedAt
        Self.writeState(state)
    }

    private func note(_ text: String, transient: Bool = true) {
        noteTask?.cancel()
        statusNote = text
        guard transient else { return }
        noteTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self.statusNote = nil
        }
    }

    // MARK: State
    //
    // UserDefaults rather than pounce's `~/.local/share/pounce/update-nudge.json`:
    // pounce needs a file because a daemon and a shell script share the state,
    // trill is the only reader. It also means the `.dev` bundle id `bench try`
    // builds under keeps its own state, exactly like its own overlay DB.

    private enum Key {
        static let checkedAt = "update.checkedAt"
        static let latest = "update.latest"
        static let notified = "update.notified"
        static let notifiedAt = "update.notifiedAt"
        static let dismissed = "update.dismissed"
        static let automatic = "automaticUpdateChecks"
    }

    private struct State {
        var checkedAt: TimeInterval?
        var latest: String?
        var notified: String?
        var notifiedAt: TimeInterval?
        var dismissed: String?
    }

    private static func readState(defaults: UserDefaults = .standard) -> State {
        State(
            checkedAt: defaults.object(forKey: Key.checkedAt) as? TimeInterval,
            latest: defaults.string(forKey: Key.latest),
            notified: defaults.string(forKey: Key.notified),
            notifiedAt: defaults.object(forKey: Key.notifiedAt) as? TimeInterval,
            dismissed: defaults.string(forKey: Key.dismissed)
        )
    }

    private static func writeState(_ state: State, defaults: UserDefaults = .standard) {
        put(state.checkedAt, Key.checkedAt, defaults)
        put(state.notifiedAt, Key.notifiedAt, defaults)
        put(state.latest, Key.latest, defaults)
        put(state.notified, Key.notified, defaults)
        put(state.dismissed, Key.dismissed, defaults)
    }

    // Typed, so a nil never reaches `set(_: Any?, forKey:)` — an Optional boxed
    // into Any is not a property-list value and would trap at write time.
    private static func put(_ value: TimeInterval?, _ key: String, _ defaults: UserDefaults) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    private static func put(_ value: String?, _ key: String, _ defaults: UserDefaults) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    /// Trill's own notification surface, so the banner is attributed to Trill
    /// and respects the permission the user already granted. Silently no-ops if
    /// notifications were denied — the sidebar card is the surface that always
    /// works. Fixed identifier: a re-notify replaces, never stacks.
    private static func postBanner(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "trill.update.available", content: content, trigger: nil)
        )
    }
}

// MARK: - Updater scripts
//
// Both run detached, after the app has quit, and both end by reopening Trill —
// success or failure. Everything variable arrives as `$1…$n`; nothing is
// interpolated into the text, so a path with a quote in it can't become code.
// Progress goes through `osascript` because the app that owns the
// UNUserNotificationCenter connection is gone by then.

// Internal, not private: `UpdateCheckTests` runs both through `bash -n`, so a
// Swift-side escaping slip can't ship as a script that dies at its first line —
// which nothing in the app would notice, because by then the app has quit.
extension UpdateCheck {
    /// Shared prelude: notify(), the fail() path that always puts the app back,
    /// and the wait for the old process to exit.
    nonisolated static let scriptPrelude = """
    set -u
    notify() { /usr/bin/osascript -e "display notification \\"$1\\" with title \\"Trill Update\\"" >/dev/null 2>&1; }
    reopen() { [ -d "$APP" ] && /usr/bin/open "$APP" >/dev/null 2>&1; }
    fail() { notify "$1"; reopen; exit 1; }
    # The app terminates itself right after spawning us; wait it out so the
    # bundle is never replaced under a live process (and brew never trips over
    # a running app). 20s, then insist.
    wait_for_exit() {
        n=0
        while /bin/kill -0 "$PID" 2>/dev/null && [ "$n" -lt 100 ]; do
            /bin/sleep 0.2
            n=$((n + 1))
        done
        /bin/kill -0 "$PID" 2>/dev/null && /bin/kill -9 "$PID" 2>/dev/null
        /bin/sleep 0.5
    }
    """

    /// $1 installed Trill.app · $2 tag (v2026.07.31) · $3 pid of the running app
    nonisolated static var directUpdateScript: String {
        """
        APP="$1"; TAG="$2"; PID="$3"
        REPO="nebelhaus/trill"
        \(scriptPrelude)

        notify "Downloading Trill ${TAG#v}…"
        WORK="$(/usr/bin/mktemp -d)"
        trap 'rm -rf "$WORK"' EXIT INT TERM

        URL="https://github.com/$REPO/releases/download/$TAG/trill-$TAG-macos.zip"
        /usr/bin/curl -fsSL --retry 3 -o "$WORK/trill.zip" "$URL" || fail "Download failed — see github.com/$REPO/releases"

        # ditto, not unzip: the release archive is written by `ditto -c -k
        # --sequesterRsrc`, and unzip scatters those metadata entries into
        # __MACOSX instead of restoring them — enough to fail the signature.
        /usr/bin/ditto -x -k "$WORK/trill.zip" "$WORK/x" || fail "Couldn't unpack the download."
        NEW="$WORK/x/Trill.app"
        [ -d "$NEW" ] || NEW="$(/usr/bin/find "$WORK/x" -maxdepth 3 -name 'Trill.app' -print -quit)"
        [ -n "$NEW" ] && [ -d "$NEW" ] || fail "The download had no Trill.app in it."

        # Only swap in what Apple would let launch — a truncated or tampered
        # download must fail HERE, not as a broken app after the swap.
        /usr/bin/codesign --verify --deep --strict "$NEW" 2>/dev/null || fail "The download failed signature verification — keeping this version."

        # …and only if it is the SAME identity: Full Disk Access is granted to
        # this bundle id + signing identity, so a differently-signed app would
        # silently lose the chat.db grant the whole app is built on.
        ident() { /usr/bin/codesign -dv "$1" 2>&1 | /usr/bin/awk -F= '/^(Identifier|TeamIdentifier)=/ { print $2 }'; }
        [ "$(ident "$NEW")" = "$(ident "$APP")" ] || fail "The download is signed by a different identity — keeping this version."

        wait_for_exit

        # Move the old app aside, not away, until the new one is in place.
        OLD="$WORK/Trill.app.old"
        if ! /bin/mv "$APP" "$OLD" || ! /bin/mv "$NEW" "$APP"; then
            [ -d "$OLD" ] && [ ! -d "$APP" ] && /bin/mv "$OLD" "$APP"
            fail "Couldn't replace $APP — check that folder's permissions."
        fi

        notify "Trill updated to ${TAG#v} ✅ Restarting…"
        reopen
        """
    }

    /// $1 installed Trill.app · $2 pid of the running app
    nonisolated static var homebrewUpdateScript: String {
        """
        APP="$1"; PID="$2"
        \(scriptPrelude)

        # brew lives in Homebrew's bindir; a GUI app inherits launchd's bare PATH.
        for d in /opt/homebrew/bin /usr/local/bin; do
            [ -d "$d" ] && case ":$PATH:" in *":$d:"*) ;; *) PATH="$d:$PATH" ;; esac
        done
        export PATH
        command -v brew >/dev/null 2>&1 || fail "Homebrew isn't on PATH — run 'brew upgrade --cask trill' in a terminal."

        wait_for_exit
        notify "Updating Trill with Homebrew…"
        brew update >/dev/null 2>&1 || true
        if brew upgrade --cask trill >/dev/null 2>&1; then
            notify "Trill updated ✅ Restarting…"
        else
            notify "Homebrew couldn't upgrade — run 'brew upgrade --cask trill' in a terminal."
        fi
        reopen
        """
    }
}

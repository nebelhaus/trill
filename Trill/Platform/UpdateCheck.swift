import AppKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - InstallKind

/// How THIS install takes an update — determines the action hint and update method.
enum InstallKind: String, Codable, Equatable, CaseIterable {
    case homebrew
    case direct
    case rice
    case nix
    case unknown

    var canSelfUpdate: Bool {
        self == .homebrew || self == .direct
    }

    var actionHint: String {
        switch self {
        case .homebrew: return "Click to update via Homebrew"
        case .direct: return "Click to update Trill"
        case .rice: return "Run haus update in terminal"
        case .nix: return "Update trill flake input"
        case .unknown: return "Click to update"
        }
    }

    var bannerHint: String {
        switch self {
        case .homebrew: return "Open Trill and click Update, or run 'brew upgrade --cask trill'."
        case .direct, .unknown: return "Open Trill and click Update to install."
        case .rice: return "Run 'haus update' in terminal to pick it up."
        case .nix: return "Update your trill flake input to pick it up."
        }
    }

    static func detect(bundlePath: String, home: String) -> InstallKind {
        if bundlePath.hasPrefix("/nix/store/") { return .nix }
        if bundlePath.hasPrefix(home + "/.local/state/trill") { return .rice }
        if bundlePath.contains("/Caskroom/trill") || bundlePath.hasPrefix("/opt/homebrew/") || bundlePath.hasPrefix("/usr/local/") {
            return .homebrew
        }
        if bundlePath.hasPrefix("/Applications/") || bundlePath.hasPrefix(home + "/Applications/") {
            return .direct
        }
        return .unknown
    }
}

// MARK: - UpdateCheck

@MainActor
final class UpdateCheck: ObservableObject {
    static let shared = UpdateCheck()

    @Published private(set) var availableVersion: String?
    @Published private(set) var dismissedVersion: String?
    @Published private(set) var isUpdating: Bool = false
    @Published private(set) var updateStatusMessage: String?

    private var fetching = false

    static let endpoint = URL(string: "https://api.github.com/repos/nebelhaus/trill/releases/latest")!
    static let maxAge: TimeInterval = 3600
    static let renotify: TimeInterval = 24 * 3600

    static var statePath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/trill/update-nudge.json")
    }

    var trillVersion: String {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           !version.isEmpty,
           version != "$(MARKETING_VERSION)" {
            return version
        }
        return "dev"
    }

    lazy var installKind: InstallKind = InstallKind.detect(
        bundlePath: Bundle.main.bundleURL.resolvingSymlinksInPath().path,
        home: FileManager.default.homeDirectoryForCurrentUser.path
    )

    nonisolated static func shouldPin(available: String?, dismissed: String?) -> Bool {
        guard let available else { return false }
        return available != dismissed
    }

    var pendingVersion: String? {
        Self.shouldPin(available: availableVersion, dismissed: dismissedVersion)
            ? availableVersion : nil
    }

    func dismiss() {
        guard let v = availableVersion else { return }
        dismissedVersion = v
        let prev = Self.readState()
        Self.writeState(
            checkedAt: prev?.checkedAt ?? Date().timeIntervalSince1970,
            latest: prev?.latest ?? v,
            notified: prev?.notified,
            notifiedAt: prev?.notifiedAt,
            dismissed: v
        )
    }

    nonisolated static func isNewer(_ candidate: String, than running: String) -> Bool {
        guard !running.isEmpty, running != "dev" else { return false }
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

    func warm() {
        checkForUpdates(userInitiated: false)
    }

    func checkForUpdates(userInitiated: Bool = false) {
        guard trillVersion != "dev" || userInitiated, !fetching else { return }

        let cached = Self.readState()
        if !userInitiated, let cached, Date().timeIntervalSince1970 - cached.checkedAt < Self.maxAge {
            apply(latest: cached.latest, previous: cached, checkedAt: cached.checkedAt)
            return
        }

        fetching = true
        var req = URLRequest(url: Self.endpoint)
        req.setValue("trill-update-check", forHTTPHeaderField: "user-agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "accept")

        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            var latest: String?
            if let data,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = obj["tag_name"] as? String {
                let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                if version.range(of: "^[0-9][0-9.\\-]*$", options: .regularExpression) != nil {
                    latest = version
                }
            }

            Task { @MainActor in
                guard let self else { return }
                self.fetching = false
                if let latest {
                    self.apply(
                        latest: latest,
                        previous: Self.readState(),
                        checkedAt: Date().timeIntervalSince1970
                    )
                } else if userInitiated {
                    self.updateStatusMessage = error?.localizedDescription ?? "Could not check for updates"
                }
            }
        }.resume()
    }

    func performUpdate() {
        guard let version = availableVersion else { return }

        switch installKind {
        case .direct:
            runDirectSelfUpdate(version: version)
        case .homebrew:
            runHomebrewSelfUpdate()
        case .rice:
            copyToClipboard(text: "haus update", message: "Copied 'haus update' to clipboard")
        case .nix:
            copyToClipboard(text: "nix flake update", message: "Copied 'nix flake update' to clipboard")
        case .unknown:
            if installKind.canSelfUpdate {
                runDirectSelfUpdate(version: version)
            } else {
                copyToClipboard(text: "haus update", message: "Copied 'haus update' to clipboard")
            }
        }
    }

    private func copyToClipboard(text: String, message: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        updateStatusMessage = message
        Self.postBanner(title: "Command Copied", body: "\(message). Run it in a terminal to update.")
    }

    private func runDirectSelfUpdate(version: String) {
        isUpdating = true
        updateStatusMessage = "Downloading Trill \(version)…"

        let bundlePath = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let tag = "v\(version)"

        let script = """
        REPO="nebelhaus/trill"
        TAG="\(tag)"
        APP="\(bundlePath)"

        notify() { /usr/bin/osascript -e "display notification \\"$1\\" with title \\"Update Trill\\""; }

        notify "Downloading Trill $TAG…"

        WORK="$(mktemp -d)"
        trap 'rm -rf "$WORK"' EXIT

        if ! curl -fsSL --retry 3 -o "$WORK/trill.zip" "https://github.com/$REPO/releases/download/$TAG/trill-$TAG-macos.zip"; then
            notify "Download failed — see github.com/$REPO/releases"
            exit 1
        fi

        unzip -q "$WORK/trill.zip" -d "$WORK/extracted"
        NEW_APP="$(find "$WORK/extracted" -maxdepth 2 -name "Trill.app" | head -n 1)"

        if [ -z "$NEW_APP" ] || [ ! -d "$NEW_APP" ] || ! /usr/bin/codesign --verify --deep --strict "$NEW_APP" 2>/dev/null; then
            notify "Downloaded app failed verification — keeping current version."
            exit 1
        fi

        OLD="$WORK/Trill.app.old"
        if ! mv "$APP" "$OLD" || ! mv "$NEW_APP" "$APP"; then
            [ -d "$OLD" ] && [ ! -d "$APP" ] && mv "$OLD" "$APP"
            notify "Couldn't replace $APP — check permissions."
            exit 1
        fi

        notify "Trill updated to ${TAG#v} ✅ Restarting…"
        pkill -f 'Trill.app/Contents/MacOS/Trill' 2>/dev/null
        sleep 1
        open "$APP"
        """

        runDetachedScript(script)
    }

    private func runHomebrewSelfUpdate() {
        isUpdating = true
        updateStatusMessage = "Updating via Homebrew…"

        let script = """
        notify() { /usr/bin/osascript -e "display notification \\"$1\\" with title \\"Update Trill\\""; }
        for _d in /opt/homebrew/bin /usr/local/bin; do
            [ -d "$_d" ] && case ":$PATH:" in *":$_d:"*) ;; *) PATH="$_d:$PATH" ;; esac
        done
        export PATH

        notify "Updating Trill via Homebrew…"
        if brew upgrade --cask trill || brew upgrade trill; then
            notify "Trill updated ✅ Restarting…"
            pkill -f 'Trill.app/Contents/MacOS/Trill' 2>/dev/null
            sleep 1
            open -a Trill
        else
            notify "Homebrew update failed — run 'brew upgrade trill' in terminal."
        fi
        """

        runDetachedScript(script)
    }

    private func runDetachedScript(_ script: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [
            "-e",
            "use POSIX qw(setsid); setsid(); exec('/bin/bash', '-c', $ARGV[0])",
            script
        ]
        try? process.run()
    }

    private func apply(latest: String?, previous: State?, checkedAt: TimeInterval) {
        guard let latest else { return }
        let now = Date().timeIntervalSince1970
        dismissedVersion = previous?.dismissed

        guard Self.isNewer(latest, than: trillVersion) else {
            availableVersion = nil
            Self.writeState(
                checkedAt: checkedAt,
                latest: latest,
                notified: previous?.notified,
                notifiedAt: previous?.notifiedAt,
                dismissed: previous?.dismissed
            )
            return
        }

        availableVersion = latest
        let firstSighting = previous?.notified != latest
        let staleReminder = (previous?.notifiedAt).map { now - $0 >= Self.renotify } ?? true
        let due = Self.shouldPin(available: latest, dismissed: dismissedVersion)
            && (firstSighting || staleReminder)

        if due {
            Self.postBanner(title: "Trill \(latest) is out", body: installKind.bannerHint)
        }

        Self.writeState(
            checkedAt: checkedAt,
            latest: latest,
            notified: latest,
            notifiedAt: due ? now : previous?.notifiedAt,
            dismissed: previous?.dismissed
        )
    }

    private struct State {
        let checkedAt: TimeInterval
        let latest: String?
        let notified: String?
        let notifiedAt: TimeInterval?
        let dismissed: String?
    }

    private static func readState() -> State? {
        guard let data = try? Data(contentsOf: statePath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let checkedAt = obj["checkedAt"] as? TimeInterval
        else { return nil }
        return State(
            checkedAt: checkedAt,
            latest: obj["latest"] as? String,
            notified: obj["notified"] as? String,
            notifiedAt: obj["notifiedAt"] as? TimeInterval,
            dismissed: obj["dismissed"] as? String
        )
    }

    private static func writeState(
        checkedAt: TimeInterval,
        latest: String?,
        notified: String?,
        notifiedAt: TimeInterval?,
        dismissed: String?
    ) {
        var obj: [String: Any] = ["checkedAt": checkedAt]
        if let latest { obj["latest"] = latest }
        if let notified { obj["notified"] = notified }
        if let notifiedAt { obj["notifiedAt"] = notifiedAt }
        if let dismissed { obj["dismissed"] = dismissed }
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        try? FileManager.default.createDirectory(
            at: statePath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: statePath, options: .atomic)
    }

    private static func postBanner(title: String, body: String) {
        let script = "display notification \"\(body)\" with title \"\(title)\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }
}

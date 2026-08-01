import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var inbox: InboxModel
    @AppStorage("displayDensity") private var densityRaw = DisplayDensity.comfortable.rawValue
    @AppStorage("accentName") private var accentName = "mauve"
    @AppStorage("uiScale") private var uiScale = 1.0
    @AppStorage("sendOnReturn") private var sendOnReturn = true
    @AppStorage("undoSend") private var undoSend = true
    @AppStorage("privacyBlur") private var privacyBlur = false
    @AppStorage("showMenuBarItem") private var showMenuBarItem = true
    @AppStorage("linkPreviews") private var linkPreviews = false
    @AppStorage("themeAppearance") private var themeAppearance = RiceAppearance.system.rawValue
    @AppStorage("themeDarkName") private var themeDarkName = ""
    @AppStorage("themeLightName") private var themeLightName = ""
    /// Read by `UpdateCheck.automaticChecksEnabled`; defaults to on.
    @AppStorage("automaticUpdateChecks") private var automaticUpdateChecks = true
    /// Listed once rather than per body evaluation — it's a directory read.
    @State private var themeNames = RicePalette.availableNames()

    /// Names how THIS install takes an update, so the toggle's copy matches
    /// what the sidebar card will offer (`InstallKind`).
    private var updateCohortNote: String {
        switch UpdateCheck.shared.installKind {
        case .homebrew: return "Installed with Homebrew — updates run brew upgrade --cask trill."
        case .direct: return "Installed from the release ZIP — Trill can replace itself."
        case .rice: return "Installed by the nebelhaus rice — updates come from haus update."
        case .nix: return "Running from the Nix store — updates come from your flake input."
        case .unknown: return "Updates open the GitHub release page."
        }
    }

    var body: some View {
        ScrollView {
            content
        }
        .frame(width: 420)
        .frame(maxHeight: 640)
        .background(Rice.base)
        // A palette dropped in while Settings was open should show up on reopen.
        .onAppear { themeNames = RicePalette.availableNames() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Theme")
                    .riceSectionHeader()
                HStack(spacing: 6) {
                    ForEach(RiceAppearance.allCases) { option in
                        Button(option.title) { themeAppearance = option.rawValue }
                            .buttonStyle(DensityChoiceStyle(isSelected: themeAppearance == option.rawValue))
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                ThemeMenu(title: "Dark", selection: $themeDarkName, names: themeNames)
                ThemeMenu(title: "Light", selection: $themeLightName, names: themeNames)
                Text("Automatic follows the nebelung variant this Mac is set to, then falls back to built-in nebelung. Drop any nebelung or Catppuccin hex JSON into ~/.config/trill/themes/ and it shows up here — no rebuild.")
                    .riceFont(10)
                    .foregroundStyle(Rice.overlay0)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Accent")
                    .riceSectionHeader()
                HStack(spacing: 8) {
                    ForEach(Rice.accentNames, id: \.self) { name in
                        Button {
                            accentName = name
                        } label: {
                            Circle()
                                .fill(Rice.accent(named: name))
                                .frame(width: 18, height: 18)
                                .overlay(
                                    Circle()
                                        .strokeBorder(Rice.text, lineWidth: accentName == name ? 2 : 0)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(name) accent")
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Display density")
                    .riceSectionHeader()
                HStack(spacing: 6) {
                    ForEach(DisplayDensity.allCases) { density in
                        Button(density.title) {
                            densityRaw = density.rawValue
                        }
                        .buttonStyle(DensityChoiceStyle(isSelected: densityRaw == density.rawValue))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Zoom")
                    .riceSectionHeader()
                HStack(spacing: 10) {
                    Button {
                        uiScale = max(UIZoom.range.lowerBound, uiScale - UIZoom.step)
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(RiceSubtleButtonStyle())
                    Text("\(Int((uiScale * 100).rounded()))%")
                        .riceFont(13, .semibold)
                        .foregroundStyle(Rice.text)
                        .frame(width: 48)
                    Button {
                        uiScale = min(UIZoom.range.upperBound, uiScale + UIZoom.step)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(RiceSubtleButtonStyle())
                    Text("⌘+ / ⌘− / ⌘0")
                        .riceFont(10)
                        .foregroundStyle(Rice.overlay0)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Send message with")
                    .riceSectionHeader()
                HStack(spacing: 6) {
                    Button("Return") { sendOnReturn = true }
                        .buttonStyle(DensityChoiceStyle(isSelected: sendOnReturn))
                    Button("⌘ Return") { sendOnReturn = false }
                        .buttonStyle(DensityChoiceStyle(isSelected: !sendOnReturn))
                }
                Text(sendOnReturn
                    ? "Return sends · Shift+Return adds a line"
                    : "⌘Return sends · Return adds a line")
                    .riceFont(10)
                    .foregroundStyle(Rice.overlay0)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Undo send")
                    .riceSectionHeader()
                HStack(spacing: 6) {
                    Button("On") { undoSend = true }
                        .buttonStyle(DensityChoiceStyle(isSelected: undoSend))
                    Button("Off") { undoSend = false }
                        .buttonStyle(DensityChoiceStyle(isSelected: !undoSend))
                }
                Text(undoSend
                    ? "Holds an outgoing message for a few seconds so an accidental send can be cancelled — press Esc or tap ⤺ before it dispatches."
                    : "Messages send immediately.")
                    .riceFont(10)
                    .foregroundStyle(Rice.overlay0)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Privacy blur")
                    .riceSectionHeader()
                HStack(spacing: 6) {
                    Button("On") { privacyBlur = true }
                        .buttonStyle(DensityChoiceStyle(isSelected: privacyBlur))
                    Button("Off") { privacyBlur = false }
                        .buttonStyle(DensityChoiceStyle(isSelected: !privacyBlur))
                }
                Text("Blurs message previews and bubbles until you hover — screen-share and shoulder-surf safe.")
                    .riceFont(10)
                    .foregroundStyle(Rice.overlay0)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Menu bar")
                    .riceSectionHeader()
                HStack(spacing: 6) {
                    Button("Show") { showMenuBarItem = true }
                        .buttonStyle(DensityChoiceStyle(isSelected: showMenuBarItem))
                    Button("Hide") { showMenuBarItem = false }
                        .buttonStyle(DensityChoiceStyle(isSelected: !showMenuBarItem))
                }
                Text("A menu-bar icon with the unread count and a dropdown of recent threads.")
                    .riceFont(10)
                    .foregroundStyle(Rice.overlay0)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Link previews")
                    .riceSectionHeader()
                HStack(spacing: 6) {
                    Button("On") { linkPreviews = true }
                        .buttonStyle(DensityChoiceStyle(isSelected: linkPreviews))
                    Button("Off") { linkPreviews = false }
                        .buttonStyle(DensityChoiceStyle(isSelected: !linkPreviews))
                }
                Text("Fetches Open Graph titles, descriptions, and thumbnails for links in the Library (⌘⇧L). Networked — each link's host is contacted; results are cached.")
                    .riceFont(10)
                    .foregroundStyle(Rice.overlay0)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Updates")
                    .riceSectionHeader()
                HStack(spacing: 6) {
                    Button("On") { automaticUpdateChecks = true }
                        .buttonStyle(DensityChoiceStyle(isSelected: automaticUpdateChecks))
                    Button("Off") { automaticUpdateChecks = false }
                        .buttonStyle(DensityChoiceStyle(isSelected: !automaticUpdateChecks))
                }
                Text("\(updateCohortNote) Checks GitHub for a new release hourly — one request carrying nothing but an IP. ⌘-menu › Check for Updates… works either way.")
                    .riceFont(10)
                    .foregroundStyle(Rice.overlay0)
            }

            SnippetSettingsView()

            ExportSettingsView(inbox: inbox)

            Text("Native Messages wears the Nebelung rice: flat, desaturated Catppuccin, in dark or latte.")
                .riceFont(10)
                .foregroundStyle(Rice.overlay0)
        }
        .padding(24)
        .frame(width: 420, alignment: .leading)
    }
}

/// Which palette one polarity uses. "Automatic" means *unset* — resolution then
/// falls through to `~/.config/trill/config.json` (what the rice writes) and
/// finally to the compiled-in nebelung pair.
private struct ThemeMenu: View {
    let title: String
    @Binding var selection: String
    let names: [String]

    private static let automatic = "Automatic"

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .riceFont(11)
                .foregroundStyle(Rice.subtext0)
                // Fixed width so the two menus line up; wide enough that the
                // label survives ⌘+ zoom without wrapping mid-word.
                .lineLimit(1)
                .fixedSize()
                .frame(width: 44, alignment: .leading)
            Menu {
                Button(Self.automatic) { selection = "" }
                Divider()
                ForEach(names, id: \.self) { name in
                    Button(name) { selection = name }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selection.isEmpty ? Self.automatic : selection)
                        .riceFont(11, .medium)
                    Image(systemName: "chevron.down")
                        .riceFont(8)
                }
                .foregroundStyle(Rice.text)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("\(title) palette")
        }
    }
}

private struct DensityChoiceStyle: ButtonStyle {
    let isSelected: Bool
    @Environment(\.riceAccent) private var accent
    @Environment(\.uiScale) private var scale

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12 * scale, weight: .medium, design: .rounded))
            .foregroundStyle(isSelected ? accent : Rice.subtext1)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                isSelected ? accent.opacity(0.18) : Rice.surface0.opacity(configuration.isPressed ? 1 : 0.55),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
    }
}

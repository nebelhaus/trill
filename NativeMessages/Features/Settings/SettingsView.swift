import SwiftUI

struct SettingsView: View {
    @AppStorage("displayDensity") private var densityRaw = DisplayDensity.comfortable.rawValue
    @AppStorage("accentName") private var accentName = "mauve"
    @AppStorage("uiScale") private var uiScale = 1.0
    @AppStorage("sendOnReturn") private var sendOnReturn = true
    @AppStorage("undoSend") private var undoSend = true
    @AppStorage("privacyBlur") private var privacyBlur = false
    @AppStorage("showMenuBarItem") private var showMenuBarItem = true
    @AppStorage("linkPreviews") private var linkPreviews = false

    var body: some View {
        ScrollView {
            content
        }
        .frame(width: 420)
        .frame(maxHeight: 640)
        .background(Rice.base)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
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

            SnippetSettingsView()

            Text("Native Messages wears the Nebelung rice: flat, dark, desaturated Catppuccin.")
                .riceFont(10)
                .foregroundStyle(Rice.overlay0)
        }
        .padding(24)
        .frame(width: 420, alignment: .leading)
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

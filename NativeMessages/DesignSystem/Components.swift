import SwiftUI

/// Flat prominent button: accent fill, dark text.
struct RiceProminentButtonStyle: ButtonStyle {
    @Environment(\.riceAccent) private var accent
    @Environment(\.uiScale) private var scale

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12 * scale, weight: .semibold, design: .rounded))
            .foregroundStyle(Rice.crust)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                accent.opacity(configuration.isPressed ? 0.75 : 1),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
    }
}

/// Flat subtle button: surface fill, normal text.
struct RiceSubtleButtonStyle: ButtonStyle {
    @Environment(\.uiScale) private var scale

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12 * scale, weight: .medium, design: .rounded))
            .foregroundStyle(Rice.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Rice.surface0.opacity(configuration.isPressed ? 0.6 : 1),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
    }
}

/// Borderless icon button with a soft hover tint.
struct RiceIconButtonStyle: ButtonStyle {
    /// Keeps the button visibly lit, for toggles like the unread filter.
    var isActive = false

    @Environment(\.uiScale) private var scale
    @Environment(\.riceAccent) private var accent
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12 * scale, weight: .medium))
            .foregroundStyle(isActive ? accent : (isHovering ? Rice.text : Rice.subtext0))
            .frame(width: 24 * scale, height: 22 * scale)
            .background(
                isActive
                    ? accent.opacity(0.18)
                    : Rice.surface0.opacity(configuration.isPressed ? 1 : (isHovering ? 0.7 : 0)),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .onHover { isHovering = $0 }
    }
}

/// Flat replacement for ContentUnavailableView.
struct EmptyStateView: View {
    let icon: String
    let title: String
    var message: String?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .riceFont(30, .light)
                .foregroundStyle(Rice.surface2)
            Text(title)
                .riceFont(15, .semibold)
                .foregroundStyle(Rice.subtext1)
            if let message {
                Text(message)
                    .riceFont(12)
                    .foregroundStyle(Rice.subtext0)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

extension MessageServiceKind {
    var displayLabel: String {
        switch self {
        case .iMessage: "iMessage"
        case .sms: "SMS"
        case .rcs: "RCS"
        case .unknown: "Chat"
        }
    }

    var chipColor: Color {
        switch self {
        case .iMessage: Rice.blue
        case .sms: Rice.green
        case .rcs: Rice.teal
        case .unknown: Rice.overlay0
        }
    }
}

/// Tiny uppercase service tag ("SMS" / "RCS" / "IMESSAGE").
struct ServiceChip: View {
    let service: MessageServiceKind

    var body: some View {
        Text(service.displayLabel)
            .riceFont(9, .semibold)
            .kerning(0.4)
            .textCase(.uppercase)
            .foregroundStyle(service.chipColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(service.chipColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// Circular avatar: contact photo when available, tinted initials otherwise.
struct AvatarView: View {
    let conversation: Conversation
    var size: CGFloat = 30

    @Environment(\.uiScale) private var scale

    var body: some View {
        Group {
            if let photo {
                Image(nsImage: photo)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    seedColor.opacity(0.16)
                    Text(initials)
                        .riceFont(size * 0.37, .semibold)
                        .foregroundStyle(seedColor)
                }
            }
        }
        .frame(width: size * scale, height: size * scale)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var photo: NSImage? {
        guard conversation.kind == .direct,
              let data = conversation.participants.first?.avatarData else { return nil }
        return NSImage(data: data)
    }

    private var seedColor: Color {
        Rice.accent(seededBy: conversation.id.id)
    }

    private var initials: String {
        let words = conversation.displayName.split(separator: " ")
        let letters = words.prefix(2).compactMap { $0.first(where: \.isLetter) }
        guard !letters.isEmpty else { return "#" }
        return letters.map(String.init).joined().uppercased()
    }
}

/// 1px flat divider.
struct RiceDivider: View {
    var axis: Axis = .horizontal

    var body: some View {
        Rectangle()
            .fill(Rice.surface1.opacity(0.5))
            .frame(
                width: axis == .vertical ? 1 : nil,
                height: axis == .horizontal ? 1 : nil
            )
    }
}

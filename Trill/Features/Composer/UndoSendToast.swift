import SwiftUI

/// The floating notification shown while a just-sent message is held in its
/// undo window. It replaces the old locked-composer countdown: the box is
/// already clear, and this toast carries the message, a depleting progress bar
/// that dispatches the send when it empties, and the Undo affordance.
///
/// Quiet by design — it sits just above the composer, dismisses itself the
/// moment the send fires, and never steals focus. Click the body to send now,
/// hit Undo (or Esc) to pull the message back into the box.
struct UndoSendToast: View {
    let presentation: ComposerModel.PendingSendPresentation
    var onUndo: () -> Void
    var onSendNow: () -> Void

    @Environment(\.riceAccent) private var accent
    /// Drives the bar from full to empty over the window. Kept as pure view
    /// state and animated locally, so the bar stays perfectly smooth without the
    /// model ticking once a second — the model's timer remains the real clock.
    @State private var progress: CGFloat = 1

    var body: some View {
        ToastCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "paperplane.fill")
                        .riceFont(13, .semibold)
                        .foregroundStyle(accent)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Sending…")
                            .riceFont(10, .semibold)
                            .kerning(0.3)
                            .textCase(.uppercase)
                            .foregroundStyle(Rice.overlay1)
                        Text(presentation.preview)
                            .riceFont(12, .medium)
                            .foregroundStyle(Rice.text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Spacer(minLength: 10)

                    Button(action: onUndo) {
                        Text("Undo")
                            .riceFont(12, .semibold)
                            .foregroundStyle(accent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(accent.opacity(0.16), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help("Undo send (Esc)")
                    .accessibilityLabel("Undo send")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                countdownBar
            }
        }
        // The whole card sends now, so an impatient tap skips the wait.
        .contentShape(Rectangle())
        .onTapGesture(perform: onSendNow)
        .help("Sending — click to send now, or Undo to cancel")
        .onAppear { startCountdown() }
        // A superseding send bumps the token; restart the bar for the new one.
        .onChange(of: presentation.token) { _, _ in startCountdown() }
    }

    private var countdownBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Rice.surface1.opacity(0.5))
                Rectangle()
                    .fill(accent)
                    .frame(width: max(0, geo.size.width * progress))
            }
        }
        .frame(height: 3)
    }

    private func startCountdown() {
        progress = 1
        withAnimation(.linear(duration: presentation.duration)) {
            progress = 0
        }
    }
}

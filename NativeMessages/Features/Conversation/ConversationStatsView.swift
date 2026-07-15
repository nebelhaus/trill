import SwiftUI

/// Sheet of per-thread figures Apple's Messages can't show: volume, the
/// you-vs-them balance, how fast each side replies, the busiest hour, and the
/// current daily streak. All derived from timestamps we already read.
struct ConversationStatsView: View {
    @ObservedObject var model: ConversationModel
    let onClose: () -> Void

    @Environment(\.riceAccent) private var accent
    @State private var stats: ConversationStats?

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        VStack(spacing: 0) {
            header
            RiceDivider()
            content
        }
        .frame(width: 460, height: 480)
        .background(Rice.mantle)
        .task { stats = await model.loadStats() }
    }

    private var header: some View {
        HStack {
            Text("Stats — \(model.conversation?.displayName ?? "Conversation")")
                .riceSectionHeader()
            Spacer()
            Button("Done", action: onClose)
                .buttonStyle(RiceSubtleButtonStyle())
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if let stats {
            if stats.totalMessages == 0 {
                EmptyStateView(
                    icon: "chart.bar",
                    title: "No Stats Yet",
                    message: "This conversation has no messages to measure."
                )
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        balanceCard(stats)
                        LazyVGrid(columns: columns, spacing: 10) {
                            StatCard(
                                icon: "arrowshape.turn.up.left",
                                label: "You reply in",
                                value: Self.duration(stats.yourMedianReply),
                                tint: accent
                            )
                            StatCard(
                                icon: "arrowshape.turn.up.right",
                                label: "They reply in",
                                value: Self.duration(stats.theirMedianReply),
                                tint: Rice.sapphire
                            )
                            StatCard(
                                icon: "clock",
                                label: "Busiest hour",
                                value: Self.hour(stats.busiestHour),
                                tint: Rice.peach
                            )
                            StatCard(
                                icon: "flame",
                                label: "Current streak",
                                value: Self.streak(stats.currentStreakDays),
                                tint: Rice.maroon
                            )
                            StatCard(
                                icon: "calendar",
                                label: "First message",
                                value: Self.day(stats.firstMessageDate),
                                tint: Rice.teal
                            )
                            StatCard(
                                icon: "calendar.badge.clock",
                                label: "Latest message",
                                value: Self.day(stats.lastMessageDate),
                                tint: Rice.lavender
                            )
                        }
                    }
                    .padding(12)
                }
            }
        } else {
            LoadingStateView(label: "Crunching stats…")
        }
    }

    /// Headline card: total volume with a two-tone bar splitting your share
    /// from theirs.
    private func balanceCard(_ stats: ConversationStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(stats.totalMessages)")
                    .riceFont(28, .semibold)
                    .foregroundStyle(Rice.text)
                Text(stats.totalMessages == 1 ? "message" : "messages")
                    .riceFont(12)
                    .foregroundStyle(Rice.subtext0)
                Spacer()
            }
            if let share = stats.yourShare {
                GeometryReader { proxy in
                    HStack(spacing: 2) {
                        Capsule().fill(accent)
                            .frame(width: max(0, (proxy.size.width - 2) * share))
                        Capsule().fill(Rice.surface1)
                    }
                }
                .frame(height: 6)
                HStack(spacing: 4) {
                    legendDot(accent)
                    Text("You \(Self.percent(share)) · \(stats.fromMeCount)")
                        .riceFont(10)
                        .foregroundStyle(Rice.subtext0)
                    Spacer()
                    Text("\(stats.fromThemCount) · Them \(Self.percent(1 - share))")
                        .riceFont(10)
                        .foregroundStyle(Rice.subtext0)
                    legendDot(Rice.surface1)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Rice.base, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func legendDot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 6, height: 6)
    }

    // MARK: - Formatting

    private static func duration(_ interval: TimeInterval?) -> String {
        guard let interval, interval >= 0 else { return "—" }
        let seconds = Int(interval.rounded())
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m" }
        let days = hours / 24
        return hours % 24 == 0 ? "\(days)d" : "\(days)d \(hours % 24)h"
    }

    private static func hour(_ hour: Int?) -> String {
        guard let hour else { return "—" }
        let period = hour < 12 ? "AM" : "PM"
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        return "\(twelve) \(period)"
    }

    private static func streak(_ days: Int) -> String {
        days == 0 ? "None" : "\(days) day\(days == 1 ? "" : "s")"
    }

    private static func day(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    private static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

/// One labelled figure in the stats grid: a tinted glyph, a caption, and the
/// value beneath it.
private struct StatCard: View {
    let icon: String
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .riceFont(11)
                    .foregroundStyle(tint)
                Text(label)
                    .riceFont(10)
                    .foregroundStyle(Rice.subtext0)
                    .lineLimit(1)
            }
            Text(value)
                .riceFont(17, .semibold)
                .foregroundStyle(Rice.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Rice.base, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

import WidgetKit
import SwiftUI

// MARK: - Timeline Entry

struct PrivateAIEntry: TimelineEntry {
    let date: Date
    let steps: Double
    let sleepHours: Double
    let moodEmoji: String
    let moodLabel: String
}

// MARK: - Timeline Provider

struct PrivateAIProvider: TimelineProvider {

    func placeholder(in context: Context) -> PrivateAIEntry {
        PrivateAIEntry(
            date: Date(),
            steps: 6800,
            sleepHours: 7.5,
            moodEmoji: "😊",
            moodLabel: "不错"
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (PrivateAIEntry) -> Void) {
        completion(makeEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PrivateAIEntry>) -> Void) {
        let entry = makeEntry()
        // Refresh every 30 minutes so the widget stays reasonably fresh.
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date()
        let timeline = Timeline(entries: [entry], policy: .after(nextRefresh))
        completion(timeline)
    }

    // MARK: - Private

    private func makeEntry() -> PrivateAIEntry {
        let steps      = SharedDefaults.todaySteps
        let sleep      = SharedDefaults.todaySleepHours
        let moodRaw    = SharedDefaults.todayMoodRaw
        let (emoji, label) = moodInfo(for: moodRaw)
        return PrivateAIEntry(
            date: Date(),
            steps: steps,
            sleepHours: sleep,
            moodEmoji: emoji,
            moodLabel: label
        )
    }

    private func moodInfo(for raw: String) -> (emoji: String, label: String) {
        switch raw {
        case "great":    return ("😄", "很棒")
        case "good":     return ("😊", "不错")
        case "tired":    return ("😴", "疲惫")
        case "stressed": return ("😰", "压力大")
        case "sad":      return ("😢", "难过")
        default:         return ("😐", "一般")
        }
    }
}

// MARK: - Small Widget View

struct SmallWidgetView: View {
    let entry: PrivateAIEntry

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "figure.walk")
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(.blue)

            Text(formattedSteps)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(.primary)

            Text("步数")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)
        .containerBackground(for: .widget) {
            Color(uiColor: .systemBackground)
        }
    }

    private var formattedSteps: String {
        let val = Int(entry.steps)
        if val >= 10_000 {
            return String(format: "%.1fk", Double(val) / 1000)
        }
        return "\(val)"
    }
}

// MARK: - Medium Widget View

struct MediumWidgetView: View {
    let entry: PrivateAIEntry

    var body: some View {
        HStack(spacing: 0) {
            statColumn(
                icon: "figure.walk",
                iconColor: .blue,
                value: formattedSteps,
                label: "步数"
            )
            Divider().padding(.vertical, 12)
            statColumn(
                icon: "moon.zzz.fill",
                iconColor: .indigo,
                value: formattedSleep,
                label: "睡眠"
            )
            Divider().padding(.vertical, 12)
            moodColumn
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 8)
        .containerBackground(for: .widget) {
            Color(uiColor: .systemBackground)
        }
    }

    private func statColumn(icon: String, iconColor: Color, value: String, label: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(iconColor)
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var moodColumn: some View {
        VStack(spacing: 5) {
            Text(entry.moodEmoji)
                .font(.system(size: 26))
            Text(entry.moodLabel)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
            Text("心情")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var formattedSteps: String {
        let val = Int(entry.steps)
        if val >= 10_000 {
            return String(format: "%.1fk", Double(val) / 1000)
        }
        return "\(val)"
    }

    private var formattedSleep: String {
        if entry.sleepHours <= 0 { return "--" }
        return String(format: "%.1fh", entry.sleepHours)
    }
}

// MARK: - Widget Entry View (size-adaptive)

struct PrivateAIWidgetEntryView: View {
    var entry: PrivateAIEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemSmall:
            SmallWidgetView(entry: entry)
        case .systemMedium:
            MediumWidgetView(entry: entry)
        default:
            SmallWidgetView(entry: entry)
        }
    }
}

// MARK: - Widget Configuration

struct PrivateAIWidget: Widget {
    let kind: String = "PrivateAIWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PrivateAIProvider()) { entry in
            PrivateAIWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("私人助理")
        .description("显示今日步数、睡眠和心情。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Widget Bundle

@main
struct PrivateAIWidgetBundle: WidgetBundle {
    var body: some Widget {
        PrivateAIWidget()
    }
}

// MARK: - Previews

#Preview(as: .systemSmall) {
    PrivateAIWidget()
} timeline: {
    PrivateAIEntry(date: .now, steps: 7432, sleepHours: 7.2, moodEmoji: "😊", moodLabel: "不错")
}

#Preview(as: .systemMedium) {
    PrivateAIWidget()
} timeline: {
    PrivateAIEntry(date: .now, steps: 7432, sleepHours: 7.2, moodEmoji: "😊", moodLabel: "不错")
}

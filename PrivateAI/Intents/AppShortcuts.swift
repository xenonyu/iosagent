import AppIntents
import Foundation

// MARK: - Mood App Enum

enum MoodAppEnum: String, AppEnum {
    case great, good, neutral, tired, stressed, sad

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "心情")
    }

    static var caseDisplayRepresentations: [MoodAppEnum: DisplayRepresentation] {
        [
            .great:    DisplayRepresentation(title: "很棒 😄"),
            .good:     DisplayRepresentation(title: "不错 😊"),
            .neutral:  DisplayRepresentation(title: "一般 😐"),
            .tired:    DisplayRepresentation(title: "疲惫 😴"),
            .stressed: DisplayRepresentation(title: "压力大 😰"),
            .sad:      DisplayRepresentation(title: "难过 😢"),
        ]
    }
}

// MARK: - Log Mood Intent

struct LogMoodIntent: AppIntent {
    static var title: LocalizedStringResource = "记录心情"
    static var description = IntentDescription("打开 iosclaw 并记录今天的心情。")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "心情", default: MoodAppEnum.good)
    var mood: MoodAppEnum

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        UserDefaults(suiteName: "group.com.iosclaw.assistant")?
            .set(mood.rawValue, forKey: "intent_pending_mood")
        return .result(dialog: "好的，正在记录你的心情：\(mood.rawValue)")
    }
}

// MARK: - Query Steps Intent

struct QueryStepsIntent: AppIntent {
    static var title: LocalizedStringResource = "查询今日步数"
    static var description = IntentDescription("读取今天的步数并朗读出来。")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let steps = UserDefaults(suiteName: "group.com.iosclaw.assistant")?
            .integer(forKey: "widget_today_steps") ?? 0
        return .result(dialog: "你今天走了 \(steps) 步。")
    }
}

// MARK: - App Shortcuts Provider

struct PrivateAIShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LogMoodIntent(),
            phrases: [
                "在\(.applicationName)记录心情",
                "用\(.applicationName)记录心情",
                "Log my mood in \(.applicationName)"
            ],
            shortTitle: "记录心情",
            systemImageName: "face.smiling"
        )
        AppShortcut(
            intent: QueryStepsIntent(),
            phrases: [
                "在\(.applicationName)查询步数",
                "Check my steps in \(.applicationName)"
            ],
            shortTitle: "今日步数",
            systemImageName: "figure.walk"
        )
    }
}

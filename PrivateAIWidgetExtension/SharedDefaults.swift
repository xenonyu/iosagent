import Foundation

/// Keys and helpers for sharing data between the main app and the widget extension
/// via an App Group UserDefaults suite.
///
/// This file is compiled into both the main app target (via PrivateAI/Widgets/SharedDefaults.swift)
/// and the widget extension target (this copy). Keep both files in sync.
enum SharedDefaults {

    static let appGroupID = "group.com.iosclaw.assistant"

    static var suite: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    // MARK: - Keys

    enum Key {
        static let todaySteps      = "widget_today_steps"
        static let todaySleepHours = "widget_today_sleep_hours"
        static let todayMood       = "widget_today_mood"
        static let lastUpdated     = "widget_last_updated"
    }

    // MARK: - Write helpers (called from main app)

    static func saveTodayStats(steps: Double, sleepHours: Double, mood: String?) {
        let defaults = suite
        defaults.set(steps,      forKey: Key.todaySteps)
        defaults.set(sleepHours, forKey: Key.todaySleepHours)
        defaults.set(mood ?? "",  forKey: Key.todayMood)
        defaults.set(Date(),     forKey: Key.lastUpdated)
    }

    // MARK: - Read helpers (called from widget)

    static var todaySteps: Double {
        suite.double(forKey: Key.todaySteps)
    }

    static var todaySleepHours: Double {
        suite.double(forKey: Key.todaySleepHours)
    }

    /// Returns the stored mood raw value string, or "neutral" if not set.
    static var todayMoodRaw: String {
        let raw = suite.string(forKey: Key.todayMood) ?? ""
        return raw.isEmpty ? "neutral" : raw
    }

    static var lastUpdated: Date? {
        suite.object(forKey: Key.lastUpdated) as? Date
    }
}

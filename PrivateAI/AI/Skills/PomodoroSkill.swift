import Foundation

/// Tracks Pomodoro focus sessions with daily goals, streaks, and weekly history.
/// All data stored locally via UserDefaults — no CoreData changes needed.
struct PomodoroSkill: ClawSkill {

    let id = "pomodoro"

    func canHandle(intent: QueryIntent) -> Bool {
        if case .pomodoro = intent { return true }
        return false
    }

    func execute(intent: QueryIntent, context: SkillContext, completion: @escaping (String) -> Void) {
        guard case .pomodoro(let action) = intent else { return }

        switch action {
        case .start(let minutes):
            handleStart(minutes: minutes, completion: completion)
        case .today:
            handleToday(completion: completion)
        case .history:
            handleHistory(completion: completion)
        case .goal(let sessions):
            handleGoal(sessions: sessions, completion: completion)
        }
    }

    // MARK: - Record Focus Session

    private func handleStart(minutes: Int, completion: @escaping (String) -> Void) {
        var log = PomodoroStorage.loadToday()
        log.sessions += 1
        log.totalMinutes += minutes
        PomodoroStorage.saveToday(log)

        let goal = PomodoroStorage.loadGoal()
        let remaining = max(0, goal - log.sessions)
        let progress = progressBar(log.sessions, goal)
        let hours = log.totalMinutes / 60
        let mins = log.totalMinutes % 60

        var lines: [String] = []

        let emojis = ["🍅", "🔥", "💪", "⚡", "🎯"]
        let emoji = emojis[Int.random(in: 0..<emojis.count)]
        lines.append("\(emoji) 完成一个 \(minutes) 分钟的专注！")
        lines.append("")
        if hours > 0 {
            lines.append("📊 今日专注：\(log.sessions) 个番茄（\(hours)小时\(mins)分钟）")
        } else {
            lines.append("📊 今日专注：\(log.sessions) 个番茄（\(mins)分钟）")
        }
        lines.append("🎯 目标：\(goal) 个  \(progress)")

        if log.sessions >= goal {
            lines.append("")
            lines.append("🎉 今日专注目标已达成！太棒了！")
            if log.sessions == goal {
                lines.append("🧘 适当休息一下吧，劳逸结合更高效~")
            }
        } else if remaining == 1 {
            lines.append("")
            lines.append("💪 再来一个就达标了，冲冲冲！")
        } else {
            lines.append("")
            lines.append("还需 \(remaining) 个达标，继续保持专注 ~")
        }

        // Break suggestion
        if log.sessions % 4 == 0 && log.sessions > 0 {
            lines.append("\n☕ 已连续 \(log.sessions) 个番茄，建议休息 15-30 分钟！")
        } else {
            lines.append("\n💡 建议休息 5 分钟后继续下一个番茄。")
        }

        // Streak info
        let streak = calculateStreak()
        if streak >= 2 {
            lines.append("🔥 连续达标 \(streak) 天！")
        }

        completion(lines.joined(separator: "\n"))
    }

    // MARK: - Today Summary

    private func handleToday(completion: @escaping (String) -> Void) {
        let log = PomodoroStorage.loadToday()
        let goal = PomodoroStorage.loadGoal()
        let remaining = max(0, goal - log.sessions)
        let progress = progressBar(log.sessions, goal)
        let hours = log.totalMinutes / 60
        let mins = log.totalMinutes % 60
        let hour = Calendar.current.component(.hour, from: Date())

        var lines: [String] = ["🍅 **今日专注报告**\n"]

        if hours > 0 {
            lines.append("📊 已完成：\(log.sessions) 个番茄（\(hours)小时\(mins)分钟）")
        } else {
            lines.append("📊 已完成：\(log.sessions) 个番茄（\(mins)分钟）")
        }
        lines.append("🎯 目标：\(goal) 个  \(progress)")

        if log.sessions >= goal {
            lines.append("\n🎉 今日目标已达成！辛苦了！")
        } else if log.sessions == 0 {
            lines.append("\n⚠️ 今天还没有专注记录哦！")
            lines.append("💡 说「完成一个番茄」或「专注了25分钟」来记录。")
        } else {
            lines.append("\n还需 \(remaining) 个达标。")
            if hour >= 9 && hour < 12 && log.sessions < 2 {
                lines.append("🌅 上午是黄金专注时段，抓紧时间！")
            } else if hour >= 14 && hour < 17 {
                lines.append("☀️ 下午继续加油！")
            } else if hour >= 20 {
                lines.append("🌙 晚上了，注意不要过度疲劳哦。")
            }
        }

        let streak = calculateStreak()
        if streak >= 2 {
            lines.append("\n🔥 连续达标 \(streak) 天！")
        }

        // Productivity tip
        let tips = [
            "💡 每 4 个番茄后，建议休息 15-30 分钟。",
            "💡 专注时关闭通知，效率翻倍。",
            "💡 设定明确的小目标，每个番茄完成一个任务。",
            "💡 早上头脑最清醒，适合做高难度任务。"
        ]
        lines.append("\n\(tips[Int.random(in: 0..<tips.count)])")

        completion(lines.joined(separator: "\n"))
    }

    // MARK: - Set Goal

    private func handleGoal(sessions: Int, completion: @escaping (String) -> Void) {
        if sessions >= 1 && sessions <= 20 {
            PomodoroStorage.saveGoal(sessions)
            let totalMinutes = sessions * 25
            let hours = totalMinutes / 60
            let mins = totalMinutes % 60
            let timeStr = hours > 0 ? "\(hours)小时\(mins)分钟" : "\(mins)分钟"
            completion("🎯 专注目标已设为 **\(sessions) 个番茄/天**（约 \(timeStr)）\n\n💡 推荐每日 4-8 个番茄（2-4 小时深度工作）。")
        } else {
            let current = PomodoroStorage.loadGoal()
            let totalMinutes = current * 25
            let hours = totalMinutes / 60
            let mins = totalMinutes % 60
            let timeStr = hours > 0 ? "\(hours)小时\(mins)分钟" : "\(mins)分钟"
            completion("🎯 当前专注目标：**\(current) 个番茄/天**（约 \(timeStr)）\n\n💡 说「番茄目标6个」来修改目标（范围 1-20 个）。\n\n推荐标准：\n  • 轻度工作：4 个（100分钟）\n  • 正常工作：6 个（150分钟）\n  • 深度工作：8+ 个（200分钟+）")
        }
    }

    // MARK: - Weekly History

    private func handleHistory(completion: @escaping (String) -> Void) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let goal = PomodoroStorage.loadGoal()
        let dayLabels = ["一", "二", "三", "四", "五", "六", "日"]

        // Find Monday of this week
        let weekday = cal.component(.weekday, from: today)
        let mondayOffset = weekday == 1 ? -6 : (2 - weekday)
        guard let monday = cal.date(byAdding: .day, value: mondayOffset, to: today) else {
            completion("📊 暂无专注历史数据。")
            return
        }

        var lines: [String] = ["🍅 **本周专注记录**\n"]
        var totalSessions = 0
        var totalMinutes = 0
        var daysWithData = 0
        var goalMetDays = 0

        for i in 0..<7 {
            guard let day = cal.date(byAdding: .day, value: i, to: monday) else { continue }
            let log = PomodoroStorage.loadForDate(day)
            totalSessions += log.sessions
            totalMinutes += log.totalMinutes
            if log.sessions > 0 { daysWithData += 1 }
            if log.sessions >= goal { goalMetDays += 1 }

            let isToday = cal.isDateInToday(day)
            let bar = miniBar(log.sessions, goal)
            let marker = isToday ? " (今天)" : ""
            let status = log.sessions >= goal ? "✅" : (log.sessions > 0 ? "🔵" : "⬜")
            let timeStr = log.totalMinutes > 0 ? " \(log.totalMinutes)min" : ""

            lines.append("  \(dayLabels[i]) \(status) \(log.sessions)/\(goal) 个 \(bar)\(timeStr)\(marker)")
        }

        lines.append("")
        let avgSessions = daysWithData > 0 ? totalSessions / daysWithData : 0
        let totalHours = totalMinutes / 60
        let totalMins = totalMinutes % 60
        let timeStr = totalHours > 0 ? "\(totalHours)小时\(totalMins)分钟" : "\(totalMins)分钟"

        lines.append("📊 本周总计：\(totalSessions) 个番茄（\(timeStr)）")
        lines.append("📈 日均：\(avgSessions) 个")
        lines.append("🎯 达标天数：\(goalMetDays)/7 天")

        let streak = calculateStreak()
        if streak >= 1 {
            lines.append("🔥 当前连续达标：\(streak) 天")
        }

        // Weekly insight
        if totalSessions >= goal * 5 {
            lines.append("\n🌟 本周专注力很强！继续保持！")
        } else if daysWithData >= 3 {
            lines.append("\n💪 坚持就是胜利，下周继续加油！")
        } else if daysWithData == 0 {
            lines.append("\n💡 本周还没有专注记录，开始你的第一个番茄吧！")
        }

        completion(lines.joined(separator: "\n"))
    }

    // MARK: - Streak Calculation

    private func calculateStreak() -> Int {
        let cal = Calendar.current
        var date = cal.startOfDay(for: Date())
        let goal = PomodoroStorage.loadGoal()
        var streak = 0

        // Check today
        let todayLog = PomodoroStorage.loadForDate(date)
        if todayLog.sessions >= goal {
            streak = 1
            date = cal.date(byAdding: .day, value: -1, to: date)!
        } else {
            date = cal.date(byAdding: .day, value: -1, to: date)!
        }

        // Count consecutive past days
        for _ in 0..<365 {
            let log = PomodoroStorage.loadForDate(date)
            if log.sessions >= goal {
                streak += 1
                date = cal.date(byAdding: .day, value: -1, to: date)!
            } else {
                break
            }
        }

        return streak
    }

    // MARK: - Display Helpers

    private func progressBar(_ current: Int, _ goal: Int) -> String {
        guard goal > 0 else { return "" }
        let ratio = min(1.0, Double(current) / Double(goal))
        let filled = Int(ratio * 10)
        let empty = 10 - filled
        let pct = Int(ratio * 100)
        return "[\(String(repeating: "█", count: filled))\(String(repeating: "░", count: empty))] \(pct)%"
    }

    private func miniBar(_ current: Int, _ goal: Int) -> String {
        guard goal > 0 else { return "" }
        let ratio = min(1.0, Double(current) / Double(goal))
        let filled = Int(ratio * 5)
        let empty = 5 - filled
        return "[\(String(repeating: "▓", count: filled))\(String(repeating: "░", count: empty))]"
    }
}

// MARK: - Pomodoro Data Model

struct PomodoroDayLog: Codable {
    var date: String       // "yyyy-MM-dd"
    var sessions: Int      // completed pomodoro count
    var totalMinutes: Int  // total focus minutes
}

/// Persistence via UserDefaults — no CoreData changes needed.
enum PomodoroStorage {
    private static let prefix = "com.iosclaw.pomodoro."
    private static let goalKey = "com.iosclaw.pomodoro.dailyGoal"
    private static let defaults = UserDefaults.standard

    // MARK: - Daily Log

    static func loadToday() -> PomodoroDayLog {
        loadForDate(Date())
    }

    static func loadForDate(_ date: Date) -> PomodoroDayLog {
        let key = dayKey(date)
        let storageKey = prefix + key
        if let data = defaults.data(forKey: storageKey),
           let log = try? JSONDecoder().decode(PomodoroDayLog.self, from: data) {
            return log
        }
        return PomodoroDayLog(date: key, sessions: 0, totalMinutes: 0)
    }

    static func saveToday(_ log: PomodoroDayLog) {
        saveForDate(Date(), log: log)
    }

    static func saveForDate(_ date: Date, log: PomodoroDayLog) {
        let key = dayKey(date)
        var updated = log
        updated.date = key
        let storageKey = prefix + key
        if let data = try? JSONEncoder().encode(updated) {
            defaults.set(data, forKey: storageKey)
        }
    }

    // MARK: - Goal

    static func loadGoal() -> Int {
        let goal = defaults.integer(forKey: goalKey)
        return goal > 0 ? goal : 6  // default 6 pomodoros/day
    }

    static func saveGoal(_ sessions: Int) {
        defaults.set(sessions, forKey: goalKey)
    }

    // MARK: - Helpers

    static func dayKey(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }
}

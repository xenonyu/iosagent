import Foundation

/// Tracks daily water intake with cup-based recording, daily goals, and weekly history.
/// All data stored locally via UserDefaults — no CoreData changes needed.
struct WaterTrackSkill: ClawSkill {

    let id = "waterTrack"

    func canHandle(intent: QueryIntent) -> Bool {
        if case .waterTrack = intent { return true }
        return false
    }

    func execute(intent: QueryIntent, context: SkillContext, completion: @escaping (String) -> Void) {
        guard case .waterTrack(let action, let amount) = intent else { return }

        switch action {
        case .drink:
            handleDrink(cups: amount, completion: completion)
        case .today:
            handleToday(completion: completion)
        case .goal:
            handleGoal(cups: amount, completion: completion)
        case .history:
            handleHistory(completion: completion)
        }
    }

    // MARK: - Actions

    private func handleDrink(cups: Int, completion: @escaping (String) -> Void) {
        var log = WaterStorage.loadToday()
        log.cups += cups
        WaterStorage.saveToday(log)

        let goal = WaterStorage.loadGoal()
        let remaining = max(0, goal - log.cups)
        let progress = progressBar(log.cups, goal)
        let ml = log.cups * 250

        var lines: [String] = []

        if cups == 1 {
            let emojis = ["💧", "🥤", "💦", "🚰"]
            lines.append("\(emojis[Int.random(in: 0..<emojis.count)]) 已记录喝水 1 杯！")
        } else {
            lines.append("💧 已记录喝水 \(cups) 杯！")
        }

        lines.append("")
        lines.append("📊 今日饮水：\(log.cups) 杯（约 \(ml) ml）")
        lines.append("🎯 目标：\(goal) 杯  \(progress)")

        if log.cups >= goal {
            lines.append("")
            lines.append("🎉 恭喜！今日饮水目标已达成！继续保持！")
        } else if remaining <= 2 {
            lines.append("")
            lines.append("💪 还差 \(remaining) 杯就达标了，加油！")
        } else {
            lines.append("")
            lines.append("还需 \(remaining) 杯达标，记得按时补水哦 ~")
        }

        // Streak info
        let streak = calculateStreak()
        if streak >= 2 {
            lines.append("\n🔥 连续达标 \(streak) 天！")
        }

        completion(lines.joined(separator: "\n"))
    }

    private func handleToday(completion: @escaping (String) -> Void) {
        let log = WaterStorage.loadToday()
        let goal = WaterStorage.loadGoal()
        let ml = log.cups * 250
        let remaining = max(0, goal - log.cups)
        let progress = progressBar(log.cups, goal)
        let hour = Calendar.current.component(.hour, from: Date())

        var lines: [String] = ["💧 **今日饮水报告**\n"]
        lines.append("🥤 已喝：\(log.cups) 杯（约 \(ml) ml）")
        lines.append("🎯 目标：\(goal) 杯  \(progress)")

        if log.cups >= goal {
            lines.append("\n🎉 今日目标已达成！太棒了！")
        } else if log.cups == 0 {
            lines.append("\n⚠️ 今天还没喝水呢！赶紧来一杯吧 ~")
            lines.append("💡 说「喝了一杯水」来记录。")
        } else {
            lines.append("\n还需 \(remaining) 杯达标。")
            // Time-based reminder
            if hour >= 14 && hour < 18 && log.cups < goal / 2 {
                lines.append("⏰ 下午了，进度有点落后，多喝几杯补上吧！")
            } else if hour >= 18 && remaining > 2 {
                lines.append("⏰ 傍晚了，注意不要睡前喝太多哦。")
            }
        }

        let streak = calculateStreak()
        if streak >= 2 {
            lines.append("\n🔥 连续达标 \(streak) 天！")
        }

        completion(lines.joined(separator: "\n"))
    }

    private func handleGoal(cups: Int, completion: @escaping (String) -> Void) {
        if cups >= 1 && cups <= 30 {
            WaterStorage.saveGoal(cups)
            let ml = cups * 250
            completion("🎯 饮水目标已设为 **\(cups) 杯/天**（约 \(ml) ml）\n\n💡 建议每日饮水 6-8 杯（1500-2000ml）。")
        } else {
            let current = WaterStorage.loadGoal()
            let ml = current * 250
            completion("🎯 当前饮水目标：**\(current) 杯/天**（约 \(ml) ml）\n\n💡 说「喝水目标8杯」来修改目标（范围 1-30 杯）。\n\n推荐标准：\n  • 轻度活动：6 杯（1500ml）\n  • 正常活动：8 杯（2000ml）\n  • 运动日：10+ 杯（2500ml+）")
        }
    }

    private func handleHistory(completion: @escaping (String) -> Void) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let goal = WaterStorage.loadGoal()
        let dayLabels = ["一", "二", "三", "四", "五", "六", "日"]

        // Find Monday of this week
        let weekday = cal.component(.weekday, from: today)
        let mondayOffset = weekday == 1 ? -6 : (2 - weekday)
        guard let monday = cal.date(byAdding: .day, value: mondayOffset, to: today) else {
            completion("📊 暂无饮水历史数据。")
            return
        }

        var lines: [String] = ["💧 **本周饮水记录**\n"]
        var totalCups = 0
        var daysWithData = 0
        var goalMetDays = 0

        for i in 0..<7 {
            guard let day = cal.date(byAdding: .day, value: i, to: monday) else { continue }
            let log = WaterStorage.loadForDate(day)
            let cups = log.cups
            totalCups += cups
            if cups > 0 { daysWithData += 1 }
            if cups >= goal { goalMetDays += 1 }

            let isToday = cal.isDateInToday(day)
            let bar = miniBar(cups, goal)
            let marker = isToday ? " (今天)" : ""
            let status = cups >= goal ? "✅" : (cups > 0 ? "🔵" : "⬜")

            lines.append("  \(dayLabels[i]) \(status) \(cups)/\(goal) 杯 \(bar)\(marker)")
        }

        lines.append("")
        let avg = daysWithData > 0 ? totalCups / daysWithData : 0
        lines.append("📊 本周总计：\(totalCups) 杯")
        lines.append("📈 日均：\(avg) 杯")
        lines.append("🎯 达标天数：\(goalMetDays)/7 天")

        let streak = calculateStreak()
        if streak >= 1 {
            lines.append("🔥 当前连续达标：\(streak) 天")
        }

        completion(lines.joined(separator: "\n"))
    }

    // MARK: - Streak Calculation

    private func calculateStreak() -> Int {
        let cal = Calendar.current
        var date = cal.startOfDay(for: Date())
        let goal = WaterStorage.loadGoal()
        var streak = 0

        // Check today
        let todayLog = WaterStorage.loadForDate(date)
        if todayLog.cups >= goal {
            streak = 1
            date = cal.date(byAdding: .day, value: -1, to: date)!
        } else {
            // If today hasn't met goal yet, check from yesterday
            date = cal.date(byAdding: .day, value: -1, to: date)!
        }

        // Count consecutive past days
        for _ in 0..<365 {
            let log = WaterStorage.loadForDate(date)
            if log.cups >= goal {
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

// MARK: - Water Data Model

struct WaterDayLog: Codable {
    var date: String   // "yyyy-MM-dd"
    var cups: Int
}

/// Persistence via UserDefaults — no CoreData changes needed.
enum WaterStorage {
    private static let prefix = "com.iosclaw.water."
    private static let goalKey = "com.iosclaw.water.dailyGoal"
    private static let defaults = UserDefaults.standard

    // MARK: - Daily Log

    static func loadToday() -> WaterDayLog {
        loadForDate(Date())
    }

    static func loadForDate(_ date: Date) -> WaterDayLog {
        let key = dayKey(date)
        let storageKey = prefix + key
        if let data = defaults.data(forKey: storageKey),
           let log = try? JSONDecoder().decode(WaterDayLog.self, from: data) {
            return log
        }
        return WaterDayLog(date: key, cups: 0)
    }

    static func saveToday(_ log: WaterDayLog) {
        saveForDate(Date(), log: log)
    }

    static func saveForDate(_ date: Date, log: WaterDayLog) {
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
        return goal > 0 ? goal : 8  // default 8 cups/day
    }

    static func saveGoal(_ cups: Int) {
        defaults.set(cups, forKey: goalKey)
    }

    // MARK: - Helpers

    static func dayKey(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }
}

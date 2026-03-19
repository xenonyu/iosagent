import Foundation

/// Tracks daily habits with check-in, streak counting, and stats.
/// All data stored locally via UserDefaults — no CoreData changes needed.
struct HabitSkill: ClawSkill {

    let id = "habit"

    func canHandle(intent: QueryIntent) -> Bool {
        if case .habit = intent { return true }
        return false
    }

    func execute(intent: QueryIntent, context: SkillContext, completion: @escaping (String) -> Void) {
        guard case .habit(let action, let content) = intent else { return }

        switch action {
        case .checkin:
            handleCheckin(content: content, completion: completion)
        case .list:
            handleList(completion: completion)
        case .create:
            handleCreate(content: content, completion: completion)
        case .delete:
            handleDelete(content: content, completion: completion)
        case .stats:
            handleStats(content: content, completion: completion)
        }
    }

    // MARK: - Actions

    private func handleCheckin(content: String, completion: @escaping (String) -> Void) {
        var habits = HabitStorage.load()

        if habits.isEmpty {
            completion("📋 你还没有创建任何习惯。\n\n试试说「创建习惯：早起」来开始追踪吧！")
            return
        }

        // If no specific habit mentioned, try to check in all unchecked habits
        if content.isEmpty {
            let today = HabitStorage.todayKey()
            let unchecked = habits.filter { !$0.checkins.contains(today) }

            if unchecked.isEmpty {
                completion("🎉 太棒了！今天所有习惯都已打卡完成！\n\n\(streakSummary(habits))")
                return
            }

            // Show list for user to pick
            var lines = ["📋 今天还有 \(unchecked.count) 个习惯未打卡：\n"]
            for (i, h) in unchecked.enumerated() {
                lines.append("  \(i + 1). ⬜ \(h.name)（连续 \(currentStreak(for: h)) 天）")
            }
            lines.append("\n💡 说「打卡 习惯名」来记录，或说「全部打卡」一次完成。")
            completion(lines.joined(separator: "\n"))
            return
        }

        // Check in all at once
        if content == "_all" {
            let today = HabitStorage.todayKey()
            var count = 0
            for i in habits.indices {
                if !habits[i].checkins.contains(today) {
                    habits[i].checkins.append(today)
                    count += 1
                }
            }
            HabitStorage.save(habits)

            if count == 0 {
                completion("✅ 今天已经全部打卡过了！继续保持！")
            } else {
                completion("🔥 一次打卡 \(count) 个习惯！\n\n\(streakSummary(habits))")
            }
            return
        }

        // Check in specific habit by name match
        if let idx = habits.firstIndex(where: { $0.name.localizedCaseInsensitiveContains(content) || content.localizedCaseInsensitiveContains($0.name) }) {
            let today = HabitStorage.todayKey()
            if habits[idx].checkins.contains(today) {
                let streak = currentStreak(for: habits[idx])
                completion("✅ 「\(habits[idx].name)」今天已经打过卡了！\n\n🔥 当前连续 \(streak) 天")
                return
            }
            habits[idx].checkins.append(today)
            HabitStorage.save(habits)
            let streak = currentStreak(for: habits[idx])
            let emoji = streakEmoji(streak)
            completion("\(emoji) 「\(habits[idx].name)」打卡成功！\n\n🔥 连续 \(streak) 天！\(streakEncouragement(streak))")
        } else {
            var lines = ["🤔 没找到匹配的习惯「\(content)」。当前习惯列表：\n"]
            for (i, h) in habits.enumerated() {
                lines.append("  \(i + 1). \(h.name)")
            }
            lines.append("\n💡 说「打卡 习惯名」来记录。")
            completion(lines.joined(separator: "\n"))
        }
    }

    private func handleCreate(content: String, completion: @escaping (String) -> Void) {
        guard !content.isEmpty else {
            completion("📝 请告诉我你想追踪什么习惯？\n\n例如：「创建习惯：早起」「新习惯：读书30分钟」")
            return
        }

        var habits = HabitStorage.load()

        // Check for duplicate
        if habits.contains(where: { $0.name.localizedCaseInsensitiveContains(content) }) {
            completion("⚠️ 已经有一个类似的习惯了。\n\n试试用其他名字，或说「我的习惯」查看列表。")
            return
        }

        // Limit to 20 habits
        if habits.count >= 20 {
            completion("⚠️ 习惯数量已达上限（20个）。\n\n请先删除一些不需要的习惯，再创建新的。")
            return
        }

        let newHabit = HabitItem(name: content, createdAt: Date())
        habits.append(newHabit)
        HabitStorage.save(habits)

        completion("🌟 新习惯「\(content)」创建成功！\n\n从今天开始打卡吧！说「打卡 \(content)」即可记录。\n📋 当前共追踪 \(habits.count) 个习惯。")
    }

    private func handleDelete(content: String, completion: @escaping (String) -> Void) {
        var habits = HabitStorage.load()

        guard !content.isEmpty else {
            completion("🗑️ 请告诉我要删除哪个习惯？\n\n例如：「删除习惯 早起」")
            return
        }

        if let idx = habits.firstIndex(where: { $0.name.localizedCaseInsensitiveContains(content) || content.localizedCaseInsensitiveContains($0.name) }) {
            let removed = habits.remove(at: idx)
            HabitStorage.save(habits)
            completion("🗑️ 已删除习惯「\(removed.name)」。\n\n📋 还剩 \(habits.count) 个习惯。")
        } else {
            completion("🤔 没找到习惯「\(content)」。说「我的习惯」查看列表。")
        }
    }

    private func handleList(completion: @escaping (String) -> Void) {
        let habits = HabitStorage.load()

        if habits.isEmpty {
            completion("📋 你还没有追踪任何习惯。\n\n试试说「创建习惯：早起」来开始吧！\n\n推荐习惯：\n  🏃 运动  📖 阅读  💧 喝水  🧘 冥想  😴 早睡")
            return
        }

        let today = HabitStorage.todayKey()
        var lines = ["📋 **习惯追踪** （共 \(habits.count) 个）\n"]

        let checked = habits.filter { $0.checkins.contains(today) }
        let unchecked = habits.filter { !$0.checkins.contains(today) }

        if !unchecked.isEmpty {
            lines.append("⏳ 今日待打卡（\(unchecked.count) 个）：")
            for h in unchecked {
                let streak = currentStreak(for: h)
                let total = h.checkins.count
                lines.append("  ⬜ \(h.name) — 连续 \(streak) 天 / 累计 \(total) 次")
            }
        }

        if !checked.isEmpty {
            if !unchecked.isEmpty { lines.append("") }
            lines.append("✅ 今日已打卡（\(checked.count) 个）：")
            for h in checked {
                let streak = currentStreak(for: h)
                let total = h.checkins.count
                lines.append("  ☑️ \(h.name) — 🔥 连续 \(streak) 天 / 累计 \(total) 次")
            }
        }

        let progress = habits.isEmpty ? 0 : Int(Double(checked.count) / Double(habits.count) * 100)
        lines.append("\n📊 今日完成率：\(progress)%  \(progressBar(checked.count, habits.count))")

        completion(lines.joined(separator: "\n"))
    }

    private func handleStats(content: String, completion: @escaping (String) -> Void) {
        let habits = HabitStorage.load()

        if habits.isEmpty {
            completion("📊 暂无习惯数据。先创建一个习惯开始追踪吧！")
            return
        }

        // If specific habit mentioned
        if !content.isEmpty,
           let habit = habits.first(where: { $0.name.localizedCaseInsensitiveContains(content) || content.localizedCaseInsensitiveContains($0.name) }) {
            let streak = currentStreak(for: habit)
            let longest = longestStreak(for: habit)
            let total = habit.checkins.count
            let weekCount = recentCheckins(for: habit, days: 7)
            let monthCount = recentCheckins(for: habit, days: 30)
            let daysSinceCreation = max(1, Calendar.current.dateComponents([.day], from: habit.createdAt, to: Date()).day ?? 1)
            let rate = min(100, Int(Double(total) / Double(daysSinceCreation) * 100))

            var lines = ["📊 **\(habit.name)** 习惯统计\n"]
            lines.append("🔥 当前连续：\(streak) 天")
            lines.append("🏆 最长连续：\(longest) 天")
            lines.append("📅 本周打卡：\(weekCount) / 7 天")
            lines.append("📅 本月打卡：\(monthCount) / 30 天")
            lines.append("📈 总打卡率：\(rate)%（\(total) 次 / \(daysSinceCreation) 天）")
            lines.append("\n\(weeklyHeatmap(for: habit))")
            completion(lines.joined(separator: "\n"))
            return
        }

        // General stats across all habits
        var lines = ["📊 **习惯总览**\n"]

        let sorted = habits.sorted { currentStreak(for: $0) > currentStreak(for: $1) }
        for h in sorted {
            let streak = currentStreak(for: h)
            let total = h.checkins.count
            let emoji = streakEmoji(streak)
            lines.append("\(emoji) \(h.name)：连续 \(streak) 天 / 累计 \(total) 次")
        }

        let today = HabitStorage.todayKey()
        let todayDone = habits.filter { $0.checkins.contains(today) }.count
        lines.append("\n📅 今日完成：\(todayDone) / \(habits.count)")

        if let best = sorted.first {
            let bestStreak = currentStreak(for: best)
            if bestStreak >= 3 {
                lines.append("🏆 最佳习惯：\(best.name)（连续 \(bestStreak) 天）")
            }
        }

        completion(lines.joined(separator: "\n"))
    }

    // MARK: - Streak Calculation

    private func currentStreak(for habit: HabitItem) -> Int {
        let cal = Calendar.current
        var date = cal.startOfDay(for: Date())
        var streak = 0

        // Check today first
        let todayKey = HabitStorage.dateKey(date)
        if habit.checkins.contains(todayKey) {
            streak = 1
            date = cal.date(byAdding: .day, value: -1, to: date)!
        }

        // Count consecutive past days
        while true {
            let key = HabitStorage.dateKey(date)
            if habit.checkins.contains(key) {
                streak += 1
                date = cal.date(byAdding: .day, value: -1, to: date)!
            } else {
                break
            }
        }

        return streak
    }

    private func longestStreak(for habit: HabitItem) -> Int {
        guard !habit.checkins.isEmpty else { return 0 }

        let sorted = habit.checkins.sorted()
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"

        var maxStreak = 1
        var current = 1

        for i in 1..<sorted.count {
            if let prev = fmt.date(from: sorted[i - 1]),
               let curr = fmt.date(from: sorted[i]) {
                let diff = cal.dateComponents([.day], from: prev, to: curr).day ?? 0
                if diff == 1 {
                    current += 1
                    maxStreak = max(maxStreak, current)
                } else if diff > 1 {
                    current = 1
                }
            }
        }

        return maxStreak
    }

    private func recentCheckins(for habit: HabitItem, days: Int) -> Int {
        let cal = Calendar.current
        var count = 0
        for offset in 0..<days {
            if let date = cal.date(byAdding: .day, value: -offset, to: Date()) {
                let key = HabitStorage.dateKey(date)
                if habit.checkins.contains(key) { count += 1 }
            }
        }
        return count
    }

    // MARK: - Display Helpers

    private func streakEmoji(_ streak: Int) -> String {
        switch streak {
        case 0: return "⬜"
        case 1...2: return "✅"
        case 3...6: return "🔥"
        case 7...13: return "💪"
        case 14...29: return "⭐"
        case 30...99: return "🏆"
        default: return "👑"
        }
    }

    private func streakEncouragement(_ streak: Int) -> String {
        switch streak {
        case 1: return " 好的开始！"
        case 3: return " 三天了，继续加油！"
        case 7: return " 一周达成！🎉"
        case 14: return " 两周了，习惯正在养成！"
        case 21: return " 21天！习惯已经形成！🎊"
        case 30: return " 整整一个月！太厉害了！🏆"
        case 50: return " 50天里程碑！👑"
        case 100: return " 100天传奇！你是最棒的！🎆"
        default:
            if streak >= 7 && streak % 7 == 0 { return " 又一周！" }
            return ""
        }
    }

    private func progressBar(_ done: Int, _ total: Int) -> String {
        guard total > 0 else { return "" }
        let filled = Int(Double(done) / Double(total) * 10)
        let empty = 10 - filled
        return "[\(String(repeating: "█", count: filled))\(String(repeating: "░", count: empty))]"
    }

    private func streakSummary(_ habits: [HabitItem]) -> String {
        let summaries = habits.map { h -> String in
            let streak = currentStreak(for: h)
            return "\(streakEmoji(streak)) \(h.name)：\(streak) 天"
        }
        return "📊 连续打卡：\n" + summaries.joined(separator: "\n")
    }

    private func weeklyHeatmap(for habit: HabitItem) -> String {
        let cal = Calendar.current
        let dayLabels = ["一", "二", "三", "四", "五", "六", "日"]
        var line = "本周打卡：  "
        let today = cal.startOfDay(for: Date())
        // Find Monday of this week
        let weekday = cal.component(.weekday, from: today)
        let mondayOffset = weekday == 1 ? -6 : (2 - weekday)
        guard let monday = cal.date(byAdding: .day, value: mondayOffset, to: today) else { return "" }

        for i in 0..<7 {
            if let day = cal.date(byAdding: .day, value: i, to: monday) {
                let key = HabitStorage.dateKey(day)
                let checked = habit.checkins.contains(key)
                line += "\(dayLabels[i])\(checked ? "✅" : "⬜") "
            }
        }
        return line
    }
}

// MARK: - Habit Data Model

enum HabitAction {
    case checkin
    case list
    case create
    case delete
    case stats
}

struct HabitItem: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var createdAt: Date
    var checkins: [String] = []  // Date keys: "yyyy-MM-dd"
}

/// Persistence via UserDefaults — no CoreData changes needed.
enum HabitStorage {
    private static let key = "com.iosclaw.habitItems"

    static func load() -> [HabitItem] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([HabitItem].self, from: data) else {
            return []
        }
        return items
    }

    static func save(_ items: [HabitItem]) {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func todayKey() -> String {
        dateKey(Date())
    }

    static func dateKey(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }
}

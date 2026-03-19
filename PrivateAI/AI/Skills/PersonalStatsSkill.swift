import Foundation

/// Shows personal usage statistics — total records, active days, streaks, data breakdown.
/// Helps users see their engagement and feel a sense of accomplishment.
/// Keywords: "我的数据", "使用统计", "数据报告", "用了多久", "my stats"
struct PersonalStatsSkill: ClawSkill {

    let id = "personalStats"

    func canHandle(intent: QueryIntent) -> Bool {
        if case .personalStats = intent { return true }
        return false
    }

    func execute(intent: QueryIntent, context: SkillContext, completion: @escaping (String) -> Void) {
        let coreData = context.coreDataContext
        let cal = Calendar.current

        // Fetch all data
        let allEvents = CDLifeEvent.fetchAll(in: coreData)
        let allLocations = CDLocationRecord.fetchAll(in: coreData)
        let allMessages = CDChatMessage.fetchAll(in: coreData)
        let todos = TodoStorage.load()
        let habits = HabitStorage.load()
        let notes = NoteStorage.load()
        let expenses = ExpenseStorage.load()

        let userName = context.profile.name.isEmpty ? "" : " \(context.profile.name)"

        var lines: [String] = []
        lines.append("📊 \(userName)的 iosclaw 使用报告\n")

        // --- App usage duration ---
        let earliestDate = findEarliestDate(events: allEvents, locations: allLocations, messages: allMessages)
        if let earliest = earliestDate {
            let daysSinceFirst = cal.dateComponents([.day], from: cal.startOfDay(for: earliest), to: cal.startOfDay(for: Date())).day ?? 0
            let dateStr = formatDate(earliest)
            if daysSinceFirst == 0 {
                lines.append("📅 今天是你开始使用的第一天！")
            } else {
                lines.append("📅 使用天数：**\(daysSinceFirst + 1) 天**（从 \(dateStr) 开始）")
            }
        }

        // --- Data overview ---
        lines.append("\n📦 **数据总览**")

        var dataItems: [(String, Int)] = []
        if !allEvents.isEmpty { dataItems.append(("📝 生活记录", allEvents.count)) }
        if !allMessages.isEmpty {
            let userMsgCount = allMessages.filter { $0.isUser }.count
            dataItems.append(("💬 对话消息", allMessages.count))
            dataItems.append(("🗣️ 你的提问", userMsgCount))
        }
        if !allLocations.isEmpty { dataItems.append(("📍 位置记录", allLocations.count)) }
        if !todos.isEmpty { dataItems.append(("✅ 待办事项", todos.count)) }
        if !habits.isEmpty { dataItems.append(("🎯 追踪习惯", habits.count)) }
        if !notes.isEmpty { dataItems.append(("🗒️ 笔记", notes.count)) }
        if !expenses.isEmpty { dataItems.append(("💰 消费记录", expenses.count)) }

        if dataItems.isEmpty {
            lines.append("  暂无数据，开始和我聊天来积累吧！")
        } else {
            for (label, count) in dataItems {
                lines.append("  \(label)：\(count) 条")
            }
        }

        // --- Active days (days with at least one event or message) ---
        let activeDays = countActiveDays(events: allEvents, messages: allMessages, calendar: cal)
        if activeDays > 0 {
            lines.append("\n🔥 **活跃天数**：\(activeDays) 天")
        }

        // --- Current streak ---
        let streak = calculateStreak(events: allEvents, messages: allMessages, calendar: cal)
        if streak > 0 {
            let streakEmoji = streak >= 7 ? "🏆" : (streak >= 3 ? "🔥" : "⭐")
            lines.append("\(streakEmoji) **连续活跃**：\(streak) 天")
        }

        // --- Mood distribution ---
        if !allEvents.isEmpty {
            let moodDistribution = buildMoodDistribution(events: allEvents)
            if !moodDistribution.isEmpty {
                lines.append("\n😊 **心情分布**")
                for (mood, count, pct) in moodDistribution.prefix(4) {
                    let bar = String(repeating: "█", count: max(1, Int(pct / 5)))
                    lines.append("  \(mood.emoji) \(mood.label)  \(bar) \(count)次（\(Int(pct))%）")
                }
            }
        }

        // --- Category distribution ---
        if allEvents.count >= 3 {
            let catDistribution = buildCategoryDistribution(events: allEvents)
            if !catDistribution.isEmpty {
                lines.append("\n📂 **记录分类**")
                for (cat, count) in catDistribution.prefix(4) {
                    lines.append("  \(cat.label)：\(count) 条")
                }
            }
        }

        // --- Most active day of week ---
        if allEvents.count >= 5 || allMessages.filter({ $0.isUser }).count >= 5 {
            let (dayName, dayCount) = mostActiveDayOfWeek(events: allEvents, messages: allMessages, calendar: cal)
            if dayCount > 0 {
                lines.append("\n📆 **最活跃的一天**：\(dayName)（共 \(dayCount) 条记录）")
            }
        }

        // --- Location highlights ---
        if allLocations.count >= 2 {
            let uniquePlaces = Set(allLocations.map { $0.displayName }).count
            lines.append("\n🌍 去过 **\(uniquePlaces)** 个不同的地方")
        }

        // --- Expense total ---
        if !expenses.isEmpty {
            let total = expenses.reduce(0.0) { $0 + $1.amount }
            let totalStr = total == Double(Int(total)) ? "¥\(Int(total))" : "¥\(String(format: "%.1f", total))"
            lines.append("\n💳 累计记账：\(totalStr)（\(expenses.count) 笔）")
        }

        // --- Encouragement ---
        lines.append("\n" + buildEncouragement(
            eventCount: allEvents.count,
            streak: streak,
            activeDays: activeDays
        ))

        completion(lines.joined(separator: "\n"))
    }

    // MARK: - Helpers

    private func findEarliestDate(events: [LifeEvent], locations: [LocationRecord], messages: [ChatMessage]) -> Date? {
        var candidates: [Date] = []
        if let e = events.last?.timestamp { candidates.append(e) } // sorted desc
        if let l = locations.last?.timestamp { candidates.append(l) }
        if let m = messages.first?.timestamp { candidates.append(m) } // sorted asc
        return candidates.min()
    }

    private func formatDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy年M月d日"
        return fmt.string(from: date)
    }

    private func countActiveDays(events: [LifeEvent], messages: [ChatMessage], calendar: Calendar) -> Int {
        var daySet = Set<String>()
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        for e in events { daySet.insert(fmt.string(from: e.timestamp)) }
        for m in messages where m.isUser { daySet.insert(fmt.string(from: m.timestamp)) }
        return daySet.count
    }

    private func calculateStreak(events: [LifeEvent], messages: [ChatMessage], calendar: Calendar) -> Int {
        var daySet = Set<Int>() // days since reference date
        let ref = calendar.startOfDay(for: Date.distantPast)
        for e in events {
            let days = calendar.dateComponents([.day], from: ref, to: calendar.startOfDay(for: e.timestamp)).day ?? 0
            daySet.insert(days)
        }
        for m in messages where m.isUser {
            let days = calendar.dateComponents([.day], from: ref, to: calendar.startOfDay(for: m.timestamp)).day ?? 0
            daySet.insert(days)
        }

        guard !daySet.isEmpty else { return 0 }

        let today = calendar.dateComponents([.day], from: ref, to: calendar.startOfDay(for: Date())).day ?? 0
        // Check if today is active, otherwise start from yesterday
        var current = daySet.contains(today) ? today : today - 1
        guard daySet.contains(current) else { return 0 }

        var streak = 0
        while daySet.contains(current) {
            streak += 1
            current -= 1
        }
        return streak
    }

    private func buildMoodDistribution(events: [LifeEvent]) -> [(MoodType, Int, Double)] {
        var counts: [MoodType: Int] = [:]
        for e in events { counts[e.mood, default: 0] += 1 }
        let total = Double(events.count)
        return counts.sorted { $0.value > $1.value }
            .map { ($0.key, $0.value, Double($0.value) / total * 100) }
    }

    private func buildCategoryDistribution(events: [LifeEvent]) -> [(EventCategory, Int)] {
        var counts: [EventCategory: Int] = [:]
        for e in events { counts[e.category, default: 0] += 1 }
        return counts.sorted { $0.value > $1.value }
    }

    private func mostActiveDayOfWeek(events: [LifeEvent], messages: [ChatMessage], calendar: Calendar) -> (String, Int) {
        var dayCounts: [Int: Int] = [:] // 1=Sunday ... 7=Saturday
        for e in events {
            let weekday = calendar.component(.weekday, from: e.timestamp)
            dayCounts[weekday, default: 0] += 1
        }
        for m in messages where m.isUser {
            let weekday = calendar.component(.weekday, from: m.timestamp)
            dayCounts[weekday, default: 0] += 1
        }

        guard let top = dayCounts.max(by: { $0.value < $1.value }) else {
            return ("无数据", 0)
        }

        let dayNames = [1: "周日", 2: "周一", 3: "周二", 4: "周三", 5: "周四", 6: "周五", 7: "周六"]
        return (dayNames[top.key] ?? "未知", top.value)
    }

    private func buildEncouragement(eventCount: Int, streak: Int, activeDays: Int) -> String {
        if eventCount == 0 && activeDays <= 1 {
            return "💡 刚刚开始使用，多和我聊天、记录生活，数据会越来越丰富！"
        }
        if streak >= 7 {
            return "🏆 连续活跃 \(streak) 天！太厉害了，坚持记录生活的你最棒！"
        }
        if eventCount >= 50 {
            return "🎉 已经记录了 \(eventCount) 条生活事件，你的数字人生档案越来越丰富了！"
        }
        if activeDays >= 10 {
            return "⭐ \(activeDays) 天的活跃记录，每一天都值得被记住！继续保持！"
        }
        return "✨ 继续记录生活点滴，你的专属助手会越来越懂你！"
    }
}

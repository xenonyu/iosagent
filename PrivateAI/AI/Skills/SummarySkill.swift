import Foundation

/// Handles life summary, daily review, weekly insight, and event listing.
struct SummarySkill: ClawSkill {

    let id = "summary"

    func canHandle(intent: QueryIntent) -> Bool {
        switch intent {
        case .summary, .weeklyInsight, .events:
            return true
        default:
            return false
        }
    }

    func execute(intent: QueryIntent, context: SkillContext, completion: @escaping (String) -> Void) {
        switch intent {
        case .summary(let range):
            let lower = context.originalQuery.lowercased()
            if range == .today && SkillRouter.containsAny(lower, ["回顾", "今天", "总结"]) {
                respondDailyReview(context: context, completion: completion)
            } else {
                respondSummary(range: range, context: context, completion: completion)
            }
        case .weeklyInsight:
            respondWeeklyInsight(context: context, completion: completion)
        case .events(let range):
            respondEvents(range: range, context: context, completion: completion)
        default:
            break
        }
    }

    // MARK: - Summary

    private func respondSummary(range: QueryTimeRange, context: SkillContext, completion: @escaping (String) -> Void) {
        let interval = range.interval
        let events = CDLifeEvent.fetch(from: interval.start, to: interval.end, in: context.coreDataContext)
        let locations = CDLocationRecord.fetch(from: interval.start, to: interval.end, in: context.coreDataContext)

        context.healthService.fetchWeeklySummaries { summaries in
            var lines: [String] = ["📋 \(range.label)的生活总结：\n"]

            if !events.isEmpty {
                let byCategory = Dictionary(grouping: events, by: { $0.category })
                lines.append("📌 生活事件（共 \(events.count) 条）")
                byCategory.forEach { cat, evts in
                    lines.append("  \(cat.label)：\(evts.count) 条")
                }
            }

            if !locations.isEmpty {
                let uniquePlaces = Set(locations.map { $0.displayName }).count
                lines.append("\n📍 去过 \(uniquePlaces) 个地点，共记录 \(locations.count) 次")
            }

            let totalSteps = summaries.reduce(0) { $0 + $1.steps }
            let totalExercise = summaries.reduce(0) { $0 + $1.exerciseMinutes }
            if totalSteps > 0 || totalExercise > 0 {
                lines.append("\n🏃 健康数据：")
                if totalSteps > 0 { lines.append("  步数：\(Int(totalSteps).formatted()) 步") }
                if totalExercise > 0 { lines.append("  运动：\(Int(totalExercise)) 分钟") }
            }

            let moods = events.map { $0.mood }
            if !moods.isEmpty {
                let dominant = Dictionary(grouping: moods, by: { $0 })
                    .max(by: { $0.value.count < $1.value.count })?.key ?? .neutral
                lines.append("\n\(dominant.emoji) 整体心情：\(dominant.label)")
            }

            if events.isEmpty && locations.isEmpty {
                lines.append("暂无足够的数据生成总结。\n请多与我互动，我会帮你记录生活点滴！")
            }

            completion(lines.joined(separator: "\n"))
        }
    }

    // MARK: - Daily Review

    private func respondDailyReview(context: SkillContext, completion: @escaping (String) -> Void) {
        let interval = QueryTimeRange.today.interval
        let events = CDLifeEvent.fetch(from: interval.start, to: interval.end, in: context.coreDataContext)
        let locations = CDLocationRecord.fetch(from: interval.start, to: interval.end, in: context.coreDataContext)

        context.healthService.fetchDailySummary(for: Date()) { health in
            let cal = Calendar.current
            let hour = cal.component(.hour, from: Date())
            let timeGreet = hour < 12 ? "早安" : (hour < 18 ? "下午好" : "晚上好")

            var lines: [String] = []
            lines.append("🌅 \(timeGreet)！今天的生活全景：\n")

            var hasData = false

            // --- Health Data ---
            if health.steps > 0 || health.exerciseMinutes > 0 || health.sleepHours > 0 {
                hasData = true
                lines.append("🏃 **健康**")
                if health.steps > 0 { lines.append("  步数：\(Int(health.steps).formatted()) 步") }
                if health.exerciseMinutes > 0 { lines.append("  运动：\(Int(health.exerciseMinutes)) 分钟") }
                if health.sleepHours > 0 { lines.append("  昨晚睡眠：\(String(format: "%.1f", health.sleepHours)) 小时") }
            }

            // --- Habits ---
            let habits = HabitStorage.load()
            if !habits.isEmpty {
                let today = HabitStorage.todayKey()
                let checked = habits.filter { $0.checkins.contains(today) }
                let total = habits.count
                hasData = true
                let pct = Int(Double(checked.count) / Double(total) * 100)
                lines.append("\n🎯 **习惯打卡**  \(checked.count)/\(total)（\(pct)%）")
                if !checked.isEmpty {
                    let names = checked.prefix(4).map { "✅\($0.name)" }.joined(separator: "  ")
                    lines.append("  \(names)")
                }
                let unchecked = habits.filter { !$0.checkins.contains(today) }
                if !unchecked.isEmpty {
                    let names = unchecked.prefix(3).map { "⬜\($0.name)" }.joined(separator: "  ")
                    lines.append("  \(names)")
                }
            }

            // --- Water Intake ---
            let waterLog = WaterStorage.loadToday()
            if waterLog.cups > 0 {
                hasData = true
                let goal = WaterStorage.loadGoal()
                let ml = waterLog.cups * 250
                let status = waterLog.cups >= goal ? "✅ 达标" : "还差 \(goal - waterLog.cups) 杯"
                lines.append("\n💧 **饮水**  \(waterLog.cups)/\(goal) 杯（\(ml)ml）\(status)")
            }

            // --- Pomodoro ---
            let pomLog = PomodoroStorage.loadToday()
            if pomLog.sessions > 0 {
                hasData = true
                let goal = PomodoroStorage.loadGoal()
                let hrs = pomLog.totalMinutes / 60
                let mins = pomLog.totalMinutes % 60
                let timeStr = hrs > 0 ? "\(hrs)h\(mins)m" : "\(mins)m"
                let status = pomLog.sessions >= goal ? "✅ 达标" : "还差 \(goal - pomLog.sessions) 个"
                lines.append("\n🍅 **专注**  \(pomLog.sessions)/\(goal) 个番茄（\(timeStr)）\(status)")
            }

            // --- Expenses ---
            let allExpenses = ExpenseStorage.load()
            let todayExpenses = allExpenses.filter { cal.isDateInToday($0.createdAt) }
            if !todayExpenses.isEmpty {
                hasData = true
                let total = todayExpenses.reduce(0.0) { $0 + $1.amount }
                let amountStr = total == Double(Int(total)) ? "¥\(Int(total))" : "¥\(String(format: "%.1f", total))"
                lines.append("\n💰 **消费**  \(amountStr)（\(todayExpenses.count) 笔）")
                // Top category
                var catTotals: [String: Double] = [:]
                todayExpenses.forEach { catTotals[$0.category, default: 0] += $0.amount }
                if let top = catTotals.max(by: { $0.value < $1.value }) {
                    let topStr = top.value == Double(Int(top.value)) ? "¥\(Int(top.value))" : "¥\(String(format: "%.1f", top.value))"
                    lines.append("  最大类目：\(top.key) \(topStr)")
                }
            }

            // --- Todos ---
            let todos = TodoStorage.load()
            let pendingTodos = todos.filter { !$0.isDone }
            let todayDone = todos.filter { $0.isDone && cal.isDateInToday($0.createdAt) }
            if !todos.isEmpty {
                hasData = true
                lines.append("\n✅ **待办**  \(pendingTodos.count) 项待完成")
                if !todayDone.isEmpty {
                    lines.append("  今日已完成 \(todayDone.count) 项 🎉")
                }
                if let next = pendingTodos.first {
                    lines.append("  下一个：\(next.title)")
                }
            }

            // --- Life Events ---
            if !events.isEmpty {
                hasData = true
                lines.append("\n📝 **今日记录**（\(events.count) 条）")
                events.prefix(3).forEach { lines.append("  \($0.mood.emoji) \($0.title)") }
                if events.count > 3 {
                    lines.append("  …还有 \(events.count - 3) 条")
                }
            }

            // --- Locations ---
            if !locations.isEmpty {
                hasData = true
                let places = Set(locations.map { $0.displayName })
                lines.append("\n📍 **去过** \(places.prefix(3).joined(separator: "、"))")
            }

            // --- Empty State ---
            if !hasData {
                lines.append("今天还没有记录哦 📭\n")
                lines.append("试试这些来充实你的一天：")
                lines.append("  • 「打卡 早起」追踪习惯")
                lines.append("  • 「喝了一杯水」记录饮水")
                lines.append("  • 「专注了25分钟」记录番茄钟")
                lines.append("  • 「记一笔 午餐 30元」记账")
                lines.append("  • 「今天跑步了，很开心」记录事件")
            }

            completion(lines.joined(separator: "\n"))
        }
    }

    // MARK: - Weekly Insight

    private func respondWeeklyInsight(context: SkillContext, completion: @escaping (String) -> Void) {
        let interval = QueryTimeRange.thisWeek.interval
        let events = CDLifeEvent.fetch(from: interval.start, to: interval.end, in: context.coreDataContext)
        let locations = CDLocationRecord.fetch(from: interval.start, to: interval.end, in: context.coreDataContext)

        context.healthService.fetchWeeklySummaries { summaries in
            let filtered = summaries.filter { interval.contains($0.date) }
            var lines: [String] = ["📊 本周生活洞察：\n"]

            if !filtered.isEmpty {
                let avgSteps = filtered.reduce(0) { $0 + $1.steps } / Double(max(filtered.count, 1))
                let avgSleep = filtered.reduce(0) { $0 + $1.sleepHours } / Double(max(filtered.count, 1))
                let goalDays = filtered.filter { $0.steps >= 8000 }.count
                lines.append("🏃 健康数据")
                lines.append("  日均步数：\(Int(avgSteps).formatted()) 步")
                lines.append("  达成 8000 步目标：\(goalDays) 天")
                if avgSleep > 0 { lines.append("  平均睡眠：\(String(format: "%.1f", avgSleep)) 小时") }
            }

            if !events.isEmpty {
                var moodCount: [MoodType: Int] = [:]
                events.forEach { moodCount[$0.mood, default: 0] += 1 }
                if let dominant = moodCount.max(by: { $0.value < $1.value })?.key {
                    lines.append("\n\(dominant.emoji) 主要心情：\(dominant.label)（共 \(moodCount[dominant] ?? 0) 次）")
                }
            }

            if !locations.isEmpty {
                var placeCount: [String: Int] = [:]
                locations.forEach { placeCount[$0.displayName, default: 0] += 1 }
                if let topPlace = placeCount.max(by: { $0.value < $1.value }) {
                    lines.append("📍 最常去：\(topPlace.key)（\(topPlace.value) 次）")
                }
            }

            if !events.isEmpty {
                lines.append("\n📝 共记录 \(events.count) 条生活事件")
            }

            if filtered.isEmpty && events.isEmpty && locations.isEmpty {
                lines.append("本周数据较少，建议开启健康、位置权限并多与我分享，让周报更丰富！")
            }

            completion(lines.joined(separator: "\n"))
        }
    }

    // MARK: - Events

    private func respondEvents(range: QueryTimeRange, context: SkillContext, completion: @escaping (String) -> Void) {
        let interval = range.interval
        let events = CDLifeEvent.fetch(from: interval.start, to: interval.end, in: context.coreDataContext)

        if events.isEmpty {
            completion("📝 \(range.label)暂无记录的事件。\n可以告诉我你做了什么，比如：「今天去健身了，感觉很好」")
            return
        }

        var lines: [String] = ["📝 \(range.label)的事件记录（共 \(events.count) 条）：\n"]
        events.prefix(10).forEach { event in
            lines.append("\(event.mood.emoji) \(event.timestamp.shortDisplay)")
            lines.append("  \(event.title)")
        }

        if events.count > 10 {
            lines.append("\n…还有 \(events.count - 10) 条记录")
        }

        completion(lines.joined(separator: "\n"))
    }
}

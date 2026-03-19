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
            var lines: [String] = []
            let hour = Calendar.current.component(.hour, from: Date())
            let timeGreet = hour < 12 ? "早安" : (hour < 18 ? "下午好" : "晚上好")
            lines.append("🌅 \(timeGreet)！今天的生活快照：\n")

            if health.steps > 0 || health.exerciseMinutes > 0 {
                lines.append("🏃 健康")
                if health.steps > 0 { lines.append("  步数：\(Int(health.steps).formatted()) 步") }
                if health.exerciseMinutes > 0 { lines.append("  运动：\(Int(health.exerciseMinutes)) 分钟") }
            }

            if !events.isEmpty {
                lines.append("\n📝 今日记录（\(events.count) 条）")
                events.prefix(5).forEach { lines.append("  \($0.mood.emoji) \($0.title)") }
            }

            if !locations.isEmpty {
                let places = Set(locations.map { $0.displayName })
                lines.append("\n📍 去过：\(places.prefix(3).joined(separator: "、"))")
            }

            if events.isEmpty && health.steps == 0 {
                lines.append("今天还没有记录哦。\n告诉我你做了什么，或者开启健康和位置权限来自动追踪。")
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

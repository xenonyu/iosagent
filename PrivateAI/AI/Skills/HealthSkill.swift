import Foundation

/// Handles exercise, health metrics, step streaks, and week-over-week comparison.
struct HealthSkill: ClawSkill {

    let id = "health"

    func canHandle(intent: QueryIntent) -> Bool {
        switch intent {
        case .exercise, .health, .streak, .comparison:
            return true
        default:
            return false
        }
    }

    func execute(intent: QueryIntent, context: SkillContext, completion: @escaping (String) -> Void) {
        switch intent {
        case .exercise(let range):
            respondExercise(range: range, context: context, completion: completion)
        case .health(let metric, let range):
            respondHealth(metric: metric, range: range, context: context, completion: completion)
        case .streak:
            respondStreak(context: context, completion: completion)
        case .comparison:
            respondComparison(context: context, completion: completion)
        default:
            break
        }
    }

    // MARK: - Exercise

    private func respondExercise(range: QueryTimeRange, context: SkillContext, completion: @escaping (String) -> Void) {
        let interval = range.interval
        let events = CDLifeEvent.fetch(from: interval.start, to: interval.end, in: context.coreDataContext)
            .filter { $0.category == .health }

        context.healthService.fetchWeeklySummaries { summaries in
            let filtered = summaries.filter { interval.contains($0.date) }
            var lines: [String] = ["🏃 \(range.label)的运动记录：\n"]

            if filtered.isEmpty && events.isEmpty {
                lines.append("暂无运动记录。建议开启健康权限获取更详细数据。")
                completion(lines.joined(separator: "\n"))
                return
            }

            let totalSteps = filtered.reduce(0) { $0 + $1.steps }
            let totalExercise = filtered.reduce(0) { $0 + $1.exerciseMinutes }
            let totalCalories = filtered.reduce(0) { $0 + $1.activeCalories }

            if totalSteps > 0 { lines.append("👟 总步数：\(Int(totalSteps).formatted()) 步") }
            if totalExercise > 0 { lines.append("⏱ 运动时长：\(Int(totalExercise)) 分钟") }
            if totalCalories > 0 { lines.append("🔥 消耗热量：\(Int(totalCalories)) 千卡") }

            if !events.isEmpty {
                lines.append("\n📝 相关记录：")
                events.prefix(5).forEach { lines.append("• \($0.timestamp.shortDisplay)：\($0.title)") }
            }

            completion(lines.joined(separator: "\n"))
        }
    }

    // MARK: - Health Metric

    private func respondHealth(metric: String, range: QueryTimeRange, context: SkillContext, completion: @escaping (String) -> Void) {
        context.healthService.fetchWeeklySummaries { summaries in
            let interval = range.interval
            let filtered = summaries.filter { interval.contains($0.date) }

            guard !filtered.isEmpty else {
                completion("📊 暂无健康数据。\n请在设置中开启健康权限以获取详细数据。")
                return
            }

            switch metric {
            case "sleep":
                let avg = filtered.reduce(0) { $0 + $1.sleepHours } / Double(filtered.count)
                completion("😴 \(range.label)平均睡眠：\(String(format: "%.1f", avg)) 小时\n建议保持 7-8 小时睡眠。")

            case "heartRate":
                let avg = filtered.compactMap { $0.heartRate > 0 ? $0.heartRate : nil }
                    .reduce(0, +) / Double(max(filtered.count, 1))
                let display = avg > 0 ? "\(Int(avg)) BPM" : "暂无数据"
                completion("❤️ \(range.label)平均心率：\(display)")

            case "steps":
                let total = filtered.reduce(0) { $0 + $1.steps }
                let avg = total / Double(max(filtered.count, 1))
                completion("👟 \(range.label)总步数：\(Int(total).formatted()) 步\n日均：\(Int(avg).formatted()) 步")

            default:
                let total = filtered.reduce(0) { $0 + $1.steps }
                let exercise = filtered.reduce(0) { $0 + $1.exerciseMinutes }
                let sleep = filtered.reduce(0) { $0 + $1.sleepHours } / Double(max(filtered.count, 1))
                completion("📊 \(range.label)健康概览：\n👟 \(Int(total).formatted()) 步\n⏱ \(Int(exercise)) 分钟运动\n😴 均睡 \(String(format: "%.1f", sleep)) 小时")
            }
        }
    }

    // MARK: - Streak

    private func respondStreak(context: SkillContext, completion: @escaping (String) -> Void) {
        context.healthService.fetchWeeklySummaries { summaries in
            let sorted = summaries.sorted { $0.date > $1.date }
            var streak = 0
            var date = Calendar.current.startOfDay(for: Date())
            for summary in sorted {
                let summaryDay = Calendar.current.startOfDay(for: summary.date)
                if summaryDay == date && summary.steps >= 8000 {
                    streak += 1
                    date = Calendar.current.date(byAdding: .day, value: -1, to: date) ?? date
                } else {
                    break
                }
            }

            if streak == 0 {
                completion("🎯 步数打卡：今天还没达成 8000 步目标哦！\n\n加油，距离目标还有一段路，迈开步伐吧 💪")
            } else if streak == 1 {
                completion("🎯 你今天达成了步数目标（≥8000步）！\n\n明天继续，让打卡连续起来 🔥")
            } else {
                let encourage = streak >= 7 ? "太厉害了！保持下去！🏆" : (streak >= 3 ? "很棒！继续加油！💪" : "好的开始！")
                completion("🔥 步数连续打卡：**\(streak) 天**！\n\n\(encourage)\n每天 8000 步，健康习惯正在养成。")
            }
        }
    }

    // MARK: - Comparison

    private func respondComparison(context: SkillContext, completion: @escaping (String) -> Void) {
        context.healthService.fetchWeeklySummaries { summaries in
            let cal = Calendar.current
            let now = Date()
            let thisWeekStart = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? now
            let lastWeekStart = cal.date(byAdding: .weekOfYear, value: -1, to: thisWeekStart) ?? now
            let lastWeekEnd = thisWeekStart

            let thisWeek = summaries.filter { $0.date >= thisWeekStart && $0.date <= now }
            let lastWeek = summaries.filter { $0.date >= lastWeekStart && $0.date < lastWeekEnd }

            let thisSteps = thisWeek.reduce(0) { $0 + $1.steps }
            let lastSteps = lastWeek.reduce(0) { $0 + $1.steps }
            let thisSleep = thisWeek.reduce(0) { $0 + $1.sleepHours } / Double(max(thisWeek.count, 1))
            let lastSleep = lastWeek.reduce(0) { $0 + $1.sleepHours } / Double(max(lastWeek.count, 1))

            var lines: [String] = ["📈 本周 vs 上周对比：\n"]

            let stepDiff = Int(thisSteps - lastSteps)
            let stepArrow = stepDiff >= 0 ? "↑" : "↓"
            let stepColor = stepDiff >= 0 ? "📈" : "📉"
            lines.append("👟 步数")
            lines.append("  本周：\(Int(thisSteps).formatted()) 步")
            lines.append("  上周：\(Int(lastSteps).formatted()) 步")
            lines.append("  \(stepColor) 变化：\(stepArrow)\(abs(stepDiff).formatted()) 步")

            if thisSleep > 0 || lastSleep > 0 {
                let sleepDiff = thisSleep - lastSleep
                let sleepArrow = sleepDiff >= 0 ? "↑" : "↓"
                lines.append("\n😴 睡眠（日均）")
                lines.append("  本周：\(String(format: "%.1f", thisSleep)) 小时")
                lines.append("  上周：\(String(format: "%.1f", lastSleep)) 小时")
                lines.append("  变化：\(sleepArrow)\(String(format: "%.1f", abs(sleepDiff))) 小时")
            }

            if thisWeek.isEmpty && lastWeek.isEmpty {
                lines.append("暂无足够的健康数据进行对比。\n请开启健康权限以追踪每日数据。")
            }

            completion(lines.joined(separator: "\n"))
        }
    }
}

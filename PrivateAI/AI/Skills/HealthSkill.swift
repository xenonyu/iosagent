import Foundation

/// Handles exercise, health metrics, step streaks, and week-over-week comparison.
/// Provides trend analysis and personalized insights instead of raw numbers.
struct HealthSkill: ClawSkill {

    let id = "health"

    func canHandle(intent: QueryIntent) -> Bool {
        switch intent {
        case .exercise, .exerciseLastOccurrence, .health, .streak, .comparison:
            return true
        default:
            return false
        }
    }

    func execute(intent: QueryIntent, context: SkillContext, completion: @escaping (String) -> Void) {
        switch intent {
        case .exercise(let range, let workoutFilter):
            if let filter = workoutFilter {
                respondWorkoutType(filter: filter, range: range, context: context, completion: completion)
            } else {
                respondExercise(range: range, context: context, completion: completion)
            }
        case .exerciseLastOccurrence(let workoutFilter):
            respondLastWorkout(filter: workoutFilter, context: context, completion: completion)
        case .health(let metric, let range):
            respondHealth(metric: metric, range: range, context: context, completion: completion)
        case .streak:
            respondStreak(context: context, completion: completion)
        case .comparison(let range):
            respondComparison(range: range, context: context, completion: completion)
        default:
            break
        }
    }

    // MARK: - Fetch Days Calculation

    /// Calculates the number of days to fetch from HealthKit to fully cover the given time range.
    /// `fetchSummaries(days:)` counts backwards from today, so we need enough days
    /// to reach back to the start of the requested interval.
    private func fetchDaysNeeded(for range: QueryTimeRange) -> Int {
        let interval = range.interval
        let cal = Calendar.current
        let daysBack = cal.dateComponents([.day], from: interval.start, to: Date()).day ?? 7
        // Add 1 to include both start and end days, minimum 1
        return max(daysBack + 1, 1)
    }

    // MARK: - Exercise

    private func respondExercise(range: QueryTimeRange, context: SkillContext, completion: @escaping (String) -> Void) {
        let interval = range.interval
        let events = CDLifeEvent.fetch(from: interval.start, to: interval.end, in: context.coreDataContext)
            .filter { $0.category == .health }

        // When range is .today, fetch 2 days so we can show yesterday as comparison context.
        // This makes "步数多少" useful even early in the day when today's data is sparse.
        let baseFetchDays = fetchDaysNeeded(for: range)
        let fetchDays = range == .today ? max(baseFetchDays, 2) : baseFetchDays
        context.healthService.fetchSummaries(days: fetchDays) { allSummaries in
            let filtered = allSummaries.filter { interval.contains($0.date) }
            var lines: [String] = ["🏃 \(range.label)的运动数据\n"]

            if filtered.isEmpty && events.isEmpty {
                if !context.healthService.isHealthDataAvailable {
                    lines.append("此设备不支持 HealthKit（如 iPad）。\n需要在 iPhone 上使用才能获取运动数据。")
                } else {
                    lines.append("暂无运动记录。\n\n请前往「设置 → iosclaw → 健康」开启权限，开启后可以自动追踪步数、运动时长、消耗热量等。")
                }
                completion(lines.joined(separator: "\n"))
                return
            }

            let daysWithData = filtered.filter { $0.hasData }
            guard !daysWithData.isEmpty else {
                var emptyMsg = "\(range.label)暂无运动数据记录。"
                if range == .today {
                    // Instead of just suggesting "ask about yesterday", show yesterday's data directly
                    let cal = Calendar.current
                    let yesterdayStart = cal.startOfDay(for: cal.date(byAdding: .day, value: -1, to: Date()) ?? Date())
                    let yesterdayEnd = cal.date(byAdding: .day, value: 1, to: yesterdayStart) ?? yesterdayStart
                    let yesterdayData = allSummaries.filter {
                        $0.date >= yesterdayStart && $0.date < yesterdayEnd && $0.hasData
                    }
                    if let yd = yesterdayData.first, yd.steps > 0 || yd.exerciseMinutes > 0 {
                        emptyMsg += "\n今天还没有足够的活动数据。\n"
                        emptyMsg += "\n📋 昨天的运动回顾："
                        if yd.steps > 0 { emptyMsg += "\n   👟 \(Int(yd.steps).formatted()) 步" }
                        if yd.exerciseMinutes > 0 { emptyMsg += "\n   ⏱ 运动 \(Int(yd.exerciseMinutes)) 分钟" }
                        if yd.activeCalories > 0 { emptyMsg += "\n   🔥 消耗 \(Int(yd.activeCalories).formatted()) 千卡" }
                    } else {
                        emptyMsg += "\n今天可能还没有足够的活动。试试问我「昨天运动了多少」？"
                    }
                } else if range == .yesterday || range.interval.duration < 86400 * 2 {
                    emptyMsg += "\n试试扩大范围：「这周运动了多少」？"
                }
                lines.append(emptyMsg)
                completion(lines.joined(separator: "\n"))
                return
            }

            let totalSteps = filtered.reduce(0) { $0 + $1.steps }
            let totalExercise = filtered.reduce(0) { $0 + $1.exerciseMinutes }
            let totalCalories = filtered.reduce(0) { $0 + $1.activeCalories }
            let totalDistance = filtered.reduce(0) { $0 + $1.distanceKm }
            let dayCount = Double(max(daysWithData.count, 1))
            let totalFlights = filtered.reduce(0) { $0 + $1.flightsClimbed }
            let isSingleDay = daysWithData.count == 1

            // Core metrics — single-day uses goal progress bars, multi-day uses totals + averages
            if isSingleDay {
                // Single-day: show progress bars toward standard daily goals
                let stepGoal = 8000.0
                let exerciseGoal = 30.0
                let calorieGoal = 500.0

                if totalSteps > 0 {
                    let progress = min(totalSteps / stepGoal, 1.0)
                    let barFilled = Int(progress * 8)
                    let bar = String(repeating: "▓", count: barFilled) + String(repeating: "░", count: 8 - barFilled)
                    let pct = Int(progress * 100)
                    let tag = totalSteps >= stepGoal ? " ✅ 达标！" : ""
                    lines.append("👟 \(Int(totalSteps).formatted()) 步 \(bar) \(pct)%\(tag)")
                    // Remaining hint when close but not yet reached
                    if totalSteps < stepGoal && totalSteps >= stepGoal * 0.5 {
                        let remaining = Int(stepGoal - totalSteps)
                        lines.append("   还差 \(remaining.formatted()) 步达标")
                    }
                }
                if totalDistance > 0.1 {
                    lines.append("📏 \(String(format: "%.1f", totalDistance)) 公里")
                }
                if totalExercise > 0 {
                    let progress = min(totalExercise / exerciseGoal, 1.0)
                    let barFilled = Int(progress * 8)
                    let bar = String(repeating: "▓", count: barFilled) + String(repeating: "░", count: 8 - barFilled)
                    let pct = Int(progress * 100)
                    let tag = totalExercise >= exerciseGoal ? " ✅" : ""
                    lines.append("⏱ 运动 \(Int(totalExercise)) 分钟 \(bar) \(pct)%\(tag)")
                }
                if totalCalories > 0 {
                    let progress = min(totalCalories / calorieGoal, 1.0)
                    let barFilled = Int(progress * 8)
                    let bar = String(repeating: "▓", count: barFilled) + String(repeating: "░", count: 8 - barFilled)
                    let tag = totalCalories >= calorieGoal ? " ✅" : ""
                    lines.append("🔥 \(Int(totalCalories).formatted()) 千卡 \(bar)\(tag)")
                }
                if totalFlights > 0 {
                    lines.append("🏢 爬楼 \(Int(totalFlights)) 层")
                }
                // Quick overall verdict for the day
                var goalsMet = 0
                var goalsTotal = 0
                if totalSteps > 0 { goalsTotal += 1; if totalSteps >= stepGoal { goalsMet += 1 } }
                if totalExercise > 0 { goalsTotal += 1; if totalExercise >= exerciseGoal { goalsMet += 1 } }
                if totalCalories > 0 { goalsTotal += 1; if totalCalories >= calorieGoal { goalsMet += 1 } }
                if goalsTotal >= 2 {
                    if goalsMet == goalsTotal {
                        lines.append("\n🏅 所有指标达标，今天运动表现满分！")
                    } else if goalsMet == 0 {
                        lines.append("")
                    } else {
                        lines.append("\n💪 \(goalsMet)/\(goalsTotal) 项达标，继续保持！")
                    }
                }
            } else {
                // Multi-day: show totals + daily averages
                if totalSteps > 0 {
                    lines.append("👟 总步数：\(Int(totalSteps).formatted()) 步（日均 \(Int(totalSteps / dayCount).formatted())）")
                }
                if totalDistance > 0.1 {
                    lines.append("📏 总距离：\(String(format: "%.1f", totalDistance)) 公里")
                }
                if totalExercise > 0 {
                    lines.append("⏱ 运动时长：\(Int(totalExercise)) 分钟（日均 \(Int(totalExercise / dayCount))）")
                }
                if totalCalories > 0 {
                    lines.append("🔥 消耗热量：\(Int(totalCalories).formatted()) 千卡")
                }
                if totalFlights > 0 {
                    lines.append("🏢 爬楼：\(Int(totalFlights)) 层")
                }
            }

            // --- Today's progress context: compare with yesterday + pace projection ---
            // When the user asks about today's exercise data, the day isn't over yet.
            // Show yesterday as a reference point and project today's final numbers
            // so the data is always actionable, even at 8am with just 500 steps.
            if range == .today {
                let cal = Calendar.current
                let hour = cal.component(.hour, from: Date())
                let yesterdayStart = cal.startOfDay(for: cal.date(byAdding: .day, value: -1, to: Date()) ?? Date())
                let yesterdayEnd = cal.date(byAdding: .day, value: 1, to: yesterdayStart) ?? yesterdayStart
                let yesterdayData = allSummaries.filter {
                    $0.date >= yesterdayStart && $0.date < yesterdayEnd && $0.hasData
                }

                if let yd = yesterdayData.first, (yd.steps > 0 || yd.exerciseMinutes > 0) {
                    lines.append("")

                    // Yesterday comparison
                    var vsLines: [String] = ["📋 对比昨天全天："]
                    if yd.steps > 0 && totalSteps > 0 {
                        let pct = Int((totalSteps / yd.steps) * 100)
                        vsLines.append("   👟 昨天 \(Int(yd.steps).formatted()) 步 → 今天已 \(pct)%")
                    }
                    if yd.exerciseMinutes > 0 && totalExercise > 0 {
                        vsLines.append("   ⏱ 昨天 \(Int(yd.exerciseMinutes)) 分钟 → 今天已 \(Int(totalExercise)) 分钟")
                    }
                    if yd.activeCalories > 0 && totalCalories > 0 {
                        let pct = Int((totalCalories / yd.activeCalories) * 100)
                        vsLines.append("   🔥 昨天 \(Int(yd.activeCalories).formatted()) 千卡 → 今天已 \(pct)%")
                    }
                    if vsLines.count > 1 {
                        lines.append(contentsOf: vsLines)
                    }

                    // Pace projection: only meaningful before evening (6-22 hour range)
                    if hour >= 6 && hour < 22 && totalSteps > 100 {
                        let elapsed = Double(hour) + Double(cal.component(.minute, from: Date())) / 60.0
                        // Assume active hours are ~6am-11pm (17 hours)
                        let activeHoursTotal = 17.0
                        let activeHoursElapsed = max(elapsed - 6.0, 0.5)
                        let projectedSteps = totalSteps / activeHoursElapsed * activeHoursTotal

                        lines.append("")
                        if projectedSteps >= yd.steps * 1.1 {
                            lines.append("📈 按当前节奏，今天预计 ~\(Int(projectedSteps).formatted()) 步，有望超过昨天！")
                        } else if projectedSteps >= yd.steps * 0.8 {
                            lines.append("📊 按当前节奏，今天预计 ~\(Int(projectedSteps).formatted()) 步，和昨天差不多。")
                        } else {
                            let gap = Int(yd.steps - projectedSteps)
                            lines.append("💡 按当前节奏，今天预计 ~\(Int(projectedSteps).formatted()) 步。多走 \(gap.formatted()) 步可追上昨天。")
                        }
                    }
                }
            }

            // --- Day-by-Day Activity Chart ---
            // Visual overview of each day's exercise: shows steps + exercise minutes
            // with goal markers so the user can immediately spot active vs rest days.
            if daysWithData.count >= 3 {
                lines.append(contentsOf: self.buildDailyExerciseChart(daysWithData))
            }

            // Workout type breakdown (from HKWorkout sessions)
            let allWorkouts = filtered.flatMap { $0.workouts }
            if !allWorkouts.isEmpty {
                lines.append(contentsOf: workoutBreakdown(allWorkouts))

                // Training balance: check if exercise is too one-dimensional
                if allWorkouts.count >= 3 {
                    lines.append(contentsOf: self.trainingBalanceInsight(allWorkouts))
                }

                // Workout ↔ Location: show WHERE workouts happened
                lines.append(contentsOf: self.workoutLocationInsight(allWorkouts, context: context))
            }

            // Workout schedule pattern: time-of-day preference + rest day rhythm
            if allWorkouts.count >= 3 {
                lines.append(contentsOf: workoutSchedulePattern(allWorkouts, daysWithData: daysWithData))
            }

            // Best day highlight
            if daysWithData.count > 1 {
                if let bestDay = daysWithData.max(by: { $0.steps < $1.steps }), bestDay.steps > 0 {
                    let fmt = DateFormatter()
                    fmt.dateFormat = "M月d日(E)"
                    fmt.locale = Locale(identifier: "zh_CN")
                    lines.append("\n🏆 最活跃的一天：\(fmt.string(from: bestDay.date))")
                    lines.append("   \(Int(bestDay.steps).formatted()) 步 · \(Int(bestDay.exerciseMinutes)) 分钟运动")
                }
            }

            // Trend insight (compare first half vs second half of the period)
            if daysWithData.count >= 4 {
                let sorted = daysWithData.sorted { $0.date < $1.date }
                let mid = sorted.count / 2
                let olderAvg = sorted.prefix(mid).reduce(0) { $0 + $1.steps } / Double(mid)
                let recentAvg = sorted.suffix(from: mid).reduce(0) { $0 + $1.steps } / Double(sorted.count - mid)

                if olderAvg > 0 {
                    let changePercent = ((recentAvg - olderAvg) / olderAvg) * 100
                    if abs(changePercent) >= 10 {
                        let trend = changePercent > 0
                            ? "📈 步数呈上升趋势（+\(Int(changePercent))%），保持这个势头！"
                            : "📉 步数略有下降（\(Int(changePercent))%），试试每天多走一站路？"
                        lines.append("\n\(trend)")
                    } else {
                        lines.append("\n📊 步数保持稳定，节奏不错！")
                    }
                }
            }

            // --- Calendar ↔ Exercise correlation ---
            // Cross-reference calendar events to explain WHY certain days had more/less activity.
            // This is a core iosclaw insight: connecting different iOS data sources about the user.
            if daysWithData.count >= 3 {
                lines.append(contentsOf: self.calendarExerciseCorrelation(
                    summaries: daysWithData, interval: interval, context: context))
            }

            // Related life events
            if !events.isEmpty {
                lines.append("\n📝 相关记录：")
                events.prefix(5).forEach { lines.append("• \($0.timestamp.shortDisplay)：\($0.title)") }
            }

            completion(lines.joined(separator: "\n"))
        }
    }

    // MARK: - Day-by-Day Exercise Chart

    /// Builds a compact day-by-day exercise visualization for multi-day exercise queries.
    /// Combines steps + exercise minutes into a visual bar per day, with goal markers
    /// and rest-day detection, so the user immediately sees their activity rhythm.
    private func buildDailyExerciseChart(_ days: [HealthSummary]) -> [String] {
        let sorted = days.sorted { $0.date < $1.date }
        guard sorted.count >= 3 else { return [] }

        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "E"
        dayFmt.locale = Locale(identifier: "zh_CN")

        let maxExercise = sorted.map(\.exerciseMinutes).max() ?? 1
        let maxSteps = sorted.map(\.steps).max() ?? 1
        // Use exercise minutes as primary bar metric; fall back to steps if no exercise data
        let hasExerciseData = maxExercise >= 5
        var restDayCount = 0

        var lines: [String] = ["", "📅 每日运动节奏"]

        for day in sorted {
            let dayLabel = dayFmt.string(from: day.date)
            let ex = day.exerciseMinutes
            let steps = day.steps

            // Determine bar length (0-8 blocks)
            let barLen: Int
            if hasExerciseData {
                barLen = maxExercise > 0 ? max(0, min(8, Int(ex / maxExercise * 8))) : 0
            } else {
                barLen = maxSteps > 0 ? max(0, min(8, Int(steps / maxSteps * 8))) : 0
            }

            // Rest day detection: <5 min exercise AND <3000 steps
            let isRestDay = ex < 5 && steps < 3000

            // Goal markers: exercise ≥30min AND steps ≥8000
            let stepGoal = steps >= 8000
            let exerciseGoal = ex >= 30
            let goalMark: String
            if stepGoal && exerciseGoal {
                goalMark = "🏅" // both goals met
            } else if stepGoal || exerciseGoal {
                goalMark = "✅" // one goal met
            } else if isRestDay {
                goalMark = "💤"
                restDayCount += 1
            } else {
                goalMark = "  "
            }

            let bar = barLen > 0
                ? String(repeating: "▓", count: barLen) + String(repeating: "░", count: 8 - barLen)
                : String(repeating: "░", count: 8)

            // Show both exercise min and steps compactly
            var detail = ""
            if ex >= 1 {
                detail += "\(Int(ex))min"
                if steps >= 1000 {
                    detail += " · \(Int(steps / 1000))k步"
                }
            } else if steps > 0 {
                detail += "\(Int(steps).formatted())步"
            } else {
                detail += "无数据"
            }

            lines.append("   \(dayLabel) \(bar) \(detail) \(goalMark)")
        }

        // Summary: active days ratio + rest day insight
        let activeDays = sorted.filter { $0.exerciseMinutes >= 15 || $0.steps >= 5000 }.count
        let totalDays = sorted.count
        if restDayCount > 0 && activeDays > 0 {
            let ratio = "\(activeDays)天活跃 · \(restDayCount)天休息"
            if restDayCount >= 1 && restDayCount <= 2 && totalDays >= 5 {
                lines.append("   ✅ \(ratio) — 运动与恢复的节奏不错")
            } else if restDayCount == 0 {
                lines.append("   ⚠️ 连续 \(totalDays) 天都在运动，记得安排休息日")
            } else if restDayCount > totalDays / 2 {
                lines.append("   💡 \(ratio) — 试试增加运动频率到每周 3-4 天")
            } else {
                lines.append("   📊 \(ratio)")
            }
        }

        return lines
    }

    // MARK: - Training Balance Insight

    /// Analyzes workout type diversity and provides training balance feedback.
    /// Detects over-reliance on a single exercise type and suggests complementary activities.
    private func trainingBalanceInsight(_ workouts: [WorkoutRecord]) -> [String] {
        // Group by broad category
        let byType = Dictionary(grouping: workouts) { $0.activityType }
        guard byType.count >= 1 else { return [] }

        let total = workouts.count
        let totalDuration = workouts.reduce(0) { $0 + $1.duration }
        guard totalDuration > 0 else { return [] }

        // Find dominant type
        let dominantEntry = byType.max(by: { $0.value.reduce(0) { $0 + $1.duration } < $1.value.reduce(0) { $0 + $1.duration } })!
        let dominantDuration = dominantEntry.value.reduce(0) { $0 + $1.duration }
        let dominantPct = dominantDuration / totalDuration * 100

        // Categorize all workout types into broad groups
        // Cardio: running(37), cycling(13), swimming(46), walking(52), hiking(24), elliptical(57), stairStepper(40)
        // Strength: traditionalStrengthTraining(50), functionalStrengthTraining(20), coreTraining(1)
        // Flexibility: yoga(3014), pilates(3021), flexibility(3041)
        // HIIT/Functional: highIntensityIntervalTraining(63), crossTraining(3015), mixedCardio(3033)
        let cardioTypes: Set<UInt> = [37, 13, 46, 52, 24, 57, 40, 3033]
        let strengthTypes: Set<UInt> = [50, 20, 1, 3015]
        let flexibilityTypes: Set<UInt> = [3014, 3021, 3041]

        var cardioMin = 0.0, strengthMin = 0.0, flexMin = 0.0
        for w in workouts {
            let mins = w.duration / 60
            if cardioTypes.contains(w.activityType) {
                cardioMin += mins
            } else if strengthTypes.contains(w.activityType) {
                strengthMin += mins
            } else if flexibilityTypes.contains(w.activityType) {
                flexMin += mins
            }
        }
        let totalCategorized = cardioMin + strengthMin + flexMin
        guard totalCategorized > 10 else { return [] } // Need meaningful data

        var lines: [String] = []

        // Only provide balance insight if we have enough variety context
        if byType.count == 1 && total >= 3 {
            // All sessions are the same type
            let typeName = dominantEntry.value.first?.typeName ?? "运动"
            lines.append("")
            lines.append("🔄 训练多样性")
            lines.append("   所有 \(total) 次运动都是\(typeName)")
            if cardioTypes.contains(dominantEntry.key) {
                lines.append("   💡 加入力量训练（如举铁、核心训练）可以更全面地提升体能")
            } else if strengthTypes.contains(dominantEntry.key) {
                lines.append("   💡 配合有氧运动（如跑步、骑行）有助于心肺健康")
            }
        } else if dominantPct >= 80 && byType.count >= 2 && total >= 4 {
            // One type dominates 80%+ duration
            let typeName = dominantEntry.value.first?.typeName ?? "运动"
            lines.append("")
            lines.append("🔄 训练多样性")
            lines.append("   \(typeName)占了 \(Int(dominantPct))% 的运动时间")
            if strengthMin < totalCategorized * 0.1 && cardioMin > 0 {
                lines.append("   💡 有氧为主，适当增加力量训练（每周 1-2 次）提升综合体能")
            } else if cardioMin < totalCategorized * 0.1 && strengthMin > 0 {
                lines.append("   💡 力量为主，适当增加有氧运动保护心血管健康")
            }
        } else if byType.count >= 3 {
            // Good variety — acknowledge it
            let typeNames = Array(Set(workouts.map { $0.typeName })).prefix(4)
            lines.append("")
            lines.append("🔄 训练多样性")
            lines.append("   涵盖 \(typeNames.joined(separator: "、")) 等 \(byType.count) 种运动")
            // Check balance across cardio/strength/flexibility
            if cardioMin > 0 && strengthMin > 0 {
                lines.append("   ✅ 有氧 + 力量搭配合理，训练比较全面")
            }
            if flexMin > 0 {
                lines.append("   🧘 有柔韧性训练，注重恢复很好")
            }
        }

        return lines
    }

    // MARK: - Last Workout Occurrence

    /// Answers "when was my last workout" queries by scanning the last 90 days of HKWorkout data.
    /// Optionally filtered to a specific workout type (e.g., "上次跑步是什么时候").
    private func respondLastWorkout(filter: String?, context: SkillContext, completion: @escaping (String) -> Void) {
        guard context.healthService.isHealthDataAvailable else {
            completion("此设备不支持 HealthKit（如 iPad）。\n需要在 iPhone 上使用才能获取运动数据。")
            return
        }

        context.healthService.fetchRecentWorkouts(days: 90) { allWorkouts in
            // Sort newest-first
            let sorted = allWorkouts.sorted { $0.startDate > $1.startDate }

            // Apply workout type filter if specified
            let workouts: [WorkoutRecord]
            let filterName: String
            if let filter = filter {
                let typeIDs = SkillRouter.workoutFilterTypeIDs(filter)
                workouts = sorted.filter { typeIDs.contains($0.activityType) }
                filterName = workouts.first?.typeName ?? filter
            } else {
                workouts = sorted
                filterName = "运动"
            }

            guard let latest = workouts.first else {
                let noDataMsg: String
                if filter != nil {
                    noDataMsg = "在最近 90 天内没有找到「\(filterName)」的记录。\n\n可能原因：\n• 这段时间没有做过该类型运动\n• HealthKit 权限未开启\n• 运动时未佩戴 Apple Watch\n\n试试问我「上次运动是什么时候」看看其他类型？"
                } else {
                    noDataMsg = "在最近 90 天内没有找到任何运动记录。\n\n请前往「设置 → iosclaw → 健康」确认权限已开启，并确保运动时佩戴 Apple Watch。"
                }
                completion(noDataMsg)
                return
            }

            let cal = Calendar.current
            let now = Date()
            let daysAgo = cal.dateComponents([.day], from: cal.startOfDay(for: latest.startDate),
                                              to: cal.startOfDay(for: now)).day ?? 0

            var lines: [String] = []

            // Header with days-ago context
            if daysAgo == 0 {
                lines.append("🏃 上次\(filterName)就在今天！\n")
            } else if daysAgo == 1 {
                lines.append("🏃 上次\(filterName)是昨天\n")
            } else {
                lines.append("🏃 上次\(filterName)是 \(daysAgo) 天前\n")
            }

            // Date and time
            let df = DateFormatter()
            df.locale = Locale(identifier: "zh_CN")
            df.dateFormat = "M月d日 EEEE HH:mm"
            lines.append("📅 \(df.string(from: latest.startDate))")

            // Workout details
            lines.append("\(latest.typeEmoji) 类型：\(latest.typeName)")
            let mins = Int(latest.duration / 60)
            if mins >= 60 {
                lines.append("⏱ 时长：\(mins / 60)小时\(mins % 60)分钟")
            } else {
                lines.append("⏱ 时长：\(mins)分钟")
            }
            if latest.totalCalories >= 10 {
                lines.append("🔥 消耗：\(Int(latest.totalCalories)) 千卡")
            }
            let distanceTypes: [UInt] = [37, 52, 13, 46, 26] // run, walk, cycle, swim, hike
            if distanceTypes.contains(latest.activityType) && latest.totalDistance > 100 {
                let km = latest.totalDistance / 1000
                var distLine = "📏 距离：\(String(format: "%.2f", km)) 公里"
                // Pace for running/walking
                if (latest.activityType == 37 || latest.activityType == 52) && km > 0.1 {
                    let paceMinPerKm = (latest.duration / 60) / km
                    if paceMinPerKm > 0 && paceMinPerKm < 30 {
                        let paceMin = Int(paceMinPerKm)
                        let paceSec = Int((paceMinPerKm - Double(paceMin)) * 60)
                        distLine += "（配速 \(paceMin)'\(String(format: "%02d", paceSec))\"）"
                    }
                }
                lines.append(distLine)
            }

            // Days-ago insight
            if daysAgo >= 7 {
                lines.append("\n⚠️ 已经 \(daysAgo) 天没有\(filterName)了，建议尽快恢复运动习惯！")
            } else if daysAgo >= 3 {
                lines.append("\n💡 距离上次已经 \(daysAgo) 天，今天安排一次\(filterName)吧？")
            } else if daysAgo <= 1 {
                lines.append("\n✅ 运动习惯保持得很好！")
            }

            // Recent frequency context (how many sessions in last 30 days)
            let thirtyDaysAgo = cal.date(byAdding: .day, value: -30, to: now)!
            let recentCount = workouts.filter { $0.startDate >= thirtyDaysAgo }.count
            if recentCount > 1 {
                let avgInterval = 30.0 / Double(recentCount)
                lines.append("\n📊 最近 30 天共 \(recentCount) 次\(filterName)，平均每 \(String(format: "%.0f", avgInterval)) 天一次")

                // Show variety if asking about general exercise
                if filter == nil {
                    let recentWorkouts = workouts.filter { $0.startDate >= thirtyDaysAgo }
                    let types = Set(recentWorkouts.map { $0.typeName })
                    if types.count > 1 {
                        lines.append("🏋️ 运动类型：\(types.joined(separator: "、"))")
                    }
                }
            }

            completion(lines.joined(separator: "\n"))
        }
    }

    // MARK: - Workout Breakdown

    /// Builds a workout type breakdown section from HKWorkout sessions.
    /// Groups by activity type, shows duration/calories/distance per type, and highlights patterns.
    private func workoutBreakdown(_ workouts: [WorkoutRecord]) -> [String] {
        var lines: [String] = ["\n🏋️ 运动类型明细"]

        // Group workouts by type
        var byType: [UInt: [WorkoutRecord]] = [:]
        for w in workouts {
            byType[w.activityType, default: []].append(w)
        }

        // Sort by total duration (most time spent first)
        let sorted = byType.sorted { a, b in
            let durA = a.value.reduce(0) { $0 + $1.duration }
            let durB = b.value.reduce(0) { $0 + $1.duration }
            return durA > durB
        }

        let totalDuration = workouts.reduce(0) { $0 + $1.duration }

        for (typeID, records) in sorted {
            let sample = records[0]
            let count = records.count
            let dur = records.reduce(0) { $0 + $1.duration }
            let cal = records.reduce(0) { $0 + $1.totalCalories }
            let dist = records.reduce(0) { $0 + $1.totalDistance }
            let pct = totalDuration > 0 ? Int(dur / totalDuration * 100) : 0

            var detail = "\(sample.typeEmoji) \(sample.typeName)：\(count)次"
            // Duration
            let mins = Int(dur / 60)
            if mins >= 60 {
                detail += " · \(mins / 60)h\(mins % 60)m"
            } else {
                detail += " · \(mins)分钟"
            }
            // Calories (only if significant)
            if cal >= 10 {
                detail += " · \(Int(cal))千卡"
            }
            // Distance (only for distance-based activities)
            let distanceTypes: [UInt] = [37, 52, 13, 46, 26] // run, walk, cycle, swim, hike
            if distanceTypes.contains(typeID) && dist > 100 {
                let km = dist / 1000
                detail += " · \(String(format: "%.1f", km))km"
                // Average pace for running/walking
                if (typeID == 37 || typeID == 52) && km > 0.1 && dur > 0 {
                    let paceMinPerKm = (dur / 60) / km
                    if paceMinPerKm > 0 && paceMinPerKm < 30 {
                        let paceMin = Int(paceMinPerKm)
                        let paceSec = Int((paceMinPerKm - Double(paceMin)) * 60)
                        detail += "（配速 \(paceMin)'\(String(format: "%02d", paceSec))\"）"
                    }
                }
            }
            // Proportion if multiple types
            if sorted.count > 1 {
                detail += "（\(pct)%）"
            }
            lines.append(detail)
        }

        // Workout frequency insight
        if workouts.count >= 3 {
            let uniqueDays = Set(workouts.map { Calendar.current.startOfDay(for: $0.startDate) }).count
            let typeCount = byType.count
            if typeCount >= 3 {
                lines.append("🌈 运动种类丰富（\(typeCount)种），交叉训练有助于全面提升！")
            } else if typeCount == 1 {
                let name = workouts[0].typeName
                lines.append("💡 这段时间只做了\(name)，可以尝试搭配其他类型运动来均衡发展。")
            }
            if uniqueDays >= 5 {
                lines.append("🔥 \(uniqueDays)天有运动记录，运动习惯非常棒！")
            }
        }

        return lines
    }

    // MARK: - Workout ↔ Location Correlation

    /// Cross-references workout sessions with CDLocationRecord to show WHERE each workout happened.
    /// e.g., "📍 运动地点：跑步 → 奥林匹克公园，瑜伽 → 家附近"
    /// This connects HealthKit workout data with CoreLocation — a core iosclaw cross-data insight.
    private func workoutLocationInsight(_ workouts: [WorkoutRecord], context: SkillContext) -> [String] {
        guard !workouts.isEmpty else { return [] }

        // Expand the time window to cover all workouts, with padding for location records
        // that may have been recorded slightly before/after the workout session.
        let sortedByTime = workouts.sorted { $0.startDate < $1.startDate }
        let windowStart = Calendar.current.date(byAdding: .minute, value: -15, to: sortedByTime.first!.startDate) ?? sortedByTime.first!.startDate
        let windowEnd = Calendar.current.date(byAdding: .minute, value: 15, to: sortedByTime.last!.endDate) ?? sortedByTime.last!.endDate
        let locationRecords = CDLocationRecord.fetch(from: windowStart, to: windowEnd, in: context.coreDataContext)

        guard !locationRecords.isEmpty else { return [] }

        // Match each workout to the nearest location record within its time window (±15 min)
        struct WorkoutPlace {
            let workout: WorkoutRecord
            let placeName: String
        }

        var matched: [WorkoutPlace] = []

        for workout in sortedByTime {
            let wStart = workout.startDate.addingTimeInterval(-15 * 60)
            let wEnd = workout.endDate.addingTimeInterval(15 * 60)

            // Find all location records within the workout window
            let nearby = locationRecords.filter { $0.timestamp >= wStart && $0.timestamp <= wEnd }
            guard !nearby.isEmpty else { continue }

            // Pick the record closest to the workout midpoint for best accuracy
            let midpoint = workout.startDate.addingTimeInterval(workout.duration / 2)
            let closest = nearby.min(by: {
                abs($0.timestamp.timeIntervalSince(midpoint)) < abs($1.timestamp.timeIntervalSince(midpoint))
            })!

            let name = !closest.placeName.isEmpty ? closest.placeName : closest.address
            guard !name.isEmpty else { continue }

            matched.append(WorkoutPlace(workout: workout, placeName: name))
        }

        guard !matched.isEmpty else { return [] }

        // Deduplicate: group by workout type + place
        struct TypePlace: Hashable {
            let typeName: String
            let typeEmoji: String
            let placeName: String
        }
        var typePlaceCounts: [TypePlace: Int] = [:]
        for m in matched {
            let key = TypePlace(typeName: m.workout.typeName, typeEmoji: m.workout.typeEmoji, placeName: m.placeName)
            typePlaceCounts[key, default: 0] += 1
        }

        // Build output: compact format for single workout, detailed for multiple
        var lines: [String] = ["\n📍 运动地点"]
        let sortedPlaces = typePlaceCounts.sorted { $0.value > $1.value }
        for (tp, count) in sortedPlaces.prefix(5) {
            if count > 1 {
                lines.append("  \(tp.typeEmoji) \(tp.typeName) → \(tp.placeName)（\(count)次）")
            } else {
                lines.append("  \(tp.typeEmoji) \(tp.typeName) → \(tp.placeName)")
            }
        }

        // Insight: identify home gym vs outdoor vs varied locations
        let uniquePlaces = Set(matched.map { $0.placeName })
        if uniquePlaces.count == 1 && matched.count >= 3 {
            lines.append("  💡 运动地点很固定，说明你有稳定的运动场所 👍")
        } else if uniquePlaces.count >= 3 {
            lines.append("  🌍 运动地点丰富（\(uniquePlaces.count)处），尝试不同环境有助于保持新鲜感！")
        }

        return lines
    }

    // MARK: - Calendar ↔ Exercise Correlation

    /// Cross-references calendar events with exercise data to explain activity patterns.
    /// e.g., "周三步数最低(2000步)，当天有4个连续会议" — the kind of self-knowledge
    /// insight that only a personal AI with access to multiple iOS data sources can provide.
    private func calendarExerciseCorrelation(summaries: [HealthSummary],
                                             interval: DateInterval,
                                             context: SkillContext) -> [String] {
        let calEvents = context.calendarService.fetchEvents(from: interval.start, to: interval.end)
        guard !calEvents.isEmpty else { return [] }

        let cal = Calendar.current

        // Build per-day event counts (non-all-day events only — all-day events don't block movement)
        var eventsByDay: [Date: Int] = [:]
        var meetingMinutesByDay: [Date: Double] = [:]
        for event in calEvents where !event.isAllDay {
            let dayStart = cal.startOfDay(for: event.startDate)
            eventsByDay[dayStart, default: 0] += 1
            meetingMinutesByDay[dayStart, default: 0] += event.duration / 60
        }

        // Pair each health summary day with its calendar load
        struct DayPair {
            let date: Date
            let steps: Double
            let exerciseMinutes: Double
            let eventCount: Int
            let meetingMinutes: Double
        }
        let paired: [DayPair] = summaries.map { s in
            let dayStart = cal.startOfDay(for: s.date)
            return DayPair(
                date: dayStart,
                steps: s.steps,
                exerciseMinutes: s.exerciseMinutes,
                eventCount: eventsByDay[dayStart] ?? 0,
                meetingMinutes: meetingMinutesByDay[dayStart] ?? 0
            )
        }

        // Need variance in both calendar load and activity to find meaningful correlation
        let eventCounts = paired.map(\.eventCount)
        let hasCalendarVariance = Set(eventCounts).count >= 2
        guard hasCalendarVariance else { return [] }

        var lines: [String] = []

        // Split into busy vs light days using median event count as threshold
        let sortedCounts = eventCounts.sorted()
        let medianEvents = sortedCounts[sortedCounts.count / 2]
        let threshold = max(medianEvents, 2) // at least 2 events to be "busy"

        let busyDays = paired.filter { $0.eventCount >= threshold }
        let lightDays = paired.filter { $0.eventCount < threshold }

        guard !busyDays.isEmpty && !lightDays.isEmpty else { return [] }

        let busyAvgSteps = busyDays.reduce(0) { $0 + $1.steps } / Double(busyDays.count)
        let lightAvgSteps = lightDays.reduce(0) { $0 + $1.steps } / Double(lightDays.count)
        let stepsDiff = lightAvgSteps - busyAvgSteps

        // Only show if the difference is meaningful (>20% or >1500 steps)
        guard lightAvgSteps > 0 && (abs(stepsDiff) / lightAvgSteps > 0.2 || abs(stepsDiff) > 1500) else {
            return []
        }

        lines.append("")
        lines.append("📅↔️🏃 日程与运动的关联")

        let fmt = DateFormatter()
        fmt.dateFormat = "E"
        fmt.locale = Locale(identifier: "zh_CN")

        if stepsDiff > 0 {
            // Light days have more steps (typical pattern)
            lines.append("   会议较多的日子（≥\(threshold)个）日均 \(Int(busyAvgSteps).formatted()) 步")
            lines.append("   空闲日日均 \(Int(lightAvgSteps).formatted()) 步（多 \(Int(stepsDiff).formatted()) 步）")

            // Identify the worst day specifically
            if let worstDay = busyDays.max(by: { $0.steps > $1.steps || ($0.steps == $1.steps && $0.eventCount < $1.eventCount) }) {
                if worstDay.eventCount >= 3 {
                    let meetingHours = worstDay.meetingMinutes / 60
                    if meetingHours >= 2 {
                        lines.append("   📌 \(fmt.string(from: worstDay.date))最少活动（\(Int(worstDay.steps).formatted()) 步），当天 \(worstDay.eventCount) 个日程共 \(String(format: "%.1f", meetingHours))h")
                    } else {
                        lines.append("   📌 \(fmt.string(from: worstDay.date))最少活动（\(Int(worstDay.steps).formatted()) 步），当天有 \(worstDay.eventCount) 个日程")
                    }
                }
            }

            // Actionable advice
            if busyAvgSteps < 5000 {
                lines.append("   💡 会议密集日可以：会间散步 5 分钟、步行去开会、站立办公。")
            } else {
                lines.append("   💡 忙碌日也保持了一定活动量，不过空闲日更充分。")
            }
        } else {
            // Busy days have more steps (unusual — commuting to meetings?)
            lines.append("   有趣：会议多的日子反而多走了 \(Int(-stepsDiff).formatted()) 步")
            lines.append("   可能与赶场开会、外出见面有关。")

            // Check if busy days also have more exercise
            let busyAvgExercise = busyDays.reduce(0) { $0 + $1.exerciseMinutes } / Double(busyDays.count)
            let lightAvgExercise = lightDays.reduce(0) { $0 + $1.exerciseMinutes } / Double(lightDays.count)
            if busyAvgExercise > lightAvgExercise + 10 {
                lines.append("   ✅ 忙碌时运动量反而更高，保持这个节奏！")
            }
        }

        return lines
    }

    // MARK: - Workout-Type-Specific Response

    /// When the user asks about a specific workout (e.g., "跑步了多少"), give a focused, rich response
    /// for that activity type with type-appropriate metrics (pace for running, speed for cycling, etc.)
    private func respondWorkoutType(filter: String, range: QueryTimeRange, context: SkillContext, completion: @escaping (String) -> Void) {
        let interval = range.interval
        let fetchDays = fetchDaysNeeded(for: range)
        let typeIDs = SkillRouter.workoutFilterTypeIDs(filter)

        context.healthService.fetchSummaries(days: fetchDays) { allSummaries in
            let filtered = allSummaries.filter { interval.contains($0.date) }
            let allWorkouts = filtered.flatMap { $0.workouts }
            let targetWorkouts = allWorkouts.filter { typeIDs.contains($0.activityType) }

            // Determine display name from first matched workout, or from filter keyword
            let typeName = targetWorkouts.first?.typeName ?? self.filterDisplayName(filter)
            let typeEmoji = targetWorkouts.first?.typeEmoji ?? "🏅"

            var lines: [String] = ["\(typeEmoji) \(range.label)的\(typeName)数据\n"]

            guard !targetWorkouts.isEmpty else {
                // No workouts of this type found
                if !context.healthService.isHealthDataAvailable {
                    lines.append("此设备不支持 HealthKit（如 iPad）。")
                } else if allWorkouts.isEmpty {
                    lines.append("\(range.label)没有任何运动记录。请确认已在「设置 → iosclaw → 健康」开启权限。")
                } else {
                    // Has other workouts but not this type
                    lines.append("\(range.label)没有\(typeName)记录。")
                    // Show what types were actually done
                    let otherTypes = Set(allWorkouts.map { $0.typeName })
                    if !otherTypes.isEmpty {
                        lines.append("不过有其他运动：\(otherTypes.joined(separator: "、"))")
                        lines.append("\n💡 试试问我「\(range.label)运动了多少」查看全部运动数据。")
                    }
                }
                completion(lines.joined(separator: "\n"))
                return
            }

            // --- Core stats ---
            let totalSessions = targetWorkouts.count
            let totalDuration = targetWorkouts.reduce(0) { $0 + $1.duration }
            let totalCalories = targetWorkouts.reduce(0) { $0 + $1.totalCalories }
            let totalDistance = targetWorkouts.reduce(0) { $0 + $1.totalDistance }
            let avgDuration = totalDuration / Double(totalSessions)
            let uniqueDays = Set(targetWorkouts.map { Calendar.current.startOfDay(for: $0.startDate) }).count

            lines.append("📊 共 \(totalSessions) 次\(typeName)，\(uniqueDays) 天有记录")

            // Duration
            let totalMins = Int(totalDuration / 60)
            if totalMins >= 60 {
                lines.append("⏱ 总时长：\(totalMins / 60)h\(totalMins % 60)m（场均 \(Int(avgDuration / 60))分钟）")
            } else {
                lines.append("⏱ 总时长：\(totalMins)分钟（场均 \(Int(avgDuration / 60))分钟）")
            }

            // Calories
            if totalCalories >= 10 {
                lines.append("🔥 消耗热量：\(Int(totalCalories)) 千卡（场均 \(Int(totalCalories / Double(totalSessions)))）")
            }

            // Distance-based metrics (running, walking, cycling, swimming, hiking)
            let distanceTypes = ["running", "walking", "cycling", "swimming", "hiking"]
            if distanceTypes.contains(filter) && totalDistance > 100 {
                let km = totalDistance / 1000
                lines.append("📏 总距离：\(String(format: "%.1f", km)) 公里")

                // Per-session distance
                if totalSessions > 1 {
                    let avgKm = km / Double(totalSessions)
                    lines.append("   场均距离：\(String(format: "%.1f", avgKm)) 公里")
                }

                // Pace for running/walking
                if (filter == "running" || filter == "walking") && km > 0.1 && totalDuration > 0 {
                    // Show per-session pace breakdown
                    lines.append("")
                    lines.append("⚡ 配速详情")
                    let sortedByDate = targetWorkouts.sorted { $0.startDate < $1.startDate }
                    let fmt = DateFormatter()
                    fmt.dateFormat = "M/d"
                    for w in sortedByDate {
                        let wKm = w.totalDistance / 1000
                        guard wKm > 0.1 && w.duration > 0 else { continue }
                        let paceMinPerKm = (w.duration / 60) / wKm
                        guard paceMinPerKm > 0 && paceMinPerKm < 30 else { continue }
                        let paceMin = Int(paceMinPerKm)
                        let paceSec = Int((paceMinPerKm - Double(paceMin)) * 60)
                        let wMins = Int(w.duration / 60)
                        lines.append("  \(fmt.string(from: w.startDate))  \(String(format: "%.1f", wKm))km · \(paceMin)'\(String(format: "%02d", paceSec))\" · \(wMins)min")
                    }

                    // Average pace
                    let avgPace = (totalDuration / 60) / km
                    if avgPace > 0 && avgPace < 30 {
                        let avgPaceMin = Int(avgPace)
                        let avgPaceSec = Int((avgPace - Double(avgPaceMin)) * 60)
                        lines.append("  📐 平均配速：\(avgPaceMin)'\(String(format: "%02d", avgPaceSec))\"/km")
                    }

                    // Pace trend (if 2+ sessions with valid pace)
                    let paces: [(Date, Double)] = sortedByDate.compactMap { w in
                        let wKm = w.totalDistance / 1000
                        guard wKm > 0.1 && w.duration > 0 else { return nil }
                        let pace = (w.duration / 60) / wKm
                        guard pace > 0 && pace < 30 else { return nil }
                        return (w.startDate, pace)
                    }
                    if paces.count >= 2 {
                        let firstPace = paces.first!.1
                        let lastPace = paces.last!.1
                        let diff = firstPace - lastPace  // lower pace = faster
                        if abs(diff) > 0.2 {
                            if diff > 0 {
                                lines.append("  📈 配速在进步！从 \(Self.formatPace(firstPace)) 提升到 \(Self.formatPace(lastPace))")
                            } else {
                                lines.append("  📉 配速略有放缓（\(Self.formatPace(firstPace)) → \(Self.formatPace(lastPace))），注意恢复和节奏。")
                            }
                        }
                    }
                }

                // Speed for cycling
                if filter == "cycling" && km > 0.1 && totalDuration > 0 {
                    let avgSpeedKmh = km / (totalDuration / 3600)
                    lines.append("💨 平均速度：\(String(format: "%.1f", avgSpeedKmh)) km/h")
                    // Best session by speed
                    if totalSessions > 1 {
                        let bestSession = targetWorkouts
                            .filter { $0.totalDistance > 100 && $0.duration > 0 }
                            .max { ($0.totalDistance / $0.duration) < ($1.totalDistance / $1.duration) }
                        if let best = bestSession {
                            let bestSpeed = (best.totalDistance / 1000) / (best.duration / 3600)
                            let fmt = DateFormatter()
                            fmt.dateFormat = "M月d日"
                            lines.append("🏆 最快一次：\(fmt.string(from: best.startDate)) \(String(format: "%.1f", bestSpeed)) km/h")
                        }
                    }
                }
            }

            // Best session (by calories or duration)
            if totalSessions > 1 {
                if let bestByCal = targetWorkouts.max(by: { $0.totalCalories < $1.totalCalories }),
                   bestByCal.totalCalories > 10 {
                    let fmt = DateFormatter()
                    fmt.dateFormat = "M月d日"
                    lines.append("\n🏆 最高消耗：\(fmt.string(from: bestByCal.startDate)) \(Int(bestByCal.totalCalories))千卡 · \(bestByCal.durationFormatted)")
                }
            }

            // Time-of-day pattern
            let hourCounts = self.workoutTimeDistribution(targetWorkouts)
            if let (period, count) = hourCounts.max(by: { $0.value < $1.value }), count > 1 {
                lines.append("\n⏰ 你通常在\(period)\(typeName)（\(count)次）")
            }

            // Frequency insight
            if uniqueDays > 1 {
                let spanDays = max(1, Calendar.current.dateComponents([.day],
                    from: targetWorkouts.map(\.startDate).min()!,
                    to: targetWorkouts.map(\.startDate).max()!).day ?? 1)
                if spanDays >= 3 {
                    let freqDays = Double(spanDays) / Double(totalSessions)
                    if freqDays <= 2 {
                        lines.append("📅 平均每 \(String(format: "%.0f", freqDays)) 天\(typeName)一次，频率很高！")
                    } else {
                        lines.append("📅 平均约 \(String(format: "%.0f", freqDays)) 天\(typeName)一次")
                    }
                }
            }

            // Workout ↔ Location: show WHERE this workout type happens
            lines.append(contentsOf: self.workoutLocationInsight(targetWorkouts, context: context))

            // Context: also mention overall exercise if there are other types
            let otherWorkouts = allWorkouts.filter { !typeIDs.contains($0.activityType) }
            if !otherWorkouts.isEmpty {
                let otherTypes = Set(otherWorkouts.map { $0.typeName }).prefix(3)
                lines.append("\n💡 \(range.label)还有其他运动：\(otherTypes.joined(separator: "、"))。问我「\(range.label)运动了多少」查看全部。")
            }

            completion(lines.joined(separator: "\n"))
        }
    }

    /// Formats a pace value (minutes per km) as "X'YY\"" string.
    private static func formatPace(_ paceMinPerKm: Double) -> String {
        let paceMin = Int(paceMinPerKm)
        let paceSec = Int((paceMinPerKm - Double(paceMin)) * 60)
        return "\(paceMin)'\(String(format: "%02d", paceSec))\""
    }

    /// Returns display name for a workout filter when no actual workout record is available.
    private func filterDisplayName(_ filter: String) -> String {
        switch filter {
        case "running": return "跑步"
        case "cycling": return "骑行"
        case "swimming": return "游泳"
        case "yoga": return "瑜伽"
        case "walking": return "步行"
        case "hiking": return "徒步"
        case "hiit": return "高强度间歇"
        case "strength": return "力量训练"
        case "core": return "核心训练"
        case "pilates": return "普拉提"
        case "boxing": return "搏击"
        case "jumpRope": return "跳绳"
        case "basketball": return "篮球"
        case "soccer": return "足球"
        case "tennis": return "网球"
        case "badminton": return "羽毛球"
        case "tableTennis": return "乒乓球"
        case "elliptical": return "椭圆机"
        case "rowing": return "划船机"
        case "climbing": return "攀岩"
        case "skiing": return "滑雪"
        case "dance": return "舞蹈"
        case "mindAndBody": return "冥想"
        case "taiChi": return "太极"
        default: return "运动"
        }
    }

    /// Analyzes workout sessions by time-of-day, returns {period: count} for the most common periods.
    private func workoutTimeDistribution(_ workouts: [WorkoutRecord]) -> [String: Int] {
        var dist: [String: Int] = [:]
        for w in workouts {
            let hour = Calendar.current.component(.hour, from: w.startDate)
            let period: String
            switch hour {
            case 5..<9:   period = "清晨"
            case 9..<12:  period = "上午"
            case 12..<14: period = "午间"
            case 14..<17: period = "下午"
            case 17..<20: period = "傍晚"
            case 20..<23: period = "晚上"
            default:       period = "深夜"
            }
            dist[period, default: 0] += 1
        }
        return dist
    }

    /// Analyzes workout schedule patterns for multi-day exercise responses:
    /// 1. Preferred time-of-day (morning exerciser vs evening exerciser?)
    /// 2. Rest-day rhythm and consistency (every other day? irregular?)
    /// These personal exercise habit insights help users understand their own patterns.
    private func workoutSchedulePattern(_ workouts: [WorkoutRecord], daysWithData: [HealthSummary]) -> [String] {
        var lines: [String] = []
        let cal = Calendar.current

        // --- Time-of-day distribution ---
        let timeDist = workoutTimeDistribution(workouts)
        let totalSessions = workouts.count

        if timeDist.count >= 2 {
            let sorted = timeDist.sorted { $0.value > $1.value }
            if let top = sorted.first {
                let topPct = top.value * 100 / totalSessions
                if topPct >= 50 {
                    var timeLine = "\n⏰ 你习惯在\(top.key)运动（\(top.value)次，\(topPct)%）"
                    // Mention secondary preference if notable
                    if sorted.count >= 2, sorted[1].value >= 2 {
                        timeLine += "，偶尔\(sorted[1].key)"
                    }
                    lines.append(timeLine)
                } else {
                    // No dominant period — spread across the day
                    let desc = sorted.prefix(3).map { "\($0.key)\($0.value)次" }.joined(separator: " · ")
                    lines.append("\n⏰ 运动时间较分散：\(desc)")
                }
            }
        } else if let only = timeDist.first, totalSessions >= 2 {
            lines.append("\n⏰ 运动都在\(only.key)，你是\(only.key)运动者 💪")
        }

        // --- Rest-day rhythm: analyze workout/rest day alternation pattern ---
        let workoutDays = Set(workouts.map { cal.startOfDay(for: $0.startDate) }).sorted()
        if workoutDays.count >= 3 {
            var gaps: [Int] = []
            for i in 0..<(workoutDays.count - 1) {
                if let daysBetween = cal.dateComponents([.day], from: workoutDays[i], to: workoutDays[i + 1]).day, daysBetween > 0 {
                    gaps.append(daysBetween)
                }
            }

            if !gaps.isEmpty {
                let avgGap = Double(gaps.reduce(0, +)) / Double(gaps.count)
                let totalDays = max(daysWithData.count, 1)
                let activeDays = workoutDays.count
                let restDays = max(0, totalDays - activeDays)

                if avgGap <= 1.2 {
                    lines.append("📅 几乎每天运动（\(activeDays)/\(totalDays) 天），频率很高！适当安排休息日有助于恢复。")
                } else if avgGap <= 2.0 {
                    lines.append("📅 \(activeDays) 天运动 · \(restDays) 天休息 — 接近隔天运动的节奏，很均衡 ✅")
                } else if avgGap <= 3.5 {
                    lines.append("📅 平均每 \(String(format: "%.0f", avgGap)) 天运动一次，频率适中。")
                } else {
                    lines.append("📅 运动间隔较长（平均 \(String(format: "%.0f", avgGap)) 天），试着在日历中预留固定运动时间。")
                }

                // Consistency check: is the interval between workouts regular?
                if gaps.count >= 3 {
                    let mean = avgGap
                    let variance = gaps.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) } / Double(gaps.count)
                    let stdDev = sqrt(variance)
                    if stdDev < 0.5 {
                        lines.append("   ✅ 运动间隔非常规律，已形成稳定的锻炼节奏。")
                    } else if stdDev >= 1.5 {
                        lines.append("   💡 运动间隔不太规律（有时连续运动，有时停几天），固定每周运动日更易坚持。")
                    }
                }
            }
        }

        return lines
    }

    // MARK: - Health Metric

    private func respondHealth(metric: String, range: QueryTimeRange, context: SkillContext, completion: @escaping (String) -> Void) {
        let baseFetchDays = fetchDaysNeeded(for: range)
        // Always fetch at least 8 days so individual metric handlers (steps, calories, etc.)
        // can show personal baseline comparison even for single-day queries like "今天步数".
        // For the general overview, fetch 2x the range for previous-period comparison.
        let isOverview = (metric == "general")
        let spanDays = max(1, Calendar.current.dateComponents([.day], from: range.interval.start, to: range.interval.end).day ?? 1)
        let fetchDays = isOverview ? baseFetchDays + spanDays : max(baseFetchDays, 8)
        context.healthService.fetchSummaries(days: fetchDays) { allSummaries in
            let interval = range.interval
            let filtered = allSummaries.filter { interval.contains($0.date) }
            let withData = filtered.filter { $0.hasData }

            // Weight has its own empty-state handling (fetches 30 days independently)
            if metric == "weight" {
                self.respondWeight(summaries: withData, range: range, context: context, completion: completion)
                return
            }

            guard !withData.isEmpty else {
                if !context.healthService.isHealthDataAvailable {
                    completion("📊 此设备不支持 HealthKit。\n需要在 iPhone 上使用才能获取健康数据。")
                } else {
                    var msg = "📊 \(range.label)暂无健康数据。\n请前往「设置 → iosclaw → 健康」确认已开启权限。"
                    if range == .today {
                        msg += "\n\n💡 也可以试试「昨天健康怎么样」查看已有数据。"
                    }
                    completion(msg)
                }
                return
            }

            switch metric {
            case "sleep":
                self.respondSleep(summaries: withData, range: range, context: context, completion: completion)
            case "heartRate":
                self.respondHeartRate(summaries: withData, allSummaries: allSummaries, range: range, completion: completion)
            case "hrv":
                self.respondHRV(summaries: withData, allSummaries: allSummaries, range: range, completion: completion)
            case "steps":
                self.respondSteps(summaries: withData, allSummaries: allSummaries, range: range, completion: completion)
            case "flights":
                self.respondFlights(summaries: withData, allSummaries: allSummaries, range: range, completion: completion)
            case "distance":
                self.respondDistance(summaries: withData, allSummaries: allSummaries, range: range, completion: completion)
            case "calories":
                self.respondCalories(summaries: withData, allSummaries: allSummaries, range: range, completion: completion)
            case "weight":
                self.respondWeight(summaries: withData, range: range, context: context, completion: completion)
            case "recovery":
                self.respondRecovery(summaries: allSummaries, todaySummaries: withData, range: range, context: context, completion: completion)
            case "bloodOxygen":
                self.respondBloodOxygen(summaries: withData, range: range, completion: completion)
            case "vo2max":
                self.respondVO2Max(summaries: withData, range: range, completion: completion)
            default:
                // Overview: pass all fetched summaries so we can compute previous-period comparison
                self.respondOverview(summaries: withData, allSummaries: allSummaries, range: range, context: context, completion: completion)
            }
        }
    }

    private func respondSleep(summaries: [HealthSummary], range: QueryTimeRange, context: SkillContext, completion: @escaping (String) -> Void) {
        let sleepDays = summaries.filter { $0.sleepHours > 0 }
        guard !sleepDays.isEmpty else {
            completion("😴 \(range.label)暂无睡眠记录。\n请确保 iPhone 或 Apple Watch 的睡眠追踪已开启。")
            return
        }

        var lines: [String] = ["😴 \(range.label)的睡眠分析\n"]
        let avg = sleepDays.reduce(0) { $0 + $1.sleepHours } / Double(sleepDays.count)
        let maxSleep = sleepDays.max(by: { $0.sleepHours < $1.sleepHours })!
        let minSleep = sleepDays.min(by: { $0.sleepHours < $1.sleepHours })!

        // --- Sleep Quality Score (composite 0-100) with per-dimension breakdown ---
        let scoreResult = computeSleepQualityScore(sleepDays: sleepDays, avgHours: avg)
        let qualityScore = scoreResult.total
        let scoreEmoji: String
        if qualityScore >= 85 { scoreEmoji = "🌟" }
        else if qualityScore >= 70 { scoreEmoji = "✅" }
        else if qualityScore >= 50 { scoreEmoji = "💡" }
        else { scoreEmoji = "⚠️" }
        lines.append("\(scoreEmoji) 睡眠质量评分：\(qualityScore) / 100")
        lines.append(sleepScoreDimensionBar(scoreResult))
        lines.append(sleepScoreTargetedAdvice(scoreResult))
        lines.append("")

        lines.append("💤 平均睡眠：\(String(format: "%.1f", avg)) 小时")
        lines.append("📊 波动范围：\(String(format: "%.1f", minSleep.sleepHours))~\(String(format: "%.1f", maxSleep.sleepHours)) 小时")

        if sleepDays.count > 1 {
            let fmt = DateFormatter()
            fmt.dateFormat = "E"
            fmt.locale = Locale(identifier: "zh_CN")
            lines.append("🌙 睡最久：\(fmt.string(from: maxSleep.date))（\(String(format: "%.1f", maxSleep.sleepHours))h）")
            lines.append("⏰ 睡最少：\(fmt.string(from: minSleep.date))（\(String(format: "%.1f", minSleep.sleepHours))h）")
        }

        // --- Sleep Efficiency (time asleep / time in bed) ---
        let bedDays = sleepDays.filter { $0.inBedHours > 0 }
        if !bedDays.isEmpty {
            let avgInBed = bedDays.reduce(0) { $0 + $1.inBedHours } / Double(bedDays.count)
            let avgAsleep = bedDays.reduce(0) { $0 + $1.sleepHours } / Double(bedDays.count)
            // HealthKit's .inBed can represent either:
            // 1. Total bed time (Apple Watch) — sleep stages are subsets, so inBed >= sleep
            // 2. Only awake-in-bed time (some third-party apps) — inBed < sleep
            let totalBedTime = avgInBed >= avgAsleep ? avgInBed : avgInBed + avgAsleep
            if totalBedTime > 0 {
                let efficiency = (avgAsleep / totalBedTime) * 100
                lines.append("")
                lines.append("🛏️ 睡眠效率：\(Int(efficiency))%")
                lines.append("   在床时间 \(String(format: "%.1f", totalBedTime))h → 实际入睡 \(String(format: "%.1f", avgAsleep))h")
                if efficiency >= 90 {
                    lines.append("   ✅ 优秀！几乎躺下就能入睡。")
                } else if efficiency >= 85 {
                    lines.append("   ✅ 良好，入睡效率正常。")
                } else if efficiency >= 75 {
                    lines.append("   💡 效率偏低，平均需 \(Int((totalBedTime - avgAsleep) * 60)) 分钟才入睡或有夜间清醒。")
                    lines.append("   建议：困了再上床，避免在床上看手机。")
                } else {
                    lines.append("   ⚠️ 效率较低，在床上有较多清醒时间。")
                    lines.append("   这可能与入睡困难或夜间频繁醒来有关。")
                    lines.append("   建议：固定起床时间、睡前 1 小时避免蓝光。")
                }
            }
        }

        // --- Sleep Consistency (standard deviation) ---
        if sleepDays.count >= 3 {
            let sleepValues = sleepDays.map { $0.sleepHours }
            let stdDev = standardDeviation(of: sleepValues)
            lines.append("")
            lines.append("📐 睡眠规律性")
            if stdDev < 0.5 {
                lines.append("   ✅ 非常规律（波动 ±\(Int(stdDev * 60)) 分钟），生物钟很稳定。")
            } else if stdDev < 1.0 {
                lines.append("   💡 较规律（波动 ±\(Int(stdDev * 60)) 分钟），可以更稳定。")
            } else {
                lines.append("   ⚠️ 波动较大（±\(String(format: "%.1f", stdDev))h），睡眠时间不太规律。")
                lines.append("   不规律的作息比睡眠不足更伤身体，试着固定上床和起床时间。")
            }
        }

        // --- Day-by-Day Trend Chart ---
        if sleepDays.count >= 3 {
            let sorted = sleepDays.sorted { $0.date < $1.date }
            lines.append("")
            lines.append("📈 逐日趋势")
            let dayFmt = DateFormatter()
            dayFmt.dateFormat = "E"
            dayFmt.locale = Locale(identifier: "zh_CN")
            for day in sorted {
                let bar = sleepTrendBar(hours: day.sleepHours)
                let label = dayFmt.string(from: day.date)
                lines.append("   \(label) \(bar) \(String(format: "%.1f", day.sleepHours))h")
            }
        }

        // Sleep phase breakdown (requires Apple Watch data)
        let phaseDays = sleepDays.filter { $0.hasSleepPhases }
        if !phaseDays.isEmpty {
            let avgDeep = phaseDays.reduce(0) { $0 + $1.sleepDeepHours } / Double(phaseDays.count)
            let avgREM = phaseDays.reduce(0) { $0 + $1.sleepREMHours } / Double(phaseDays.count)
            let avgCore = phaseDays.reduce(0) { $0 + $1.sleepCoreHours } / Double(phaseDays.count)
            let avgPhaseTotal = avgDeep + avgREM + avgCore

            lines.append("\n🧠 睡眠阶段分析")

            // Show phase durations with percentage bars
            if avgPhaseTotal > 0 {
                let deepPct = avgDeep / avgPhaseTotal * 100
                let remPct = avgREM / avgPhaseTotal * 100
                let corePct = avgCore / avgPhaseTotal * 100

                lines.append("🟣 深睡眠：\(String(format: "%.1f", avgDeep))h（\(Int(deepPct))%）\(phaseBar(pct: deepPct))")
                lines.append("🔵 REM 睡眠：\(String(format: "%.1f", avgREM))h（\(Int(remPct))%）\(phaseBar(pct: remPct))")
                lines.append("⚪ 核心睡眠：\(String(format: "%.1f", avgCore))h（\(Int(corePct))%）\(phaseBar(pct: corePct))")

                // Sleep quality insights based on phase ratios
                lines.append("")
                lines.append(contentsOf: sleepPhaseInsights(deepPct: deepPct, remPct: remPct, avgDeep: avgDeep, avgREM: avgREM))
            }

            // Phase consistency across days (only if multiple days)
            if phaseDays.count >= 3 {
                let deepValues = phaseDays.map { $0.sleepDeepHours }
                let deepVariation = coefficient(of: deepValues)
                if deepVariation > 0.4 {
                    lines.append("📉 深睡眠波动较大，尽量保持固定的睡眠时间有助于稳定。")
                } else if deepVariation < 0.2 {
                    lines.append("📊 深睡眠非常稳定，说明你的睡眠节律很好。")
                }
            }
        }

        // --- Sleep Debt ---
        if sleepDays.count >= 3 {
            let targetHours = 7.5 // midpoint of healthy 7-9h range
            let totalDebt = sleepDays.reduce(0.0) { $0 + max(0, targetHours - $1.sleepHours) }
            if totalDebt >= 2 {
                lines.append("")
                lines.append("💸 睡眠债务：累计欠 \(String(format: "%.1f", totalDebt)) 小时")
                if totalDebt >= 7 {
                    lines.append("   相当于欠了一整晚！周末补觉效果有限，建议每晚多睡 30 分钟逐渐偿还。")
                } else if totalDebt >= 3 {
                    lines.append("   连续几天多睡 30 分钟就能补回来。")
                } else {
                    lines.append("   轻微不足，今晚早睡一点就好。")
                }
            }
        }

        // Personalized insight based on total duration
        let goodDays = sleepDays.filter { $0.sleepHours >= 7 && $0.sleepHours <= 9 }.count
        let goodRate = Double(goodDays) / Double(sleepDays.count) * 100

        lines.append("")
        if goodRate >= 80 {
            lines.append("✅ \(Int(goodRate))% 的夜晚在 7-9 小时的健康范围内，睡眠习惯很棒！")
        } else if goodRate >= 50 {
            lines.append("💡 \(Int(goodRate))% 的夜晚在健康范围（7-9h），还有提升空间。")
            if avg < 7 {
                lines.append("建议尝试提前 \(Int((7 - avg) * 60)) 分钟上床。")
            }
        } else {
            lines.append("⚠️ 仅 \(Int(goodRate))% 的夜晚在健康范围内。")
            if avg < 6 {
                lines.append("长期睡眠不足 6 小时会影响注意力和免疫力，试着调整作息吧。")
            } else if avg > 9 {
                lines.append("睡眠过多可能反而影响精力，试试固定起床时间。")
            }
        }

        // --- Cross-metric: Sleep ↔ Recovery Correlation ---
        // Correlate sleep quality with HRV and resting heart rate to show
        // how sleep physically affects the body's recovery state.
        if sleepDays.count >= 3 {
            let pairedHRV = summaries.filter { $0.sleepHours > 0 && $0.hrv > 0 }
            let pairedRHR = summaries.filter { $0.sleepHours > 0 && $0.restingHeartRate > 0 }

            var correlationInsights: [String] = []

            // HRV vs sleep: split into good-sleep (≥7h) and poor-sleep (<7h) nights
            if pairedHRV.count >= 3 {
                let medianSleep = pairedHRV.map(\.sleepHours).sorted()[pairedHRV.count / 2]
                let wellSlept = pairedHRV.filter { $0.sleepHours >= medianSleep }
                let poorSlept = pairedHRV.filter { $0.sleepHours < medianSleep }

                if !wellSlept.isEmpty && !poorSlept.isEmpty {
                    let hrvOnGood = wellSlept.reduce(0) { $0 + $1.hrv } / Double(wellSlept.count)
                    let hrvOnPoor = poorSlept.reduce(0) { $0 + $1.hrv } / Double(poorSlept.count)
                    let diff = hrvOnGood - hrvOnPoor

                    if abs(diff) >= 3 {
                        if diff > 0 {
                            correlationInsights.append("📳 睡够的夜晚 HRV 平均高 \(Int(diff)) ms — 充足睡眠显著提升了你的自主神经恢复能力。")
                        } else {
                            correlationInsights.append("📳 睡得少的夜晚 HRV 反而高 \(Int(-diff)) ms — 可能与运动疲劳导致的深度补偿性恢复有关。")
                        }
                    }
                }
            }

            // Resting HR vs sleep: lower resting HR on well-rested days = better recovery
            if pairedRHR.count >= 3 {
                let medianSleep = pairedRHR.map(\.sleepHours).sorted()[pairedRHR.count / 2]
                let wellSlept = pairedRHR.filter { $0.sleepHours >= medianSleep }
                let poorSlept = pairedRHR.filter { $0.sleepHours < medianSleep }

                if !wellSlept.isEmpty && !poorSlept.isEmpty {
                    let rhrOnGood = wellSlept.reduce(0) { $0 + $1.restingHeartRate } / Double(wellSlept.count)
                    let rhrOnPoor = poorSlept.reduce(0) { $0 + $1.restingHeartRate } / Double(poorSlept.count)
                    let diff = rhrOnPoor - rhrOnGood // positive means poor sleep → higher RHR

                    if abs(diff) >= 2 {
                        if diff > 0 {
                            correlationInsights.append("🫀 睡眠不足时静息心率平均高 \(Int(diff)) BPM — 睡不好时心脏负担更重。")
                        } else {
                            correlationInsights.append("🫀 睡眠充足时静息心率反而偏高 \(Int(-diff)) BPM — 可能与运动日睡更久有关。")
                        }
                    }
                }
            }

            // Deep sleep phase vs HRV: deep sleep is the primary physical recovery window
            let pairedDeepHRV = summaries.filter { $0.hasSleepPhases && $0.hrv > 0 }
            if pairedDeepHRV.count >= 3 {
                let medianDeep = pairedDeepHRV.map(\.sleepDeepHours).sorted()[pairedDeepHRV.count / 2]
                let highDeep = pairedDeepHRV.filter { $0.sleepDeepHours >= medianDeep }
                let lowDeep = pairedDeepHRV.filter { $0.sleepDeepHours < medianDeep }

                if !highDeep.isEmpty && !lowDeep.isEmpty {
                    let hrvHighDeep = highDeep.reduce(0) { $0 + $1.hrv } / Double(highDeep.count)
                    let hrvLowDeep = lowDeep.reduce(0) { $0 + $1.hrv } / Double(lowDeep.count)
                    let diff = hrvHighDeep - hrvLowDeep

                    if diff >= 4 {
                        correlationInsights.append("🟣 深睡眠充足时 HRV 高 \(Int(diff)) ms — 深睡眠是身体物理修复的关键窗口。")
                    }
                }
            }

            if !correlationInsights.isEmpty {
                lines.append("")
                lines.append("🔗 睡眠与身体恢复的关联")
                lines.append(contentsOf: correlationInsights)

                // Actionable summary based on findings
                let hasPositiveCorrelation = correlationInsights.contains { $0.contains("显著提升") || $0.contains("心脏负担更重") || $0.contains("物理修复") }
                if hasPositiveCorrelation {
                    lines.append("")
                    lines.append("💡 你的身体数据证实：睡眠质量直接影响恢复状态。优先保障睡眠比多练一次效果更大。")
                }
            }
        }

        // --- Exercise ↔ Sleep Correlation ---
        // Show whether exercise days lead to better/worse sleep.
        let pairedExercise = summaries.filter { $0.sleepHours > 0 && $0.exerciseMinutes >= 0 }
        if pairedExercise.count >= 4 {
            let medianExercise = pairedExercise.map(\.exerciseMinutes).sorted()[pairedExercise.count / 2]
            let activeDays = pairedExercise.filter { $0.exerciseMinutes >= max(medianExercise, 15) }
            let restDays = pairedExercise.filter { $0.exerciseMinutes < max(medianExercise, 15) }

            if activeDays.count >= 2 && restDays.count >= 2 {
                let sleepOnActive = activeDays.reduce(0) { $0 + $1.sleepHours } / Double(activeDays.count)
                let sleepOnRest = restDays.reduce(0) { $0 + $1.sleepHours } / Double(restDays.count)
                let diff = sleepOnActive - sleepOnRest

                if abs(diff) >= 0.3 {
                    lines.append("")
                    lines.append("🏃↔️😴 运动与睡眠的关联")
                    if diff > 0 {
                        lines.append("   运动日平均睡 \(String(format: "%.1f", sleepOnActive))h，休息日 \(String(format: "%.1f", sleepOnRest))h")
                        lines.append("   ✅ 运动让你多睡了 \(String(format: "%.1f", diff)) 小时 — 坚持运动就是最好的助眠。")
                    } else {
                        lines.append("   运动日平均睡 \(String(format: "%.1f", sleepOnActive))h，休息日 \(String(format: "%.1f", sleepOnRest))h")
                        lines.append("   💡 运动日反而少睡 \(String(format: "%.1f", -diff))h — 试试把运动时间提前，避免睡前 2 小时剧烈运动。")
                    }
                }

                // Deep sleep on exercise vs rest days
                let activePhase = activeDays.filter { $0.hasSleepPhases }
                let restPhase = restDays.filter { $0.hasSleepPhases }
                if activePhase.count >= 2 && restPhase.count >= 2 {
                    let deepOnActive = activePhase.reduce(0) { $0 + $1.sleepDeepHours } / Double(activePhase.count)
                    let deepOnRest = restPhase.reduce(0) { $0 + $1.sleepDeepHours } / Double(restPhase.count)
                    let deepDiff = deepOnActive - deepOnRest
                    if deepDiff >= 0.2 {
                        lines.append("   🟣 运动日深睡眠多 \(String(format: "%.1f", deepDiff))h — 运动促进了身体的深度修复。")
                    }
                }
            }
        }

        // --- Weekday vs Weekend Sleep Pattern ---
        let cal = Calendar.current
        if sleepDays.count >= 5 {
            let weekdaySleep = sleepDays.filter { !cal.isDateInWeekend($0.date) }
            let weekendSleep = sleepDays.filter { cal.isDateInWeekend($0.date) }

            if weekdaySleep.count >= 2 && weekendSleep.count >= 1 {
                let wdAvg = weekdaySleep.reduce(0) { $0 + $1.sleepHours } / Double(weekdaySleep.count)
                let weAvg = weekendSleep.reduce(0) { $0 + $1.sleepHours } / Double(weekendSleep.count)
                let diff = weAvg - wdAvg

                if abs(diff) >= 0.4 {
                    lines.append("")
                    lines.append("🗓 工作日 vs 周末睡眠")
                    lines.append("   工作日均 \(String(format: "%.1f", wdAvg))h · 周末均 \(String(format: "%.1f", weAvg))h")
                    if diff > 0 {
                        let weeklyDebt = diff * Double(weekdaySleep.count)
                        lines.append("   📌 周末多睡 \(String(format: "%.1f", diff))h — 说明工作日累积了约 \(String(format: "%.0f", weeklyDebt))h 的睡眠债。")
                        if diff >= 1.5 {
                            lines.append("   ⚠️ 差异超过 1.5h，社交时差（social jet lag）会打乱生物钟。")
                            lines.append("   建议工作日至少保证 \(String(format: "%.0f", wdAvg + 0.5))h 睡眠。")
                        }
                    } else {
                        lines.append("   💡 周末反而少睡 \(String(format: "%.1f", -diff))h — 周末活动较多，注意不要透支。")
                    }
                }
            }
        }

        // --- Sleep Timing & Circadian Rhythm ---
        // Surface bedtime/wake time patterns from HealthKit sleep samples.
        // Consistent timing is more important than duration for long-term health.
        let timingDays = sleepDays.filter { $0.sleepOnset != nil && $0.wakeTime != nil }
        if !timingDays.isEmpty {
            let timeFmt = DateFormatter()
            timeFmt.dateFormat = "HH:mm"

            if timingDays.count == 1, let day = timingDays.first,
               let onset = day.sleepOnset, let wake = day.wakeTime {
                // Single day: just show the times
                lines.append("")
                lines.append("🕐 作息时间")
                lines.append("   入睡 \(timeFmt.string(from: onset)) → 醒来 \(timeFmt.string(from: wake))")
                let onsetHour = cal.component(.hour, from: onset)
                if onsetHour >= 0 && onsetHour < 6 {
                    lines.append("   ⚠️ 凌晨才入睡，即使时长够，也会错过深睡眠的最佳窗口（22:00-02:00）。")
                } else if onsetHour >= 22 && onsetHour < 24 || onsetHour >= 0 && onsetHour < 1 {
                    lines.append("   ✅ 入睡时间在理想窗口内。")
                }
            } else if timingDays.count >= 2 {
                // Multi-day: compute average onset/wake + consistency
                // Convert onset times to "minutes since midnight" for averaging
                // Sleep onset often crosses midnight, so normalize to 18:00 as base
                // (anything >= 18h stays as-is, < 18h add 24h to treat as next day)
                let onsetMinutes: [Double] = timingDays.compactMap { day in
                    guard let onset = day.sleepOnset else { return nil }
                    let h = Double(cal.component(.hour, from: onset))
                    let m = Double(cal.component(.minute, from: onset))
                    let raw = h * 60 + m
                    return raw < 18 * 60 ? raw + 24 * 60 : raw // normalize past-midnight onsets
                }
                let wakeMinutes: [Double] = timingDays.compactMap { day in
                    guard let wake = day.wakeTime else { return nil }
                    let h = Double(cal.component(.hour, from: wake))
                    let m = Double(cal.component(.minute, from: wake))
                    return h * 60 + m
                }

                if !onsetMinutes.isEmpty && !wakeMinutes.isEmpty {
                    let avgOnsetMins = onsetMinutes.reduce(0, +) / Double(onsetMinutes.count)
                    let avgWakeMins = wakeMinutes.reduce(0, +) / Double(wakeMinutes.count)

                    // Format average onset (may be > 1440 if past midnight)
                    let normalizedOnset = avgOnsetMins.truncatingRemainder(dividingBy: 1440)
                    let onsetH = Int(normalizedOnset) / 60
                    let onsetM = Int(normalizedOnset) % 60
                    let wakeH = Int(avgWakeMins) / 60
                    let wakeM = Int(avgWakeMins) % 60

                    lines.append("")
                    lines.append("🕐 作息时间")
                    lines.append("   平均入睡 \(String(format: "%02d:%02d", onsetH, onsetM)) → 平均醒来 \(String(format: "%02d:%02d", wakeH, wakeM))")

                    // Late sleeper warning
                    if normalizedOnset >= 0 * 60 && normalizedOnset < 6 * 60 {
                        lines.append("   ⚠️ 平均凌晨才入睡，深睡眠的黄金窗口（22:00-02:00）被压缩。")
                        lines.append("   建议每周提前 15 分钟入睡，逐步调整到 23:00 前。")
                    } else if normalizedOnset >= 22 * 60 && normalizedOnset < 23.5 * 60 {
                        lines.append("   ✅ 平均入睡时间在理想窗口（22:00-23:30），有利于深睡眠。")
                    } else if normalizedOnset >= 23.5 * 60 {
                        lines.append("   💡 接近午夜入睡，可以尝试再提前 30 分钟。")
                    }

                    // Circadian consistency: bedtime regularity
                    if onsetMinutes.count >= 3 {
                        let onsetStdDev = standardDeviation(of: onsetMinutes) // in minutes
                        let wakeStdDev = standardDeviation(of: wakeMinutes)

                        lines.append("")
                        lines.append("⏱ 作息规律性")
                        if onsetStdDev < 30 {
                            lines.append("   🌙 入睡时间波动 ±\(Int(onsetStdDev)) 分钟 ✅ 非常规律")
                        } else if onsetStdDev < 60 {
                            lines.append("   🌙 入睡时间波动 ±\(Int(onsetStdDev)) 分钟 — 较规律，继续保持")
                        } else {
                            lines.append("   🌙 入睡时间波动 ±\(Int(onsetStdDev)) 分钟 ⚠️ 不太规律")
                            lines.append("   作息不规律相当于每天经历「时差」，比睡眠不足更伤身体。")
                        }
                        if wakeStdDev < 30 {
                            lines.append("   ☀️ 起床时间波动 ±\(Int(wakeStdDev)) 分钟 ✅ 非常规律")
                        } else if wakeStdDev < 60 {
                            lines.append("   ☀️ 起床时间波动 ±\(Int(wakeStdDev)) 分钟 — 较规律")
                        } else {
                            lines.append("   ☀️ 起床时间波动 ±\(Int(wakeStdDev)) 分钟 ⚠️ 不太规律")
                            lines.append("   💡 即使睡眠时间不同，固定起床时间是稳定生物钟最有效的方法。")
                        }

                        // Social jet lag: weekday vs weekend onset difference
                        let wdOnsets = timingDays.filter { !cal.isDateInWeekend($0.date) }
                            .compactMap { day -> Double? in
                                guard let onset = day.sleepOnset else { return nil }
                                let h = Double(cal.component(.hour, from: onset))
                                let m = Double(cal.component(.minute, from: onset))
                                let raw = h * 60 + m
                                return raw < 18 * 60 ? raw + 24 * 60 : raw
                            }
                        let weOnsets = timingDays.filter { cal.isDateInWeekend($0.date) }
                            .compactMap { day -> Double? in
                                guard let onset = day.sleepOnset else { return nil }
                                let h = Double(cal.component(.hour, from: onset))
                                let m = Double(cal.component(.minute, from: onset))
                                let raw = h * 60 + m
                                return raw < 18 * 60 ? raw + 24 * 60 : raw
                            }
                        if wdOnsets.count >= 2 && weOnsets.count >= 1 {
                            let wdAvgOnset = wdOnsets.reduce(0, +) / Double(wdOnsets.count)
                            let weAvgOnset = weOnsets.reduce(0, +) / Double(weOnsets.count)
                            let jetLagMins = abs(weAvgOnset - wdAvgOnset)
                            if jetLagMins >= 60 {
                                lines.append("")
                                lines.append("🌀 社交时差：周末比工作日晚睡 \(Int(jetLagMins)) 分钟")
                                if jetLagMins >= 120 {
                                    lines.append("   ⚠️ 相当于每周经历 \(String(format: "%.1f", jetLagMins / 60)) 小时时差，影响周一状态。")
                                    lines.append("   研究表明社交时差 >2h 会增加代谢疾病风险。")
                                } else {
                                    lines.append("   💡 轻度时差，周末尽量不比工作日晚睡超过 1 小时。")
                                }
                            }
                        }
                    }

                    // --- Sleep Schedule Drift Detection ---
                    // Detect whether bedtime is progressively getting later or earlier
                    // over the measured period. Uses linear regression on onset/wake times
                    // sorted chronologically to find the daily shift rate.
                    if timingDays.count >= 3 {
                        let sorted = timingDays.sorted { $0.date < $1.date }

                        // Build chronological onset minutes (normalized for midnight crossing)
                        let chronoOnsets: [(dayIndex: Double, mins: Double)] = sorted.enumerated().compactMap { (i, day) in
                            guard let onset = day.sleepOnset else { return nil }
                            let h = Double(cal.component(.hour, from: onset))
                            let m = Double(cal.component(.minute, from: onset))
                            let raw = h * 60 + m
                            return (Double(i), raw < 18 * 60 ? raw + 24 * 60 : raw)
                        }
                        let chronoWakes: [(dayIndex: Double, mins: Double)] = sorted.enumerated().compactMap { (i, day) in
                            guard let wake = day.wakeTime else { return nil }
                            let h = Double(cal.component(.hour, from: wake))
                            let m = Double(cal.component(.minute, from: wake))
                            return (Double(i), h * 60 + m)
                        }

                        // Simple linear regression: slope = Σ((x-x̄)(y-ȳ)) / Σ((x-x̄)²)
                        func linearSlope(_ points: [(dayIndex: Double, mins: Double)]) -> Double? {
                            guard points.count >= 3 else { return nil }
                            let n = Double(points.count)
                            let xMean = points.reduce(0) { $0 + $1.dayIndex } / n
                            let yMean = points.reduce(0) { $0 + $1.mins } / n
                            let numerator = points.reduce(0) { $0 + ($1.dayIndex - xMean) * ($1.mins - yMean) }
                            let denominator = points.reduce(0) { $0 + ($1.dayIndex - xMean) * ($1.dayIndex - xMean) }
                            guard denominator > 0 else { return nil }
                            return numerator / denominator // minutes per day
                        }

                        let onsetSlope = linearSlope(chronoOnsets)
                        let wakeSlope = linearSlope(chronoWakes)

                        // Only report meaningful drift (>= 8 min/day shift over 3+ days)
                        let driftThreshold = 8.0
                        var hasDrift = false

                        if let slope = onsetSlope, abs(slope) >= driftThreshold {
                            hasDrift = true
                            lines.append("")
                            lines.append("📉 作息漂移趋势")
                            let totalShift = Int(abs(slope) * Double(chronoOnsets.count - 1))
                            if slope > 0 {
                                lines.append("   🌙 入睡时间在逐渐推迟（约每天晚 \(Int(slope)) 分钟）")
                                lines.append("   这 \(chronoOnsets.count) 天累计推迟了约 \(totalShift) 分钟")
                                if slope >= 20 {
                                    lines.append("   ⚠️ 漂移速度较快，如不干预一周后将再晚睡 \(Int(slope * 7 / 60)) 小时")
                                    lines.append("   建议：设定固定的「准备上床」闹钟，每晚提前 15 分钟开始放松")
                                } else {
                                    lines.append("   💡 轻度推迟，注意保持固定入睡时间，避免渐渐变成夜猫子")
                                }
                            } else {
                                lines.append("   🌙 入睡时间在逐渐提前（约每天早 \(Int(abs(slope))) 分钟）")
                                lines.append("   ✅ 这 \(chronoOnsets.count) 天累计提前了约 \(totalShift) 分钟，作息在改善！")
                            }
                        }

                        if let slope = wakeSlope, abs(slope) >= driftThreshold {
                            if !hasDrift {
                                lines.append("")
                                lines.append("📉 作息漂移趋势")
                            }
                            hasDrift = true
                            if slope > 0 {
                                lines.append("   ☀️ 起床时间在逐渐推迟（约每天晚 \(Int(slope)) 分钟）")
                            } else {
                                lines.append("   ☀️ 起床时间在逐渐提前（约每天早 \(Int(abs(slope))) 分钟）")
                            }
                        }

                        // Cross-check: if onset drifts later but wake stays → sleep getting shorter
                        if let os = onsetSlope, let ws = wakeSlope, hasDrift {
                            let durationSlope = ws - os // positive = sleeping longer, negative = shorter
                            if abs(durationSlope) >= 10 {
                                if durationSlope < 0 {
                                    lines.append("   ⚠️ 睡眠时长在缩短（每天减少约 \(Int(abs(durationSlope))) 分钟）")
                                    lines.append("   睡得越来越晚但起床时间没变 → 累积睡眠债")
                                } else {
                                    lines.append("   📊 睡眠时长在增加（每天增加约 \(Int(durationSlope)) 分钟）")
                                }
                            }
                        }

                        // Day-by-day timing chart (visual timeline of onset → wake)
                        if timingDays.count >= 3 {
                            lines.append("")
                            lines.append("🕰 逐日作息时间线")
                            let dayFmt = DateFormatter()
                            dayFmt.dateFormat = "E"
                            dayFmt.locale = Locale(identifier: "zh_CN")

                            for day in sorted {
                                guard let onset = day.sleepOnset, let wake = day.wakeTime else { continue }
                                let label = dayFmt.string(from: day.date)
                                let onsetStr = timeFmt.string(from: onset)
                                let wakeStr = timeFmt.string(from: wake)
                                let durationH = String(format: "%.1f", day.sleepHours)
                                lines.append("   \(label) 🌙\(onsetStr) → ☀️\(wakeStr)（\(durationH)h）")
                            }
                        }
                    }
                }
            }
        }

        // --- Calendar ↔ Sleep Correlation ---
        // Show whether busy days with many meetings lead to worse sleep.
        let interval = range.interval
        let calEvents = context.calendarService.fetchEvents(from: interval.start, to: interval.end)
        let timedEvents = calEvents.filter { !$0.isAllDay }
        if sleepDays.count >= 3 && !timedEvents.isEmpty {
            // Group events by day
            var eventsByDay: [Date: Int] = [:]
            for event in timedEvents {
                let dayStart = cal.startOfDay(for: event.startDate)
                eventsByDay[dayStart, default: 0] += 1
            }

            // Pair sleep data with event counts
            var busySleep: [Double] = []
            var lightSleep: [Double] = []
            let medianEvents = eventsByDay.values.sorted()[eventsByDay.count / 2]
            let threshold = max(medianEvents, 2)

            for day in sleepDays {
                let dayStart = cal.startOfDay(for: day.date)
                let count = eventsByDay[dayStart] ?? 0
                if count >= threshold {
                    busySleep.append(day.sleepHours)
                } else {
                    lightSleep.append(day.sleepHours)
                }
            }

            if busySleep.count >= 2 && lightSleep.count >= 2 {
                let busyAvg = busySleep.reduce(0, +) / Double(busySleep.count)
                let lightAvg = lightSleep.reduce(0, +) / Double(lightSleep.count)
                let diff = lightAvg - busyAvg

                if diff >= 0.3 {
                    lines.append("")
                    lines.append("📅↔️😴 日程与睡眠的关联")
                    lines.append("   会议多的日子（≥\(threshold)个）平均睡 \(String(format: "%.1f", busyAvg))h")
                    lines.append("   轻松的日子平均睡 \(String(format: "%.1f", lightAvg))h")
                    lines.append("   💡 忙碌日少睡 \(String(format: "%.1f", diff))h — 会议密集时更需要保护睡眠时间。")
                } else if diff <= -0.3 {
                    lines.append("")
                    lines.append("📅↔️😴 日程与睡眠的关联")
                    lines.append("   ✅ 即使忙碌日（≥\(threshold)个会议）也能保持 \(String(format: "%.1f", busyAvg))h 睡眠，时间管理很好！")
                }
            }
        }

        // --- Sleep → Next Day Activity Correlation ---
        // Pairs each night's sleep with the following day's step count
        // to reveal how sleep quality impacts daily performance.
        let sortedByDate = summaries.sorted { $0.date < $1.date }
        if sleepDays.count >= 4 && sortedByDate.count >= 3 {
            var goodSleepNextSteps: [Double] = []
            var poorSleepNextSteps: [Double] = []

            for i in 0..<(sortedByDate.count - 1) {
                let tonight = sortedByDate[i]
                let nextDay = sortedByDate[i + 1]
                // Verify consecutive calendar days
                guard tonight.sleepHours > 0,
                      nextDay.steps > 0,
                      let expectedNext = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: tonight.date)),
                      cal.isDate(nextDay.date, inSameDayAs: expectedNext)
                else { continue }

                if tonight.sleepHours >= 7.0 {
                    goodSleepNextSteps.append(nextDay.steps)
                } else if tonight.sleepHours < 6.0 {
                    poorSleepNextSteps.append(nextDay.steps)
                }
            }

            if goodSleepNextSteps.count >= 2 && poorSleepNextSteps.count >= 1 {
                let goodAvg = goodSleepNextSteps.reduce(0, +) / Double(goodSleepNextSteps.count)
                let poorAvg = poorSleepNextSteps.reduce(0, +) / Double(poorSleepNextSteps.count)
                if poorAvg > 0 {
                    let pctDiff = (goodAvg - poorAvg) / poorAvg * 100
                    if pctDiff >= 15 {
                        let stepDiff = Int(goodAvg - poorAvg)
                        lines.append("")
                        lines.append("😴→👟 睡眠对第二天的影响")
                        lines.append("   睡够 7h 后：次日均 \(Int(goodAvg).formatted()) 步")
                        lines.append("   不足 6h 后：次日均 \(Int(poorAvg).formatted()) 步")
                        lines.append("   📊 好睡眠让你第二天多走 \(stepDiff.formatted()) 步（+\(Int(pctDiff))%）")
                        lines.append("   💡 睡好是活力的基础 — 今晚早点休息，明天会更有精力。")
                    } else if pctDiff <= -20 {
                        lines.append("")
                        lines.append("😴→👟 睡眠对第二天的影响")
                        lines.append("   💡 睡不够 6h 后第二天步数反而更高 — 可能是补偿性奔波。")
                        lines.append("   ⚠️ 长期睡眠不足+高活动量容易导致身体透支，请注意休息。")
                    }
                }
            }
        }

        // --- Tonight's Sleep Recommendation (forward-looking calendar cross-data) ---
        // The ultimate iosclaw insight: connect past sleep data with tomorrow's schedule
        // to give a concrete, actionable bedtime recommendation.
        if range == .today || range == .yesterday || range == .lastWeek || range == .thisWeek {
            let tonightRec = buildTonightSleepRecommendation(
                sleepDays: sleepDays,
                context: context
            )
            if !tonightRec.isEmpty {
                lines.append("")
                lines.append(contentsOf: tonightRec)
            }
        }

        completion(lines.joined(separator: "\n"))
    }

    // MARK: - Tonight's Sleep Recommendation

    /// Builds a forward-looking bedtime recommendation by cross-referencing
    /// the user's personal sleep patterns with tomorrow's calendar events.
    /// Answers: "What time should I sleep tonight given my schedule tomorrow?"
    private func buildTonightSleepRecommendation(
        sleepDays: [HealthSummary],
        context: SkillContext
    ) -> [String] {
        guard context.calendarService.isAuthorized else { return [] }

        let cal = Calendar.current
        let now = Date()

        // Only show this in the evening or when today's sleep is being reviewed
        let currentHour = cal.component(.hour, from: now)

        // Fetch tomorrow's events
        let tomorrowStart = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
        let tomorrowEnd = cal.date(byAdding: .day, value: 1, to: tomorrowStart)!
        let tomorrowEvents = context.calendarService.fetchEvents(from: tomorrowStart, to: tomorrowEnd)
        let timedEvents = tomorrowEvents.filter { !$0.isAllDay }

        // Find the first timed event tomorrow
        let sortedEvents = timedEvents.sorted { $0.startDate < $1.startDate }
        let firstEvent = sortedEvents.first

        // Calculate personal sleep needs from recent data
        let targetSleep: Double
        if sleepDays.count >= 3 {
            let avgSleep = sleepDays.reduce(0) { $0 + $1.sleepHours } / Double(sleepDays.count)
            // Use personal average, clamped to 6.5-9h range
            targetSleep = min(max(avgSleep, 6.5), 9.0)
        } else {
            targetSleep = 7.5 // default recommendation
        }

        // Calculate the user's typical wake-before-first-meeting buffer
        // (how much time they usually have between waking and their first meeting)
        let wakeBuffer: Double = 45 // minutes — reasonable default for getting ready

        var lines: [String] = []
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"

        if let first = firstEvent {
            let firstMeetingHour = cal.component(.hour, from: first.startDate)
            let firstMeetingMin = cal.component(.minute, from: first.startDate)

            // Calculate recommended wake time: first meeting - buffer
            let wakeMinutes = Double(firstMeetingHour * 60 + firstMeetingMin) - wakeBuffer
            guard wakeMinutes > 0 else { return [] }

            // Calculate recommended bedtime: wake time - target sleep hours
            let bedtimeMinutes = wakeMinutes - targetSleep * 60
            guard bedtimeMinutes > 0 else { return [] }

            // Only show if the recommended bedtime is in a reasonable window (20:00 - 03:00)
            let normalizedBedtime = bedtimeMinutes.truncatingRemainder(dividingBy: 1440)
            guard normalizedBedtime >= 20 * 60 || normalizedBedtime < 3 * 60 else { return [] }

            let bedH = Int(normalizedBedtime) / 60
            let bedM = Int(normalizedBedtime) % 60
            let wakeH = Int(wakeMinutes) / 60
            let wakeM = Int(wakeMinutes) % 60

            lines.append("🌙 今晚睡眠建议")

            // Schedule context
            let meetingCount = timedEvents.count
            let totalMeetingMin = timedEvents.reduce(0.0) { $0 + $1.duration } / 60.0
            let isHeavyDay = meetingCount >= 4 || totalMeetingMin >= 240

            if isHeavyDay {
                lines.append("   📅 明天日程紧凑：\(meetingCount) 个安排，\(timeFmt.string(from: first.startDate)) 开始")
                lines.append("   💤 建议 \(String(format: "%02d:%02d", bedH, bedM)) 前入睡 → \(String(format: "%02d:%02d", wakeH, wakeM)) 起床")
                lines.append("   争取 \(String(format: "%.1f", targetSleep))h 以上睡眠，忙碌日需要更充沛的精力。")
            } else if meetingCount == 0 {
                // No timed events but might have all-day events
                if !tomorrowEvents.isEmpty {
                    lines.append("   📅 明天只有全天事件，没有定时安排")
                    lines.append("   💤 可以按自己的节奏安排作息，但规律入睡有助于保持生物钟稳定。")
                }
                // Don't show bedtime recommendation for fully free day
                return lines.isEmpty ? [] : lines
            } else {
                lines.append("   📅 明天有 \(meetingCount) 个安排，最早 \(timeFmt.string(from: first.startDate))「\(first.title)」")
                lines.append("   💤 建议 \(String(format: "%02d:%02d", bedH, bedM)) 前入睡 → \(String(format: "%02d:%02d", wakeH, wakeM)) 起床")
            }

            // Recent sleep debt warning: if recent sleep is consistently below target
            if sleepDays.count >= 3 {
                let recentAvg = sleepDays.prefix(3).reduce(0) { $0 + $1.sleepHours } / Double(min(sleepDays.count, 3))
                if recentAvg < 6.5 {
                    lines.append("   ⚠️ 最近几天均睡不足 6.5h，今晚尤其需要早点休息。")
                }
            }

            // If it's already late and we can calculate the gap
            if currentHour >= 21 {
                let nowMinutes = Double(currentHour * 60 + cal.component(.minute, from: now))
                let minutesUntilBed = normalizedBedtime - nowMinutes
                if minutesUntilBed > 0 && minutesUntilBed <= 120 {
                    lines.append("   ⏰ 距建议入睡时间还有 \(Int(minutesUntilBed)) 分钟，开始准备放松吧。")
                } else if minutesUntilBed <= 0 && minutesUntilBed > -60 {
                    lines.append("   ⏰ 已经超过建议入睡时间了，尽快休息吧！")
                }
            }
        } else if tomorrowEvents.isEmpty {
            // No events at all tomorrow — encourage maintaining rhythm
            if sleepDays.count >= 3 {
                let avgSleep = sleepDays.reduce(0) { $0 + $1.sleepHours } / Double(sleepDays.count)
                if avgSleep < 7 {
                    lines.append("🌙 今晚睡眠建议")
                    lines.append("   📅 明天暂无安排，适合补觉。")
                    lines.append("   💤 最近均睡 \(String(format: "%.1f", avgSleep))h，今晚争取达到 7h 以上。")
                    lines.append("   💡 但起床时间尽量不要比平时晚超过 1 小时，以免打乱生物钟。")
                }
            }
        }

        return lines
    }

    // MARK: - Sleep Quality Score

    /// Per-dimension breakdown of the sleep quality score (0-100).
    /// - Duration adequacy (30 pts): how close to the 7-9h ideal
    /// - Phase quality (25 pts): deep + REM ratios within healthy ranges
    /// - Consistency (25 pts): low variance in sleep duration across days
    /// - Efficiency (20 pts): time asleep vs time in bed
    private struct SleepScoreResult {
        let durationScore: Double   // out of 30
        let phaseScore: Double      // out of 25
        let consistencyScore: Double // out of 25
        let efficiencyScore: Double // out of 20
        let hasPhaseData: Bool
        let hasEfficiencyData: Bool
        let avgHours: Double
        let stdDev: Double          // sleep duration standard deviation
        let efficiencyPct: Double   // sleep efficiency as percentage (0-100)

        var total: Int {
            min(100, max(0, Int(durationScore + phaseScore + consistencyScore + efficiencyScore)))
        }

        /// Returns the weakest dimension (lowest score as fraction of its max).
        var weakestDimension: String {
            let dims: [(name: String, ratio: Double, available: Bool)] = [
                ("duration", durationScore / 30, true),
                ("phase", phaseScore / 25, hasPhaseData),
                ("consistency", consistencyScore / 25, true),
                ("efficiency", efficiencyScore / 20, hasEfficiencyData)
            ]
            // Only consider dimensions with real data
            let available = dims.filter { $0.available }
            return available.min(by: { $0.ratio < $1.ratio })?.name ?? "duration"
        }
    }

    private func computeSleepQualityScore(sleepDays: [HealthSummary], avgHours: Double) -> SleepScoreResult {
        // 1. Duration adequacy (30 pts) — peak at 7.5-8h
        var durationPts: Double = 0
        if avgHours >= 7 && avgHours <= 9 {
            durationPts = 30
        } else if avgHours >= 6 && avgHours < 7 {
            durationPts = 30 * (avgHours - 5) / 2   // 5h=0, 7h=30
        } else if avgHours > 9 && avgHours <= 10 {
            durationPts = 30 * (10 - avgHours)       // 9h=30, 10h=0
        } else if avgHours >= 5 {
            durationPts = 10
        }
        // below 5h or above 10h = 0 pts

        // 2. Phase quality (25 pts)
        var phasePts: Double = 0
        var hasPhaseData = false
        let phaseDays = sleepDays.filter { $0.hasSleepPhases }
        if !phaseDays.isEmpty {
            hasPhaseData = true
            let avgDeep = phaseDays.reduce(0) { $0 + $1.sleepDeepHours } / Double(phaseDays.count)
            let avgREM = phaseDays.reduce(0) { $0 + $1.sleepREMHours } / Double(phaseDays.count)
            let avgCore = phaseDays.reduce(0) { $0 + $1.sleepCoreHours } / Double(phaseDays.count)
            let total = avgDeep + avgREM + avgCore
            if total > 0 {
                let deepPct = avgDeep / total * 100
                let remPct = avgREM / total * 100
                // Deep: ideal 15-25%, REM: ideal 20-25%
                let deepScore = deepPct >= 15 && deepPct <= 25 ? 12.5 : max(0, 12.5 - abs(deepPct - 20) * 0.8)
                let remScore = remPct >= 20 && remPct <= 25 ? 12.5 : max(0, 12.5 - abs(remPct - 22.5) * 0.8)
                phasePts = deepScore + remScore
            }
        } else {
            // No phase data — give neutral mid-range score
            phasePts = 12.5
        }

        // 3. Consistency (25 pts) — low standard deviation = high score
        var consistencyPts: Double = 0
        var stdDev: Double = 0
        if sleepDays.count >= 3 {
            stdDev = standardDeviation(of: sleepDays.map { $0.sleepHours })
            if stdDev < 0.3 { consistencyPts = 25 }
            else if stdDev < 0.5 { consistencyPts = 22 }
            else if stdDev < 1.0 { consistencyPts = 15 }
            else if stdDev < 1.5 { consistencyPts = 8 }
            else { consistencyPts = 3 }
        } else {
            consistencyPts = 15 // not enough data to judge consistency
        }

        // 4. Efficiency (20 pts)
        var efficiencyPts: Double = 0
        var hasEffData = false
        var effPct: Double = 0
        let bedDays = sleepDays.filter { $0.inBedHours > 0 }
        if !bedDays.isEmpty {
            hasEffData = true
            let avgInBed = bedDays.reduce(0) { $0 + $1.inBedHours } / Double(bedDays.count)
            let avgAsleep = bedDays.reduce(0) { $0 + $1.sleepHours } / Double(bedDays.count)
            // Handle both Apple Watch (inBed = total bed time) and third-party apps (inBed = awake only)
            let totalBed = avgInBed >= avgAsleep ? avgInBed : avgInBed + avgAsleep
            if totalBed > 0 {
                let eff = avgAsleep / totalBed
                effPct = eff * 100
                if eff >= 0.9 { efficiencyPts = 20 }
                else if eff >= 0.85 { efficiencyPts = 16 }
                else if eff >= 0.75 { efficiencyPts = 10 }
                else { efficiencyPts = 5 }
            }
        } else {
            efficiencyPts = 12 // no in-bed data, neutral score
        }

        return SleepScoreResult(
            durationScore: durationPts,
            phaseScore: phasePts,
            consistencyScore: consistencyPts,
            efficiencyScore: efficiencyPts,
            hasPhaseData: hasPhaseData,
            hasEfficiencyData: hasEffData,
            avgHours: avgHours,
            stdDev: stdDev,
            efficiencyPct: effPct
        )
    }

    /// Displays a transparent per-dimension score bar so users can see WHERE quality is strong/weak.
    private func sleepScoreDimensionBar(_ result: SleepScoreResult) -> String {
        var parts: [String] = []
        parts.append("时长 \(Int(result.durationScore))/30")
        if result.hasPhaseData {
            parts.append("阶段 \(Int(result.phaseScore))/25")
        }
        parts.append("规律 \(Int(result.consistencyScore))/25")
        if result.hasEfficiencyData {
            parts.append("效率 \(Int(result.efficiencyScore))/20")
        }
        return "   📊 " + parts.joined(separator: " · ")
    }

    /// Pinpoints the weakest dimension and gives a specific, actionable suggestion.
    private func sleepScoreTargetedAdvice(_ result: SleepScoreResult) -> String {
        let total = result.total

        // For excellent sleep, just affirm
        if total >= 85 {
            return "   睡眠质量优秀 — 时长、节律、效率全面达标，继续保持！"
        }

        // For scores below 85, identify the weakest dimension and give targeted advice
        switch result.weakestDimension {
        case "duration":
            if result.avgHours < 6 {
                return "   ⚡ 最大提升点：睡眠时长 — 平均仅 \(String(format: "%.1f", result.avgHours))h，远低于 7h 底线。试着每周提前 15 分钟上床，逐步调整。"
            } else if result.avgHours < 7 {
                let deficit = Int((7 - result.avgHours) * 60)
                return "   ⚡ 最大提升点：睡眠时长 — 平均差 \(deficit) 分钟达到 7h，提前半小时上床就能补回来。"
            } else {
                return "   ⚡ 最大提升点：睡眠时长 — 平均 \(String(format: "%.1f", result.avgHours))h 偏长，试试固定起床时间来提升精力。"
            }

        case "phase":
            return "   ⚡ 最大提升点：睡眠阶段 — 深睡或 REM 比例偏离理想区间。避免睡前饮酒、减少屏幕蓝光有助改善。"

        case "consistency":
            let stdDevMin = Int(result.stdDev * 60)
            return "   ⚡ 最大提升点：作息规律性 — 每晚睡眠波动约 ±\(stdDevMin) 分钟。固定上床和起床时间比多睡一小时更有效。"

        case "efficiency":
            if result.efficiencyPct > 0 && result.efficiencyPct < 85 {
                let wasteMin = Int((100 - result.efficiencyPct) / 100 * result.avgHours * 60)
                return "   ⚡ 最大提升点：入睡效率（\(Int(result.efficiencyPct))%）— 每晚约 \(wasteMin) 分钟在床上未入睡。试试「困了再上床」和睡前放松练习。"
            }
            return "   ⚡ 最大提升点：入睡效率 — 尝试在固定时间上床，避免在床上看手机。"

        default:
            return "   睡眠质量 \(total >= 70 ? "良好" : total >= 50 ? "一般" : "需要关注") — 从最薄弱的维度开始改善。"
        }
    }

    /// Day-by-day sleep bar (scaled to max 12h, using 8 blocks).
    private func sleepTrendBar(hours: Double) -> String {
        let maxH = 10.0
        let blocks = max(1, min(8, Int((hours / maxH) * 8)))
        let bar = String(repeating: "▓", count: blocks) + String(repeating: "░", count: 8 - blocks)
        // Color indicator
        if hours >= 7 && hours <= 9 { return "🟢 \(bar)" }
        if hours >= 6 { return "🟡 \(bar)" }
        return "🔴 \(bar)"
    }

    /// Standard deviation of an array of Doubles.
    private func standardDeviation(of values: [Double]) -> Double {
        guard values.count >= 2 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return variance.squareRoot()
    }

    /// Builds a mini bar chart for sleep phase percentage (max 10 blocks).
    private func phaseBar(pct: Double) -> String {
        let blocks = max(1, Int(pct / 10))
        return String(repeating: "▓", count: blocks) + String(repeating: "░", count: 10 - blocks)
    }

    /// Returns personalized insights based on sleep phase ratios.
    /// Healthy adults: ~15-25% deep, ~20-25% REM.
    private func sleepPhaseInsights(deepPct: Double, remPct: Double, avgDeep: Double, avgREM: Double) -> [String] {
        var insights: [String] = []

        // Deep sleep analysis (healthy: 15-25%, or ~1.5-2h for 8h sleep)
        if deepPct >= 15 && deepPct <= 25 {
            insights.append("✅ 深睡眠比例健康，身体恢复充分。")
        } else if deepPct < 15 {
            insights.append("💡 深睡眠偏少（理想为 15-25%），这是身体修复的关键阶段。")
            if avgDeep < 1.0 {
                insights.append("   避免睡前饮酒和大量咖啡因，有助于增加深睡眠。")
            }
        } else {
            insights.append("💤 深睡眠比例较高，可能与近期运动量大或身体疲劳有关。")
        }

        // REM sleep analysis (healthy: 20-25%, important for memory)
        if remPct >= 20 && remPct <= 25 {
            insights.append("✅ REM 睡眠充足，有利于记忆巩固和情绪调节。")
        } else if remPct < 20 {
            insights.append("💡 REM 偏少（理想为 20-25%），REM 对学习和记忆力很重要。")
            if avgREM < 1.0 {
                insights.append("   规律作息和减少睡前屏幕时间有助于改善 REM。")
            }
        } else {
            insights.append("🔵 REM 比例较高，可能与近期压力或活跃的梦境有关。")
        }

        return insights
    }

    /// Coefficient of variation: stddev / mean. Lower = more consistent.
    private func coefficient(of values: [Double]) -> Double {
        guard values.count >= 2 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        guard mean > 0 else { return 0 }
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return (variance.squareRoot()) / mean
    }

    private func respondHeartRate(summaries: [HealthSummary], allSummaries: [HealthSummary] = [], range: QueryTimeRange, completion: @escaping (String) -> Void) {
        let hrDays = summaries.filter { $0.heartRate > 0 }
        guard !hrDays.isEmpty else {
            completion("❤️ \(range.label)暂无心率数据。\n需要 Apple Watch 来追踪心率。")
            return
        }

        var lines: [String] = ["❤️ \(range.label)的心率分析\n"]
        let avg = hrDays.reduce(0) { $0 + $1.heartRate } / Double(hrDays.count)
        let maxHR = hrDays.max(by: { $0.heartRate < $1.heartRate })!
        let minHR = hrDays.min(by: { $0.heartRate < $1.heartRate })!

        lines.append("💓 平均心率：\(Int(avg)) BPM")
        lines.append("📊 波动范围：\(Int(minHR.heartRate))~\(Int(maxHR.heartRate)) BPM")

        // --- Resting heart rate (the gold-standard fitness indicator) ---
        let restingDays = summaries.filter { $0.restingHeartRate > 0 }
        if !restingDays.isEmpty {
            let avgResting = restingDays.reduce(0) { $0 + $1.restingHeartRate } / Double(restingDays.count)
            lines.append("")
            lines.append("🫀 静息心率：\(Int(avgResting)) BPM")

            // Fitness-level interpretation based on resting HR
            // (AHA guidelines: athletes <60, excellent 60-65, good 66-73, average 74-80, above-average 81+)
            if avgResting < 60 {
                lines.append("🏅 运动员水平！静息心率低于 60 说明心肺功能出色。")
            } else if avgResting <= 65 {
                lines.append("✅ 心肺功能优秀，静息心率处于健身人群范围。")
            } else if avgResting <= 73 {
                lines.append("✅ 静息心率正常偏好，坚持运动可以进一步降低。")
            } else if avgResting <= 80 {
                lines.append("💡 静息心率中等，规律有氧运动（跑步、游泳）可以逐步改善。")
            } else {
                lines.append("⚠️ 静息心率偏高（>80），建议增加有氧运动并减少久坐。")
            }

            // Resting HR trend (compare first half vs second half)
            if restingDays.count >= 4 {
                let sortedResting = restingDays.sorted { $0.date < $1.date }
                let mid = sortedResting.count / 2
                let olderAvg = sortedResting.prefix(mid).reduce(0) { $0 + $1.restingHeartRate } / Double(mid)
                let recentAvg = sortedResting.suffix(from: mid).reduce(0) { $0 + $1.restingHeartRate } / Double(sortedResting.count - mid)
                let diff = recentAvg - olderAvg
                if abs(diff) >= 2 {
                    if diff < 0 {
                        lines.append("📈 静息心率呈下降趋势（\(String(format: "%.0f", diff)) BPM），心肺功能在提升！")
                    } else {
                        lines.append("📉 静息心率略有上升（+\(String(format: "%.0f", diff)) BPM），可能与疲劳、压力或缺乏运动有关。")
                    }
                }
            }
        }

        // --- HRV analysis (stress & recovery indicator) ---
        let hrvDays = summaries.filter { $0.hrv > 0 }
        if !hrvDays.isEmpty {
            let avgHRV = hrvDays.reduce(0) { $0 + $1.hrv } / Double(hrvDays.count)
            let maxHRV = hrvDays.max(by: { $0.hrv < $1.hrv })!
            let minHRV = hrvDays.min(by: { $0.hrv < $1.hrv })!

            lines.append("")
            lines.append("📳 心率变异性（HRV）：\(Int(avgHRV)) ms")
            if hrvDays.count > 1 {
                lines.append("   波动范围：\(Int(minHRV.hrv))~\(Int(maxHRV.hrv)) ms")
            }

            // HRV interpretation (higher = better autonomic nervous system balance)
            // Normal ranges vary greatly by age, so we give general guidance
            if avgHRV >= 50 {
                lines.append("✅ HRV 较高，说明身体恢复状态好，自主神经调节能力强。")
            } else if avgHRV >= 30 {
                lines.append("💡 HRV 中等，适当休息和规律运动有助于提升。")
            } else {
                lines.append("⚠️ HRV 偏低，可能处于疲劳或压力较大的状态，注意恢复。")
            }

            // HRV consistency — stable HRV is a good sign
            if hrvDays.count >= 3 {
                let hrvCV = coefficient(of: hrvDays.map { $0.hrv })
                if hrvCV < 0.2 {
                    lines.append("📊 HRV 非常稳定，身体节律良好。")
                } else if hrvCV > 0.4 {
                    lines.append("🎢 HRV 波动较大，可能受睡眠质量或压力影响。")
                }
            }

            // HRV trend
            if hrvDays.count >= 4 {
                let sortedHRV = hrvDays.sorted { $0.date < $1.date }
                let mid = sortedHRV.count / 2
                let olderAvg = sortedHRV.prefix(mid).reduce(0) { $0 + $1.hrv } / Double(mid)
                let recentAvg = sortedHRV.suffix(from: mid).reduce(0) { $0 + $1.hrv } / Double(sortedHRV.count - mid)
                let diff = recentAvg - olderAvg
                if abs(diff) >= 5 {
                    if diff > 0 {
                        lines.append("📈 HRV 呈上升趋势（+\(Int(diff)) ms），恢复状态在改善！")
                    } else {
                        lines.append("📉 HRV 有所下降（\(Int(diff)) ms），注意休息和压力管理。")
                    }
                }
            }
        }

        // --- Cross-metric: heart rate vs exercise correlation ---
        if hrDays.count >= 4 {
            let paired = summaries.filter { $0.heartRate > 0 && $0.exerciseMinutes > 0 }
            if paired.count >= 3 {
                let exerciseMedian = paired.map(\.exerciseMinutes).sorted()[paired.count / 2]
                let activeDays = paired.filter { $0.exerciseMinutes >= exerciseMedian }
                let restDays = paired.filter { $0.exerciseMinutes < exerciseMedian }

                if !activeDays.isEmpty && !restDays.isEmpty {
                    let hrOnActive = activeDays.reduce(0) { $0 + $1.heartRate } / Double(activeDays.count)
                    let hrOnRest = restDays.reduce(0) { $0 + $1.heartRate } / Double(restDays.count)
                    let diff = hrOnActive - hrOnRest

                    if abs(diff) >= 3 {
                        lines.append("")
                        if diff > 0 {
                            lines.append("💡 运动日平均心率高 \(Int(diff)) BPM，属于正常的运动反应。")
                        } else {
                            lines.append("💡 运动日心率反而低 \(Int(-diff)) BPM，长期运动正在降低你的基础心率。")
                        }
                    }
                }
            }
        }

        // --- Sleep ↔ Next-Day Resting HR / HRV Correlation ---
        // This is one of the most scientifically validated health patterns:
        // poor sleep → higher resting HR and lower HRV the following day.
        // We pair each day's resting HR/HRV with the PREVIOUS night's sleep.
        if !allSummaries.isEmpty {
            let cal = Calendar.current
            let allSorted = allSummaries.sorted { $0.date < $1.date }

            // Build pairs: (previous night's sleep hours, this day's resting HR / HRV)
            var sleepHRPairs: [(sleep: Double, rhr: Double)] = []
            var sleepHRVPairs: [(sleep: Double, hrv: Double)] = []
            for (i, day) in allSorted.enumerated() where i > 0 {
                let prevDay = allSorted[i - 1]
                guard prevDay.sleepHours > 0 else { continue }
                if day.restingHeartRate > 0 {
                    sleepHRPairs.append((sleep: prevDay.sleepHours, rhr: day.restingHeartRate))
                }
                if day.hrv > 0 {
                    sleepHRVPairs.append((sleep: prevDay.sleepHours, hrv: day.hrv))
                }
            }

            // Need at least 4 pairs and sufficient sleep variance to draw meaningful conclusions
            let sleepValues = sleepHRPairs.map(\.sleep)
            let hasSleepVariance = sleepValues.count >= 4 && (sleepValues.max() ?? 0) - (sleepValues.min() ?? 0) >= 1.0

            if hasSleepVariance {
                let medianSleep = sleepValues.sorted()[sleepValues.count / 2]
                let goodSleep = sleepHRPairs.filter { $0.sleep >= medianSleep }
                let poorSleep = sleepHRPairs.filter { $0.sleep < medianSleep }

                if !goodSleep.isEmpty && !poorSleep.isEmpty {
                    let rhrAfterGood = goodSleep.reduce(0.0) { $0 + $1.rhr } / Double(goodSleep.count)
                    let rhrAfterPoor = poorSleep.reduce(0.0) { $0 + $1.rhr } / Double(poorSleep.count)
                    let rhrDiff = rhrAfterPoor - rhrAfterGood

                    var sleepInsights: [String] = []
                    if rhrDiff >= 2 {
                        sleepInsights.append("🫀 睡眠不足的次日静息心率高 \(Int(rhrDiff)) BPM（\(Int(rhrAfterPoor)) vs \(Int(rhrAfterGood))）")
                    } else if rhrDiff <= -2 {
                        sleepInsights.append("🫀 你的静息心率和睡眠时长没有明显负相关，身体适应力不错")
                    }

                    // HRV correlation
                    let goodSleepHRV = sleepHRVPairs.filter { $0.sleep >= medianSleep }
                    let poorSleepHRV = sleepHRVPairs.filter { $0.sleep < medianSleep }
                    if goodSleepHRV.count >= 2 && poorSleepHRV.count >= 2 {
                        let hrvAfterGood = goodSleepHRV.reduce(0.0) { $0 + $1.hrv } / Double(goodSleepHRV.count)
                        let hrvAfterPoor = poorSleepHRV.reduce(0.0) { $0 + $1.hrv } / Double(poorSleepHRV.count)
                        let hrvDiff = hrvAfterGood - hrvAfterPoor
                        if hrvDiff >= 3 {
                            sleepInsights.append("📳 充足睡眠后 HRV 高 \(Int(hrvDiff)) ms（\(Int(hrvAfterGood)) vs \(Int(hrvAfterPoor))），恢复更充分")
                        }
                    }

                    if !sleepInsights.isEmpty {
                        lines.append("")
                        lines.append("😴↔️❤️ 睡眠对心率的影响")
                        lines.append(contentsOf: sleepInsights)
                        if rhrDiff >= 3 {
                            lines.append("💡 对你来说，保证睡眠质量是降低静息心率最直接的方式")
                        }
                    }
                }
            }

            // Day-by-day detailed log: connect previous night sleep → today's resting HR + HRV
            // This gives users a visual "aha" moment — they can see the pattern day by day.
            let rangeSorted = summaries.filter { $0.restingHeartRate > 0 || $0.hrv > 0 }
                .sorted { $0.date < $1.date }
            if rangeSorted.count >= 3 {
                let dayFmt = DateFormatter()
                dayFmt.dateFormat = "E"
                dayFmt.locale = Locale(identifier: "zh_CN")

                lines.append("")
                lines.append("📋 逐日心血管日志")
                for day in rangeSorted {
                    var cols: [String] = [dayFmt.string(from: day.date)]
                    if day.restingHeartRate > 0 {
                        cols.append("🫀\(Int(day.restingHeartRate))")
                    }
                    if day.hrv > 0 {
                        cols.append("HRV \(Int(day.hrv))")
                    }
                    // Find previous night's sleep from allSummaries
                    let prevDay = allSorted.first {
                        cal.isDate($0.date, inSameDayAs: cal.date(byAdding: .day, value: -1, to: day.date) ?? day.date)
                    }
                    if let sleep = prevDay, sleep.sleepHours > 0 {
                        let sleepEmoji = sleep.sleepHours >= 7 ? "✅" : (sleep.sleepHours >= 6 ? "💡" : "⚠️")
                        cols.append("前晚 \(String(format: "%.1f", sleep.sleepHours))h \(sleepEmoji)")
                    }
                    lines.append("   \(cols.joined(separator: " · "))")
                }
            }
        }

        // --- Context-aware overall insight ---
        lines.append("")
        if restingDays.isEmpty && hrvDays.isEmpty {
            // Fallback: only average HR available (no Apple Watch resting/HRV)
            if avg < 60 {
                lines.append("🏅 平均心率较低，心肺功能看起来不错！")
            } else if avg <= 80 {
                lines.append("✅ 心率处于正常范围（60-80 BPM）。")
            } else if avg <= 100 {
                lines.append("💡 心率偏高，可能与压力、缺乏运动或咖啡因有关。")
            } else {
                lines.append("⚠️ 平均心率超过 100 BPM，建议关注并咨询医生。")
            }
            lines.append("💡 佩戴 Apple Watch 可获取静息心率和 HRV 数据，提供更深入的心肺分析。")
        } else {
            // Holistic cardiovascular verdict
            var cardioScore = 0
            if let rhr = restingDays.isEmpty ? nil : restingDays.reduce(0, { $0 + $1.restingHeartRate }) / Double(restingDays.count) {
                if rhr <= 73 { cardioScore += 1 }
            }
            if let hv = hrvDays.isEmpty ? nil : hrvDays.reduce(0, { $0 + $1.hrv }) / Double(hrvDays.count) {
                if hv >= 40 { cardioScore += 1 }
            }
            // Check HRV stability
            if hrvDays.count >= 3 {
                let cv = coefficient(of: hrvDays.map { $0.hrv })
                if cv < 0.3 { cardioScore += 1 }
            }

            switch cardioScore {
            case 3:
                lines.append("🫀 心血管状态优秀！静息心率、HRV 和稳定性都表现很好。")
            case 2:
                lines.append("💪 心血管健康良好，继续保持规律运动。")
            case 1:
                lines.append("💡 心血管指标还有提升空间，有氧运动是最好的投资。")
            default:
                lines.append("🌱 建议增加有氧运动、改善睡眠，逐步提升心血管健康。")
            }
        }

        // Day-by-day HR sparkline
        if hrDays.count >= 3 {
            let sorted = hrDays.sorted { $0.date < $1.date }
            let maxVal = sorted.map(\.heartRate).max() ?? 1
            let minVal = sorted.map(\.heartRate).min() ?? 0
            let range = maxVal - minVal
            if range > 0 {
                let sparkChars: [Character] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
                let spark = sorted.map { day -> Character in
                    let idx = min(Int((day.heartRate - minVal) / range * 7), 7)
                    return sparkChars[idx]
                }
                lines.append("\n📈 心率趋势：\(String(spark))")
            }
        }

        // Variability insight
        let spread = maxHR.heartRate - minHR.heartRate
        if spread > 15 && hrDays.count > 2 {
            lines.append("心率日间波动 \(Int(spread)) BPM，运动日和休息日差异明显。")
        }

        completion(lines.joined(separator: "\n"))
    }

    private func respondSteps(summaries: [HealthSummary], allSummaries: [HealthSummary] = [], range: QueryTimeRange, completion: @escaping (String) -> Void) {
        let stepDays = summaries.filter { $0.steps > 0 }
        guard !stepDays.isEmpty else {
            completion("👟 \(range.label)暂无步数记录。")
            return
        }

        let cal = Calendar.current
        var lines: [String] = ["👟 \(range.label)的步数详情\n"]
        let total = stepDays.reduce(0) { $0 + $1.steps }
        let avg = total / Double(stepDays.count)
        let best = stepDays.max(by: { $0.steps < $1.steps })!
        let worst = stepDays.min(by: { $0.steps < $1.steps })!

        lines.append("📊 总步数：\(Int(total).formatted()) 步")

        // --- Personal baseline comparison for single-day queries ---
        // When asking "今天步数" or "昨天步数", show how it compares to the 7-day average.
        // This transforms a raw number into a meaningful insight.
        let isSingleDay = (range == .today || range == .yesterday || range == .dayBeforeYesterday)
        if isSingleDay, let todaySteps = stepDays.first {
            let interval = range.interval
            let baseline = allSummaries.filter { $0.steps > 0 && !interval.contains($0.date) }
            if !baseline.isEmpty {
                let baselineAvg = baseline.reduce(0) { $0 + $1.steps } / Double(baseline.count)
                let diff = todaySteps.steps - baselineAvg
                let pct = baselineAvg > 0 ? abs(diff) / baselineAvg * 100 : 0

                if pct >= 10 && baselineAvg > 0 {
                    if diff > 0 {
                        lines.append("📈 比你 7 日均值（\(Int(baselineAvg).formatted())）高 \(Int(pct))%")
                    } else {
                        lines.append("📉 比你 7 日均值（\(Int(baselineAvg).formatted())）低 \(Int(pct))%")
                    }
                } else if baselineAvg > 0 {
                    lines.append("📊 与你 7 日均值（\(Int(baselineAvg).formatted())）持平")
                }
            }

            // Goal projection for today: estimate end-of-day steps based on current pace
            if range == .today {
                let hour = cal.component(.hour, from: Date())
                let minute = cal.component(.minute, from: Date())
                let elapsedHours = Double(hour) + Double(minute) / 60.0
                // Only project if we have a meaningful portion of the day (after 9 AM)
                // and before 10 PM (projection makes less sense very late)
                if elapsedHours >= 9 && elapsedHours < 22 && todaySteps.steps > 0 {
                    // Discount: people walk less in late evening
                    let activeHoursLeft = max(0, 22.0 - elapsedHours)
                    let pacePerHour = todaySteps.steps / elapsedHours
                    let projected = todaySteps.steps + pacePerHour * activeHoursLeft * 0.6
                    if projected >= 8000 && todaySteps.steps < 8000 {
                        lines.append("🎯 按当前节奏，今天有望达到 \(Int(projected).formatted()) 步（达标 ✅）")
                    } else if todaySteps.steps < 8000 {
                        let remaining = 8000 - todaySteps.steps
                        lines.append("🎯 距 8000 步目标还差 \(Int(remaining).formatted()) 步")
                    }
                }
            }

            // Yesterday comparison for today
            if range == .today {
                let yesterdaySummary = allSummaries.first { cal.isDateInYesterday($0.date) && $0.steps > 0 }
                if let yd = yesterdaySummary {
                    let diff = todaySteps.steps - yd.steps
                    if abs(diff) >= 500 {
                        if diff > 0 {
                            lines.append("↗️ 比昨天同期多走了 \(Int(diff).formatted()) 步")
                        } else {
                            lines.append("↘️ 比昨天少了 \(Int(-diff).formatted()) 步")
                        }
                    }
                }
            }
        } else {
            lines.append("📈 日均：\(Int(avg).formatted()) 步")
        }

        if stepDays.count > 1 {
            let fmt = DateFormatter()
            fmt.dateFormat = "M月d日(E)"
            fmt.locale = Locale(identifier: "zh_CN")
            lines.append("🏆 最多：\(fmt.string(from: best.date)) \(Int(best.steps).formatted()) 步")
            lines.append("📉 最少：\(fmt.string(from: worst.date)) \(Int(worst.steps).formatted()) 步")
        }

        // --- Day-by-day trend chart ---
        if stepDays.count >= 3 {
            let sorted = stepDays.sorted { $0.date < $1.date }
            lines.append("")
            lines.append("📈 逐日趋势")
            let dayFmt = DateFormatter()
            dayFmt.dateFormat = "E"
            dayFmt.locale = Locale(identifier: "zh_CN")
            for day in sorted {
                let bar = stepsTrendBar(steps: day.steps)
                lines.append("   \(dayFmt.string(from: day.date)) \(bar) \(Int(day.steps).formatted())")
            }
        }

        // --- Goal analysis ---
        let goalDays = stepDays.filter { $0.steps >= 8000 }.count
        let goalRate = Double(goalDays) / Double(stepDays.count) * 100
        lines.append("\n🎯 达标天数（≥8000步）：\(goalDays)/\(stepDays.count) 天（\(Int(goalRate))%）")

        if goalRate >= 80 {
            lines.append("太棒了！大部分时间都达标了 🏅")
        } else if goalRate >= 50 {
            lines.append("过半天数达标，继续保持！💪")
        } else if avg >= 5000 {
            lines.append("离目标还差一点，试试饭后散步 15 分钟？")
        } else {
            lines.append("活动量偏少，可以从每天增加 1000 步开始。")
        }

        // --- Activity distribution buckets ---
        if stepDays.count >= 3 {
            let sedentary = stepDays.filter { $0.steps < 3000 }.count
            let light = stepDays.filter { $0.steps >= 3000 && $0.steps < 5000 }.count
            let moderate = stepDays.filter { $0.steps >= 5000 && $0.steps < 8000 }.count
            let active = stepDays.filter { $0.steps >= 8000 && $0.steps < 12000 }.count
            let veryActive = stepDays.filter { $0.steps >= 12000 }.count
            let n = stepDays.count

            lines.append("")
            lines.append("📊 活动分布")
            if sedentary > 0 { lines.append("   🔴 久坐（<3000）：\(sedentary) 天（\(sedentary * 100 / n)%）") }
            if light > 0 { lines.append("   🟡 轻度（3k-5k）：\(light) 天（\(light * 100 / n)%）") }
            if moderate > 0 { lines.append("   🟢 中度（5k-8k）：\(moderate) 天（\(moderate * 100 / n)%）") }
            if active > 0 { lines.append("   💚 活跃（8k-12k）：\(active) 天（\(active * 100 / n)%）") }
            if veryActive > 0 { lines.append("   🏅 高活跃（12k+）：\(veryActive) 天（\(veryActive * 100 / n)%）") }
        }

        // --- Consistency analysis ---
        if stepDays.count >= 3 {
            let cv = coefficient(of: stepDays.map { $0.steps })
            lines.append("")
            if cv < 0.2 {
                lines.append("🎯 步数非常规律（波动仅 \(Int(cv * 100))%），节奏感很好！")
            } else if cv < 0.4 {
                lines.append("📊 步数比较规律（波动 \(Int(cv * 100))%），偶有高低起伏。")
            } else {
                lines.append("🎢 步数波动较大（\(Int(cv * 100))%），试试每天固定时间散步来建立节奏。")
            }
        }

        // --- Weekday vs Weekend pattern ---
        if stepDays.count >= 5 {
            let weekdays = stepDays.filter { !cal.isDateInWeekend($0.date) }
            let weekends = stepDays.filter { cal.isDateInWeekend($0.date) }
            if !weekdays.isEmpty && !weekends.isEmpty {
                let wdAvg = weekdays.reduce(0) { $0 + $1.steps } / Double(weekdays.count)
                let weAvg = weekends.reduce(0) { $0 + $1.steps } / Double(weekends.count)
                let diff = abs(weAvg - wdAvg)
                let pct = wdAvg > 0 ? diff / wdAvg * 100 : 0
                if pct > 15 {
                    lines.append("")
                    lines.append("🗓 工作日 vs 周末")
                    lines.append("   工作日均 \(Int(wdAvg).formatted()) 步 · 周末均 \(Int(weAvg).formatted()) 步")
                    if weAvg > wdAvg {
                        lines.append("   周末更活跃（+\(Int(pct))%），工作日可以增加午间散步。")
                    } else {
                        lines.append("   工作日更活跃（+\(Int(pct))%），可能因通勤带来更多步数。")
                    }
                }
            }
        }

        // --- Trend: first half vs second half ---
        if stepDays.count >= 4 {
            let sorted = stepDays.sorted { $0.date < $1.date }
            let mid = sorted.count / 2
            let olderAvg = sorted.prefix(mid).reduce(0) { $0 + $1.steps } / Double(mid)
            let recentAvg = sorted.suffix(from: mid).reduce(0) { $0 + $1.steps } / Double(sorted.count - mid)
            if olderAvg > 0 {
                let changePct = ((recentAvg - olderAvg) / olderAvg) * 100
                if abs(changePct) >= 10 {
                    lines.append("")
                    if changePct > 0 {
                        lines.append("📈 步数呈上升趋势（+\(Int(changePct))%），保持这个势头！")
                    } else {
                        lines.append("📉 步数略有下降（\(Int(changePct))%），试试每天多走一站路？")
                    }
                } else {
                    lines.append("")
                    lines.append("📊 步数保持稳定，节奏不错！")
                }
            }
        }

        // --- Cross-metric: steps vs sleep correlation ---
        if stepDays.count >= 4 {
            let paired = summaries.filter { $0.steps > 0 && $0.sleepHours > 0 }
            if paired.count >= 3 {
                let stepMedian = paired.map(\.steps).sorted()[paired.count / 2]
                let highStepDays = paired.filter { $0.steps >= stepMedian }
                let lowStepDays = paired.filter { $0.steps < stepMedian }
                if !highStepDays.isEmpty && !lowStepDays.isEmpty {
                    let sleepOnHigh = highStepDays.reduce(0) { $0 + $1.sleepHours } / Double(highStepDays.count)
                    let sleepOnLow = lowStepDays.reduce(0) { $0 + $1.sleepHours } / Double(lowStepDays.count)
                    let diff = sleepOnHigh - sleepOnLow
                    if abs(diff) >= 0.3 {
                        lines.append("")
                        lines.append("🔗 步数与睡眠的关联")
                        if diff > 0 {
                            lines.append("   多走路的日子平均多睡 \(String(format: "%.1f", diff)) 小时 — 运动有助于改善睡眠质量。")
                        } else {
                            lines.append("   少走路的日子反而多睡 \(String(format: "%.1f", -diff)) 小时 — 可能在休息日补觉较多。")
                        }
                    }
                }
            }
        }

        // --- Distance equivalent (fun context) ---
        let totalDistance = stepDays.reduce(0) { $0 + $1.distanceKm }
        if totalDistance >= 1.0 {
            lines.append("")
            var distLine = "🚶 总距离 \(String(format: "%.1f", totalDistance)) 公里"
            if totalDistance >= 42.195 {
                let marathons = totalDistance / 42.195
                distLine += "（相当于 \(String(format: "%.1f", marathons)) 个全马！）"
            } else if totalDistance >= 21.1 {
                distLine += "（相当于一个半马的距离！）"
            } else if totalDistance >= 10 {
                distLine += "（已经超过 10 公里了！）"
            }
            lines.append(distLine)
        }

        completion(lines.joined(separator: "\n"))
    }

    /// Day-by-day step bar (scaled to 15000 steps, using 8 blocks).
    private func stepsTrendBar(steps: Double) -> String {
        let maxS = 15000.0
        let blocks = max(1, min(8, Int((steps / maxS) * 8)))
        let bar = String(repeating: "▓", count: blocks) + String(repeating: "░", count: 8 - blocks)
        if steps >= 8000 { return "🟢 \(bar)" }
        if steps >= 5000 { return "🟡 \(bar)" }
        return "🔴 \(bar)"
    }

    // MARK: - Flights Climbed

    private func respondFlights(summaries: [HealthSummary], allSummaries: [HealthSummary] = [], range: QueryTimeRange, completion: @escaping (String) -> Void) {
        let flightDays = summaries.filter { $0.flightsClimbed > 0 }
        guard !flightDays.isEmpty else {
            completion("🏢 \(range.label)暂无爬楼数据。\niPhone 会自动记录爬楼层数，确保已开启健康权限。")
            return
        }

        let cal = Calendar.current
        var lines: [String] = ["🏢 \(range.label)的爬楼数据\n"]
        let total = flightDays.reduce(0) { $0 + $1.flightsClimbed }
        let avg = total / Double(flightDays.count)
        let best = flightDays.max(by: { $0.flightsClimbed < $1.flightsClimbed })!

        lines.append("🪜 总楼层：\(Int(total)) 层（日均 \(Int(avg)) 层）")

        // --- Personal baseline comparison for single-day queries ---
        let isSingleDay = (range == .today || range == .yesterday || range == .dayBeforeYesterday)
        if isSingleDay, let todayFlights = flightDays.first {
            let interval = range.interval
            let baseline = allSummaries.filter { $0.flightsClimbed > 0 && !interval.contains($0.date) }
            if !baseline.isEmpty {
                let baselineAvg = baseline.reduce(0) { $0 + $1.flightsClimbed } / Double(baseline.count)
                let diff = todayFlights.flightsClimbed - baselineAvg
                let pct = baselineAvg > 0 ? abs(diff) / baselineAvg * 100 : 0

                if pct >= 15 && baselineAvg > 0 {
                    if diff > 0 {
                        lines.append("📈 比你 7 日均值（\(Int(baselineAvg)) 层）高 \(Int(pct))%")
                    } else {
                        lines.append("📉 比你 7 日均值（\(Int(baselineAvg)) 层）低 \(Int(pct))%")
                    }
                } else if baselineAvg > 0 {
                    lines.append("📊 与你 7 日均值（\(Int(baselineAvg)) 层）持平")
                }
            }

            // Yesterday comparison for today
            if range == .today {
                let yesterdaySummary = allSummaries.first { cal.isDateInYesterday($0.date) && $0.flightsClimbed > 0 }
                if let yd = yesterdaySummary {
                    let diff = todayFlights.flightsClimbed - yd.flightsClimbed
                    if abs(diff) >= 3 {
                        if diff > 0 {
                            lines.append("↗️ 比昨天多爬了 \(Int(diff)) 层")
                        } else {
                            lines.append("↘️ 比昨天少爬了 \(Int(-diff)) 层")
                        }
                    }
                }
            }
        }

        // 1 flight ≈ 3 meters of elevation gain
        let totalMeters = total * 3
        lines.append("📐 约等于爬升 \(Int(totalMeters)) 米")

        if flightDays.count > 1 {
            let fmt = DateFormatter()
            fmt.dateFormat = "M月d日(E)"
            fmt.locale = Locale(identifier: "zh_CN")
            lines.append("🏆 最多的一天：\(fmt.string(from: best.date))，\(Int(best.flightsClimbed)) 层")
        }

        // --- Day-by-day trend chart ---
        if flightDays.count >= 3 {
            let sorted = flightDays.sorted { $0.date < $1.date }
            lines.append("")
            lines.append("📈 逐日趋势")
            let dayFmt = DateFormatter()
            dayFmt.dateFormat = "E"
            dayFmt.locale = Locale(identifier: "zh_CN")
            let maxFlights = sorted.map(\.flightsClimbed).max() ?? 1
            for day in sorted {
                let blocks = max(1, min(8, Int((day.flightsClimbed / maxFlights) * 8)))
                let bar = String(repeating: "▓", count: blocks) + String(repeating: "░", count: 8 - blocks)
                let color = day.flightsClimbed >= 10 ? "🟢" : (day.flightsClimbed >= 5 ? "🟡" : "🔴")
                lines.append("   \(dayFmt.string(from: day.date)) \(color) \(bar) \(Int(day.flightsClimbed)) 层")
            }
        }

        // Fun comparisons for motivation
        lines.append("")
        if total >= 163 {
            let percent = Int(total / 163 * 100)
            lines.append("🏔 相当于爬了 \(percent)% 座广州塔（\(Int(totalMeters))m / 489m）")
        } else if total >= 50 {
            lines.append("🏗 相当于爬了一栋 \(Int(total)) 层的大楼，很有毅力！")
        } else if total >= 10 {
            lines.append("👍 积少成多，每天多爬几层楼对心肺有益。")
        }

        // Daily goal insight (WHO recommends regular stair climbing)
        let goalFlights = 10.0
        let activeDays = flightDays.filter { $0.flightsClimbed >= goalFlights }.count
        let goalRate = Double(activeDays) / Double(flightDays.count) * 100
        lines.append("🎯 达标天数（≥10层）：\(activeDays)/\(flightDays.count) 天（\(Int(goalRate))%）")

        if goalRate >= 80 {
            lines.append("   太棒了！经常爬楼，心肺功能一定不错 🏅")
        } else if goalRate >= 50 {
            lines.append("   过半天数达标，继续保持 💪")
        } else if avg >= 5 {
            lines.append("   每天再多爬 \(Int(goalFlights - avg)) 层就达标了，少坐电梯试试？")
        } else {
            lines.append("   可以试试每天走楼梯代替电梯，从 3-5 层开始。")
        }

        // --- Weekday vs Weekend pattern ---
        if flightDays.count >= 5 {
            let weekdays = flightDays.filter { !cal.isDateInWeekend($0.date) }
            let weekends = flightDays.filter { cal.isDateInWeekend($0.date) }
            if !weekdays.isEmpty && !weekends.isEmpty {
                let wdAvg = weekdays.reduce(0) { $0 + $1.flightsClimbed } / Double(weekdays.count)
                let weAvg = weekends.reduce(0) { $0 + $1.flightsClimbed } / Double(weekends.count)
                let pct = wdAvg > 0 ? abs(weAvg - wdAvg) / wdAvg * 100 : 0
                if pct > 20 {
                    lines.append("")
                    lines.append("🗓 工作日 vs 周末")
                    lines.append("   工作日均 \(Int(wdAvg)) 层 · 周末均 \(Int(weAvg)) 层")
                    if weAvg > wdAvg {
                        lines.append("   周末爬楼更多（+\(Int(pct))%），可能有户外活动或逛街。")
                    } else {
                        lines.append("   工作日爬楼更多（+\(Int(pct))%），办公环境中经常走楼梯 👍")
                    }
                }
            }
        }

        // --- Trend: first half vs second half ---
        if flightDays.count >= 4 {
            let sorted = flightDays.sorted { $0.date < $1.date }
            let mid = sorted.count / 2
            let olderAvg = sorted.prefix(mid).reduce(0) { $0 + $1.flightsClimbed } / Double(mid)
            let recentAvg = sorted.suffix(from: mid).reduce(0) { $0 + $1.flightsClimbed } / Double(sorted.count - mid)
            if olderAvg > 0 {
                let pct = ((recentAvg - olderAvg) / olderAvg) * 100
                if abs(pct) >= 15 {
                    lines.append("")
                    if pct > 0 {
                        lines.append("📈 爬楼量呈上升趋势（+\(Int(pct))%），保持这个势头！")
                    } else {
                        lines.append("📉 爬楼量有所下降（\(Int(pct))%），试试每天多走一趟楼梯？")
                    }
                }
            }
        }

        // --- Cross-metric: flights vs exercise correlation ---
        if flightDays.count >= 4 {
            let paired = summaries.filter { $0.flightsClimbed > 0 && $0.exerciseMinutes > 0 }
            if paired.count >= 3 {
                let flightMedian = paired.map(\.flightsClimbed).sorted()[paired.count / 2]
                let highFlightDays = paired.filter { $0.flightsClimbed >= flightMedian }
                let lowFlightDays = paired.filter { $0.flightsClimbed < flightMedian }
                if !highFlightDays.isEmpty && !lowFlightDays.isEmpty {
                    let exOnHigh = highFlightDays.reduce(0) { $0 + $1.exerciseMinutes } / Double(highFlightDays.count)
                    let exOnLow = lowFlightDays.reduce(0) { $0 + $1.exerciseMinutes } / Double(lowFlightDays.count)
                    let diff = exOnHigh - exOnLow
                    if abs(diff) >= 5 {
                        lines.append("")
                        lines.append("🔗 爬楼与运动的关联")
                        if diff > 0 {
                            lines.append("   多爬楼的日子平均多运动 \(Int(diff)) 分钟 — 整体活动量更高。")
                        } else {
                            lines.append("   少爬楼的日子反而运动更多 — 可能在健身房专注训练。")
                        }
                    }
                }
            }
        }

        completion(lines.joined(separator: "\n"))
    }

    // MARK: - Distance

    private func respondDistance(summaries: [HealthSummary], allSummaries: [HealthSummary] = [], range: QueryTimeRange, completion: @escaping (String) -> Void) {
        let cal = Calendar.current
        let distanceDays = summaries.filter { $0.distanceKm > 0.01 }
        guard !distanceDays.isEmpty else {
            completion("📏 \(range.label)暂无步行距离数据。\n开启健康权限后可以自动追踪步行和跑步距离。")
            return
        }

        var lines: [String] = ["📏 \(range.label)的步行/跑步距离\n"]
        let total = distanceDays.reduce(0) { $0 + $1.distanceKm }
        let avg = total / Double(distanceDays.count)
        let best = distanceDays.max(by: { $0.distanceKm < $1.distanceKm })!
        let worst = distanceDays.min(by: { $0.distanceKm < $1.distanceKm })!

        lines.append("🛣 总距离：\(String(format: "%.1f", total)) 公里")

        // --- Personal baseline comparison for single-day queries ---
        let isSingleDay = (range == .today || range == .yesterday || range == .dayBeforeYesterday)
        if isSingleDay, let todayDist = distanceDays.first {
            let interval = range.interval
            let baseline = allSummaries.filter { $0.distanceKm > 0.01 && !interval.contains($0.date) }
            if !baseline.isEmpty {
                let baselineAvg = baseline.reduce(0) { $0 + $1.distanceKm } / Double(baseline.count)
                let diff = todayDist.distanceKm - baselineAvg
                let pct = baselineAvg > 0 ? abs(diff) / baselineAvg * 100 : 0

                if pct >= 10 && baselineAvg > 0 {
                    if diff > 0 {
                        lines.append("📈 比你 7 日均值（\(String(format: "%.1f", baselineAvg)) km）高 \(Int(pct))%")
                    } else {
                        lines.append("📉 比你 7 日均值（\(String(format: "%.1f", baselineAvg)) km）低 \(Int(pct))%")
                    }
                } else if baselineAvg > 0 {
                    lines.append("📊 与你 7 日均值（\(String(format: "%.1f", baselineAvg)) km）持平")
                }
            }

            // Goal projection for today
            if range == .today {
                let hour = cal.component(.hour, from: Date())
                let minute = cal.component(.minute, from: Date())
                let elapsedHours = Double(hour) + Double(minute) / 60.0
                let goalKm = 5.0
                if elapsedHours >= 9 && elapsedHours < 22 && todayDist.distanceKm > 0.1 {
                    let activeHoursLeft = max(0, 22.0 - elapsedHours)
                    let pacePerHour = todayDist.distanceKm / elapsedHours
                    let projected = todayDist.distanceKm + pacePerHour * activeHoursLeft * 0.6
                    if projected >= goalKm && todayDist.distanceKm < goalKm {
                        lines.append("🎯 按当前节奏，今天有望达到 \(String(format: "%.1f", projected)) km（达标 ✅）")
                    } else if todayDist.distanceKm < goalKm {
                        let remaining = goalKm - todayDist.distanceKm
                        let walkMin = Int(remaining / 0.08) // ~80m per minute of walking
                        lines.append("🎯 距 5km 目标还差 \(String(format: "%.1f", remaining)) km（约快走 \(walkMin) 分钟）")
                    }
                }
            }

            // Yesterday comparison for today
            if range == .today {
                let yesterdaySummary = allSummaries.first { cal.isDateInYesterday($0.date) && $0.distanceKm > 0.01 }
                if let yd = yesterdaySummary {
                    let diff = todayDist.distanceKm - yd.distanceKm
                    if abs(diff) >= 0.5 {
                        if diff > 0 {
                            lines.append("↗️ 比昨天多走了 \(String(format: "%.1f", diff)) km")
                        } else {
                            lines.append("↘️ 比昨天少了 \(String(format: "%.1f", -diff)) km")
                        }
                    }
                }
            }
        } else {
            lines.append("📊 日均 \(String(format: "%.1f", avg)) 公里")
            lines.append("📊 波动范围：\(String(format: "%.1f", worst.distanceKm))~\(String(format: "%.1f", best.distanceKm)) 公里")
        }

        if distanceDays.count > 1 {
            let fmt = DateFormatter()
            fmt.dateFormat = "M月d日(E)"
            fmt.locale = Locale(identifier: "zh_CN")
            lines.append("🏆 最远：\(fmt.string(from: best.date)) \(String(format: "%.1f", best.distanceKm)) km")
            lines.append("📉 最短：\(fmt.string(from: worst.date)) \(String(format: "%.1f", worst.distanceKm)) km")
        }

        // --- Day-by-day trend chart ---
        if distanceDays.count >= 3 {
            let sorted = distanceDays.sorted { $0.date < $1.date }
            lines.append("")
            lines.append("📈 逐日趋势")
            let dayFmt = DateFormatter()
            dayFmt.dateFormat = "E"
            dayFmt.locale = Locale(identifier: "zh_CN")
            let maxDist = sorted.map(\.distanceKm).max() ?? 1
            for day in sorted {
                let blocks = max(1, min(8, Int((day.distanceKm / maxDist) * 8)))
                let bar = String(repeating: "▓", count: blocks) + String(repeating: "░", count: 8 - blocks)
                let color = day.distanceKm >= 5 ? "🟢" : (day.distanceKm >= 3 ? "🟡" : "🔴")
                lines.append("   \(dayFmt.string(from: day.date)) \(color) \(bar) \(String(format: "%.1f", day.distanceKm)) km")
            }
        }

        // --- Goal analysis (5 km daily — WHO moderate activity target) ---
        let goalKm = 5.0
        let goalDays = distanceDays.filter { $0.distanceKm >= goalKm }.count
        let goalRate = Double(goalDays) / Double(distanceDays.count) * 100
        lines.append("\n🎯 达标天数（≥\(String(format: "%.0f", goalKm))km）：\(goalDays)/\(distanceDays.count) 天（\(Int(goalRate))%）")

        if goalRate >= 80 {
            lines.append("   太棒了！日常活动量非常充足 🏅")
        } else if goalRate >= 50 {
            lines.append("   过半天数达标，保持这个节奏 💪")
        } else if avg >= 3 {
            let gap = String(format: "%.1f", goalKm - avg)
            lines.append("   每天再多走 \(gap) 公里就达标了，饭后散步 15 分钟试试？")
        } else {
            lines.append("   活动距离偏少，从每天多走一站路开始。")
        }

        // Correlate with steps: stride length
        let totalSteps = distanceDays.reduce(0) { $0 + $1.steps }
        if totalSteps > 0 && total > 0 {
            let strideCm = Int(total * 100000 / totalSteps)
            lines.append("\n👣 平均步幅约 \(strideCm) cm")
            if strideCm >= 70 {
                lines.append("   步幅较大，走路速度应该不慢！")
            } else if strideCm <= 50 {
                lines.append("   步幅偏小，有意识地迈大步可以提升锻炼效果。")
            }
        }

        // --- Cross-metric: distance vs exercise time → effective walking pace ---
        let pairedDays = distanceDays.filter { $0.exerciseMinutes > 0 && $0.distanceKm >= 0.5 }
        if !pairedDays.isEmpty {
            let totalExMin = pairedDays.reduce(0) { $0 + $1.exerciseMinutes }
            let totalExDist = pairedDays.reduce(0) { $0 + $1.distanceKm }
            if totalExDist > 0 {
                let minPerKm = totalExMin / totalExDist
                lines.append("")
                lines.append("⏱ 运动效率")
                lines.append("   平均配速约 \(String(format: "%.0f", minPerKm)) 分钟/公里")
                if minPerKm < 8 {
                    lines.append("   🏃 以跑步为主的节奏，运动强度不错！")
                } else if minPerKm < 12 {
                    lines.append("   🚶‍♂️ 快走节奏，属于中等强度有氧运动。")
                } else {
                    lines.append("   🚶 以日常步行为主，尝试加入 15 分钟快走提升心率。")
                }
            }
        }

        // --- Weekday vs weekend pattern ---
        if distanceDays.count >= 5 {
            let weekdays = distanceDays.filter { !cal.isDateInWeekend($0.date) }
            let weekends = distanceDays.filter { cal.isDateInWeekend($0.date) }
            if !weekdays.isEmpty && !weekends.isEmpty {
                let wdAvg = weekdays.reduce(0) { $0 + $1.distanceKm } / Double(weekdays.count)
                let weAvg = weekends.reduce(0) { $0 + $1.distanceKm } / Double(weekends.count)
                let pct = wdAvg > 0 ? abs(weAvg - wdAvg) / wdAvg * 100 : 0
                if pct > 15 {
                    lines.append("")
                    lines.append("🗓 工作日 vs 周末")
                    lines.append("   工作日均 \(String(format: "%.1f", wdAvg)) km · 周末均 \(String(format: "%.1f", weAvg)) km")
                    if weAvg > wdAvg {
                        lines.append("   周末更爱走动（+\(Int(pct))%），可能有户外活动或逛街。")
                    } else {
                        lines.append("   工作日走更远（+\(Int(pct))%），通勤贡献了不少距离。")
                    }
                }
            }
        }

        // --- Consistency analysis ---
        if distanceDays.count >= 3 {
            let cv = coefficient(of: distanceDays.map { $0.distanceKm })
            lines.append("")
            if cv < 0.2 {
                lines.append("🎯 步行距离非常规律（波动仅 \(Int(cv * 100))%），好习惯！")
            } else if cv < 0.4 {
                lines.append("📊 距离比较规律（波动 \(Int(cv * 100))%），偶有高低。")
            } else {
                lines.append("🎢 距离波动较大（\(Int(cv * 100))%），可以固定时间散步来建立规律。")
            }
        }

        // --- Trend: first half vs second half ---
        if distanceDays.count >= 4 {
            let sorted = distanceDays.sorted { $0.date < $1.date }
            let mid = sorted.count / 2
            let olderAvg = sorted.prefix(mid).reduce(0) { $0 + $1.distanceKm } / Double(mid)
            let recentAvg = sorted.suffix(from: mid).reduce(0) { $0 + $1.distanceKm } / Double(sorted.count - mid)
            if olderAvg > 0 {
                let pct = ((recentAvg - olderAvg) / olderAvg) * 100
                if abs(pct) >= 10 {
                    if pct > 0 {
                        lines.append("📈 步行距离呈上升趋势（+\(Int(pct))%），活动量在增加！")
                    } else {
                        lines.append("📉 步行距离有所下降（\(Int(pct))%），试试换条新路线散步？")
                    }
                } else {
                    lines.append("📊 步行距离保持稳定，节奏不错。")
                }
            }
        }

        // --- Cross-metric: distance vs sleep correlation ---
        if distanceDays.count >= 4 {
            let paired = summaries.filter { $0.distanceKm > 0.01 && $0.sleepHours > 0 }
            if paired.count >= 3 {
                let distMedian = paired.map(\.distanceKm).sorted()[paired.count / 2]
                let highDistDays = paired.filter { $0.distanceKm >= distMedian }
                let lowDistDays = paired.filter { $0.distanceKm < distMedian }
                if !highDistDays.isEmpty && !lowDistDays.isEmpty {
                    let sleepOnHigh = highDistDays.reduce(0) { $0 + $1.sleepHours } / Double(highDistDays.count)
                    let sleepOnLow = lowDistDays.reduce(0) { $0 + $1.sleepHours } / Double(lowDistDays.count)
                    let diff = sleepOnHigh - sleepOnLow
                    if abs(diff) >= 0.3 {
                        lines.append("")
                        lines.append("🔗 距离与睡眠的关联")
                        if diff > 0 {
                            lines.append("   走得多的日子平均多睡 \(String(format: "%.1f", diff)) 小时 — 白天活动有助于提升睡眠质量。")
                        } else {
                            lines.append("   走得少的日子反而多睡 \(String(format: "%.1f", -diff)) 小时 — 可能在休息日补觉较多。")
                        }
                    }
                }
            }
        }

        // --- Fun distance comparisons ---
        lines.append("")
        if total >= 42.195 {
            let marathons = total / 42.195
            lines.append("🏅 累计距离相当于 \(String(format: "%.1f", marathons)) 个全马！")
        } else if total >= 21.1 {
            let remaining = 42.195 - total
            lines.append("🏅 已超过半马距离！再走 \(String(format: "%.1f", remaining)) km 就是一个全马。")
        } else if total >= 10 {
            let remaining = 21.1 - total
            lines.append("🎯 再走 \(String(format: "%.1f", remaining)) 公里就达到半马距离了。")
        } else if total >= 5 {
            lines.append("🚶 保持日常步行，积少成多。")
        }

        // Sparkline
        if distanceDays.count >= 3 {
            let sorted = distanceDays.sorted { $0.date < $1.date }
            let maxDist = sorted.map(\.distanceKm).max() ?? 1
            if maxDist > 0 {
                let sparkChars: [Character] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
                let spark = sorted.map { day -> Character in
                    let idx = min(Int(day.distanceKm / maxDist * 7), 7)
                    return sparkChars[idx]
                }
                lines.append("📈 距离趋势：\(String(spark))")
            }
        }

        // --- Overall insight ---
        lines.append("")
        if avg >= goalKm {
            lines.append("✅ 日均活动距离充足，保持现在的节奏！")
        } else if avg >= 3 {
            let extraMin = Int((goalKm - avg) / 0.08) // ~80m per minute of walking
            lines.append("💡 每天再多走 \(extraMin) 分钟就达到推荐活动量——午间散步是个好选择。")
        } else {
            lines.append("🌱 增加日常步行是最简单的运动方式，从出门走走开始吧。")
        }

        completion(lines.joined(separator: "\n"))
    }

    // MARK: - Calories (Active Energy)

    private func respondCalories(summaries: [HealthSummary], allSummaries: [HealthSummary] = [], range: QueryTimeRange, completion: @escaping (String) -> Void) {
        let calDays = summaries.filter { $0.activeCalories > 0 }
        guard !calDays.isEmpty else {
            completion("🔥 \(range.label)暂无热量消耗数据。\n开启健康权限后可以自动追踪每日活动消耗。")
            return
        }

        let cal = Calendar.current
        var lines: [String] = ["🔥 \(range.label)的热量消耗分析\n"]

        let total = calDays.reduce(0) { $0 + $1.activeCalories }
        let avg = total / Double(calDays.count)
        let best = calDays.max(by: { $0.activeCalories < $1.activeCalories })!
        let worst = calDays.min(by: { $0.activeCalories < $1.activeCalories })!

        // Core metrics
        lines.append("🔥 总活动消耗：\(Int(total).formatted()) 千卡")

        // --- Personal baseline comparison for single-day queries ---
        let isSingleDay = (range == .today || range == .yesterday || range == .dayBeforeYesterday)
        if isSingleDay, let todayCal = calDays.first {
            let interval = range.interval
            let baseline = allSummaries.filter { $0.activeCalories > 0 && !interval.contains($0.date) }
            if !baseline.isEmpty {
                let baselineAvg = baseline.reduce(0) { $0 + $1.activeCalories } / Double(baseline.count)
                let diff = todayCal.activeCalories - baselineAvg
                let pct = baselineAvg > 0 ? abs(diff) / baselineAvg * 100 : 0

                if pct >= 10 && baselineAvg > 0 {
                    if diff > 0 {
                        lines.append("📈 比你 7 日均值（\(Int(baselineAvg).formatted())）高 \(Int(pct))%")
                    } else {
                        lines.append("📉 比你 7 日均值（\(Int(baselineAvg).formatted())）低 \(Int(pct))%")
                    }
                } else if baselineAvg > 0 {
                    lines.append("📊 与你 7 日均值（\(Int(baselineAvg).formatted())）持平")
                }
            }

            // Ring completion progress for today
            if range == .today {
                let goalKcal = 500.0
                if todayCal.activeCalories >= goalKcal {
                    lines.append("🔴 活动环已合环！超出 \(Int(todayCal.activeCalories - goalKcal)) 千卡 ✅")
                } else {
                    let remaining = goalKcal - todayCal.activeCalories
                    let walkMin = Int(remaining / 5) // ~5 kcal per minute of brisk walking
                    lines.append("🔴 距合环（\(Int(goalKcal))千卡）还差 \(Int(remaining)) 千卡（约快走 \(walkMin) 分钟）")
                }
            }
        } else {
            lines.append("📊 日均消耗：\(Int(avg).formatted()) 千卡")
        }

        if calDays.count > 1 {
            let fmt = DateFormatter()
            fmt.dateFormat = "M月d日(E)"
            fmt.locale = Locale(identifier: "zh_CN")
            lines.append("🏆 最多的一天：\(fmt.string(from: best.date))  \(Int(best.activeCalories).formatted()) 千卡")
            lines.append("📉 最少的一天：\(fmt.string(from: worst.date))  \(Int(worst.activeCalories).formatted()) 千卡")
        }

        // Goal analysis (Apple Watch default ring: 500 kcal active, adjustable)
        let goalKcal = 500.0
        let goalDays = calDays.filter { $0.activeCalories >= goalKcal }.count
        let goalRate = Double(goalDays) / Double(calDays.count) * 100
        lines.append("\n🎯 达标天数（≥\(Int(goalKcal))千卡）：\(goalDays)/\(calDays.count) 天（\(Int(goalRate))%）")

        if goalRate >= 80 {
            lines.append("   太棒了！大部分时间都合环了 🏅")
        } else if goalRate >= 50 {
            lines.append("   过半天数达标，保持这个节奏 💪")
        } else if avg >= 300 {
            lines.append("   每天再多活动一点就能合环了，加油！")
        } else {
            lines.append("   活动消耗偏少，从每天多走 15 分钟开始？")
        }

        // Calorie source breakdown: correlate with exercise and steps
        let exerciseDays = calDays.filter { $0.exerciseMinutes > 0 }
        if !exerciseDays.isEmpty {
            let totalExMin = exerciseDays.reduce(0) { $0 + $1.exerciseMinutes }
            let totalExCal = exerciseDays.reduce(0) { $0 + $1.activeCalories }
            if totalExMin > 0 {
                let calPerMin = totalExCal / totalExMin
                lines.append("\n⏱ 运动效率：日均 \(Int(totalExMin / Double(calDays.count))) 分钟运动")
                lines.append("   每分钟运动约消耗 \(String(format: "%.1f", calPerMin)) 千卡")
            }
        }

        // --- Day-by-day visual trend chart ---
        if calDays.count >= 3 {
            let sorted = calDays.sorted { $0.date < $1.date }
            lines.append("")
            lines.append("📈 逐日趋势")
            let dayFmt = DateFormatter()
            dayFmt.dateFormat = "E"
            dayFmt.locale = Locale(identifier: "zh_CN")
            let maxCalVal = sorted.map(\.activeCalories).max() ?? 1
            for day in sorted {
                let blocks = max(1, min(8, Int((day.activeCalories / maxCalVal) * 8)))
                let bar = String(repeating: "▓", count: blocks) + String(repeating: "░", count: 8 - blocks)
                let color = day.activeCalories >= goalKcal ? "🟢" : (day.activeCalories >= goalKcal * 0.7 ? "🟡" : "🔴")
                lines.append("   \(dayFmt.string(from: day.date)) \(color) \(bar) \(Int(day.activeCalories).formatted()) kcal")
            }
        }

        // Weekday vs weekend pattern
        if calDays.count >= 5 {
            let weekdays = calDays.filter { !cal.isDateInWeekend($0.date) }
            let weekends = calDays.filter { cal.isDateInWeekend($0.date) }
            if !weekdays.isEmpty && !weekends.isEmpty {
                let wdAvg = weekdays.reduce(0) { $0 + $1.activeCalories } / Double(weekdays.count)
                let weAvg = weekends.reduce(0) { $0 + $1.activeCalories } / Double(weekends.count)
                let diff = abs(weAvg - wdAvg) / max(wdAvg, 1) * 100
                if diff > 15 {
                    let more = weAvg > wdAvg ? "周末" : "工作日"
                    lines.append("\n🗓 工作日均 \(Int(wdAvg).formatted()) · 周末均 \(Int(weAvg).formatted()) 千卡（\(more)更活跃）")
                }
            }
        }

        // --- Consistency analysis (coefficient of variation) ---
        if calDays.count >= 3 {
            let cv = coefficient(of: calDays.map { $0.activeCalories })
            lines.append("")
            if cv < 0.2 {
                lines.append("🎯 热量消耗非常规律（波动仅 \(Int(cv * 100))%），运动习惯很稳定！")
            } else if cv < 0.4 {
                lines.append("📊 消耗比较规律（波动 \(Int(cv * 100))%），偶有高低起伏。")
            } else {
                lines.append("🎢 消耗波动较大（\(Int(cv * 100))%），固定每天的运动时间有助于稳定消耗。")
            }
        }

        // Trend (first half vs second half)
        if calDays.count >= 4 {
            let sorted = calDays.sorted { $0.date < $1.date }
            let mid = sorted.count / 2
            let olderAvg = sorted.prefix(mid).reduce(0) { $0 + $1.activeCalories } / Double(mid)
            let recentAvg = sorted.suffix(from: mid).reduce(0) { $0 + $1.activeCalories } / Double(sorted.count - mid)
            if olderAvg > 0 {
                let pct = ((recentAvg - olderAvg) / olderAvg) * 100
                if abs(pct) >= 10 {
                    let trend = pct > 0
                        ? "📈 消耗呈上升趋势（+\(Int(pct))%），活动量在增加！"
                        : "📉 消耗有所下降（\(Int(pct))%），试试增加每天的活动量。"
                    lines.append("\n\(trend)")
                } else {
                    lines.append("\n📊 消耗量保持稳定，节奏不错。")
                }
            }
        }

        // --- Cross-metric: calories vs sleep correlation ---
        if calDays.count >= 4 {
            let paired = summaries.filter { $0.activeCalories > 0 && $0.sleepHours > 0 }
            if paired.count >= 3 {
                let calMedian = paired.map(\.activeCalories).sorted()[paired.count / 2]
                let highCalDays = paired.filter { $0.activeCalories >= calMedian }
                let lowCalDays = paired.filter { $0.activeCalories < calMedian }
                if !highCalDays.isEmpty && !lowCalDays.isEmpty {
                    let sleepOnHigh = highCalDays.reduce(0) { $0 + $1.sleepHours } / Double(highCalDays.count)
                    let sleepOnLow = lowCalDays.reduce(0) { $0 + $1.sleepHours } / Double(lowCalDays.count)
                    let sleepDiff = sleepOnHigh - sleepOnLow
                    if abs(sleepDiff) >= 0.3 {
                        lines.append("")
                        lines.append("🔗 消耗与睡眠的关联")
                        if sleepDiff > 0 {
                            lines.append("   高消耗日平均多睡 \(String(format: "%.1f", sleepDiff)) 小时 — 活动量大有助于提升睡眠质量。")
                        } else {
                            lines.append("   低消耗日反而多睡 \(String(format: "%.1f", -sleepDiff)) 小时 — 可能在休息日补觉较多。")
                        }
                    }
                }
            }
        }

        // Fun equivalencies
        lines.append("")
        if total >= 7700 {
            // ~7700 kcal ≈ 1 kg body fat
            let kgFat = total / 7700
            lines.append("💡 累计消耗约等于 \(String(format: "%.1f", kgFat)) kg 脂肪的热量")
        }
        // Food equivalence
        let mealEquiv = Int(total / 600) // ~600 kcal per average meal
        if mealEquiv >= 1 {
            lines.append("🍱 约等于 \(mealEquiv) 顿正餐的热量")
        }

        // Sparkline
        if calDays.count >= 3 {
            let sorted = calDays.sorted { $0.date < $1.date }
            let maxCal = sorted.map(\.activeCalories).max() ?? 1
            if maxCal > 0 {
                let sparkChars: [Character] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
                let spark = sorted.map { day -> Character in
                    let idx = min(Int(day.activeCalories / maxCal * 7), 7)
                    return sparkChars[idx]
                }
                lines.append("📈 消耗趋势：\(String(spark))")
            }
        }

        // Overall insight
        lines.append("")
        if avg >= goalKcal {
            lines.append("✅ 活动消耗健康，保持现在的运动习惯！")
        } else if avg >= goalKcal * 0.7 {
            let gap = Int(goalKcal - avg)
            lines.append("💡 每天再多消耗 \(gap) 千卡就达标了——大约快走 \(gap / 5) 分钟。")
        } else {
            lines.append("🌱 增加日常活动是提升消耗最简单的方式，从走路开始吧。")
        }

        completion(lines.joined(separator: "\n"))
    }

    // MARK: - Weight / Body Mass

    private func respondWeight(summaries: [HealthSummary], range: QueryTimeRange,
                               context: SkillContext, completion: @escaping (String) -> Void) {
        // Weight data is sparse (usually 1 record/day or less), so fetch 30 days for trend context
        context.healthService.fetchSummaries(days: 30) { allSummaries in
            let weightDays = allSummaries.filter { $0.bodyMassKg > 0 }.sorted { $0.date < $1.date }

            guard !weightDays.isEmpty else {
                var lines: [String] = ["⚖️ **体重数据**\n"]
                lines.append("暂无体重记录。")
                lines.append("")
                lines.append("💡 你可以通过以下方式记录体重：")
                lines.append("• 连接智能体重秤（如 Withings、小米等）自动同步")
                lines.append("• 在 Apple 健康 App 中手动添加体重数据")
                lines.append("")
                lines.append("记录后再来问我，我会帮你分析趋势！")
                completion(lines.joined(separator: "\n"))
                return
            }

            // Also filter summaries within the requested range
            let interval = range.interval
            let rangeWeightDays = weightDays.filter { interval.contains($0.date) }

            var lines: [String] = ["⚖️ **\(range.label)的体重数据**\n"]
            let cal = Calendar.current
            let dateFormatter = DateFormatter()
            dateFormatter.locale = Locale(identifier: "zh_CN")
            dateFormatter.dateFormat = "M/d"

            let latest = weightDays.last!
            lines.append("📌 最新体重：**\(String(format: "%.1f", latest.bodyMassKg)) kg**（\(dateFormatter.string(from: latest.date))）")

            // Range-specific data
            if !rangeWeightDays.isEmpty && rangeWeightDays.count > 1 {
                let first = rangeWeightDays.first!
                let last = rangeWeightDays.last!
                let change = last.bodyMassKg - first.bodyMassKg
                let changeStr: String
                if abs(change) < 0.1 {
                    changeStr = "基本持平 →"
                } else if change > 0 {
                    changeStr = "增加 \(String(format: "%.1f", change)) kg ↑"
                } else {
                    changeStr = "减少 \(String(format: "%.1f", abs(change))) kg ↓"
                }

                lines.append("")
                lines.append("📈 \(range.label)变化：\(changeStr)")
                lines.append("　　\(dateFormatter.string(from: first.date)) \(String(format: "%.1f", first.bodyMassKg)) → \(dateFormatter.string(from: last.date)) \(String(format: "%.1f", last.bodyMassKg))")

                // Average in range
                let avg = rangeWeightDays.reduce(0.0) { $0 + $1.bodyMassKg } / Double(rangeWeightDays.count)
                let maxW = rangeWeightDays.max(by: { $0.bodyMassKg < $1.bodyMassKg })!
                let minW = rangeWeightDays.min(by: { $0.bodyMassKg < $1.bodyMassKg })!
                lines.append("　　平均：\(String(format: "%.1f", avg)) kg")
                if maxW.bodyMassKg - minW.bodyMassKg > 0.2 {
                    lines.append("　　波动：\(String(format: "%.1f", minW.bodyMassKg)) ~ \(String(format: "%.1f", maxW.bodyMassKg)) kg")
                }
            }

            // 30-day trend (if enough data points)
            if weightDays.count >= 3 {
                let oldest = weightDays.first!
                let newest = weightDays.last!
                let totalChange = newest.bodyMassKg - oldest.bodyMassKg
                let daysBetween = max(cal.dateComponents([.day], from: oldest.date, to: newest.date).day ?? 1, 1)

                lines.append("")
                lines.append("📊 **近期趋势**（\(weightDays.count) 条记录，跨 \(daysBetween) 天）")

                if abs(totalChange) < 0.3 {
                    lines.append("体重保持稳定，波动极小。👍")
                } else if totalChange > 0 {
                    let weeklyRate = totalChange / Double(daysBetween) * 7
                    lines.append("整体呈上升趋势，\(String(format: "%.1f", totalChange)) kg（周均 +\(String(format: "%.1f", weeklyRate)) kg）")
                    if weeklyRate > 0.5 {
                        lines.append("⚠️ 体重增长较快，建议关注饮食和运动平衡。")
                    }
                } else {
                    let weeklyRate = abs(totalChange) / Double(daysBetween) * 7
                    lines.append("整体呈下降趋势，减少 \(String(format: "%.1f", abs(totalChange))) kg（周均 -\(String(format: "%.1f", weeklyRate)) kg）")
                    if weeklyRate > 1.0 {
                        lines.append("⚠️ 减重速度偏快，建议控制在每周 0.5~1 kg，保护身体。")
                    } else if weeklyRate > 0.3 {
                        lines.append("✅ 减重节奏健康，继续保持！")
                    }
                }

                // Daily weight log (recent 7 entries max)
                let recentEntries = weightDays.suffix(7)
                if recentEntries.count > 1 {
                    lines.append("")
                    lines.append("📋 **近期记录**")
                    for entry in recentEntries {
                        let dayLabel = cal.isDateInToday(entry.date) ? "今天" :
                                       cal.isDateInYesterday(entry.date) ? "昨天" :
                                       dateFormatter.string(from: entry.date)
                        let diff = entry.bodyMassKg - (weightDays.first { $0.date < entry.date && $0.bodyMassKg > 0 }?.bodyMassKg ?? entry.bodyMassKg)
                        let diffStr: String
                        if abs(diff) < 0.05 {
                            diffStr = ""
                        } else if diff > 0 {
                            diffStr = " (+\(String(format: "%.1f", diff)))"
                        } else {
                            diffStr = " (\(String(format: "%.1f", diff)))"
                        }
                        lines.append("　\(dayLabel)　\(String(format: "%.1f", entry.bodyMassKg)) kg\(diffStr)")
                    }
                }
            } else if weightDays.count == 1 {
                lines.append("")
                lines.append("📝 目前只有 1 条记录，持续记录后我可以帮你分析体重趋势。")
            }

            // Insight: correlate with exercise if weight trend is notable
            if weightDays.count >= 5 {
                let newest = weightDays.last!
                let oldest = weightDays.first!
                let change = newest.bodyMassKg - oldest.bodyMassKg
                let exerciseDays = summaries.filter { $0.exerciseMinutes > 0 }

                if abs(change) > 0.5 && !exerciseDays.isEmpty {
                    let avgExercise = exerciseDays.reduce(0.0) { $0 + $1.exerciseMinutes } / Double(exerciseDays.count)
                    lines.append("")
                    if change < 0 && avgExercise > 20 {
                        lines.append("💪 同期日均运动 \(Int(avgExercise)) 分钟，运动配合减重效果不错！")
                    } else if change > 0 && avgExercise < 15 {
                        lines.append("💡 同期运动较少（日均 \(Int(avgExercise)) 分钟），增加运动量可能有帮助。")
                    }
                }
            }

            completion(lines.joined(separator: "\n"))
        }
    }

    // MARK: - Recovery Readiness

    /// Synthesizes HRV, sleep quality, resting HR, and recent training load into
    /// a single "recovery readiness" score (0-100) with actionable training advice.
    /// Uses today's data compared against the user's own 7-day baseline — not
    /// population averages — so the insight is truly personal.
    private func respondRecovery(summaries: [HealthSummary], todaySummaries: [HealthSummary],
                                 range: QueryTimeRange, context: SkillContext, completion: @escaping (String) -> Void) {
        let interval = range.interval
        let cal = Calendar.current
        let isSingleDay = range == .today || range == .yesterday ||
            (cal.dateComponents([.day], from: interval.start, to: interval.end).day ?? 0) <= 1

        // Fetch enough data: the requested range + 7 extra days for baseline
        let daysForRange = max(cal.dateComponents([.day], from: interval.start, to: Date()).day ?? 7, 1) + 1
        let totalFetch = daysForRange + 7
        context.healthService.fetchSummaries(days: totalFetch) { allData in
            let rangeData = allData.filter { interval.contains($0.date) && $0.hasData }
            // Baseline: 7 days preceding the range start for personal comparison
            let baselineEnd = interval.start
            let baselineStart = cal.date(byAdding: .day, value: -7, to: baselineEnd) ?? baselineEnd
            let baseline = allData.filter { $0.date >= baselineStart && $0.date < baselineEnd && $0.hasData }

            // For single-day mode, use the most recent day with data
            let focusDay = isSingleDay
                ? (rangeData.sorted { $0.date > $1.date }.first ?? allData.sorted { $0.date > $1.date }.first)
                : nil
            let effectiveBaseline = baseline.isEmpty ? allData.filter { $0.hasData } : baseline

            guard (!isSingleDay && !rangeData.isEmpty) || (isSingleDay && focusDay != nil) else {
                completion("🔋 暂无足够的健康数据来评估恢复状态。\n请确保已开启健康权限，佩戴 Apple Watch 可提供更精准的恢复分析。")
                return
            }

            if isSingleDay, let day = focusDay {
                // ── Single-day detailed breakdown with calendar context ──
                self.respondRecoverySingleDay(day: day, baseline: effectiveBaseline, range: range, context: context, completion: completion)
            } else {
                // ── Multi-day recovery trend ──
                self.respondRecoveryTrend(days: rangeData, baseline: effectiveBaseline, range: range, completion: completion)
            }
        }
    }

    // MARK: - Single-Day Recovery (detailed breakdown)

    private func respondRecoverySingleDay(day: HealthSummary, baseline: [HealthSummary],
                                          range: QueryTimeRange, context: SkillContext,
                                          completion: @escaping (String) -> Void) {
        let dayLabel = range == .today ? "今日" : range.label
        var lines: [String] = ["🔋 \(dayLabel)恢复状态分析\n"]

        let score = computeDailyRecoveryScore(day: day, baseline: baseline)

        // Score display with visual bar
        let barFilled = max(1, score.total / 10)
        let barEmpty = 10 - barFilled
        let barStr = String(repeating: "▓", count: barFilled) + String(repeating: "░", count: barEmpty)

        let (scoreEmoji, readiness) = recoveryLabel(score: score.total)

        lines.append("\(scoreEmoji) 恢复指数：\(score.total) / 100 — \(readiness)")
        lines.append("   \(barStr)")

        // Data completeness note: when dimensions are missing, the score is still
        // accurate for the available data but the user should know it's partial.
        if score.missingDimensionCount > 0 {
            let availableCount = 4 - score.missingDimensionCount
            lines.append("   基于 \(availableCount)/4 项指标评估")
        }

        // Dimension breakdown
        lines.append("")
        for dim in score.dimensions {
            if dim.maxScore == 0 {
                // Dimension excluded from scoring — show as greyed-out
                lines.append("\(dim.emoji) \(dim.name)  —  \(dim.detail)")
            } else {
                let dimBar = max(1, dim.score * 5 / dim.maxScore)
                let dimBarStr = String(repeating: "●", count: dimBar) + String(repeating: "○", count: 5 - dimBar)
                lines.append("\(dim.emoji) \(dim.name) \(dimBarStr) \(dim.score)/\(dim.maxScore)")
                lines.append("   \(dim.detail)")
            }
        }

        // Suggest Apple Watch for more complete recovery analysis
        if score.missingDimensionCount >= 2 {
            lines.append("")
            lines.append("⌚ 佩戴 Apple Watch 可获取 HRV 和静息心率数据，恢复评估会更全面精准。")
        }

        // --- Calendar-Aware Training Recommendation ---
        // Cross-reference recovery score with today's schedule to suggest
        // not just WHAT to do, but WHEN the user can actually do it.
        lines.append("")
        lines.append("💡 训练建议")

        // Fetch today's calendar for timing context (only for today/yesterday queries)
        let todayEvents: [CalendarEventItem]
        if range == .today {
            todayEvents = context.calendarService.todayEvents().filter { !$0.isAllDay }
        } else {
            todayEvents = []
        }

        // Base recommendation by recovery score
        let trainingType: String
        let trainingList: String
        if score.total >= 85 {
            trainingType = "高强度训练"
            trainingList = "可以挑战：间歇跑、HIIT、力量训练、速度训练"
            lines.append("身体恢复充分，今天适合高强度训练！")
        } else if score.total >= 70 {
            trainingType = "中高强度训练"
            trainingList = "推荐：稳态有氧、常规力量训练、球类运动"
            lines.append("状态不错，适合中高强度训练。")
        } else if score.total >= 55 {
            trainingType = "中低强度活动"
            trainingList = "推荐：轻松慢跑、瑜伽、散步、拉伸"
            lines.append("身体还在恢复，建议中低强度活动。")
        } else if score.total >= 40 {
            trainingType = "轻度活动"
            trainingList = "推荐：散步、轻度拉伸、冥想，避免高强度运动"
            lines.append("恢复不足，今天以轻度活动为主。")
        } else {
            trainingType = "恢复为主"
            trainingList = "推荐：充足睡眠、轻度散步、放松活动"
            lines.append("身体需要休息，建议今天以恢复为主。")
            lines.append("如果持续多天恢复不佳，请留意是否有过度训练或生活压力。")
        }
        lines.append(trainingList)

        // --- Calendar ↔ Recovery cross-data: find free windows for exercise ---
        if range == .today && !todayEvents.isEmpty {
            let calendarInsight = buildRecoveryCalendarInsight(
                events: todayEvents, recoveryScore: score.total, trainingType: trainingType
            )
            if !calendarInsight.isEmpty {
                lines.append("")
                lines.append("📅 结合今日日程")
                lines.append(contentsOf: calendarInsight)
            }
        } else if range == .today && todayEvents.isEmpty {
            lines.append("")
            if score.total >= 55 {
                lines.append("📅 今天没有日程安排，随时可以运动！选一个你最有精力的时段吧。")
            } else {
                lines.append("📅 今天日程空闲，可以充分休息恢复。")
            }
        }

        // --- HRV trend note ---
        if baseline.count >= 4 {
            let sorted = baseline.sorted { $0.date > $1.date }
            let recentHRV = sorted.prefix(3).filter { $0.hrv > 0 }
            let olderHRV = sorted.suffix(from: min(3, sorted.count)).filter { $0.hrv > 0 }

            if recentHRV.count >= 2 && olderHRV.count >= 2 {
                let recentAvgHRV = recentHRV.reduce(0) { $0 + $1.hrv } / Double(recentHRV.count)
                let olderAvgHRV = olderHRV.reduce(0) { $0 + $1.hrv } / Double(olderHRV.count)
                let trendDiff = recentAvgHRV - olderAvgHRV

                if abs(trendDiff) >= 5 {
                    lines.append("")
                    if trendDiff > 0 {
                        lines.append("📈 恢复趋势向好：近几天 HRV 上升 \(Int(trendDiff)) ms，身体在逐步恢复。")
                    } else {
                        lines.append("📉 恢复趋势下降：近几天 HRV 下降 \(Int(-trendDiff)) ms，注意休息和压力管理。")
                    }
                }
            }
        }

        completion(lines.joined(separator: "\n"))
    }

    // MARK: - Recovery × Calendar Insight

    /// Cross-references the user's recovery score with today's calendar events to find
    /// free windows for exercise. This is core iosclaw value: only a personal AI with access
    /// to both HealthKit and EventKit can answer "when should I work out today?"
    private func buildRecoveryCalendarInsight(events: [CalendarEventItem],
                                              recoveryScore: Int,
                                              trainingType: String) -> [String] {
        let cal = Calendar.current
        let now = Date()
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"

        // Sort events by start time
        let sorted = events.sorted { $0.startDate < $1.startDate }

        // Calculate total meeting hours
        let totalMeetingMinutes = sorted.reduce(0.0) { $0 + $1.duration / 60 }
        let eventCount = sorted.count

        var lines: [String] = []

        // Describe today's calendar load
        if totalMeetingMinutes >= 360 { // 6+ hours of meetings
            lines.append("今天有 \(eventCount) 个日程（共约 \(Self.formatDurationShort(totalMeetingMinutes))），日程比较紧张。")
        } else if totalMeetingMinutes >= 180 { // 3-6 hours
            lines.append("今天有 \(eventCount) 个日程（共约 \(Self.formatDurationShort(totalMeetingMinutes))）。")
        } else {
            lines.append("今天日程较轻松（\(eventCount) 个，共 \(Self.formatDurationShort(totalMeetingMinutes))）。")
        }

        // Find free windows (gaps between events where exercise is possible)
        // Only look at future windows (or from morning if it's still early)
        let dayStart = cal.startOfDay(for: now)
        let scanStart: Date
        let currentHour = cal.component(.hour, from: now)
        if currentHour < 6 {
            // Very early — scan from 6 AM
            scanStart = cal.date(bySettingHour: 6, minute: 0, second: 0, of: now) ?? now
        } else {
            scanStart = now
        }
        let dayEnd = cal.date(bySettingHour: 22, minute: 0, second: 0, of: dayStart) ?? dayStart

        guard scanStart < dayEnd else {
            lines.append("今天已经比较晚了，明天再安排运动吧。")
            return lines
        }

        // Build free windows by scanning gaps between events
        struct FreeWindow {
            let start: Date
            let end: Date
            var minutes: Double { end.timeIntervalSince(start) / 60 }
        }

        var freeWindows: [FreeWindow] = []
        var cursor = scanStart

        for event in sorted {
            // Skip events that already ended
            guard event.endDate > scanStart else { continue }
            let eventStart = max(event.startDate, scanStart)
            if eventStart > cursor {
                let gap = FreeWindow(start: cursor, end: eventStart)
                if gap.minutes >= 20 { // At least 20 minutes to be useful
                    freeWindows.append(gap)
                }
            }
            cursor = max(cursor, event.endDate)
        }
        // Gap after last event until evening
        if cursor < dayEnd {
            let gap = FreeWindow(start: cursor, end: dayEnd)
            if gap.minutes >= 20 {
                freeWindows.append(gap)
            }
        }

        // Recommend specific time windows
        if freeWindows.isEmpty {
            if recoveryScore >= 55 {
                lines.append("日程排得很满，不过可以利用会间休息走动 5-10 分钟，积少成多。")
            } else {
                lines.append("日程密集，恢复又不够充分，今天专注工作就好，运动可以明天再安排。")
            }
        } else {
            // Find the best window for exercise
            // Prefer: long enough for the recommended training type, and not too late
            let minMinutesForTraining: Double = recoveryScore >= 70 ? 45 : 30

            // Sort by: windows that are long enough first, then by start time (prefer earlier)
            let goodWindows = freeWindows.filter { $0.minutes >= minMinutesForTraining }
            let bestWindow = goodWindows.first ?? freeWindows.max(by: { $0.minutes < $1.minutes })

            if let window = bestWindow {
                let startStr = timeFmt.string(from: window.start)
                let endStr = timeFmt.string(from: window.end)
                let windowMins = Int(window.minutes)

                if windowMins >= 60 {
                    lines.append("⏰ 推荐运动时段：\(startStr)-\(endStr)（\(windowMins) 分钟空闲）")
                    if recoveryScore >= 70 {
                        lines.append("   时间充裕，可以完成一次完整的\(trainingType)。")
                    } else {
                        lines.append("   时间充裕，但注意控制强度，\(trainingType)为宜。")
                    }
                } else if windowMins >= 30 {
                    lines.append("⏰ 推荐运动时段：\(startStr)-\(endStr)（\(windowMins) 分钟空闲）")
                    lines.append("   时间紧凑，可以做一组高效的 \(windowMins - 10) 分钟训练（留 10 分钟洗漱）。")
                } else {
                    lines.append("⏰ \(startStr)-\(endStr) 有 \(windowMins) 分钟空隙")
                    lines.append("   适合快走、拉伸或简短的活动。")
                }
            }

            // If there are multiple good windows, mention alternatives
            if freeWindows.count >= 2 {
                let otherWindows = freeWindows.filter { $0.start != (bestWindow?.start ?? Date()) }.prefix(2)
                if !otherWindows.isEmpty {
                    let alternatives = otherWindows.map { w in
                        "\(timeFmt.string(from: w.start))-\(timeFmt.string(from: w.end))（\(Int(w.minutes))分钟）"
                    }.joined(separator: "、")
                    lines.append("   备选时段：\(alternatives)")
                }
            }
        }

        // Back-to-back meeting warning: suggest movement between long consecutive meetings
        let consecutiveBlocks = findConsecutiveMeetingBlocks(events: sorted)
        for block in consecutiveBlocks where block.count >= 3 {
            let blockMinutes = block.reduce(0.0) { $0 + $1.duration / 60 }
            if blockMinutes >= 120 {
                let endTime = timeFmt.string(from: block.last!.endDate)
                lines.append("⚠️ \(block.count) 个连续日程到 \(endTime)，建议会间起身走动、做做拉伸。")
                break // Only show one such warning
            }
        }

        return lines
    }

    /// Finds groups of consecutive/overlapping events (gaps < 15 min are considered consecutive).
    private func findConsecutiveMeetingBlocks(events: [CalendarEventItem]) -> [[CalendarEventItem]] {
        guard !events.isEmpty else { return [] }
        var blocks: [[CalendarEventItem]] = []
        var current: [CalendarEventItem] = [events[0]]

        for i in 1..<events.count {
            let prev = current.last!
            let gap = events[i].startDate.timeIntervalSince(prev.endDate)
            if gap <= 900 { // 15 minutes or less between meetings
                current.append(events[i])
            } else {
                if current.count >= 2 { blocks.append(current) }
                current = [events[i]]
            }
        }
        if current.count >= 2 { blocks.append(current) }
        return blocks
    }

    /// Formats minutes into a short duration string like "3.5h" or "45分钟".
    private static func formatDurationShort(_ minutes: Double) -> String {
        if minutes >= 60 {
            let hours = minutes / 60
            if hours == Double(Int(hours)) {
                return "\(Int(hours)) 小时"
            }
            return "\(String(format: "%.1f", hours)) 小时"
        }
        return "\(Int(minutes)) 分钟"
    }

    // MARK: - Multi-Day Recovery Trend

    private func respondRecoveryTrend(days: [HealthSummary], baseline: [HealthSummary],
                                      range: QueryTimeRange, completion: @escaping (String) -> Void) {
        let sorted = days.sorted { $0.date < $1.date }
        var lines: [String] = ["🔋 \(range.label)恢复状态趋势\n"]

        // Compute per-day recovery scores
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "E"
        dayFmt.locale = Locale(identifier: "zh_CN")
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "M/d"
        dateFmt.locale = Locale(identifier: "zh_CN")

        var dailyScores: [(date: Date, score: Int, label: String)] = []
        var totalMissingDimensions = 0
        for day in sorted {
            let score = computeDailyRecoveryScore(day: day, baseline: baseline)
            let label = sorted.count <= 7 ? dayFmt.string(from: day.date) : dateFmt.string(from: day.date)
            dailyScores.append((day.date, score.total, label))
            totalMissingDimensions += score.missingDimensionCount
        }

        guard !dailyScores.isEmpty else {
            lines.append("暂无足够数据生成恢复趋势。")
            completion(lines.joined(separator: "\n"))
            return
        }

        // Average score
        let avgScore = dailyScores.reduce(0) { $0 + $1.score } / dailyScores.count
        let (avgEmoji, avgReadiness) = recoveryLabel(score: avgScore)
        lines.append("\(avgEmoji) 平均恢复指数：\(avgScore) / 100 — \(avgReadiness)")

        // Score distribution
        let greenDays = dailyScores.filter { $0.score >= 70 }.count
        let yellowDays = dailyScores.filter { $0.score >= 40 && $0.score < 70 }.count
        let redDays = dailyScores.filter { $0.score < 40 }.count
        var distParts: [String] = []
        if greenDays > 0 { distParts.append("🟢 \(greenDays)天") }
        if yellowDays > 0 { distParts.append("🟡 \(yellowDays)天") }
        if redDays > 0 { distParts.append("🔴 \(redDays)天") }
        lines.append("   \(distParts.joined(separator: "  "))")

        // Day-by-day trend chart
        if dailyScores.count >= 2 {
            lines.append("")
            lines.append("📈 逐日恢复趋势")
            for entry in dailyScores {
                let (emoji, _) = recoveryLabel(score: entry.score)
                let barCount = max(1, entry.score / 10)
                let bar = String(repeating: "▓", count: barCount) + String(repeating: "░", count: 10 - barCount)
                lines.append("   \(entry.label) \(emoji) \(bar) \(entry.score)")
            }
        }

        // Best and worst days
        if dailyScores.count >= 3 {
            let best = dailyScores.max(by: { $0.score < $1.score })!
            let worst = dailyScores.min(by: { $0.score < $1.score })!
            let bestFmt = DateFormatter()
            bestFmt.dateFormat = "M月d日(E)"
            bestFmt.locale = Locale(identifier: "zh_CN")

            if best.score != worst.score {
                lines.append("")
                lines.append("🏆 最佳恢复：\(bestFmt.string(from: best.date))（\(best.score)分）")
                lines.append("📉 最低恢复：\(bestFmt.string(from: worst.date))（\(worst.score)分）")
            }
        }

        // Trend direction (first half vs second half)
        if dailyScores.count >= 4 {
            let mid = dailyScores.count / 2
            let olderAvg = dailyScores.prefix(mid).reduce(0) { $0 + $1.score } / mid
            let recentAvg = dailyScores.suffix(from: mid).reduce(0) { $0 + $1.score } / (dailyScores.count - mid)
            let diff = recentAvg - olderAvg

            lines.append("")
            if diff >= 8 {
                lines.append("📈 恢复趋势向好（+\(diff)分），身体状态在改善！")
            } else if diff <= -8 {
                lines.append("📉 恢复趋势下降（\(diff)分），注意休息和压力管理。")
            } else {
                lines.append("📊 恢复状态保持稳定，波动不大。")
            }
        }

        // Underlying metric averages for context
        let sleepDays = sorted.filter { $0.sleepHours > 0 }
        let hrvDays = sorted.filter { $0.hrv > 0 }
        let rhrDays = sorted.filter { $0.restingHeartRate > 0 }
        let exerciseDays = sorted.filter { $0.exerciseMinutes > 0 }

        var contextLines: [String] = []
        if !sleepDays.isEmpty {
            let avgSleep = sleepDays.reduce(0) { $0 + $1.sleepHours } / Double(sleepDays.count)
            let goodSleepDays = sleepDays.filter { $0.sleepHours >= 7 && $0.sleepHours <= 9 }.count
            contextLines.append("😴 平均睡眠 \(String(format: "%.1f", avgSleep))h（\(goodSleepDays)/\(sleepDays.count) 天在 7-9h 范围）")
        }
        if !hrvDays.isEmpty {
            let avgHRV = hrvDays.reduce(0) { $0 + $1.hrv } / Double(hrvDays.count)
            contextLines.append("📳 平均 HRV \(Int(avgHRV)) ms")
        }
        if !rhrDays.isEmpty {
            let avgRHR = rhrDays.reduce(0) { $0 + $1.restingHeartRate } / Double(rhrDays.count)
            contextLines.append("🫀 平均静息心率 \(Int(avgRHR)) BPM")
        }
        if !exerciseDays.isEmpty {
            let avgExercise = exerciseDays.reduce(0) { $0 + $1.exerciseMinutes } / Double(max(sorted.count, 1))
            contextLines.append("🏋️ 日均运动 \(Int(avgExercise)) 分钟")
        }

        if !contextLines.isEmpty {
            lines.append("")
            lines.append("📊 期间关键指标")
            lines.append(contentsOf: contextLines)
        }

        // Cross-data insight: correlate exercise days with recovery scores
        if dailyScores.count >= 4 {
            let pairedData = sorted.enumerated().compactMap { (idx, day) -> (exercise: Double, score: Int)? in
                guard idx < dailyScores.count else { return nil }
                return (day.exerciseMinutes, dailyScores[idx].score)
            }
            let exerciseMedian = sorted.map(\.exerciseMinutes).sorted()[sorted.count / 2]
            let highExDays = pairedData.filter { $0.exercise >= exerciseMedian && $0.exercise > 0 }
            let lowExDays = pairedData.filter { $0.exercise < exerciseMedian }

            if highExDays.count >= 2 && lowExDays.count >= 2 {
                let highExAvgScore = highExDays.reduce(0) { $0 + $1.score } / highExDays.count
                let lowExAvgScore = lowExDays.reduce(0) { $0 + $1.score } / lowExDays.count
                let scoreDiff = highExAvgScore - lowExAvgScore

                if abs(scoreDiff) >= 8 {
                    lines.append("")
                    if scoreDiff > 0 {
                        lines.append("💡 运动多的日子恢复评分反而更高（+\(scoreDiff)分）— 适度运动促进恢复。")
                    } else {
                        lines.append("💡 运动多的日子恢复评分更低（\(scoreDiff)分）— 可能训练强度偏大，注意恢复节奏。")
                    }
                }
            }
        }

        // Overall advice based on period
        lines.append("")
        if avgScore >= 70 {
            lines.append("✅ 恢复状态整体健康，身体节律不错！")
        } else if avgScore >= 50 {
            lines.append("💡 恢复状态一般，关注睡眠质量和训练负荷平衡。")
        } else {
            lines.append("⚠️ 恢复偏低，建议减少高强度训练，优先保障 7 小时以上睡眠。")
        }

        // Data completeness: if most days are missing Watch data, note it once
        let avgMissing = sorted.isEmpty ? 0 : totalMissingDimensions / sorted.count
        if avgMissing >= 2 {
            lines.append("")
            lines.append("⌚ 评分基于睡眠和运动数据。佩戴 Apple Watch 可获取 HRV 和静息心率，让恢复评估更全面。")
        }

        completion(lines.joined(separator: "\n"))
    }

    // MARK: - Daily Recovery Score Calculator

    /// Computes a recovery score (0-100) for a single day against a personal baseline.
    /// Reusable across single-day detail and multi-day trend views.
    private struct RecoveryScore {
        let total: Int
        let dimensions: [(name: String, emoji: String, score: Int, maxScore: Int, detail: String)]
        /// Number of dimensions that had no data and were excluded from scoring.
        let missingDimensionCount: Int
    }

    private func computeDailyRecoveryScore(day: HealthSummary, baseline: [HealthSummary]) -> RecoveryScore {
        var totalScore: Double = 0
        var maxPossible: Double = 0
        var dimensions: [(name: String, emoji: String, score: Int, maxScore: Int, detail: String)] = []
        var missingCount = 0

        // --- 1. Sleep Recovery (35 pts) ---
        // Sleep data comes from iPhone or Apple Watch — usually available.
        if day.sleepHours > 0 {
            maxPossible += 35
            var sleepScore: Double = 0
            let sleepDays = baseline.filter { $0.sleepHours > 0 }
            let avgSleep = sleepDays.isEmpty ? 7.5 : sleepDays.reduce(0) { $0 + $1.sleepHours } / Double(sleepDays.count)

            if day.sleepHours >= 7 && day.sleepHours <= 9 {
                sleepScore += 20
            } else if day.sleepHours >= 6 {
                sleepScore += 20 * (day.sleepHours - 5) / 2
            } else if day.sleepHours > 9 && day.sleepHours <= 10 {
                sleepScore += 20 * (10 - day.sleepHours)
            } else {
                sleepScore += 5
            }

            if day.hasSleepPhases {
                let phaseTotal = day.sleepDeepHours + day.sleepREMHours + day.sleepCoreHours
                if phaseTotal > 0 {
                    let deepPct = day.sleepDeepHours / phaseTotal * 100
                    if deepPct >= 15 && deepPct <= 25 { sleepScore += 15 }
                    else if deepPct >= 10 { sleepScore += 10 }
                    else { sleepScore += 5 }
                }
            } else {
                sleepScore += day.sleepHours >= avgSleep ? 12 : 7
            }

            totalScore += sleepScore
            let sleepDetail = day.hasSleepPhases
                ? "\(String(format: "%.1f", day.sleepHours))h（深睡 \(String(format: "%.1f", day.sleepDeepHours))h）"
                : "\(String(format: "%.1f", day.sleepHours))h"
            dimensions.append(("睡眠恢复", "😴", Int(sleepScore), 35, sleepDetail))
        } else {
            missingCount += 1
            dimensions.append(("睡眠恢复", "😴", 0, 0, "无数据（未纳入评分）"))
        }

        // --- 2. HRV Status (30 pts) ---
        // HRV requires Apple Watch — skip entirely when unavailable instead of
        // injecting a phantom mid-point score that would dilute the final result.
        let hrvDays = baseline.filter { $0.hrv > 0 }
        if day.hrv > 0 && !hrvDays.isEmpty {
            maxPossible += 30
            let avgHRV = hrvDays.reduce(0) { $0 + $1.hrv } / Double(hrvDays.count)
            let ratio = day.hrv / avgHRV

            var hrvScore: Double = 0
            if ratio >= 1.1 { hrvScore = 30 }
            else if ratio >= 0.95 { hrvScore = 25 }
            else if ratio >= 0.8 { hrvScore = 18 }
            else if ratio >= 0.65 { hrvScore = 10 }
            else { hrvScore = 5 }

            totalScore += hrvScore
            let pctChange = Int((ratio - 1) * 100)
            let pctStr = pctChange >= 0 ? "+\(pctChange)%" : "\(pctChange)%"
            dimensions.append(("心率变异性", "📳", Int(hrvScore), 30, "\(Int(day.hrv)) ms（\(pctStr)）"))
        } else if day.hrv > 0 {
            maxPossible += 30
            var hrvScore: Double = 0
            if day.hrv >= 50 { hrvScore = 25 }
            else if day.hrv >= 30 { hrvScore = 18 }
            else { hrvScore = 10 }
            totalScore += hrvScore
            dimensions.append(("心率变异性", "📳", Int(hrvScore), 30, "\(Int(day.hrv)) ms"))
        } else {
            missingCount += 1
            dimensions.append(("心率变异性", "📳", 0, 0, "无数据（需 Apple Watch）"))
        }

        // --- 3. Resting HR (20 pts) ---
        // Resting HR also requires Apple Watch — skip when unavailable.
        let rhrDays = baseline.filter { $0.restingHeartRate > 0 }
        if day.restingHeartRate > 0 && !rhrDays.isEmpty {
            maxPossible += 20
            let avgRHR = rhrDays.reduce(0) { $0 + $1.restingHeartRate } / Double(rhrDays.count)
            let diff = day.restingHeartRate - avgRHR

            var rhrScore: Double = 0
            if diff <= -2 { rhrScore = 20 }
            else if diff <= 2 { rhrScore = 17 }
            else if diff <= 5 { rhrScore = 10 }
            else { rhrScore = 4 }

            totalScore += rhrScore
            let diffStr: String
            if abs(diff) < 1 { diffStr = "基线" }
            else if diff > 0 { diffStr = "+\(Int(diff))" }
            else { diffStr = "\(Int(diff))" }
            dimensions.append(("静息心率", "🫀", Int(rhrScore), 20, "\(Int(day.restingHeartRate)) BPM（\(diffStr)）"))
        } else if day.restingHeartRate > 0 {
            maxPossible += 20
            var rhrScore: Double = 0
            if day.restingHeartRate <= 65 { rhrScore = 18 }
            else if day.restingHeartRate <= 75 { rhrScore = 14 }
            else { rhrScore = 8 }
            totalScore += rhrScore
            dimensions.append(("静息心率", "🫀", Int(rhrScore), 20, "\(Int(day.restingHeartRate)) BPM"))
        } else {
            missingCount += 1
            dimensions.append(("静息心率", "🫀", 0, 0, "无数据（需 Apple Watch）"))
        }

        // --- 4. Training Load (15 pts) ---
        // Training load uses exercise minutes which are available from iPhone.
        maxPossible += 15
        let recentExercise = baseline.suffix(3).reduce(0) { $0 + $1.exerciseMinutes }
        let avgDailyExercise = baseline.reduce(0) { $0 + $1.exerciseMinutes } / Double(max(baseline.count, 1))

        var loadScore: Double = 0
        if recentExercise == 0 && avgDailyExercise == 0 {
            loadScore = 12
        } else {
            let recent3DayAvg = recentExercise / 3.0
            let loadRatio = avgDailyExercise > 0 ? recent3DayAvg / avgDailyExercise : 1.0
            if loadRatio <= 0.5 { loadScore = 15 }
            else if loadRatio <= 1.0 { loadScore = 12 }
            else if loadRatio <= 1.5 { loadScore = 8 }
            else { loadScore = 4 }
        }
        totalScore += loadScore

        let loadDetail: String
        if day.exerciseMinutes > 0 {
            loadDetail = "\(Int(day.exerciseMinutes)) 分钟运动"
        } else {
            loadDetail = "无运动记录"
        }
        dimensions.append(("训练负荷", "🏋️", Int(loadScore), 15, loadDetail))

        let finalScore = maxPossible > 0 ? Int(totalScore / maxPossible * 100) : 50
        return RecoveryScore(total: finalScore, dimensions: dimensions, missingDimensionCount: missingCount)
    }

    /// Returns emoji + label for a recovery score value.
    private func recoveryLabel(score: Int) -> (emoji: String, label: String) {
        if score >= 85 { return ("🟢", "恢复充分") }
        if score >= 70 { return ("🟢", "恢复良好") }
        if score >= 55 { return ("🟡", "恢复中等") }
        if score >= 40 { return ("🟠", "恢复不足") }
        return ("🔴", "需要休息")
    }

    // MARK: - HRV (Heart Rate Variability) — Dedicated Analysis

    private func respondHRV(summaries: [HealthSummary], allSummaries: [HealthSummary] = [], range: QueryTimeRange, completion: @escaping (String) -> Void) {
        let hrvDays = summaries.filter { $0.hrv > 0 }
        guard !hrvDays.isEmpty else {
            var lines: [String] = ["📳 \(range.label)暂无心率变异性（HRV）数据。\n"]
            lines.append("HRV 是衡量自主神经系统平衡的关键指标，反映身体的压力与恢复状态。")
            lines.append("")
            lines.append("💡 如何获取 HRV 数据：")
            lines.append("• 需要 Apple Watch（任意型号）")
            lines.append("• 佩戴 Apple Watch 睡觉，系统会在夜间自动测量")
            lines.append("• 也可以在「呼吸」App 中主动测量")
            lines.append("")
            lines.append("HRV 越高，通常说明身体恢复越充分、压力越低。")
            completion(lines.joined(separator: "\n"))
            return
        }

        var lines: [String] = ["📳 \(range.label)的心率变异性（HRV）分析\n"]

        // --- Basic stats ---
        let avgHRV = hrvDays.reduce(0) { $0 + $1.hrv } / Double(hrvDays.count)
        let maxDay = hrvDays.max(by: { $0.hrv < $1.hrv })!
        let minDay = hrvDays.min(by: { $0.hrv < $1.hrv })!
        let latestDay = hrvDays.sorted { $0.date > $1.date }.first!

        lines.append("💓 最新 HRV：\(Int(latestDay.hrv)) ms")
        lines.append("📊 期间平均：\(Int(avgHRV)) ms")
        if hrvDays.count > 1 {
            lines.append("   波动范围：\(Int(minDay.hrv))~\(Int(maxDay.hrv)) ms")
        }

        // --- Interpretation based on personal baseline + absolute ---
        lines.append("")
        if avgHRV >= 60 {
            lines.append("🏅 HRV 较高，自主神经调节能力出色，身体恢复状态非常好。")
        } else if avgHRV >= 45 {
            lines.append("✅ HRV 良好，身体处于健康的恢复状态。")
        } else if avgHRV >= 30 {
            lines.append("💡 HRV 中等。规律运动、充足睡眠和压力管理有助于提升。")
        } else {
            lines.append("⚠️ HRV 偏低，身体可能处于较大压力或疲劳状态，需要重视恢复。")
        }

        // --- Today vs personal baseline ---
        if hrvDays.count >= 3 {
            let baselineAvg = avgHRV
            let todayHRV = latestDay.hrv
            let pctDiff = ((todayHRV - baselineAvg) / baselineAvg) * 100

            lines.append("")
            if abs(pctDiff) < 10 {
                lines.append("📍 最新 HRV 接近你的个人基线，身体节律稳定。")
            } else if pctDiff >= 10 {
                lines.append("📈 最新 HRV 高于你的基线 \(Int(pctDiff))%，恢复状态很好！")
                if pctDiff >= 25 {
                    lines.append("   这可能反映了近期良好的睡眠和适度的运动。")
                }
            } else {
                lines.append("📉 最新 HRV 低于你的基线 \(Int(-pctDiff))%。")
                if pctDiff <= -25 {
                    lines.append("   显著偏低——可能与压力、睡眠不足、高强度训练或身体不适有关。")
                    lines.append("   建议今天以轻松活动为主，优先保证休息。")
                } else {
                    lines.append("   轻度偏低，注意观察是否与近期压力或疲劳有关。")
                }
            }
        }

        // --- HRV stability (coefficient of variation) ---
        if hrvDays.count >= 4 {
            let cv = coefficient(of: hrvDays.map { $0.hrv })
            lines.append("")
            if cv < 0.15 {
                lines.append("🔒 HRV 非常稳定（波动率 \(Int(cv * 100))%），自主神经节律规律。")
            } else if cv < 0.25 {
                lines.append("📊 HRV 波动正常（波动率 \(Int(cv * 100))%），属于健康范围。")
            } else if cv < 0.4 {
                lines.append("🎢 HRV 波动较大（波动率 \(Int(cv * 100))%），可能受睡眠质量或压力事件影响。")
            } else {
                lines.append("⚡ HRV 波动很大（波动率 \(Int(cv * 100))%），建议关注影响因素：睡眠、酒精、压力。")
            }
        }

        // --- Day-by-day timeline ---
        if hrvDays.count >= 3 {
            let sorted = hrvDays.sorted { $0.date < $1.date }
            let dayFmt = DateFormatter()
            dayFmt.dateFormat = "M/d"
            dayFmt.locale = Locale(identifier: "zh_CN")

            lines.append("")
            lines.append("📅 逐日 HRV 趋势")

            // Sparkline visualization
            let sparkChars: [Character] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
            let vals = sorted.map { $0.hrv }
            let lo = vals.min()!
            let hi = vals.max()!
            let spread = max(hi - lo, 1)

            let spark = sorted.map { day -> Character in
                let normalized = (day.hrv - lo) / spread
                let idx = min(Int(normalized * 7), 7)
                return sparkChars[idx]
            }
            let startLabel = dayFmt.string(from: sorted.first!.date)
            let endLabel = dayFmt.string(from: sorted.last!.date)
            lines.append("   \(startLabel) \(String(spark)) \(endLabel)")
            lines.append("   低 \(Int(lo)) ← → \(Int(hi)) ms 高")

            // Mark best & worst days
            let bestDay = sorted.max(by: { $0.hrv < $1.hrv })!
            let worstDay = sorted.min(by: { $0.hrv < $1.hrv })!
            if sorted.count >= 4 {
                lines.append("   🟢 最佳：\(dayFmt.string(from: bestDay.date)) (\(Int(bestDay.hrv)) ms)")
                lines.append("   🔴 最低：\(dayFmt.string(from: worstDay.date)) (\(Int(worstDay.hrv)) ms)")
            }
        }

        // --- Trend analysis (first half vs second half) ---
        if hrvDays.count >= 4 {
            let sorted = hrvDays.sorted { $0.date < $1.date }
            let mid = sorted.count / 2
            let olderAvg = sorted.prefix(mid).reduce(0) { $0 + $1.hrv } / Double(mid)
            let recentAvg = sorted.suffix(from: mid).reduce(0) { $0 + $1.hrv } / Double(sorted.count - mid)
            let diff = recentAvg - olderAvg

            lines.append("")
            if abs(diff) < 3 {
                lines.append("📊 HRV 整体保持稳定，没有明显趋势变化。")
            } else if diff > 0 {
                lines.append("📈 HRV 呈上升趋势（+\(Int(diff)) ms），恢复能力在改善！")
                lines.append("   这通常反映运动适应性增强或压力管理有效。")
            } else {
                lines.append("📉 HRV 呈下降趋势（\(Int(diff)) ms），恢复能力在减弱。")
                lines.append("   可能原因：训练过度、睡眠不足、持续压力或身体状态变化。")
            }
        }

        // --- Sleep quality → next-day HRV correlation ---
        let allSorted = (allSummaries.isEmpty ? summaries : allSummaries).sorted { $0.date < $1.date }
        if allSorted.count >= 4 {
            var sleepHRVPairs: [(sleep: Double, deep: Double, hrv: Double)] = []
            for (i, day) in allSorted.enumerated() where i > 0 {
                let prevDay = allSorted[i - 1]
                guard prevDay.sleepHours > 0 && day.hrv > 0 else { continue }
                sleepHRVPairs.append((sleep: prevDay.sleepHours, deep: prevDay.sleepDeepHours, hrv: day.hrv))
            }

            let sleepValues = sleepHRVPairs.map(\.sleep)
            let hasSleepVariance = sleepValues.count >= 4 && (sleepValues.max() ?? 0) - (sleepValues.min() ?? 0) >= 1.0

            if hasSleepVariance {
                let medianSleep = sleepValues.sorted()[sleepValues.count / 2]
                let goodSleep = sleepHRVPairs.filter { $0.sleep >= medianSleep }
                let poorSleep = sleepHRVPairs.filter { $0.sleep < medianSleep }

                if goodSleep.count >= 2 && poorSleep.count >= 2 {
                    let hrvAfterGood = goodSleep.reduce(0.0) { $0 + $1.hrv } / Double(goodSleep.count)
                    let hrvAfterPoor = poorSleep.reduce(0.0) { $0 + $1.hrv } / Double(poorSleep.count)
                    let hrvDiff = hrvAfterGood - hrvAfterPoor

                    lines.append("")
                    lines.append("😴↔️📳 睡眠如何影响你的 HRV")
                    if hrvDiff >= 3 {
                        lines.append("   睡眠充足时 HRV 平均 \(Int(hrvAfterGood)) ms，睡眠不足时 \(Int(hrvAfterPoor)) ms")
                        lines.append("   差距 \(Int(hrvDiff)) ms —— 对你来说，好的睡眠显著提升恢复能力。")
                    } else if hrvDiff >= 0 {
                        lines.append("   你的 HRV 与睡眠时长关联不大（差异仅 \(Int(hrvDiff)) ms）。")
                        lines.append("   可能睡眠质量（深睡比例）比时长更重要。")
                    } else {
                        lines.append("   你的 HRV 与睡眠时长无负相关，身体适应力不错。")
                    }

                    // Deep sleep → HRV correlation
                    let deepPairs = sleepHRVPairs.filter { $0.deep > 0 }
                    if deepPairs.count >= 4 {
                        let medianDeep = deepPairs.map(\.deep).sorted()[deepPairs.count / 2]
                        let goodDeep = deepPairs.filter { $0.deep >= medianDeep }
                        let poorDeep = deepPairs.filter { $0.deep < medianDeep }
                        if goodDeep.count >= 2 && poorDeep.count >= 2 {
                            let hrvGoodDeep = goodDeep.reduce(0.0) { $0 + $1.hrv } / Double(goodDeep.count)
                            let hrvPoorDeep = poorDeep.reduce(0.0) { $0 + $1.hrv } / Double(poorDeep.count)
                            let deepDiff = hrvGoodDeep - hrvPoorDeep
                            if deepDiff >= 3 {
                                lines.append("   🌙 深度睡眠效果更显著：深睡充足时 HRV 高 \(Int(deepDiff)) ms。")
                            }
                        }
                    }
                }
            }
        }

        // --- Exercise load → next-day HRV impact ---
        if allSorted.count >= 4 {
            var exerciseHRVPairs: [(exercise: Double, calories: Double, hrv: Double)] = []
            for (i, day) in allSorted.enumerated() where i > 0 {
                let prevDay = allSorted[i - 1]
                guard day.hrv > 0 else { continue }
                exerciseHRVPairs.append((exercise: prevDay.exerciseMinutes, calories: prevDay.activeCalories, hrv: day.hrv))
            }

            let exerciseValues = exerciseHRVPairs.map(\.exercise)
            let hasExerciseVariance = exerciseValues.count >= 4 && (exerciseValues.max() ?? 0) - (exerciseValues.min() ?? 0) >= 10

            if hasExerciseVariance {
                let medianExercise = exerciseValues.sorted()[exerciseValues.count / 2]
                let heavyDays = exerciseHRVPairs.filter { $0.exercise > medianExercise }
                let lightDays = exerciseHRVPairs.filter { $0.exercise <= medianExercise }

                if heavyDays.count >= 2 && lightDays.count >= 2 {
                    let hrvAfterHeavy = heavyDays.reduce(0.0) { $0 + $1.hrv } / Double(heavyDays.count)
                    let hrvAfterLight = lightDays.reduce(0.0) { $0 + $1.hrv } / Double(lightDays.count)
                    let exDiff = hrvAfterLight - hrvAfterHeavy

                    lines.append("")
                    lines.append("🏃↔️📳 运动如何影响你的 HRV")
                    if exDiff >= 3 {
                        lines.append("   高强度运动后次日 HRV 低 \(Int(exDiff)) ms（\(Int(hrvAfterHeavy)) vs \(Int(hrvAfterLight)) ms）")
                        lines.append("   这是正常的生理反应——身体在修复中，给它足够的恢复时间。")
                    } else if exDiff >= 0 {
                        lines.append("   你的 HRV 受运动强度影响不大（差异 \(Int(exDiff)) ms），运动耐受力不错。")
                    } else {
                        lines.append("   有趣的是，运动后你的 HRV 反而更高，说明适度运动对你是积极的恢复信号。")
                    }
                }
            }
        }

        // --- Weekly rhythm: which day of week has best/worst HRV ---
        if hrvDays.count >= 7 {
            let cal = Calendar.current
            var weekdayHRV: [Int: [Double]] = [:]
            for day in hrvDays {
                let wd = cal.component(.weekday, from: day.date)
                weekdayHRV[wd, default: []].append(day.hrv)
            }

            let weekdayAvgs = weekdayHRV.compactMap { (wd, vals) -> (Int, Double)? in
                guard vals.count >= 1 else { return nil }
                return (wd, vals.reduce(0, +) / Double(vals.count))
            }.sorted { $0.1 > $1.1 }

            if weekdayAvgs.count >= 3 {
                let dayNames = ["", "周日", "周一", "周二", "周三", "周四", "周五", "周六"]
                let best = weekdayAvgs.first!
                let worst = weekdayAvgs.last!
                let diff = best.1 - worst.1

                if diff >= 5 {
                    lines.append("")
                    lines.append("📆 一周 HRV 节律")
                    lines.append("   最佳：\(dayNames[best.0])（平均 \(Int(best.1)) ms）")
                    lines.append("   最低：\(dayNames[worst.0])（平均 \(Int(worst.1)) ms）")
                    // Provide context
                    if worst.0 == 2 { // Monday
                        lines.append("   💡 周一 HRV 最低？可能是周末作息不规律的滞后影响。")
                    } else if worst.0 == 6 || worst.0 == 7 { // Friday/Saturday
                        lines.append("   💡 周末前 HRV 下降？可能累积了一周的工作压力。")
                    }
                }
            }
        }

        // --- Actionable summary ---
        lines.append("")
        lines.append("💡 提升 HRV 的关键因素")
        // Personalized tips based on data
        var tips: [String] = []
        let sleepDays = summaries.filter { $0.sleepHours > 0 }
        if !sleepDays.isEmpty {
            let avgSleep = sleepDays.reduce(0) { $0 + $1.sleepHours } / Double(sleepDays.count)
            if avgSleep < 7 {
                tips.append("😴 增加睡眠时间（目前平均 \(String(format: "%.1f", avgSleep))h，建议 ≥7h）")
            } else {
                tips.append("😴 睡眠时长不错（\(String(format: "%.1f", avgSleep))h），继续保持")
            }
        }
        let exerciseDays = summaries.filter { $0.exerciseMinutes > 0 }
        if !exerciseDays.isEmpty {
            let avgEx = exerciseDays.reduce(0) { $0 + $1.exerciseMinutes } / Double(max(summaries.count, 1))
            if avgEx < 20 {
                tips.append("🏃 增加规律有氧运动（日均 \(Int(avgEx)) 分钟，建议 ≥30 分钟）")
            } else {
                tips.append("🏃 运动习惯良好（日均 \(Int(avgEx)) 分钟），注意避免过度训练")
            }
        }
        tips.append("🧘 减压活动（深呼吸、冥想）可直接提升副交感神经活性")
        tips.append("🚫 减少酒精摄入——酒精是 HRV 最大的隐形杀手之一")

        for tip in tips {
            lines.append("   \(tip)")
        }

        lines.append("")
        lines.append("📖 HRV 反映的是自主神经系统的平衡——交感（战斗）与副交感（恢复）的拉锯。")
        lines.append("   长期追踪 HRV 趋势比关注单日数值更有意义。")

        completion(lines.joined(separator: "\n"))
    }

    // MARK: - Blood Oxygen (SpO2)

    private func respondBloodOxygen(summaries: [HealthSummary], range: QueryTimeRange, completion: @escaping (String) -> Void) {
        let spo2Days = summaries.filter { $0.oxygenSaturation > 0 }
        guard !spo2Days.isEmpty else {
            var lines: [String] = ["🫁 \(range.label)暂无血氧数据。\n"]
            lines.append("血氧饱和度（SpO2）需要 Apple Watch Series 6 或更新型号才能自动测量。")
            lines.append("💡 可以在 Apple Watch 的「血氧」App 中手动测量，")
            lines.append("   或在设置中开启后台自动测量。")
            completion(lines.joined(separator: "\n"))
            return
        }

        var lines: [String] = ["🫁 \(range.label)的血氧分析\n"]
        let avg = spo2Days.reduce(0) { $0 + $1.oxygenSaturation } / Double(spo2Days.count)
        let maxVal = spo2Days.max(by: { $0.oxygenSaturation < $1.oxygenSaturation })!
        let minVal = spo2Days.min(by: { $0.oxygenSaturation < $1.oxygenSaturation })!

        lines.append("💨 平均血氧：\(String(format: "%.1f", avg))%")
        if spo2Days.count > 1 {
            lines.append("📊 波动范围：\(String(format: "%.0f", minVal.oxygenSaturation))%~\(String(format: "%.0f", maxVal.oxygenSaturation))%")
        }

        // Clinical interpretation (WHO/medical guidelines)
        lines.append("")
        if avg >= 95 {
            lines.append("✅ 血氧正常（≥95%），身体供氧充足。")
        } else if avg >= 90 {
            lines.append("⚠️ 血氧偏低（90-94%），可能与呼吸不畅、高海拔或剧烈运动后有关。")
            lines.append("   如果持续低于 95%，建议咨询医生。")
        } else {
            lines.append("🔴 血氧较低（<90%），建议尽快就医检查。")
        }

        // Low-value alert: flag any day below 90%
        let lowDays = spo2Days.filter { $0.oxygenSaturation < 92 }
        if !lowDays.isEmpty && lowDays.count < spo2Days.count {
            let fmt = DateFormatter()
            fmt.dateFormat = "M月d日"
            fmt.locale = Locale(identifier: "zh_CN")
            let dayStrs = lowDays.prefix(3).map { fmt.string(from: $0.date) }
            lines.append("\n⚠️ 有 \(lowDays.count) 天血氧低于 92%：\(dayStrs.joined(separator: "、"))")
        }

        // Sleep correlation: lower SpO2 during sleep can indicate issues
        let sleepDays = summaries.filter { $0.sleepHours > 0 && $0.oxygenSaturation > 0 }
        if sleepDays.count >= 3 {
            let poorSleepSpo2 = sleepDays.filter { $0.sleepHours < 6 }
            let goodSleepSpo2 = sleepDays.filter { $0.sleepHours >= 7 }
            if !poorSleepSpo2.isEmpty && !goodSleepSpo2.isEmpty {
                let poorAvg = poorSleepSpo2.reduce(0) { $0 + $1.oxygenSaturation } / Double(poorSleepSpo2.count)
                let goodAvg = goodSleepSpo2.reduce(0) { $0 + $1.oxygenSaturation } / Double(goodSleepSpo2.count)
                let diff = goodAvg - poorAvg
                if diff >= 1.0 {
                    lines.append("\n😴↔️🫁 睡眠充足的日子血氧高 \(String(format: "%.1f", diff))% —— 好的睡眠有助于血氧稳定。")
                }
            }
        }

        // Trend (compare first half vs second half)
        if spo2Days.count >= 4 {
            let sorted = spo2Days.sorted { $0.date < $1.date }
            let mid = sorted.count / 2
            let olderAvg = sorted.prefix(mid).reduce(0) { $0 + $1.oxygenSaturation } / Double(mid)
            let recentAvg = sorted.suffix(from: mid).reduce(0) { $0 + $1.oxygenSaturation } / Double(sorted.count - mid)
            let diff = recentAvg - olderAvg
            if abs(diff) >= 0.5 {
                if diff > 0 {
                    lines.append("\n📈 血氧呈上升趋势（+\(String(format: "%.1f", diff))%），供氧状态在改善。")
                } else {
                    lines.append("\n📉 血氧有所下降（\(String(format: "%.1f", diff))%），注意呼吸通畅和适度运动。")
                }
            } else {
                lines.append("\n📊 血氧保持稳定，状态不错。")
            }
        }

        // Day-by-day sparkline
        if spo2Days.count >= 3 {
            let sorted = spo2Days.sorted { $0.date < $1.date }
            let sparkChars: [Character] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
            // Scale from 88-100% for visibility
            let spark = sorted.map { day -> Character in
                let normalized = min(max((day.oxygenSaturation - 88) / 12, 0), 1)
                let idx = min(Int(normalized * 7), 7)
                return sparkChars[idx]
            }
            lines.append("📈 血氧趋势：\(String(spark))")
        }

        lines.append("")
        lines.append("💡 血氧正常范围：95~100%。Apple Watch 在后台自动测量，")
        lines.append("   运动、高海拔、呼吸问题等都可能影响血氧。")

        completion(lines.joined(separator: "\n"))
    }

    // MARK: - VO2 Max

    private func respondVO2Max(summaries: [HealthSummary], range: QueryTimeRange, completion: @escaping (String) -> Void) {
        let vo2Days = summaries.filter { $0.vo2Max > 0 }
        guard !vo2Days.isEmpty else {
            var lines: [String] = ["🏅 \(range.label)暂无 VO2 Max 数据。\n"]
            lines.append("VO2 Max（最大摄氧量）是衡量心肺适能的金标准指标。")
            lines.append("")
            lines.append("💡 如何获取 VO2 Max 数据：")
            lines.append("• 需要 Apple Watch Series 3 或更新型号")
            lines.append("• 进行 20 分钟以上的户外步行、跑步或健走")
            lines.append("• Apple Watch 会在运动后自动估算 VO2 Max")
            lines.append("")
            lines.append("坚持户外有氧运动，Apple Watch 就会开始记录你的心肺适能水平。")
            completion(lines.joined(separator: "\n"))
            return
        }

        var lines: [String] = ["🏅 \(range.label)的心肺适能（VO2 Max）\n"]
        let latest = vo2Days.sorted { $0.date > $1.date }.first!
        let avg = vo2Days.reduce(0) { $0 + $1.vo2Max } / Double(vo2Days.count)

        lines.append("💨 最新 VO2 Max：\(String(format: "%.1f", latest.vo2Max)) mL/(kg·min)")
        if vo2Days.count > 1 {
            lines.append("📊 期间平均：\(String(format: "%.1f", avg)) mL/(kg·min)")
            let maxVal = vo2Days.max(by: { $0.vo2Max < $1.vo2Max })!
            let minVal = vo2Days.min(by: { $0.vo2Max < $1.vo2Max })!
            if maxVal.vo2Max - minVal.vo2Max > 0.5 {
                lines.append("   波动范围：\(String(format: "%.1f", minVal.vo2Max))~\(String(format: "%.1f", maxVal.vo2Max))")
            }
        }

        // Fitness level classification (AHA/ACSM guidelines, approximate for adults)
        // These are rough midpoints; actual norms vary by age and sex
        lines.append("")
        let v = latest.vo2Max
        if v >= 50 {
            lines.append("🏆 优秀！VO2 Max ≥50 属于高水平有氧能力，接近运动员级别。")
        } else if v >= 43 {
            lines.append("✅ 良好，心肺适能高于平均水平，有氧基础扎实。")
        } else if v >= 36 {
            lines.append("💡 中等水平，规律有氧训练可以进一步提升。")
        } else if v >= 30 {
            lines.append("📊 略低于平均，建议增加每周 3~5 次有氧运动（跑步、游泳、骑行）。")
        } else {
            lines.append("⚠️ 偏低，心肺适能需要关注。从每天 20 分钟快走开始，循序渐进。")
        }

        // What VO2 Max means in practical terms
        lines.append("")
        if v >= 40 {
            let fiveKPace = 25.0 / (v / 10.0) // rough estimate
            lines.append("🏃 你的有氧能力约可支撑 5K 跑步配速 \(Int(fiveKPace))~\(Int(fiveKPace + 1)) 分钟/公里")
        }

        // Trend analysis
        if vo2Days.count >= 3 {
            let sorted = vo2Days.sorted { $0.date < $1.date }
            let first = sorted.first!
            let last = sorted.last!
            let change = last.vo2Max - first.vo2Max

            lines.append("")
            if abs(change) < 0.5 {
                lines.append("📊 VO2 Max 保持稳定，继续当前的训练节奏。")
            } else if change > 0 {
                lines.append("📈 VO2 Max 提升了 \(String(format: "%.1f", change))，心肺功能在进步！")
                lines.append("   每提升 1 mL/(kg·min) 都意味着身体能更高效地利用氧气。")
            } else {
                lines.append("📉 VO2 Max 下降了 \(String(format: "%.1f", abs(change)))。")
                lines.append("   可能与近期运动量减少、疲劳或身体状况有关。")
                lines.append("   恢复规律有氧训练后通常会回升。")
            }
        }

        // Correlate with exercise data
        let exerciseDays = summaries.filter { $0.exerciseMinutes > 0 }
        if !exerciseDays.isEmpty {
            let avgExercise = exerciseDays.reduce(0) { $0 + $1.exerciseMinutes } / Double(exerciseDays.count)
            lines.append("")
            if avgExercise >= 30 {
                lines.append("💪 日均运动 \(Int(avgExercise)) 分钟，这对维持和提升 VO2 Max 很有帮助。")
            } else {
                lines.append("💡 日均运动 \(Int(avgExercise)) 分钟，增加到 30 分钟以上对提升 VO2 Max 效果更好。")
            }
        }

        lines.append("")
        lines.append("📖 VO2 Max 是预测长寿和心血管健康最重要的单一指标之一。")
        lines.append("   研究表明，VO2 Max 每提升 1 mL/(kg·min)，全因死亡风险下降约 9%。")

        completion(lines.joined(separator: "\n"))
    }

    private func respondOverview(summaries: [HealthSummary], allSummaries: [HealthSummary]? = nil, range: QueryTimeRange, context: SkillContext, completion: @escaping (String) -> Void) {
        var lines: [String] = []
        let dayCount = Double(max(summaries.count, 1))
        let cal = Calendar.current

        // --- Holistic Health Score (0-100) at the top ---
        let healthScore = computeHealthScore(summaries: summaries)
        let scoreEmoji: String
        if healthScore.total >= 85 { scoreEmoji = "🌟" }
        else if healthScore.total >= 70 { scoreEmoji = "✅" }
        else if healthScore.total >= 50 { scoreEmoji = "💡" }
        else { scoreEmoji = "🌱" }

        lines.append("📊 \(range.label)健康概览\n")
        lines.append("\(scoreEmoji) 综合健康评分：\(healthScore.total) / 100")
        lines.append(healthScoreVerdict(healthScore))

        // Dimension breakdown bar
        let dims = healthScore.dimensions
        if !dims.isEmpty {
            lines.append("")
            for dim in dims {
                let filled = max(1, Int(Double(dim.score) / Double(dim.maxScore) * 6))
                let bar = String(repeating: "▓", count: filled) + String(repeating: "░", count: 6 - filled)
                let pct = dim.maxScore > 0 ? dim.score * 100 / dim.maxScore : 0
                lines.append("  \(dim.emoji) \(dim.name) [\(bar)] \(pct)%\(dim.note.isEmpty ? "" : "  \(dim.note)")")
            }
            lines.append("")
        }

        // --- Previous-period quick comparison ---
        // Shows brief trend arrows (↑/↓/→) vs the previous equal-length period
        // so the user immediately sees whether they're improving or declining.
        if let allData = allSummaries {
            let interval = range.interval
            let spanDays = max(1, cal.dateComponents([.day], from: interval.start, to: interval.end).day ?? 1)
            let prevEnd = interval.start
            let prevStart = cal.date(byAdding: .day, value: -spanDays, to: prevEnd) ?? prevEnd
            let prevSummaries = allData.filter { $0.date >= prevStart && $0.date < prevEnd && $0.hasData }

            if !prevSummaries.isEmpty {
                let compLines = buildQuickComparison(current: summaries, previous: prevSummaries)
                if !compLines.isEmpty {
                    lines.append(contentsOf: compLines)
                    lines.append("")
                }
            }
        }

        // --- Core metrics ---
        let totalSteps = summaries.reduce(0) { $0 + $1.steps }
        let totalExercise = summaries.reduce(0) { $0 + $1.exerciseMinutes }
        let sleepDays = summaries.filter { $0.sleepHours > 0 }
        let avgSleep = sleepDays.isEmpty ? 0 : sleepDays.reduce(0) { $0 + $1.sleepHours } / Double(sleepDays.count)
        let hrDays = summaries.filter { $0.heartRate > 0 }
        let avgHR = hrDays.isEmpty ? 0 : hrDays.reduce(0) { $0 + $1.heartRate } / Double(hrDays.count)
        let totalDistance = summaries.reduce(0) { $0 + $1.distanceKm }
        let totalFlights = summaries.reduce(0) { $0 + $1.flightsClimbed }

        let avgSteps = totalSteps / dayCount
        let avgExercise = totalExercise / dayCount

        let totalCalories = summaries.reduce(0) { $0 + $1.activeCalories }
        let avgCalories = totalCalories / dayCount

        if totalSteps > 0 { lines.append("👟 日均 \(Int(avgSteps).formatted()) 步") }
        if totalDistance > 0.1 { lines.append("📏 累计 \(String(format: "%.1f", totalDistance)) 公里") }
        if totalExercise > 0 { lines.append("⏱ 日均运动 \(Int(avgExercise)) 分钟") }
        if totalCalories > 0 {
            var calLine = "🔥 日均消耗 \(Int(avgCalories).formatted()) 千卡"
            // Show ring completion hint (default Apple Watch goal: 500 kcal)
            if avgCalories >= 500 {
                calLine += " ✅"
            } else if avgCalories >= 350 {
                calLine += "（接近合环）"
            }
            lines.append(calLine)
        }
        if avgSleep > 0 {
            lines.append("😴 均睡 \(String(format: "%.1f", avgSleep)) 小时")
            let phaseDays = summaries.filter { $0.hasSleepPhases }
            if !phaseDays.isEmpty {
                let avgDeep = phaseDays.reduce(0) { $0 + $1.sleepDeepHours } / Double(phaseDays.count)
                lines.append("   🟣 深睡眠 \(String(format: "%.1f", avgDeep))h · 查看「睡眠」获取详细分析")
            }
        }
        if avgHR > 0 { lines.append("❤️ 均心率 \(Int(avgHR)) BPM") }
        let restingDaysOverview = summaries.filter { $0.restingHeartRate > 0 }
        if !restingDaysOverview.isEmpty {
            let avgResting = restingDaysOverview.reduce(0) { $0 + $1.restingHeartRate } / Double(restingDaysOverview.count)
            lines.append("🫀 静息心率 \(Int(avgResting)) BPM")
        }
        let hrvDaysOverview = summaries.filter { $0.hrv > 0 }
        if !hrvDaysOverview.isEmpty {
            let avgHRV = hrvDaysOverview.reduce(0) { $0 + $1.hrv } / Double(hrvDaysOverview.count)
            lines.append("📳 HRV \(Int(avgHRV)) ms · 查看「心率」获取详细分析")
        }
        if totalFlights > 0 { lines.append("🏢 爬楼 \(Int(totalFlights)) 层（日均 \(Int(totalFlights / dayCount))）") }
        let weightDays = summaries.filter { $0.bodyMassKg > 0 }.sorted { $0.date < $1.date }
        if let latestWeight = weightDays.last {
            var weightLine = "⚖️ 体重 \(String(format: "%.1f", latestWeight.bodyMassKg)) kg"
            if weightDays.count >= 2, let firstWeight = weightDays.first {
                let diff = latestWeight.bodyMassKg - firstWeight.bodyMassKg
                if abs(diff) >= 0.1 {
                    weightLine += diff > 0 ? "（+\(String(format: "%.1f", diff))）" : "（\(String(format: "%.1f", diff))）"
                }
            }
            lines.append(weightLine)
        }

        // --- SpO2 & VO2 Max ---
        let spo2Days = summaries.filter { $0.oxygenSaturation > 0 }
        if !spo2Days.isEmpty {
            let avgSpO2 = spo2Days.reduce(0) { $0 + $1.oxygenSaturation } / Double(spo2Days.count)
            let spo2Emoji = avgSpO2 >= 95 ? "✅" : (avgSpO2 >= 90 ? "⚠️" : "🔴")
            lines.append("🫁 血氧 \(String(format: "%.0f", avgSpO2))% \(spo2Emoji)")
        }
        let vo2Days = summaries.filter { $0.vo2Max > 0 }
        if let latestVO2 = vo2Days.sorted(by: { $0.date > $1.date }).first {
            lines.append("🏅 VO2 Max \(String(format: "%.1f", latestVO2.vo2Max)) mL/(kg·min)")
        }

        // --- Workout type summary (from HKWorkout sessions) ---
        let allWorkouts = summaries.flatMap { $0.workouts }
        if !allWorkouts.isEmpty {
            var byType: [UInt: (count: Int, duration: Double)] = [:]
            for w in allWorkouts {
                let existing = byType[w.activityType] ?? (0, 0)
                byType[w.activityType] = (existing.count + 1, existing.duration + w.duration)
            }
            // Show top 3 workout types sorted by total duration
            let topTypes = byType.sorted { $0.value.duration > $1.value.duration }.prefix(3)
            let typeStrs = topTypes.map { (typeID, info) -> String in
                let sample = allWorkouts.first { $0.activityType == typeID }!
                let mins = Int(info.duration / 60)
                return "\(sample.typeEmoji)\(sample.typeName) \(info.count)次·\(mins)min"
            }
            lines.append("🏋️ 运动：\(typeStrs.joined(separator: "  "))")

            // Compact workout location hint for overview (show top 1-2 places)
            let locInsight = workoutLocationInsight(allWorkouts, context: context)
            // In overview mode, only include if there are locations and keep it concise
            if locInsight.count > 1 {
                // Take just the first 1-2 place lines (skip the header)
                let placeLines = locInsight.dropFirst().prefix(2)
                lines.append("📍 运动地点：\(placeLines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " · "))")
            }
        }

        // --- Sparkline: day-by-day step trend ---
        if summaries.count >= 3 {
            let sorted = summaries.sorted { $0.date < $1.date }
            let maxSteps = sorted.map(\.steps).max() ?? 1
            if maxSteps > 0 {
                let sparkChars: [Character] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
                let spark = sorted.map { day -> Character in
                    let idx = min(Int(day.steps / maxSteps * 7), 7)
                    return sparkChars[idx]
                }
                lines.append("\n📈 步数趋势：\(String(spark))")
            }
        }

        // --- Weekday vs Weekend patterns ---
        if summaries.count >= 5 {
            let weekdays = summaries.filter { !cal.isDateInWeekend($0.date) }
            let weekends = summaries.filter { cal.isDateInWeekend($0.date) }

            if !weekdays.isEmpty && !weekends.isEmpty {
                let wdAvgSteps = weekdays.reduce(0) { $0 + $1.steps } / Double(weekdays.count)
                let weAvgSteps = weekends.reduce(0) { $0 + $1.steps } / Double(weekends.count)
                let wdAvgExercise = weekdays.reduce(0) { $0 + $1.exerciseMinutes } / Double(weekdays.count)
                let weAvgExercise = weekends.reduce(0) { $0 + $1.exerciseMinutes } / Double(weekends.count)

                // Only show if there's a meaningful difference (>15%)
                let stepsDiff = wdAvgSteps > 0 ? abs(weAvgSteps - wdAvgSteps) / wdAvgSteps * 100 : 0
                let exerciseDiff = wdAvgExercise > 0 ? abs(weAvgExercise - wdAvgExercise) / wdAvgExercise * 100 : 0

                if stepsDiff > 15 || exerciseDiff > 15 {
                    lines.append("\n🗓 工作日 vs 周末")
                    if stepsDiff > 15 {
                        let moreActive = weAvgSteps > wdAvgSteps ? "周末" : "工作日"
                        lines.append("   步数：工作日均 \(Int(wdAvgSteps).formatted()) · 周末均 \(Int(weAvgSteps).formatted())（\(moreActive)更活跃）")
                    }
                    if exerciseDiff > 15 && wdAvgExercise > 0 {
                        let moreActive = weAvgExercise > wdAvgExercise ? "周末" : "工作日"
                        lines.append("   运动：工作日均 \(Int(wdAvgExercise))min · 周末均 \(Int(weAvgExercise))min（\(moreActive)更多）")
                    }
                }

                // Sleep pattern: weekday vs weekend
                let wdSleep = weekdays.filter { $0.sleepHours > 0 }
                let weSleep = weekends.filter { $0.sleepHours > 0 }
                if !wdSleep.isEmpty && !weSleep.isEmpty {
                    let wdAvgSleep = wdSleep.reduce(0) { $0 + $1.sleepHours } / Double(wdSleep.count)
                    let weAvgSleep = weSleep.reduce(0) { $0 + $1.sleepHours } / Double(weSleep.count)
                    let sleepDiffH = weAvgSleep - wdAvgSleep
                    if abs(sleepDiffH) >= 0.5 {
                        if sleepDiffH > 0 {
                            lines.append("   😴 周末多睡 \(String(format: "%.1f", sleepDiffH))h — 工作日可能欠下了睡眠债")
                        } else {
                            lines.append("   😴 工作日反而多睡 \(String(format: "%.1f", -sleepDiffH))h — 周末活动较多")
                        }
                    }
                }
            }
        }

        // --- Consistency score (coefficient of variation for steps) ---
        let stepValues = summaries.map(\.steps).filter { $0 > 0 }
        if stepValues.count >= 3 {
            let cv = coefficient(of: stepValues)
            lines.append("")
            if cv < 0.2 {
                lines.append("🎯 活动非常规律（波动仅 \(Int(cv * 100))%），节律感很好！")
            } else if cv < 0.4 {
                lines.append("📊 活动比较规律（波动 \(Int(cv * 100))%），偶有高低起伏。")
            } else {
                lines.append("🎢 活动波动较大（\(Int(cv * 100))%），试试每天固定时间散步来建立节奏。")
            }
        }

        // --- Cross-metric insight: sleep vs exercise correlation ---
        if summaries.count >= 4 {
            let paired = summaries.filter { $0.exerciseMinutes > 0 && $0.sleepHours > 0 }
            if paired.count >= 3 {
                let exerciseThreshold = paired.reduce(0) { $0 + $1.exerciseMinutes } / Double(paired.count)
                let activeDays = paired.filter { $0.exerciseMinutes >= exerciseThreshold }
                let restDays = paired.filter { $0.exerciseMinutes < exerciseThreshold }

                if !activeDays.isEmpty && !restDays.isEmpty {
                    let sleepOnActive = activeDays.reduce(0) { $0 + $1.sleepHours } / Double(activeDays.count)
                    let sleepOnRest = restDays.reduce(0) { $0 + $1.sleepHours } / Double(restDays.count)
                    let diff = sleepOnActive - sleepOnRest

                    if abs(diff) >= 0.3 {
                        if diff > 0 {
                            lines.append("💡 运动多的日子平均多睡 \(String(format: "%.1f", diff))h — 运动促进了睡眠质量。")
                        } else {
                            lines.append("💡 运动多的日子反而少睡 \(String(format: "%.1f", -diff))h — 注意运动后留够恢复时间。")
                        }
                    }
                }
            }
        }

        // --- Calendar ↔ Exercise correlation (overview context) ---
        if summaries.count >= 3 {
            let rangeInterval = range.interval
            let overviewStart = summaries.map(\.date).min() ?? rangeInterval.start
            let overviewEnd = summaries.map(\.date).max() ?? rangeInterval.end
            // Extend end by 1 day to capture events on the last day
            let extendedEnd = cal.date(byAdding: .day, value: 1, to: overviewEnd) ?? overviewEnd
            let overviewInterval = DateInterval(start: overviewStart, end: extendedEnd)
            lines.append(contentsOf: calendarExerciseCorrelation(
                summaries: summaries, interval: overviewInterval, context: context))
        }

        // --- Anomaly detection: flag unusually low days ---
        if stepValues.count >= 5 {
            let mean = stepValues.reduce(0, +) / Double(stepValues.count)
            let threshold = mean * 0.4 // Below 40% of average
            let lowDays = summaries.filter { $0.steps > 0 && $0.steps < threshold }
            if !lowDays.isEmpty && lowDays.count <= 2 {
                let fmt = DateFormatter()
                fmt.dateFormat = "M月d日(E)"
                fmt.locale = Locale(identifier: "zh_CN")
                let dayNames = lowDays.prefix(2).map { fmt.string(from: $0.date) }.joined(separator: "、")
                lines.append("⚠️ \(dayNames)活动量明显偏低，那天是否身体不适或特别忙碌？")
            } else if lowDays.count > 2 {
                lines.append("⚠️ 有 \(lowDays.count) 天活动量低于平均的 40%，建议关注每日基础活动量。")
            }
        }

        // --- Actionable improvement tip based on health score dimensions ---
        let weakest = healthScore.dimensions.filter { $0.maxScore > 0 }
            .min(by: { Double($0.score) / Double($0.maxScore) < Double($1.score) / Double($1.maxScore) })
        if let weak = weakest, weak.score < weak.maxScore * 3 / 4 {
            lines.append("")
            lines.append("💡 最容易提升的维度：\(weak.emoji) \(weak.name) — \(weak.tip)")
        }

        // --- Today: Calendar-Aware Readiness ---
        // When showing today's health overview, cross-reference with calendar events
        // to give a holistic "readiness" verdict. This connects "how your body is"
        // with "what your day demands" — the core iosclaw cross-data insight.
        if range == .today && context.calendarService.isAuthorized {
            let calLines = self.buildCalendarReadiness(
                summaries: summaries,
                context: context
            )
            if !calLines.isEmpty {
                lines.append("")
                lines.append(contentsOf: calLines)
            }
        }

        completion(lines.joined(separator: "\n"))
    }

    // MARK: - Calendar-Aware Readiness for Health Overview

    /// Builds a brief "readiness vs demands" section for today's health overview.
    /// Connects health state (sleep, HRV, resting HR) with calendar load (meetings,
    /// total scheduled time) to produce actionable advice.
    private func buildCalendarReadiness(
        summaries: [HealthSummary],
        context: SkillContext
    ) -> [String] {
        let cal = Calendar.current
        let now = Date()
        let dayStart = cal.startOfDay(for: now)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? now
        let events = context.calendarService.fetchEvents(from: dayStart, to: dayEnd)

        let timedEvents = events.filter { !$0.isAllDay }
        // Only show this section when there's meaningful calendar load
        guard timedEvents.count >= 2 else { return [] }

        let totalMinutes = timedEvents.reduce(0.0) { $0 + $1.duration } / 60.0
        let remaining = timedEvents.filter { $0.endDate > now }
        let remainingCount = remaining.count

        // Detect back-to-back meetings (gap < 15 min)
        let sorted = timedEvents.sorted { $0.startDate < $1.startDate }
        var backToBackCount = 0
        for i in 0..<(sorted.count - 1) {
            let gap = sorted[i + 1].startDate.timeIntervalSince(sorted[i].endDate) / 60
            if gap < 15 { backToBackCount += 1 }
        }

        // Assess schedule intensity
        let isHeavy = timedEvents.count >= 5 || totalMinutes >= 300
        let isMedium = timedEvents.count >= 3 || totalMinutes >= 120

        // Assess health readiness from today's data
        let today = summaries.first(where: { cal.isDateInToday($0.date) })
        let yesterday = summaries.first(where: { cal.isDateInYesterday($0.date) })
        let sleepHours = (today?.sleepHours ?? 0) > 0
            ? today!.sleepHours
            : (yesterday?.sleepHours ?? 0)
        let hrv = today?.hrv ?? 0
        let restingHR = today?.restingHeartRate ?? 0

        // Personal baseline for HRV and RHR
        let baselineDays = summaries.filter { !cal.isDateInToday($0.date) && $0.hasData }
        let baselineHRV = baselineDays.filter { $0.hrv > 0 }
        let avgHRV = baselineHRV.isEmpty ? 0.0
            : baselineHRV.reduce(0) { $0 + $1.hrv } / Double(baselineHRV.count)
        let baselineRHR = baselineDays.filter { $0.restingHeartRate > 0 }
        let avgRHR = baselineRHR.isEmpty ? 0.0
            : baselineRHR.reduce(0) { $0 + $1.restingHeartRate } / Double(baselineRHR.count)

        // Readiness signals
        let sleepGood = sleepHours >= 7.0
        let sleepPoor = sleepHours > 0 && sleepHours < 6.0
        let hrvLow = hrv > 0 && avgHRV > 0 && hrv < avgHRV * 0.8
        let hrvHigh = hrv > 0 && avgHRV > 0 && hrv >= avgHRV * 1.1
        let rhrElevated = restingHR > 0 && avgRHR > 0 && restingHR > avgRHR + 5

        var lines: [String] = []

        // Schedule summary line
        var scheduleLine = "📅 今日日程："
        if remainingCount > 0 {
            scheduleLine += "\(timedEvents.count) 个安排（还剩 \(remainingCount) 个）"
        } else {
            scheduleLine += "\(timedEvents.count) 个安排（已全部结束）"
        }
        if totalMinutes >= 60 {
            let hours = Int(totalMinutes / 60)
            let mins = Int(totalMinutes.truncatingRemainder(dividingBy: 60))
            scheduleLine += "，共约 \(hours)h\(mins > 0 ? "\(mins)m" : "")"
        }
        lines.append(scheduleLine)

        if backToBackCount >= 2 {
            lines.append("  ⚠️ \(backToBackCount + 1) 个会议连轴转")
        }

        // Readiness verdict: combine health state with schedule demands
        if remainingCount > 0 {
            if isHeavy && sleepPoor {
                lines.append("  🔴 密集日程 + 睡眠不足 → 优先在会议间隙休息，避免高强度运动")
            } else if isHeavy && hrvLow {
                lines.append("  🟡 日程密集且恢复状态偏低 → 会议间喝水、起身走动，帮助恢复")
            } else if isHeavy && (sleepGood || hrvHigh) {
                lines.append("  🟢 虽然日程密集，但身体状态不错 → 节奏从容，精力足够应对")
            } else if isHeavy && rhrElevated {
                lines.append("  🟡 密集日程 + 静息心率偏高 → 注意别透支，保持补水")
            } else if isMedium && sleepPoor {
                lines.append("  🟡 睡眠不足遇上一般日程 → 利用空闲时段补个短休")
            } else if isMedium && (sleepGood || hrvHigh) {
                lines.append("  🟢 身体恢复充分，日程适中 → 适合安排运动或挑战性任务")
            } else if isMedium {
                lines.append("  🟢 日程适中，状态正常")
            }
        }

        return lines
    }

    // MARK: - Holistic Health Score

    /// A single dimension contributing to the overall health score.
    private struct ScoreDimension {
        let emoji: String
        let name: String
        let score: Int      // earned points
        let maxScore: Int   // maximum possible
        let note: String    // short status note
        let tip: String     // improvement suggestion
    }

    /// Composite health score result.
    private struct HealthScoreResult {
        let total: Int
        let dimensions: [ScoreDimension]
    }

    /// Computes a holistic health score (0-100) from all available HealthKit dimensions:
    ///   - Activity (30 pts): daily steps + exercise minutes
    ///   - Sleep (25 pts): duration adequacy + consistency
    ///   - Cardio (25 pts): resting HR + HRV
    ///   - Consistency (10 pts): low day-to-day variance in steps
    ///   - Body (10 pts): weight data availability + stability
    private func computeHealthScore(summaries: [HealthSummary]) -> HealthScoreResult {
        let dayCount = Double(max(summaries.count, 1))
        var dims: [ScoreDimension] = []

        // 1. Activity (30 pts) — steps target 8000, exercise target 30 min
        let avgSteps = summaries.reduce(0) { $0 + $1.steps } / dayCount
        let avgExercise = summaries.reduce(0) { $0 + $1.exerciseMinutes } / dayCount
        var activityPts = 0.0
        // Steps: 0-8000 → 0-18 pts, above 8000 = full 18
        activityPts += min(avgSteps / 8000.0, 1.0) * 18
        // Exercise: 0-30 min → 0-12 pts
        activityPts += min(avgExercise / 30.0, 1.0) * 12
        let actScore = min(30, Int(activityPts))
        let actNote: String
        if actScore >= 25 { actNote = "达标" }
        else if actScore >= 15 { actNote = "尚可" }
        else { actNote = "不足" }
        dims.append(ScoreDimension(
            emoji: "🏃", name: "活动量", score: actScore, maxScore: 30,
            note: actNote,
            tip: avgSteps < 8000
                ? "日均步数 \(Int(avgSteps).formatted())，目标 8000 步，试试饭后散步 15 分钟"
                : "增加运动时长到每天 30 分钟，收益更大"))

        // 2. Sleep (25 pts) — duration adequacy (15) + consistency (10)
        let sleepDays = summaries.filter { $0.sleepHours > 0 }
        var sleepPts = 0.0
        if !sleepDays.isEmpty {
            let avgSleep = sleepDays.reduce(0) { $0 + $1.sleepHours } / Double(sleepDays.count)
            // Duration: 7-9h = full 15 pts, gradual falloff
            if avgSleep >= 7 && avgSleep <= 9 {
                sleepPts += 15
            } else if avgSleep >= 6 && avgSleep < 7 {
                sleepPts += 15 * (avgSleep - 5) / 2
            } else if avgSleep > 9 && avgSleep <= 10 {
                sleepPts += 15 * (10 - avgSleep)
            } else if avgSleep >= 5 {
                sleepPts += 5
            }
            // Consistency: low stddev = high score
            if sleepDays.count >= 3 {
                let stdDev = standardDeviation(of: sleepDays.map { $0.sleepHours })
                if stdDev < 0.3 { sleepPts += 10 }
                else if stdDev < 0.5 { sleepPts += 8 }
                else if stdDev < 1.0 { sleepPts += 5 }
                else if stdDev < 1.5 { sleepPts += 2 }
            } else {
                sleepPts += 5 // not enough data
            }
        }
        let slpScore = min(25, Int(sleepPts))
        let slpAvg = sleepDays.isEmpty ? 0 : sleepDays.reduce(0) { $0 + $1.sleepHours } / Double(sleepDays.count)
        let slpNote: String
        if sleepDays.isEmpty { slpNote = "无数据" }
        else if slpScore >= 20 { slpNote = "优质" }
        else if slpScore >= 12 { slpNote = "一般" }
        else { slpNote = "需关注" }
        dims.append(ScoreDimension(
            emoji: "😴", name: "睡  眠", score: slpScore, maxScore: 25,
            note: slpNote,
            tip: sleepDays.isEmpty
                ? "开启睡眠追踪以获取睡眠评分"
                : (slpAvg < 7
                    ? "平均 \(String(format: "%.1f", slpAvg))h，试着提前 \(Int((7 - slpAvg) * 60)) 分钟上床"
                    : "保持规律的起床时间，比延长睡眠更重要")))

        // 3. Cardio (25 pts) — resting HR (12) + HRV (13)
        let restingDays = summaries.filter { $0.restingHeartRate > 0 }
        let hrvDays = summaries.filter { $0.hrv > 0 }
        var cardioPts = 0.0
        if !restingDays.isEmpty {
            let avgResting = restingDays.reduce(0) { $0 + $1.restingHeartRate } / Double(restingDays.count)
            if avgResting < 60 { cardioPts += 12 }
            else if avgResting <= 65 { cardioPts += 11 }
            else if avgResting <= 73 { cardioPts += 9 }
            else if avgResting <= 80 { cardioPts += 6 }
            else { cardioPts += 3 }
        } else {
            cardioPts += 6 // no data = neutral
        }
        if !hrvDays.isEmpty {
            let avgHRV = hrvDays.reduce(0) { $0 + $1.hrv } / Double(hrvDays.count)
            if avgHRV >= 50 { cardioPts += 13 }
            else if avgHRV >= 40 { cardioPts += 10 }
            else if avgHRV >= 30 { cardioPts += 7 }
            else { cardioPts += 4 }
            // Stability bonus: replace 1-2 pts based on HRV CV
            if hrvDays.count >= 3 {
                let cv = coefficient(of: hrvDays.map { $0.hrv })
                if cv < 0.2 { cardioPts += 1 }
            }
        } else {
            cardioPts += 6.5 // no data = neutral
        }
        let cardScore = min(25, Int(cardioPts))
        let cardNote: String
        if restingDays.isEmpty && hrvDays.isEmpty { cardNote = "需 Watch" }
        else if cardScore >= 20 { cardNote = "优秀" }
        else if cardScore >= 13 { cardNote = "正常" }
        else { cardNote = "偏弱" }
        dims.append(ScoreDimension(
            emoji: "🫀", name: "心  血管", score: cardScore, maxScore: 25,
            note: cardNote,
            tip: restingDays.isEmpty
                ? "佩戴 Apple Watch 可获取静息心率和 HRV 数据"
                : "规律有氧运动（跑步、游泳）是降低静息心率的最佳方式"))

        // 4. Consistency (10 pts) — how regular are daily patterns
        let stepValues = summaries.map(\.steps).filter { $0 > 0 }
        var consistPts = 0.0
        if stepValues.count >= 3 {
            let cv = coefficient(of: stepValues)
            if cv < 0.15 { consistPts = 10 }
            else if cv < 0.25 { consistPts = 8 }
            else if cv < 0.4 { consistPts = 5 }
            else if cv < 0.6 { consistPts = 3 }
            else { consistPts = 1 }
        } else {
            consistPts = 5 // not enough data
        }
        let conScore = min(10, Int(consistPts))
        let conNote: String
        if stepValues.count < 3 { conNote = "数据少" }
        else if conScore >= 8 { conNote = "规律" }
        else if conScore >= 5 { conNote = "一般" }
        else { conNote = "波动大" }
        dims.append(ScoreDimension(
            emoji: "🎯", name: "规律性", score: conScore, maxScore: 10,
            note: conNote,
            tip: "每天固定时间散步或运动，建立稳定的活动节律"))

        // 5. Body (10 pts) — weight tracking + stability
        let weightDays = summaries.filter { $0.bodyMassKg > 0 }.sorted { $0.date < $1.date }
        var bodyPts = 0.0
        if weightDays.count >= 2 {
            bodyPts += 5 // has tracking data
            let first = weightDays.first!.bodyMassKg
            let last = weightDays.last!.bodyMassKg
            let changePct = abs(last - first) / first * 100
            if changePct < 1.0 { bodyPts += 5 }       // very stable
            else if changePct < 2.0 { bodyPts += 4 }
            else if changePct < 5.0 { bodyPts += 2 }
            else { bodyPts += 1 }
        } else if weightDays.count == 1 {
            bodyPts += 5 // has some data
        } else {
            bodyPts += 5 // no data = neutral (don't penalize)
        }
        let bodyScore = min(10, Int(bodyPts))
        let bodyNote: String
        if weightDays.isEmpty { bodyNote = "未记录" }
        else if bodyScore >= 8 { bodyNote = "稳定" }
        else { bodyNote = "波动中" }
        dims.append(ScoreDimension(
            emoji: "⚖️", name: "体  重", score: bodyScore, maxScore: 10,
            note: bodyNote,
            tip: weightDays.isEmpty
                ? "连接智能体重秤或手动记录体重，追踪长期趋势"
                : "体重小幅波动是正常的，关注周均值而非每日数字"))

        let total = min(100, dims.reduce(0) { $0 + $1.score })
        return HealthScoreResult(total: total, dimensions: dims)
    }

    /// Verdict text for the holistic health score.
    /// Builds a compact "vs previous period" comparison for the health overview.
    /// Returns lines like: "📈 vs 上个同期：步数 ↑12%  运动 ↑25%  睡眠 →持平  心率 ↓3%"
    private func buildQuickComparison(current: [HealthSummary], previous: [HealthSummary]) -> [String] {
        let curDays = Double(max(current.count, 1))
        let prevDays = Double(max(previous.count, 1))

        struct MetricDelta {
            let label: String
            let emoji: String
            let curAvg: Double
            let prevAvg: Double
            /// Whether lower is better (e.g. resting heart rate)
            let lowerIsBetter: Bool

            var pctChange: Double {
                guard prevAvg > 0 else { return 0 }
                return (curAvg - prevAvg) / prevAvg * 100
            }

            var arrow: String {
                let pct = pctChange
                if abs(pct) < 5 { return "→" }
                let isUp = pct > 0
                if lowerIsBetter { return isUp ? "↑" : "↓" }
                return isUp ? "↑" : "↓"
            }

            /// Green = improving, red = declining, gray = stable
            var trendEmoji: String {
                let pct = pctChange
                if abs(pct) < 5 { return "" }
                let isUp = pct > 0
                let improving = lowerIsBetter ? !isUp : isUp
                return improving ? "🟢" : "🔴"
            }

            var display: String? {
                guard prevAvg > 0 && curAvg > 0 else { return nil }
                let pct = pctChange
                if abs(pct) < 2 { return "\(emoji)\(label) →持平" }
                let sign = pct > 0 ? "+" : ""
                return "\(emoji)\(label) \(arrow)\(sign)\(Int(pct))%"
            }
        }

        // Compute averages for current and previous periods
        let curAvgSteps = current.reduce(0) { $0 + $1.steps } / curDays
        let prevAvgSteps = previous.reduce(0) { $0 + $1.steps } / prevDays

        let curAvgExercise = current.reduce(0) { $0 + $1.exerciseMinutes } / curDays
        let prevAvgExercise = previous.reduce(0) { $0 + $1.exerciseMinutes } / prevDays

        let curSleepDays = current.filter { $0.sleepHours > 0 }
        let prevSleepDays = previous.filter { $0.sleepHours > 0 }
        let curAvgSleep = curSleepDays.isEmpty ? 0 : curSleepDays.reduce(0) { $0 + $1.sleepHours } / Double(curSleepDays.count)
        let prevAvgSleep = prevSleepDays.isEmpty ? 0 : prevSleepDays.reduce(0) { $0 + $1.sleepHours } / Double(prevSleepDays.count)

        let curHRDays = current.filter { $0.restingHeartRate > 0 }
        let prevHRDays = previous.filter { $0.restingHeartRate > 0 }
        let curAvgRHR = curHRDays.isEmpty ? 0 : curHRDays.reduce(0) { $0 + $1.restingHeartRate } / Double(curHRDays.count)
        let prevAvgRHR = prevHRDays.isEmpty ? 0 : prevHRDays.reduce(0) { $0 + $1.restingHeartRate } / Double(prevHRDays.count)

        let curAvgCal = current.reduce(0) { $0 + $1.activeCalories } / curDays
        let prevAvgCal = previous.reduce(0) { $0 + $1.activeCalories } / prevDays

        let deltas: [MetricDelta] = [
            MetricDelta(label: "步数", emoji: "👟", curAvg: curAvgSteps, prevAvg: prevAvgSteps, lowerIsBetter: false),
            MetricDelta(label: "运动", emoji: "⏱", curAvg: curAvgExercise, prevAvg: prevAvgExercise, lowerIsBetter: false),
            MetricDelta(label: "睡眠", emoji: "😴", curAvg: curAvgSleep, prevAvg: prevAvgSleep, lowerIsBetter: false),
            MetricDelta(label: "消耗", emoji: "🔥", curAvg: curAvgCal, prevAvg: prevAvgCal, lowerIsBetter: false),
            MetricDelta(label: "静息心率", emoji: "🫀", curAvg: curAvgRHR, prevAvg: prevAvgRHR, lowerIsBetter: true),
        ]

        let displayParts = deltas.compactMap { $0.display }
        guard !displayParts.isEmpty else { return [] }

        // Count improving vs declining metrics for a one-line verdict
        let improving = deltas.filter { $0.prevAvg > 0 && $0.curAvg > 0 }.filter { d in
            let pct = d.pctChange
            if abs(pct) < 5 { return false }
            return d.lowerIsBetter ? pct < 0 : pct > 0
        }.count
        let declining = deltas.filter { $0.prevAvg > 0 && $0.curAvg > 0 }.filter { d in
            let pct = d.pctChange
            if abs(pct) < 5 { return false }
            return d.lowerIsBetter ? pct > 0 : pct < 0
        }.count

        var lines: [String] = []
        let trendVerdict: String
        if improving > declining && improving >= 2 {
            trendVerdict = "整体在变好 📈"
        } else if declining > improving && declining >= 2 {
            trendVerdict = "部分指标下滑 📉"
        } else {
            trendVerdict = "基本持平"
        }
        lines.append("🔄 **vs 上个同期**（\(trendVerdict)）")
        lines.append("  \(displayParts.joined(separator: "  "))")

        return lines
    }

    private func healthScoreVerdict(_ result: HealthScoreResult) -> String {
        let s = result.total
        if s >= 85 {
            return "   身体状态优秀 — 活动充足、睡眠规律、心血管健康"
        } else if s >= 70 {
            return "   整体状态良好 — 大部分指标正常，部分维度有优化空间"
        } else if s >= 50 {
            return "   状态一般 — 某些方面需要关注，小改变就能带来大提升"
        } else {
            return "   建议关注健康 — 从最弱的一项开始，每天改善一点点"
        }
    }

    // MARK: - Streak

    private func respondStreak(context: SkillContext, completion: @escaping (String) -> Void) {
        context.healthService.fetchSummaries(days: 30) { summaries in
            let sorted = summaries.sorted { $0.date > $1.date }
            let cal = Calendar.current

            // --- Multi-metric streak calculation ---
            struct MetricStreak {
                var current: Int = 0
                var longest: Int = 0
            }

            // Calculate streaks for each metric by walking backwards from today
            func calculateStreak(_ predicate: (HealthSummary) -> Bool) -> MetricStreak {
                var result = MetricStreak()
                var date = cal.startOfDay(for: Date())
                var counting = true

                // Current streak: walk backwards from today
                for summary in sorted {
                    let summaryDay = cal.startOfDay(for: summary.date)
                    if summaryDay == date {
                        if counting {
                            if predicate(summary) {
                                result.current += 1
                            } else {
                                counting = false
                            }
                        }
                        date = cal.date(byAdding: .day, value: -1, to: date) ?? date
                    }
                }

                // Longest streak in 30-day window
                var temp = 0
                let chronological = summaries.sorted { $0.date < $1.date }
                for summary in chronological {
                    if predicate(summary) {
                        temp += 1
                        result.longest = max(result.longest, temp)
                    } else {
                        temp = 0
                    }
                }

                return result
            }

            let stepsStreak = calculateStreak { $0.steps >= 8000 }
            let exerciseStreak = calculateStreak { $0.exerciseMinutes >= 30 }
            let sleepStreak = calculateStreak { $0.sleepHours >= 7 && $0.sleepHours <= 9 }
            // Triple ring: all 3 health goals met on the same day
            let tripleStreak = calculateStreak { $0.steps >= 8000 && $0.exerciseMinutes >= 30 && $0.sleepHours >= 7 && $0.sleepHours <= 9 }

            let today = sorted.first
            let todaySteps = today?.steps ?? 0
            let todayExercise = today?.exerciseMinutes ?? 0
            let todaySleep = today?.sleepHours ?? 0

            var lines: [String] = ["🔥 健康连续打卡\n"]

            // --- Triple Ring (the aspirational goal) ---
            if tripleStreak.current >= 1 {
                lines.append("🏅 全勤连续打卡：\(tripleStreak.current) 天！")
                lines.append("   步数 + 运动 + 睡眠 三项达标")
                if tripleStreak.current >= 7 {
                    lines.append("   🏆 一周全勤，自律的力量令人佩服！")
                } else if tripleStreak.current >= 3 {
                    lines.append("   💪 三天以上的全勤，习惯正在养成！")
                }
                if tripleStreak.longest > tripleStreak.current {
                    lines.append("   📊 近 30 天最长全勤：\(tripleStreak.longest) 天")
                }
                lines.append("")
            }

            // --- Individual Metric Streaks ---
            // Steps
            lines.append("👟 步数打卡（≥8,000 步）")
            if stepsStreak.current > 0 {
                lines.append("   连续 \(stepsStreak.current) 天达标\(streakEmoji(stepsStreak.current))")
            } else {
                if todaySteps > 0 {
                    let remaining = max(0, Int(8000 - todaySteps))
                    if remaining > 0 {
                        lines.append("   今天 \(Int(todaySteps).formatted()) 步，还差 \(remaining.formatted()) 步（约 \(remaining / 100) 分钟步行）")
                    } else {
                        lines.append("   ✅ 今天已达标 \(Int(todaySteps).formatted()) 步")
                    }
                } else {
                    lines.append("   今天还没有步数记录")
                }
            }
            if stepsStreak.longest > stepsStreak.current && stepsStreak.longest >= 2 {
                lines.append("   📊 近 30 天最长：\(stepsStreak.longest) 天")
            }

            // Exercise
            lines.append("\n⏱ 运动打卡（≥30 分钟）")
            if exerciseStreak.current > 0 {
                lines.append("   连续 \(exerciseStreak.current) 天达标\(streakEmoji(exerciseStreak.current))")
            } else {
                if todayExercise > 0 {
                    let remaining = max(0, Int(30 - todayExercise))
                    if remaining > 0 {
                        lines.append("   今天 \(Int(todayExercise)) 分钟，还差 \(remaining) 分钟")
                    } else {
                        lines.append("   ✅ 今天已达标 \(Int(todayExercise)) 分钟")
                    }
                } else {
                    lines.append("   今天还没有运动记录")
                }
            }
            if exerciseStreak.longest > exerciseStreak.current && exerciseStreak.longest >= 2 {
                lines.append("   📊 近 30 天最长：\(exerciseStreak.longest) 天")
            }

            // Sleep
            lines.append("\n😴 睡眠打卡（7-9 小时）")
            if sleepStreak.current > 0 {
                lines.append("   连续 \(sleepStreak.current) 天达标\(streakEmoji(sleepStreak.current))")
            } else {
                if todaySleep > 0 {
                    if todaySleep < 7 {
                        let deficit = String(format: "%.1f", 7 - todaySleep)
                        lines.append("   昨晚睡了 \(String(format: "%.1f", todaySleep))h，少了 \(deficit) 小时")
                    } else if todaySleep > 9 {
                        lines.append("   昨晚睡了 \(String(format: "%.1f", todaySleep))h，超过 9 小时可能影响精力")
                    }
                } else {
                    lines.append("   暂无睡眠记录")
                }
            }
            if sleepStreak.longest > sleepStreak.current && sleepStreak.longest >= 2 {
                lines.append("   📊 近 30 天最长：\(sleepStreak.longest) 天")
            }

            // --- 30-Day Consistency Summary ---
            let daysWithData = summaries.filter { $0.hasData }
            if daysWithData.count >= 7 {
                lines.append("\n📈 近 30 天达标率")
                let stepGoalDays = summaries.filter { $0.steps >= 8000 }.count
                let exerciseGoalDays = summaries.filter { $0.exerciseMinutes >= 30 }.count
                let sleepGoalDays = summaries.filter { $0.sleepHours >= 7 && $0.sleepHours <= 9 }.count
                let total = daysWithData.count

                let stepRate = stepGoalDays * 100 / total
                let exerciseRate = exerciseGoalDays * 100 / total
                let sleepRate = sleepGoalDays * 100 / total

                lines.append("   👟 步数 \(rateBar(pct: stepRate)) \(stepRate)%（\(stepGoalDays)/\(total) 天）")
                lines.append("   ⏱ 运动 \(rateBar(pct: exerciseRate)) \(exerciseRate)%（\(exerciseGoalDays)/\(total) 天）")
                lines.append("   😴 睡眠 \(rateBar(pct: sleepRate)) \(sleepRate)%（\(sleepGoalDays)/\(total) 天）")

                // Find the weakest metric for actionable advice
                let rates = [("步数", stepRate), ("运动", exerciseRate), ("睡眠", sleepRate)]
                if let weakest = rates.min(by: { $0.1 < $1.1 }), weakest.1 < 50 {
                    lines.append("")
                    switch weakest.0 {
                    case "步数":
                        lines.append("💡 步数达标率最低，试试设置每天固定的散步时间。")
                    case "运动":
                        lines.append("💡 运动达标率最低，每天 30 分钟快走也算，从简单的开始。")
                    case "睡眠":
                        lines.append("💡 睡眠达标率最低，固定就寝时间是最有效的改善方式。")
                    default:
                        break
                    }
                } else if rates.allSatisfy({ $0.1 >= 70 }) {
                    lines.append("")
                    lines.append("🌟 三项达标率都在 70% 以上，健康习惯非常稳定！")
                }
            }

            // --- Recovery Body Check (cross-data insight) ---
            // When exercise streak is ≥ 5 days, cross-reference HRV and resting HR
            // to detect overtraining risk. This is a uniquely personal insight: only
            // an AI with access to both exercise AND recovery data can say "your body
            // needs rest" based on real physiological signals.
            if exerciseStreak.current >= 5 {
                let recentDays = sorted.prefix(exerciseStreak.current)
                let hrvDays = recentDays.filter { $0.hrv > 0 }
                let rhrDays = recentDays.filter { $0.restingHeartRate > 0 }
                let sleepDays = recentDays.filter { $0.sleepHours > 0 }

                var recoveryLines: [String] = []
                var warningCount = 0

                // HRV trend: compare first half vs second half of streak
                if hrvDays.count >= 4 {
                    let hrvSorted = hrvDays.sorted { $0.date < $1.date }
                    let mid = hrvSorted.count / 2
                    let earlierAvg = hrvSorted.prefix(mid).reduce(0.0) { $0 + $1.hrv } / Double(mid)
                    let recentAvg = hrvSorted.suffix(from: mid).reduce(0.0) { $0 + $1.hrv } / Double(hrvSorted.count - mid)
                    let hrvChange = recentAvg - earlierAvg

                    if hrvChange < -5 {
                        recoveryLines.append("   📉 HRV 下降 \(String(format: "%.0f", abs(hrvChange)))ms（\(String(format: "%.0f", earlierAvg))→\(String(format: "%.0f", recentAvg))）— 身体恢复能力在下降")
                        warningCount += 1
                    } else if hrvChange > 3 {
                        recoveryLines.append("   📈 HRV 上升 \(String(format: "%.0f", hrvChange))ms — 身体适应良好，恢复能力在增强")
                    }
                }

                // Resting HR trend: rising RHR during exercise streak = overtraining signal
                if rhrDays.count >= 4 {
                    let rhrSorted = rhrDays.sorted { $0.date < $1.date }
                    let mid = rhrSorted.count / 2
                    let earlierAvg = rhrSorted.prefix(mid).reduce(0.0) { $0 + $1.restingHeartRate } / Double(mid)
                    let recentAvg = rhrSorted.suffix(from: mid).reduce(0.0) { $0 + $1.restingHeartRate } / Double(rhrSorted.count - mid)
                    let rhrChange = recentAvg - earlierAvg

                    if rhrChange > 3 {
                        recoveryLines.append("   📈 静息心率升高 \(String(format: "%.0f", rhrChange))BPM（\(String(format: "%.0f", earlierAvg))→\(String(format: "%.0f", recentAvg))）— 可能训练负荷偏高")
                        warningCount += 1
                    } else if rhrChange < -2 {
                        recoveryLines.append("   📉 静息心率下降 \(String(format: "%.0f", abs(rhrChange)))BPM — 心血管适应性在提升 ✅")
                    }
                }

                // Sleep quality during streak: poor sleep + high exercise = recovery deficit
                if sleepDays.count >= 3 {
                    let avgSleep = sleepDays.reduce(0.0) { $0 + $1.sleepHours } / Double(sleepDays.count)
                    let poorSleepDays = sleepDays.filter { $0.sleepHours < 6.5 }.count
                    if poorSleepDays >= 2 {
                        recoveryLines.append("   😴 连续运动期间有 \(poorSleepDays) 天睡不到 6.5h — 睡眠不足会削弱运动收益")
                        warningCount += 1
                    } else if avgSleep >= 7.5 {
                        recoveryLines.append("   😴 平均睡眠 \(String(format: "%.1f", avgSleep))h — 运动期间睡眠充足，恢复有保障 ✅")
                    }
                }

                if !recoveryLines.isEmpty {
                    lines.append("")
                    if warningCount >= 2 {
                        lines.append("🩺 身体恢复信号 ⚠️")
                        lines.append(contentsOf: recoveryLines)
                        lines.append("")
                        lines.append("   💡 连续 \(exerciseStreak.current) 天运动，多项恢复指标提示身体需要休息。")
                        lines.append("   建议安排 1-2 天轻松活动（散步、拉伸）代替高强度训练。")
                    } else if warningCount == 1 {
                        lines.append("🩺 身体恢复信号")
                        lines.append(contentsOf: recoveryLines)
                        lines.append("")
                        lines.append("   💡 有一项指标值得关注，留意身体感受，必要时安排一天恢复日。")
                    } else {
                        lines.append("🩺 身体恢复状态")
                        lines.append(contentsOf: recoveryLines)
                        lines.append("")
                        lines.append("   ✅ 恢复指标良好，身体正在适应当前运动量，继续保持！")
                    }
                } else if exerciseStreak.current >= 7 {
                    // No recovery data available but long streak — generic rest reminder
                    lines.append("")
                    lines.append("🩺 连续 \(exerciseStreak.current) 天运动，非常自律！")
                    lines.append("   💡 即使状态好，每周安排 1-2 天休息也能让肌肉更好修复、避免过度训练。")
                    lines.append("   佩戴 Apple Watch 可获取 HRV 和静息心率，帮你精准判断恢复状态。")
                }
            }

            // --- Motivation based on best streak ---
            let bestCurrent = max(stepsStreak.current, exerciseStreak.current, sleepStreak.current)
            if bestCurrent == 0 && tripleStreak.current == 0 {
                lines.append("")
                lines.append("💪 今天是新起点！每一天的坚持都在为明天的连续记录铺路。")
            }

            completion(lines.joined(separator: "\n"))
        }
    }

    /// Returns an emoji suffix for streak length milestones.
    private func streakEmoji(_ days: Int) -> String {
        if days >= 21 { return " 🏆🔥" }
        if days >= 14 { return " 🏆" }
        if days >= 7 { return " 💪" }
        if days >= 3 { return " 🔥" }
        return " ✅"
    }

    /// A mini bar chart (6 blocks) for percentage rates.
    private func rateBar(pct: Int) -> String {
        let filled = max(0, min(6, pct * 6 / 100))
        return "[\(String(repeating: "▓", count: filled))\(String(repeating: "░", count: 6 - filled))]"
    }

    // MARK: - Comparison

    private func respondComparison(range: QueryTimeRange, context: SkillContext, completion: @escaping (String) -> Void) {
        // Dynamic period calculation: compare the requested period against
        // the preceding period of equal length.
        // e.g. thisWeek vs lastWeek, thisMonth vs lastMonth, last 7 days vs prior 7 days
        let cal = Calendar.current
        let now = Date()
        let currentInterval = range.interval
        let spanDays = max(1, cal.dateComponents([.day], from: currentInterval.start, to: currentInterval.end).day ?? 7)
        let prevEnd = currentInterval.start
        let prevStart = cal.date(byAdding: .day, value: -spanDays, to: prevEnd) ?? prevEnd

        // Fetch enough health data to cover both periods
        let totalDaysBack = max(cal.dateComponents([.day], from: prevStart, to: now).day ?? 14, 1) + 1
        context.healthService.fetchSummaries(days: totalDaysBack) { summaries in
            let thisWeek = summaries.filter { currentInterval.contains($0.date) }
            let lastWeek = summaries.filter { $0.date >= prevStart && $0.date < prevEnd }

            // Fetch multi-dimensional life data for holistic comparison
            let thisLocations = CDLocationRecord.fetch(from: currentInterval.start, to: currentInterval.end, in: context.coreDataContext)
            let lastLocations = CDLocationRecord.fetch(from: prevStart, to: prevEnd, in: context.coreDataContext)
            let thisEvents = CDLifeEvent.fetch(from: currentInterval.start, to: currentInterval.end, in: context.coreDataContext)
            let lastEvents = CDLifeEvent.fetch(from: prevStart, to: prevEnd, in: context.coreDataContext)
            let thisCalEvents = context.calendarService.fetchEvents(from: currentInterval.start, to: currentInterval.end)
            let lastCalEvents = context.calendarService.fetchEvents(from: prevStart, to: prevEnd)

            let hasHealthData = !thisWeek.isEmpty || !lastWeek.isEmpty
            let hasCalData = !thisCalEvents.isEmpty || !lastCalEvents.isEmpty
            let hasLocData = !thisLocations.isEmpty || !lastLocations.isEmpty
            let hasPhotoData = context.photoService.isAuthorized

            guard hasHealthData || hasCalData || hasLocData || hasPhotoData else {
                completion("📊 暂无足够的数据进行对比。\n请开启健康、日历、位置等权限以追踪每周数据。")
                return
            }

            // Build period labels for the header
            let periodLabel = self.comparisonPeriodLabel(range: range, spanDays: spanDays)
            var lines: [String] = ["📈 \(periodLabel) · 生活全景对比\n"]
            var better = 0
            var worse = 0

            // ── Health Section ──
            if hasHealthData && (!thisWeek.isEmpty || !lastWeek.isEmpty) {
                lines.append("🏃 **健康**")

                // Steps comparison
                let thisSteps = thisWeek.reduce(0) { $0 + $1.steps }
                let lastSteps = lastWeek.reduce(0) { $0 + $1.steps }
                lines.append(self.buildComparisonLine(
                    icon: "  👟", label: "步数",
                    thisVal: thisSteps, lastVal: lastSteps,
                    unit: "步", formatter: { Int($0).formatted() }
                ))
                if thisSteps > lastSteps * 1.05 { better += 1 } else if thisSteps < lastSteps * 0.95 { worse += 1 }

                // Exercise comparison
                let thisExercise = thisWeek.reduce(0) { $0 + $1.exerciseMinutes }
                let lastExercise = lastWeek.reduce(0) { $0 + $1.exerciseMinutes }
                if thisExercise > 0 || lastExercise > 0 {
                    lines.append(self.buildComparisonLine(
                        icon: "  ⏱", label: "运动",
                        thisVal: thisExercise, lastVal: lastExercise,
                        unit: "分钟", formatter: { "\(Int($0))" }
                    ))
                    if thisExercise > lastExercise * 1.05 { better += 1 } else if thisExercise < lastExercise * 0.95 { worse += 1 }
                }

                // Sleep comparison
                let thisSleepDays = thisWeek.filter { $0.sleepHours > 0 }
                let lastSleepDays = lastWeek.filter { $0.sleepHours > 0 }
                let thisSleep = thisSleepDays.isEmpty ? 0 : thisSleepDays.reduce(0) { $0 + $1.sleepHours } / Double(thisSleepDays.count)
                let lastSleep = lastSleepDays.isEmpty ? 0 : lastSleepDays.reduce(0) { $0 + $1.sleepHours } / Double(lastSleepDays.count)
                if thisSleep > 0 || lastSleep > 0 {
                    lines.append(self.buildComparisonLine(
                        icon: "  😴", label: "日均睡眠",
                        thisVal: thisSleep, lastVal: lastSleep,
                        unit: "h", formatter: { String(format: "%.1f", $0) }
                    ))
                    if thisSleep > lastSleep * 1.05 && thisSleep <= 9 { better += 1 } else if thisSleep < lastSleep * 0.95 { worse += 1 }
                }

                // Calories comparison
                let thisCal = thisWeek.reduce(0) { $0 + $1.activeCalories }
                let lastCal = lastWeek.reduce(0) { $0 + $1.activeCalories }
                if thisCal > 0 || lastCal > 0 {
                    lines.append(self.buildComparisonLine(
                        icon: "  🔥", label: "热量",
                        thisVal: thisCal, lastVal: lastCal,
                        unit: "千卡", formatter: { Int($0).formatted() }
                    ))
                }

                // Distance comparison
                let thisDist = thisWeek.reduce(0) { $0 + $1.distanceKm }
                let lastDist = lastWeek.reduce(0) { $0 + $1.distanceKm }
                if thisDist > 0.1 || lastDist > 0.1 {
                    lines.append(self.buildComparisonLine(
                        icon: "  📏", label: "距离",
                        thisVal: thisDist, lastVal: lastDist,
                        unit: "km", formatter: { String(format: "%.1f", $0) }
                    ))
                }

                // Flights climbed comparison
                let thisFlights = thisWeek.reduce(0) { $0 + $1.flightsClimbed }
                let lastFlights = lastWeek.reduce(0) { $0 + $1.flightsClimbed }
                if thisFlights > 0 || lastFlights > 0 {
                    lines.append(self.buildComparisonLine(
                        icon: "  🏢", label: "爬楼",
                        thisVal: thisFlights, lastVal: lastFlights,
                        unit: "层", formatter: { "\(Int($0))" }
                    ))
                }

                // Recovery indicators (HRV + Resting HR)
                let thisHRVDays = thisWeek.filter { $0.hrv > 0 }
                let lastHRVDays = lastWeek.filter { $0.hrv > 0 }
                let thisHRV = thisHRVDays.isEmpty ? 0.0 : thisHRVDays.reduce(0) { $0 + $1.hrv } / Double(thisHRVDays.count)
                let lastHRV = lastHRVDays.isEmpty ? 0.0 : lastHRVDays.reduce(0) { $0 + $1.hrv } / Double(lastHRVDays.count)
                if thisHRV > 0 || lastHRV > 0 {
                    var hrvLine = self.buildComparisonLine(
                        icon: "  📳", label: "HRV",
                        thisVal: thisHRV, lastVal: lastHRV,
                        unit: "ms", formatter: { "\(Int($0))" }
                    )
                    if thisHRV > 0 && lastHRV > 0 {
                        let diff = thisHRV - lastHRV
                        if diff >= 5 { hrvLine += "  ✅ 恢复力提升" }
                        else if diff <= -5 { hrvLine += "  ⚠️ 恢复力下降" }
                    }
                    lines.append(hrvLine)
                    if thisHRV > lastHRV * 1.05 { better += 1 } else if thisHRV < lastHRV * 0.95 { worse += 1 }
                }

                let thisRHRDays = thisWeek.filter { $0.restingHeartRate > 0 }
                let lastRHRDays = lastWeek.filter { $0.restingHeartRate > 0 }
                let thisRHR = thisRHRDays.isEmpty ? 0.0 : thisRHRDays.reduce(0) { $0 + $1.restingHeartRate } / Double(thisRHRDays.count)
                let lastRHR = lastRHRDays.isEmpty ? 0.0 : lastRHRDays.reduce(0) { $0 + $1.restingHeartRate } / Double(lastRHRDays.count)
                if thisRHR > 0 || lastRHR > 0 {
                    var rhrLine = self.buildComparisonLine(
                        icon: "  💓", label: "静息心率",
                        thisVal: thisRHR, lastVal: lastRHR,
                        unit: "bpm", formatter: { "\(Int($0))" }
                    )
                    if thisRHR > 0 && lastRHR > 0 {
                        let diff = thisRHR - lastRHR
                        if diff <= -3 { rhrLine += "  ✅ 心肺适能提升" }
                        else if diff >= 3 { rhrLine += "  ⚠️ 可能需要更多休息" }
                    }
                    lines.append(rhrLine)
                    if lastRHR > 0 && thisRHR < lastRHR * 0.95 { better += 1 } else if thisRHR > lastRHR * 1.05 { worse += 1 }
                }

                // Personalized recovery insight
                if thisHRV > 0 && thisSleep > 0 && lastHRV > 0 && lastSleep > 0 {
                    let hrvImproved = thisHRV > lastHRV * 1.05
                    let sleepImproved = thisSleep > lastSleep && thisSleep >= 7
                    let exerciseUp = thisExercise > lastExercise * 1.1

                    if hrvImproved && sleepImproved {
                        lines.append("  🧬 睡眠改善 + HRV 提升 → 恢复状态很好，可以适当增加训练强度")
                    } else if exerciseUp && !hrvImproved && thisHRV > 0 {
                        lines.append("  🧬 运动量增加但 HRV 没跟上 → 注意不要过度训练")
                    } else if !sleepImproved && thisRHR > lastRHR + 2 {
                        lines.append("  🧬 睡眠不足 + 心率偏高 → 身体需要更多休息")
                    }
                }
            }

            // ── Calendar Section ──
            if hasCalData {
                lines.append("")
                lines.append("📅 **日程**")
                let thisTimedCount = thisCalEvents.filter { !$0.isAllDay }.count
                let lastTimedCount = lastCalEvents.filter { !$0.isAllDay }.count
                let thisTimedMins = thisCalEvents.filter { !$0.isAllDay }.reduce(0.0) { $0 + $1.duration } / 60.0
                let lastTimedMins = lastCalEvents.filter { !$0.isAllDay }.reduce(0.0) { $0 + $1.duration } / 60.0

                lines.append(self.buildComparisonLine(
                    icon: "  📋", label: "事件数",
                    thisVal: Double(thisTimedCount), lastVal: Double(lastTimedCount),
                    unit: "个", formatter: { "\(Int($0))" }
                ))

                if thisTimedMins > 0 || lastTimedMins > 0 {
                    lines.append(self.buildComparisonLine(
                        icon: "  ⏳", label: "会议时长",
                        thisVal: thisTimedMins, lastVal: lastTimedMins,
                        unit: "", formatter: { Self.formatDurationShort($0) }
                    ))
                }

                // Busy days comparison
                let thisBusyDays = Set(thisCalEvents.filter { !$0.isAllDay }.map { cal.startOfDay(for: $0.startDate) }).count
                let lastBusyDays = Set(lastCalEvents.filter { !$0.isAllDay }.map { cal.startOfDay(for: $0.startDate) }).count
                if thisBusyDays != lastBusyDays {
                    let delta = thisBusyDays - lastBusyDays
                    if delta > 0 {
                        lines.append("  📊 忙碌天数多了 \(delta) 天")
                    } else {
                        lines.append("  💚 忙碌天数少了 \(-delta) 天，节奏放缓")
                    }
                }

                // Track if schedule is lighter or heavier
                if thisTimedCount > 0 && lastTimedCount > 0 {
                    if Double(thisTimedCount) > Double(lastTimedCount) * 1.2 {
                        worse += 1 // busier = more stress
                    } else if Double(thisTimedCount) < Double(lastTimedCount) * 0.8 {
                        better += 1 // less busy = more recovery time
                    }
                }
            }

            // ── Location Section ──
            if hasLocData {
                lines.append("")
                lines.append("📍 **足迹**")
                let thisPlaces = Set(thisLocations.map { $0.displayName })
                let lastPlaces = Set(lastLocations.map { $0.displayName })
                lines.append(self.buildComparisonLine(
                    icon: "  🗺️", label: "去过",
                    thisVal: Double(thisPlaces.count), lastVal: Double(lastPlaces.count),
                    unit: "个地点", formatter: { "\(Int($0))" }
                ))

                // New places discovered (in this week but not last week)
                let newPlaces = thisPlaces.subtracting(lastPlaces)
                if !newPlaces.isEmpty {
                    let names = newPlaces.prefix(3).joined(separator: "、")
                    let extra = newPlaces.count > 3 ? " 等" : ""
                    lines.append("  🆕 新探索：\(names)\(extra)")
                    better += 1 // exploring new places is positive
                }

                // Outing frequency
                let thisOutDays = Set(thisLocations.map { cal.startOfDay(for: $0.timestamp) }).count
                let lastOutDays = Set(lastLocations.map { cal.startOfDay(for: $0.timestamp) }).count
                if thisOutDays > 0 && lastOutDays > 0 && thisOutDays != lastOutDays {
                    lines.append(self.buildComparisonLine(
                        icon: "  🚶", label: "外出天数",
                        thisVal: Double(thisOutDays), lastVal: Double(lastOutDays),
                        unit: "天", formatter: { "\(Int($0))" }
                    ))
                }
            }

            // ── Photo Section ──
            let thisPhotoList = hasPhotoData ? context.photoService.fetchMetadata(from: currentInterval.start, to: currentInterval.end) : []
            let lastPhotoList = hasPhotoData ? context.photoService.fetchMetadata(from: prevStart, to: prevEnd) : []
            if !thisPhotoList.isEmpty || !lastPhotoList.isEmpty {
                    lines.append("")
                    lines.append("📷 **记录**")
                    lines.append(self.buildComparisonLine(
                        icon: "  🖼️", label: "照片",
                        thisVal: Double(thisPhotoList.count), lastVal: Double(lastPhotoList.count),
                        unit: "张", formatter: { "\(Int($0))" }
                    ))

                    let thisActiveDays = Set(thisPhotoList.map { cal.startOfDay(for: $0.date) }).count
                    let lastActiveDays = Set(lastPhotoList.map { cal.startOfDay(for: $0.date) }).count
                    if thisActiveDays > 0 || lastActiveDays > 0 {
                        lines.append(self.buildComparisonLine(
                            icon: "  📆", label: "拍照天数",
                            thisVal: Double(thisActiveDays), lastVal: Double(lastActiveDays),
                            unit: "天", formatter: { "\(Int($0))" }
                        ))
                    }

                    let thisFav = thisPhotoList.filter { $0.isFavorite }.count
                    let lastFav = lastPhotoList.filter { $0.isFavorite }.count
                    if thisFav > 0 || lastFav > 0 {
                        lines.append(self.buildComparisonLine(
                            icon: "  ⭐", label: "收藏",
                            thisVal: Double(thisFav), lastVal: Double(lastFav),
                            unit: "张", formatter: { "\(Int($0))" }
                        ))
                    }
            }

            // ── Life Events Section ──
            if !thisEvents.isEmpty || !lastEvents.isEmpty {
                lines.append("")
                lines.append("📝 **生活记录**")
                lines.append(self.buildComparisonLine(
                    icon: "  📖", label: "事件",
                    thisVal: Double(thisEvents.count), lastVal: Double(lastEvents.count),
                    unit: "条", formatter: { "\(Int($0))" }
                ))

                // Mood comparison
                let thisMoods = thisEvents.map { $0.mood }
                let lastMoods = lastEvents.map { $0.mood }
                if !thisMoods.isEmpty && !lastMoods.isEmpty {
                    let thisMoodAvg = thisMoods.reduce(0.0) { $0 + self.moodScoreForComparison($1) } / Double(thisMoods.count)
                    let lastMoodAvg = lastMoods.reduce(0.0) { $0 + self.moodScoreForComparison($1) } / Double(lastMoods.count)
                    let diff = thisMoodAvg - lastMoodAvg
                    let prevLabel = self.comparisonPrevPeriodLabel(range: range)
                    if abs(diff) >= 0.3 {
                        if diff > 0 {
                            lines.append("  😊 心情比\(prevLabel)好转（\(String(format: "%.1f", thisMoodAvg)) vs \(String(format: "%.1f", lastMoodAvg))）")
                            better += 1
                        } else {
                            lines.append("  😔 心情比\(prevLabel)略低（\(String(format: "%.1f", thisMoodAvg)) vs \(String(format: "%.1f", lastMoodAvg))）")
                            worse += 1
                        }
                    }
                }
            }

            // ── Overall Verdict ──
            let prevPeriod = self.comparisonPrevPeriodLabel(range: range)
            let isDayLevel = (range == .today || range == .yesterday)
            lines.append("")
            if better > worse + 1 {
                lines.append("💪 整体趋势向好，多项指标都在进步！")
            } else if better > worse {
                lines.append("💪 略有进步，保持这个势头！")
            } else if worse > better + 1 {
                lines.append("💡 多项指标下降，注意休息和调整节奏。")
            } else if worse > better {
                if isDayLevel {
                    lines.append("💡 比\(prevPeriod)有所下降，调整一下状态。")
                } else {
                    lines.append("💡 比\(prevPeriod)稍有松懈，找回节奏吧！")
                }
            } else {
                lines.append("📊 和\(prevPeriod)基本持平，保持稳定也是一种力量。")
            }

            // ── Cross-Data Narrative ──
            // Correlate changes across dimensions to produce insights no single metric can
            var narratives: [String] = []
            let thisTimedCount = thisCalEvents.filter { !$0.isAllDay }.count
            let lastTimedCount = lastCalEvents.filter { !$0.isAllDay }.count
            let thisStepsN = thisWeek.reduce(0) { $0 + $1.steps }
            let lastStepsN = lastWeek.reduce(0) { $0 + $1.steps }
            let thisSleepN = thisWeek.filter { $0.sleepHours > 0 }
            let avgThisSleep = thisSleepN.isEmpty ? 0.0 : thisSleepN.reduce(0) { $0 + $1.sleepHours } / Double(thisSleepN.count)
            let lastSleepN = lastWeek.filter { $0.sleepHours > 0 }
            let avgLastSleep = lastSleepN.isEmpty ? 0.0 : lastSleepN.reduce(0) { $0 + $1.sleepHours } / Double(lastSleepN.count)

            // Busier schedule + less sleep = burnout risk
            if Double(thisTimedCount) > Double(max(lastTimedCount, 1)) * 1.3 && avgThisSleep < avgLastSleep - 0.3 && avgThisSleep > 0 {
                narratives.append("⚠️ 日程增多 + 睡眠减少 → 注意节奏，避免累积疲劳")
            }
            // Busier schedule + fewer places = stuck at desk
            if Double(thisTimedCount) > Double(max(lastTimedCount, 1)) * 1.2 && thisLocations.count < lastLocations.count {
                narratives.append("🪑 会议变多但外出减少 → 忙碌之余记得活动一下")
            }
            // More photos + more places = enriching week
            if thisPhotoList.count > lastPhotoList.count && thisLocations.count > lastLocations.count {
                narratives.append("🌈 照片更多、足迹更广 → 这周的生活体验很丰富！")
            }
            // Less activity + fewer outings
            if thisStepsN < lastStepsN * 0.7 && lastLocations.count > 0 && thisLocations.count < lastLocations.count / 2 {
                narratives.append("🏠 活动量和外出都明显减少 → 是身体不适还是在享受宅家？")
            }

            if !narratives.isEmpty {
                lines.append("")
                lines.append("💡 **跨维度洞察**")
                narratives.forEach { lines.append("  \($0)") }
            }

            completion(lines.joined(separator: "\n"))
        }
    }

    /// Mood score for comparison (same scale as MoodSkill).
    private func moodScoreForComparison(_ mood: MoodType) -> Double {
        switch mood {
        case .great: return 5.0
        case .good: return 4.0
        case .neutral: return 3.0
        case .tired: return 2.0
        case .stressed: return 1.5
        case .sad: return 1.0
        }
    }

    // MARK: - Helpers

    /// Builds a human-readable header label for the comparison period.
    /// e.g. "本周 vs 上周", "本月 vs 上月", "最近 14 天 vs 之前 14 天"
    private func comparisonPeriodLabel(range: QueryTimeRange, spanDays: Int) -> String {
        switch range {
        case .thisWeek:
            return "本周 vs 上周"
        case .lastWeek:
            return "上周 vs 上上周"
        case .thisMonth:
            return "本月 vs 上月"
        case .lastMonth:
            return "上月 vs 前月"
        case .today:
            return "今天 vs 昨天"
        case .yesterday:
            return "昨天 vs 前天"
        default:
            if spanDays <= 7 {
                return "最近 \(spanDays) 天 vs 之前 \(spanDays) 天"
            } else if spanDays <= 31 {
                return "近 \(spanDays) 天 vs 之前同期"
            } else {
                return "\(range.label) vs 上期"
            }
        }
    }

    /// Returns a short label for the previous period, used in verdict text.
    /// e.g. "昨天", "上周", "上月", "上期"
    private func comparisonPrevPeriodLabel(range: QueryTimeRange) -> String {
        switch range {
        case .today:     return "昨天"
        case .yesterday: return "前天"
        case .thisWeek:  return "上周"
        case .lastWeek:  return "上上周"
        case .thisMonth: return "上月"
        case .lastMonth: return "前月"
        default:         return "上期"
        }
    }

    private func buildComparisonLine(
        icon: String, label: String,
        thisVal: Double, lastVal: Double,
        unit: String, formatter: (Double) -> String
    ) -> String {
        let arrow: String
        let change: String
        if lastVal > 0 {
            let pct = ((thisVal - lastVal) / lastVal) * 100
            arrow = pct >= 0 ? "↑" : "↓"
            change = "\(arrow)\(abs(Int(pct)))%"
        } else if thisVal > 0 {
            change = "新增"
        } else {
            change = "—"
        }
        return "\(icon) \(label)：\(formatter(thisVal))\(unit) vs \(formatter(lastVal))\(unit)  \(change)"
    }
}

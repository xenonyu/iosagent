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

        let fetchDays = fetchDaysNeeded(for: range)
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
                    emptyMsg += "\n今天可能还没有足够的活动。试试问我「昨天运动了多少」？"
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

            // Core metrics
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
            let totalFlights = filtered.reduce(0) { $0 + $1.flightsClimbed }
            if totalFlights > 0 {
                lines.append("🏢 爬楼：\(Int(totalFlights)) 层")
            }

            // Workout type breakdown (from HKWorkout sessions)
            let allWorkouts = filtered.flatMap { $0.workouts }
            if !allWorkouts.isEmpty {
                lines.append(contentsOf: workoutBreakdown(allWorkouts))
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

            // Related life events
            if !events.isEmpty {
                lines.append("\n📝 相关记录：")
                events.prefix(5).forEach { lines.append("• \($0.timestamp.shortDisplay)：\($0.title)") }
            }

            completion(lines.joined(separator: "\n"))
        }
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

    // MARK: - Health Metric

    private func respondHealth(metric: String, range: QueryTimeRange, context: SkillContext, completion: @escaping (String) -> Void) {
        let fetchDays = fetchDaysNeeded(for: range)
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
                respondSleep(summaries: withData, range: range, context: context, completion: completion)
            case "heartRate":
                respondHeartRate(summaries: withData, range: range, completion: completion)
            case "steps":
                respondSteps(summaries: withData, range: range, completion: completion)
            case "flights":
                respondFlights(summaries: withData, range: range, completion: completion)
            case "distance":
                respondDistance(summaries: withData, range: range, completion: completion)
            case "calories":
                respondCalories(summaries: withData, range: range, completion: completion)
            case "weight":
                respondWeight(summaries: withData, range: range, context: context, completion: completion)
            case "recovery":
                respondRecovery(summaries: allSummaries, todaySummaries: withData, range: range, context: context, completion: completion)
            case "bloodOxygen":
                self.respondBloodOxygen(summaries: withData, range: range, completion: completion)
            case "vo2max":
                self.respondVO2Max(summaries: withData, range: range, completion: completion)
            default:
                respondOverview(summaries: withData, range: range, completion: completion)
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

        // --- Sleep Quality Score (composite 0-100) ---
        let qualityScore = computeSleepQualityScore(sleepDays: sleepDays, avgHours: avg)
        let scoreEmoji: String
        if qualityScore >= 85 { scoreEmoji = "🌟" }
        else if qualityScore >= 70 { scoreEmoji = "✅" }
        else if qualityScore >= 50 { scoreEmoji = "💡" }
        else { scoreEmoji = "⚠️" }
        lines.append("\(scoreEmoji) 睡眠质量评分：\(qualityScore) / 100")
        lines.append(sleepScoreBreakdown(qualityScore))
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

        completion(lines.joined(separator: "\n"))
    }

    // MARK: - Sleep Quality Score

    /// Computes a composite sleep quality score (0-100) from multiple dimensions:
    /// - Duration adequacy (30 pts): how close to the 7-9h ideal
    /// - Phase quality (25 pts): deep + REM ratios within healthy ranges
    /// - Consistency (25 pts): low variance in sleep duration across days
    /// - Efficiency (20 pts): time asleep vs time in bed
    private func computeSleepQualityScore(sleepDays: [HealthSummary], avgHours: Double) -> Int {
        var score: Double = 0

        // 1. Duration adequacy (30 pts) — peak at 7.5-8h
        if avgHours >= 7 && avgHours <= 9 {
            score += 30
        } else if avgHours >= 6 && avgHours < 7 {
            score += 30 * (avgHours - 5) / 2   // 5h=0, 7h=30
        } else if avgHours > 9 && avgHours <= 10 {
            score += 30 * (10 - avgHours)       // 9h=30, 10h=0
        } else if avgHours >= 5 {
            score += 10
        }
        // below 5h or above 10h = 0 pts

        // 2. Phase quality (25 pts)
        let phaseDays = sleepDays.filter { $0.hasSleepPhases }
        if !phaseDays.isEmpty {
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
                score += deepScore + remScore
            }
        } else {
            // No phase data — give neutral mid-range score
            score += 12.5
        }

        // 3. Consistency (25 pts) — low standard deviation = high score
        if sleepDays.count >= 3 {
            let stdDev = standardDeviation(of: sleepDays.map { $0.sleepHours })
            if stdDev < 0.3 { score += 25 }
            else if stdDev < 0.5 { score += 22 }
            else if stdDev < 1.0 { score += 15 }
            else if stdDev < 1.5 { score += 8 }
            else { score += 3 }
        } else {
            score += 15 // not enough data to judge consistency
        }

        // 4. Efficiency (20 pts)
        let bedDays = sleepDays.filter { $0.inBedHours > 0 }
        if !bedDays.isEmpty {
            let avgInBed = bedDays.reduce(0) { $0 + $1.inBedHours } / Double(bedDays.count)
            let avgAsleep = bedDays.reduce(0) { $0 + $1.sleepHours } / Double(bedDays.count)
            // Handle both Apple Watch (inBed = total bed time) and third-party apps (inBed = awake only)
            let totalBed = avgInBed >= avgAsleep ? avgInBed : avgInBed + avgAsleep
            if totalBed > 0 {
                let eff = avgAsleep / totalBed
                if eff >= 0.9 { score += 20 }
                else if eff >= 0.85 { score += 16 }
                else if eff >= 0.75 { score += 10 }
                else { score += 5 }
            }
        } else {
            score += 12 // no in-bed data, neutral score
        }

        return min(100, max(0, Int(score)))
    }

    /// Short text explanation for the quality score range.
    private func sleepScoreBreakdown(_ score: Int) -> String {
        if score >= 85 {
            return "   睡眠质量优秀 — 时长充足、节律稳定、入睡高效"
        } else if score >= 70 {
            return "   睡眠质量良好 — 整体不错，部分维度还有优化空间"
        } else if score >= 50 {
            return "   睡眠质量一般 — 可能存在时长不足、节律不规律或入睡困难"
        } else {
            return "   睡眠质量需要关注 — 建议从固定作息时间开始改善"
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

    private func respondHeartRate(summaries: [HealthSummary], range: QueryTimeRange, completion: @escaping (String) -> Void) {
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

    private func respondSteps(summaries: [HealthSummary], range: QueryTimeRange, completion: @escaping (String) -> Void) {
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
        lines.append("📈 日均：\(Int(avg).formatted()) 步")

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

    private func respondFlights(summaries: [HealthSummary], range: QueryTimeRange, completion: @escaping (String) -> Void) {
        let flightDays = summaries.filter { $0.flightsClimbed > 0 }
        guard !flightDays.isEmpty else {
            completion("🏢 \(range.label)暂无爬楼数据。\niPhone 会自动记录爬楼层数，确保已开启健康权限。")
            return
        }

        var lines: [String] = ["🏢 \(range.label)的爬楼数据\n"]
        let total = flightDays.reduce(0) { $0 + $1.flightsClimbed }
        let avg = total / Double(flightDays.count)
        let best = flightDays.max(by: { $0.flightsClimbed < $1.flightsClimbed })!

        lines.append("🪜 总楼层：\(Int(total)) 层（日均 \(Int(avg)) 层）")
        // 1 flight ≈ 3 meters of elevation gain
        let totalMeters = total * 3
        lines.append("📐 约等于爬升 \(Int(totalMeters)) 米")

        if flightDays.count > 1 {
            let fmt = DateFormatter()
            fmt.dateFormat = "M月d日(E)"
            fmt.locale = Locale(identifier: "zh_CN")
            lines.append("🏆 最多的一天：\(fmt.string(from: best.date))，\(Int(best.flightsClimbed)) 层")
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
        let activeDays = flightDays.filter { $0.flightsClimbed >= 10 }.count
        if activeDays > 0 {
            lines.append("🎯 有 \(activeDays) 天达到了 10 层以上，爬楼是很好的有氧运动！")
        }

        completion(lines.joined(separator: "\n"))
    }

    // MARK: - Distance

    private func respondDistance(summaries: [HealthSummary], range: QueryTimeRange, completion: @escaping (String) -> Void) {
        let distanceDays = summaries.filter { $0.distanceKm > 0.01 }
        guard !distanceDays.isEmpty else {
            completion("📏 \(range.label)暂无步行距离数据。\n开启健康权限后可以自动追踪步行和跑步距离。")
            return
        }

        var lines: [String] = ["📏 \(range.label)的步行/跑步距离\n"]
        let total = distanceDays.reduce(0) { $0 + $1.distanceKm }
        let avg = total / Double(distanceDays.count)
        let best = distanceDays.max(by: { $0.distanceKm < $1.distanceKm })!

        lines.append("🛣 总距离：\(String(format: "%.1f", total)) 公里（日均 \(String(format: "%.1f", avg)) 公里）")

        if distanceDays.count > 1 {
            let fmt = DateFormatter()
            fmt.dateFormat = "M月d日(E)"
            fmt.locale = Locale(identifier: "zh_CN")
            lines.append("🏆 最远的一天：\(fmt.string(from: best.date))，\(String(format: "%.1f", best.distanceKm)) 公里")
        }

        // Correlate with steps if available
        let totalSteps = distanceDays.reduce(0) { $0 + $1.steps }
        if totalSteps > 0 && total > 0 {
            let strideCm = Int(total * 100000 / totalSteps)
            lines.append("👣 平均步幅约 \(strideCm) cm")
        }

        // Fun distance comparisons
        lines.append("")
        if total >= 42.195 {
            let marathons = total / 42.195
            lines.append("🏅 累计距离超过 \(String(format: "%.1f", marathons)) 个马拉松！")
        } else if total >= 21.1 {
            lines.append("🏅 累计距离超过一个半马拉松（21.1km），继续加油！")
        } else if total >= 10 {
            let remaining = 21.1 - total
            lines.append("🎯 再走 \(String(format: "%.1f", remaining)) 公里就达到半马距离了。")
        } else if total >= 5 {
            lines.append("🚶 保持日常步行，积少成多。")
        }

        // Trend (compare first half vs second half)
        if distanceDays.count >= 4 {
            let sorted = distanceDays.sorted { $0.date < $1.date }
            let mid = sorted.count / 2
            let olderAvg = sorted.prefix(mid).reduce(0) { $0 + $1.distanceKm } / Double(mid)
            let recentAvg = sorted.suffix(from: mid).reduce(0) { $0 + $1.distanceKm } / Double(sorted.count - mid)
            if olderAvg > 0 {
                let pct = ((recentAvg - olderAvg) / olderAvg) * 100
                if pct >= 10 {
                    lines.append("📈 步行距离呈上升趋势（+\(Int(pct))%），活动量在增加！")
                } else if pct <= -10 {
                    lines.append("📉 步行距离有所下降（\(Int(pct))%），试试换条新路线散步？")
                }
            }
        }

        completion(lines.joined(separator: "\n"))
    }

    // MARK: - Calories (Active Energy)

    private func respondCalories(summaries: [HealthSummary], range: QueryTimeRange, completion: @escaping (String) -> Void) {
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
        lines.append("📊 日均消耗：\(Int(avg).formatted()) 千卡")

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
                // ── Single-day detailed breakdown (original behavior) ──
                self.respondRecoverySingleDay(day: day, baseline: effectiveBaseline, range: range, completion: completion)
            } else {
                // ── Multi-day recovery trend ──
                self.respondRecoveryTrend(days: rangeData, baseline: effectiveBaseline, range: range, completion: completion)
            }
        }
    }

    // MARK: - Single-Day Recovery (detailed breakdown)

    private func respondRecoverySingleDay(day: HealthSummary, baseline: [HealthSummary],
                                          range: QueryTimeRange, completion: @escaping (String) -> Void) {
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

        // Dimension breakdown
        lines.append("")
        for dim in score.dimensions {
            let dimBar = max(1, dim.score * 5 / dim.maxScore)
            let dimBarStr = String(repeating: "●", count: dimBar) + String(repeating: "○", count: 5 - dimBar)
            lines.append("\(dim.emoji) \(dim.name) \(dimBarStr) \(dim.score)/\(dim.maxScore)")
            lines.append("   \(dim.detail)")
        }

        // --- Training Recommendation ---
        lines.append("")
        lines.append("💡 训练建议")
        if score.total >= 85 {
            lines.append("身体恢复充分，今天适合高强度训练！")
            lines.append("可以挑战：间歇跑、HIIT、力量训练、速度训练")
        } else if score.total >= 70 {
            lines.append("状态不错，适合中高强度训练。")
            lines.append("推荐：稳态有氧、常规力量训练、球类运动")
        } else if score.total >= 55 {
            lines.append("身体还在恢复，建议中低强度活动。")
            lines.append("推荐：轻松慢跑、瑜伽、散步、拉伸")
        } else if score.total >= 40 {
            lines.append("恢复不足，今天以轻度活动为主。")
            lines.append("推荐：散步、轻度拉伸、冥想，避免高强度运动")
        } else {
            lines.append("身体需要休息，建议今天以恢复为主。")
            lines.append("推荐：充足睡眠、轻度散步、放松活动")
            lines.append("如果持续多天恢复不佳，请留意是否有过度训练或生活压力。")
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
        for day in sorted {
            let score = computeDailyRecoveryScore(day: day, baseline: baseline)
            let label = sorted.count <= 7 ? dayFmt.string(from: day.date) : dateFmt.string(from: day.date)
            dailyScores.append((day.date, score.total, label))
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

        completion(lines.joined(separator: "\n"))
    }

    // MARK: - Daily Recovery Score Calculator

    /// Computes a recovery score (0-100) for a single day against a personal baseline.
    /// Reusable across single-day detail and multi-day trend views.
    private struct RecoveryScore {
        let total: Int
        let dimensions: [(name: String, emoji: String, score: Int, maxScore: Int, detail: String)]
    }

    private func computeDailyRecoveryScore(day: HealthSummary, baseline: [HealthSummary]) -> RecoveryScore {
        var totalScore: Double = 0
        var maxPossible: Double = 0
        var dimensions: [(name: String, emoji: String, score: Int, maxScore: Int, detail: String)] = []

        // --- 1. Sleep Recovery (35 pts) ---
        maxPossible += 35
        if day.sleepHours > 0 {
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
            totalScore += 15
            dimensions.append(("睡眠恢复", "😴", 15, 35, "无数据"))
        }

        // --- 2. HRV Status (30 pts) ---
        maxPossible += 30
        let hrvDays = baseline.filter { $0.hrv > 0 }
        if day.hrv > 0 && !hrvDays.isEmpty {
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
            var hrvScore: Double = 0
            if day.hrv >= 50 { hrvScore = 25 }
            else if day.hrv >= 30 { hrvScore = 18 }
            else { hrvScore = 10 }
            totalScore += hrvScore
            dimensions.append(("心率变异性", "📳", Int(hrvScore), 30, "\(Int(day.hrv)) ms"))
        } else {
            totalScore += 15
            dimensions.append(("心率变异性", "📳", 15, 30, "无数据"))
        }

        // --- 3. Resting HR (20 pts) ---
        maxPossible += 20
        let rhrDays = baseline.filter { $0.restingHeartRate > 0 }
        if day.restingHeartRate > 0 && !rhrDays.isEmpty {
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
            var rhrScore: Double = 0
            if day.restingHeartRate <= 65 { rhrScore = 18 }
            else if day.restingHeartRate <= 75 { rhrScore = 14 }
            else { rhrScore = 8 }
            totalScore += rhrScore
            dimensions.append(("静息心率", "🫀", Int(rhrScore), 20, "\(Int(day.restingHeartRate)) BPM"))
        } else {
            totalScore += 10
            dimensions.append(("静息心率", "🫀", 10, 20, "无数据"))
        }

        // --- 4. Training Load (15 pts) ---
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
        return RecoveryScore(total: finalScore, dimensions: dimensions)
    }

    /// Returns emoji + label for a recovery score value.
    private func recoveryLabel(score: Int) -> (emoji: String, label: String) {
        if score >= 85 { return ("🟢", "恢复充分") }
        if score >= 70 { return ("🟢", "恢复良好") }
        if score >= 55 { return ("🟡", "恢复中等") }
        if score >= 40 { return ("🟠", "恢复不足") }
        return ("🔴", "需要休息")
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

    private func respondOverview(summaries: [HealthSummary], range: QueryTimeRange, completion: @escaping (String) -> Void) {
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

        completion(lines.joined(separator: "\n"))
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
                    if abs(diff) >= 0.3 {
                        if diff > 0 {
                            lines.append("  😊 心情比上周好转（\(String(format: "%.1f", thisMoodAvg)) vs \(String(format: "%.1f", lastMoodAvg))）")
                            better += 1
                        } else {
                            lines.append("  😔 心情比上周略低（\(String(format: "%.1f", thisMoodAvg)) vs \(String(format: "%.1f", lastMoodAvg))）")
                            worse += 1
                        }
                    }
                }
            }

            // ── Overall Verdict ──
            lines.append("")
            if better > worse + 1 {
                lines.append("💪 整体趋势向好，多项指标都在进步！")
            } else if better > worse {
                lines.append("💪 略有进步，保持这个势头！")
            } else if worse > better + 1 {
                lines.append("💡 多项指标下降，注意休息和调整节奏。")
            } else if worse > better {
                lines.append("💡 这周稍有松懈，下周找回节奏吧！")
            } else {
                lines.append("📊 和上周基本持平，保持稳定也是一种力量。")
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

    /// Format minutes into short duration string.
    private static func formatDurationShort(_ minutes: Double) -> String {
        if minutes >= 60 {
            let h = Int(minutes) / 60
            let m = Int(minutes) % 60
            return m > 0 ? "\(h)h\(m)m" : "\(h)h"
        }
        return "\(Int(minutes))m"
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

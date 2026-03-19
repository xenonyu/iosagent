import Foundation
import CoreData

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
        let cal = Calendar.current
        let events = CDLifeEvent.fetch(from: interval.start, to: interval.end, in: context.coreDataContext)
        let locations = CDLocationRecord.fetch(from: interval.start, to: interval.end, in: context.coreDataContext)
        let spanDays = max(1, cal.dateComponents([.day], from: interval.start, to: interval.end).day ?? 1)

        // Fetch health data covering the requested range + previous period for comparison
        let fetchDays = max(cal.dateComponents([.day], from: interval.start, to: Date()).day ?? 7, 1) + 1
        let totalFetchDays = fetchDays + spanDays // extra span for previous-period comparison
        context.healthService.fetchSummaries(days: totalFetchDays) { allSummaries in
            let summaries = allSummaries.filter { interval.contains($0.date) }
            let withData = summaries.filter { $0.hasData }

            // Previous period of equal length for comparison
            let prevEnd = interval.start
            let prevStart = cal.date(byAdding: .day, value: -spanDays, to: prevEnd) ?? prevEnd
            let prevSummaries = allSummaries.filter { $0.date >= prevStart && $0.date < prevEnd && $0.hasData }

            var lines: [String] = ["📋 \(range.label)的生活总结：\n"]
            var hasAnyData = false

            // ── Calendar Events ──
            let calInterval = Self.calendarInterval(for: range)
            let calendarEvents = context.calendarService.fetchEvents(from: calInterval.start, to: calInterval.end)
            if !calendarEvents.isEmpty {
                hasAnyData = true
                let timedEvents = calendarEvents.filter { !$0.isAllDay }
                let totalMinutes = timedEvents.reduce(0.0) { $0 + $1.duration } / 60.0

                lines.append("📅 **日程**")
                var calLine = "  共 \(calendarEvents.count) 个事件"
                if totalMinutes >= 60 { calLine += "，约 \(Self.formatDuration(totalMinutes)) 有安排" }
                lines.append(calLine)

                // Busiest day
                if spanDays > 1 {
                    let dateFmt = DateFormatter()
                    dateFmt.dateFormat = "M月d日（E）"
                    dateFmt.locale = Locale(identifier: "zh_CN")
                    let grouped = Dictionary(grouping: timedEvents) { cal.startOfDay(for: $0.startDate) }
                    if let busiestDay = grouped.max(by: { $0.value.count < $1.value.count }),
                       busiestDay.value.count > 1 {
                        lines.append("  📊 最忙：\(dateFmt.string(from: busiestDay.key))（\(busiestDay.value.count) 个会议）")
                    }
                    // Free days
                    let daysWithEvents = grouped.count
                    let freeDays = spanDays - daysWithEvents
                    if freeDays > 0 {
                        lines.append("  💚 \(freeDays) 天没有日程安排")
                    }
                }

                // Previous-period calendar comparison
                let prevCalEvents = context.calendarService.fetchEvents(from: prevStart, to: prevEnd)
                if !prevCalEvents.isEmpty {
                    let delta = calendarEvents.count - prevCalEvents.count
                    if delta > 2 {
                        lines.append("  📈 比上个同期多 \(delta) 个事件")
                    } else if delta < -2 {
                        lines.append("  📉 比上个同期少 \(-delta) 个事件，节奏放缓")
                    }
                }
            }

            // ── Health Data with averages, goals, and trends ──
            if !withData.isEmpty {
                hasAnyData = true
                let dayCount = Double(max(withData.count, 1))
                let totalSteps = withData.reduce(0) { $0 + $1.steps }
                let avgSteps = totalSteps / dayCount
                let totalExercise = withData.reduce(0) { $0 + $1.exerciseMinutes }
                let avgExercise = totalExercise / dayCount
                let totalCalories = withData.reduce(0) { $0 + $1.activeCalories }
                let totalDistance = withData.reduce(0) { $0 + $1.distanceKm }
                let totalFlights = withData.reduce(0) { $0 + $1.flightsClimbed }
                let sleepDays = withData.filter { $0.sleepHours > 0 }
                let avgSleep = sleepDays.isEmpty ? 0.0 : sleepDays.reduce(0) { $0 + $1.sleepHours } / Double(sleepDays.count)
                let goalDays = withData.filter { $0.steps >= 8000 }.count
                let exerciseGoalDays = withData.filter { $0.exerciseMinutes >= 30 }.count

                // Previous-period health baselines
                let hasPrev = !prevSummaries.isEmpty
                let prevDayCount = Double(max(prevSummaries.count, 1))
                let prevAvgSteps = hasPrev ? prevSummaries.reduce(0) { $0 + $1.steps } / prevDayCount : 0
                let prevAvgExercise = hasPrev ? prevSummaries.reduce(0) { $0 + $1.exerciseMinutes } / prevDayCount : 0
                let prevSleepDays = prevSummaries.filter { $0.sleepHours > 0 }
                let prevAvgSleep = prevSleepDays.isEmpty ? 0.0 : prevSleepDays.reduce(0) { $0 + $1.sleepHours } / Double(prevSleepDays.count)

                lines.append("\n🏃 **健康**")

                // Steps: daily average + goal attainment + trend
                if totalSteps > 0 {
                    var stepsLine = "  👟 日均 \(Int(avgSteps).formatted()) 步"
                    if withData.count > 1 { stepsLine += "，\(goalDays)/\(withData.count) 天达标（≥8000）" }
                    if hasPrev && prevAvgSteps > 0 {
                        stepsLine += " \(Self.formatDelta(current: avgSteps, previous: prevAvgSteps))"
                    }
                    lines.append(stepsLine)
                }

                // Exercise: daily average + goal days
                if totalExercise > 0 {
                    var exLine = "  ⏱ 日均运动 \(Int(avgExercise)) 分钟"
                    if withData.count > 1 { exLine += "，\(exerciseGoalDays) 天达标（≥30min）" }
                    if hasPrev && prevAvgExercise > 0 {
                        exLine += " \(Self.formatDelta(current: avgExercise, previous: prevAvgExercise))"
                    }
                    lines.append(exLine)
                }

                // Workout type breakdown for the period
                let allWorkouts = withData.flatMap { $0.workouts }
                if !allWorkouts.isEmpty {
                    var typeStats: [String: (emoji: String, count: Int, totalMin: Double)] = [:]
                    for w in allWorkouts {
                        var stat = typeStats[w.typeName] ?? (emoji: w.typeEmoji, count: 0, totalMin: 0)
                        stat.count += 1
                        stat.totalMin += w.duration / 60.0
                        typeStats[w.typeName] = stat
                    }
                    let sortedTypes = typeStats.sorted { $0.value.totalMin > $1.value.totalMin }
                    let summary = sortedTypes.prefix(4).map { t in
                        "\(t.value.emoji)\(t.key)×\(t.value.count)"
                    }.joined(separator: "  ")
                    lines.append("  🗂️ 运动类型：\(summary)")
                }

                // Calories
                if totalCalories > 0 {
                    lines.append("  🔥 累计消耗 \(Int(totalCalories).formatted()) 千卡")
                }

                // Distance + flights
                if totalDistance > 0.5 {
                    var moveLine = "  📏 步行 \(String(format: "%.1f", totalDistance)) 公里"
                    if totalFlights > 0 { moveLine += "，爬楼 \(Int(totalFlights)) 层" }
                    lines.append(moveLine)
                } else if totalFlights > 0 {
                    lines.append("  🏢 爬楼 \(Int(totalFlights)) 层")
                }

                // Sleep average
                if avgSleep > 0 {
                    let goodSleepDays = sleepDays.filter { $0.sleepHours >= 7 && $0.sleepHours <= 9 }.count
                    var sleepLine = "  😴 均睡 \(String(format: "%.1f", avgSleep))h"
                    if sleepDays.count > 1 {
                        sleepLine += "，\(goodSleepDays)/\(sleepDays.count) 晚在健康范围"
                    }
                    if prevAvgSleep > 0 {
                        let sleepDiff = avgSleep - prevAvgSleep
                        if abs(sleepDiff) >= 0.3 {
                            let arrow = sleepDiff > 0 ? "↑" : "↓"
                            sleepLine += "（\(arrow)\(String(format: "%.1f", abs(sleepDiff)))h vs 上期）"
                        }
                    }
                    lines.append(sleepLine)

                    // Sleep quality breakdown: deep/REM/efficiency when available
                    let qualityLines = Self.buildSleepQualityBreakdown(
                        sleepDays: sleepDays,
                        prevSleepDays: prevSleepDays
                    )
                    lines.append(contentsOf: qualityLines)
                }

                // ── Recovery Metrics: HRV + Resting HR ──
                let recoveryLines = Self.buildRecoveryMetrics(
                    withData: withData,
                    prevSummaries: prevSummaries
                )
                lines.append(contentsOf: recoveryLines)

                // Best and worst day
                if withData.count >= 3, let best = withData.max(by: { $0.steps < $1.steps }),
                   let worst = withData.filter({ $0.steps > 0 }).min(by: { $0.steps < $1.steps }),
                   best.steps > worst.steps * 1.5 {
                    let fmt = DateFormatter()
                    fmt.dateFormat = "M/d（E）"
                    fmt.locale = Locale(identifier: "zh_CN")
                    lines.append("  🏆 最活跃：\(fmt.string(from: best.date)) \(Int(best.steps).formatted())步")
                    lines.append("  📉 最安静：\(fmt.string(from: worst.date)) \(Int(worst.steps).formatted())步")
                }

                // Overall health verdict — considers activity, sleep, AND recovery
                let hrvDays = withData.filter { $0.hrv > 0 }
                let avgHRV = hrvDays.isEmpty ? 0.0 : hrvDays.reduce(0) { $0 + $1.hrv } / Double(hrvDays.count)
                let rhrDays = withData.filter { $0.restingHeartRate > 0 }
                let avgRHR = rhrDays.isEmpty ? 0.0 : rhrDays.reduce(0) { $0 + $1.restingHeartRate } / Double(rhrDays.count)

                var score = 0
                if avgSteps >= 8000 { score += 1 }
                if avgExercise >= 30 { score += 1 }
                if avgSleep >= 7 && avgSleep <= 9 { score += 1 }
                // Recovery bonus: good HRV trend or low resting HR indicates body is thriving
                let recoveryGood = (avgHRV > 0 && avgHRV >= 40) || (avgRHR > 0 && avgRHR <= 65)
                let recoveryPoor = (avgHRV > 0 && avgHRV < 25) || (avgRHR > 0 && avgRHR >= 80)

                if score == 3 && recoveryGood {
                    lines.append("  ✅ 活动、睡眠、恢复全面达标，身体状态极佳！")
                } else if score == 3 {
                    lines.append("  ✅ 步数、运动、睡眠全面达标！")
                } else if score >= 2 && recoveryGood {
                    lines.append("  💪 整体状态不错，身体恢复良好")
                } else if score >= 2 && recoveryPoor {
                    lines.append("  ⚠️ 活动达标但恢复指标偏低，注意休息和放松")
                } else if score >= 2 {
                    lines.append("  💪 整体状态不错，还有一项可以提升")
                } else if recoveryPoor && withData.count >= 3 {
                    lines.append("  ⚠️ 恢复指标偏低，建议优先保证睡眠质量")
                } else if score == 1 && withData.count >= 3 {
                    lines.append("  💡 有提升空间，试试从最容易的一项开始")
                }
            }

            // ── Locations with top places ──
            if !locations.isEmpty {
                hasAnyData = true
                let uniquePlaces = Set(locations.map { $0.displayName })
                var placeCount: [String: Int] = [:]
                locations.forEach { placeCount[$0.displayName, default: 0] += 1 }
                let sorted = placeCount.sorted { $0.value > $1.value }

                lines.append("\n📍 **足迹**  \(uniquePlaces.count) 个地点")
                // Top 3 places
                for (place, count) in sorted.prefix(3) {
                    lines.append("  • \(place)（\(count) 次）")
                }
                if uniquePlaces.count > 3 {
                    lines.append("  …还去过 \(uniquePlaces.count - 3) 个其他地点")
                }
            }

            // ── Photo Activity with peak day ──
            if context.photoService.isAuthorized {
                let photos = context.photoService.fetchMetadata(from: interval.start, to: interval.end)
                if !photos.isEmpty {
                    hasAnyData = true
                    let activeDays = Set(photos.map { cal.startOfDay(for: $0.date) }).count
                    let favCount = photos.filter { $0.isFavorite }.count

                    var photoLine = "\n📷 **照片**  \(photos.count) 张"
                    if activeDays > 1 { photoLine += "，\(activeDays) 天有拍照" }
                    if favCount > 0 { photoLine += "，\(favCount) 张收藏" }
                    lines.append(photoLine)

                    // Peak shooting day
                    if activeDays >= 2 {
                        var dayPhotoCount: [Date: Int] = [:]
                        photos.forEach { dayPhotoCount[cal.startOfDay(for: $0.date), default: 0] += 1 }
                        if let (bestDay, count) = dayPhotoCount.max(by: { $0.value < $1.value }), count >= 3 {
                            let dayFmt = DateFormatter()
                            dayFmt.dateFormat = "M月d日"
                            dayFmt.locale = Locale(identifier: "zh_CN")
                            lines.append("  🏆 拍照最多：\(dayFmt.string(from: bestDay))（\(count) 张）")
                        }
                    }

                    // Photo content breakdown from Vision index
                    let contentLines = self.buildPhotoContentSummary(interval: interval, context: context)
                    lines.append(contentsOf: contentLines)
                }
            }

            // ── Life Events ──
            if !events.isEmpty {
                hasAnyData = true
                let byCategory = Dictionary(grouping: events, by: { $0.category })
                lines.append("\n📝 **生活事件**（\(events.count) 条）")
                for (cat, evts) in byCategory.sorted(by: { $0.value.count > $1.value.count }) {
                    lines.append("  \(cat.label)：\(evts.count) 条")
                }
            }

            // ── Mood ──
            let moods = events.map { $0.mood }
            if !moods.isEmpty {
                let moodCount = Dictionary(grouping: moods, by: { $0 }).mapValues { $0.count }
                if let dominant = moodCount.max(by: { $0.value < $1.value }) {
                    var moodLine = "\(dominant.key.emoji) 主要心情：\(dominant.key.label)"
                    if moodCount.count >= 2 {
                        let sorted = moodCount.sorted { $0.value > $1.value }
                        let desc = sorted.prefix(3).map { "\($0.key.emoji)\($0.value)次" }.joined(separator: " ")
                        moodLine += "（\(desc)）"
                    }
                    lines.append("\n\(moodLine)")
                }
            }

            // ── Cross-Data Insights for the period ──
            if hasAnyData && withData.count >= 2 {
                let periodInsights = Self.buildPeriodCrossInsights(
                    healthSummaries: withData,
                    calendarEvents: calendarEvents,
                    locations: locations,
                    cal: cal
                )
                if !periodInsights.isEmpty {
                    lines.append("\n💡 **发现**")
                    periodInsights.forEach { lines.append("  \($0)") }
                }
            }

            if !hasAnyData {
                var tips: [String] = ["暂无足够的数据生成总结。\n\n可以这样让总结更丰富："]
                if !context.calendarService.isAuthorized {
                    tips.append("• 开启「日历」权限 → 查看日程安排")
                }
                if !context.photoService.isAuthorized {
                    tips.append("• 开启「照片」权限 → 查看拍照记录")
                }
                tips.append("• 开启「健康」权限 → 查看运动和睡眠数据")
                tips.append("• 开启「位置」权限 → 查看去过的地方")
                tips.append("\n前往「设置 → iosclaw」开启相关权限即可。")
                lines.append(tips.joined(separator: "\n"))
            }

            completion(lines.joined(separator: "\n"))
        }
    }

    // MARK: - Daily Review

    private func respondDailyReview(context: SkillContext, completion: @escaping (String) -> Void) {
        let interval = QueryTimeRange.today.interval
        let events = CDLifeEvent.fetch(from: interval.start, to: interval.end, in: context.coreDataContext)
        let locations = CDLocationRecord.fetch(from: interval.start, to: interval.end, in: context.coreDataContext)

        // Fetch today + recent 7 days for comparison context
        context.healthService.fetchDailySummary(for: Date()) { health in
            context.healthService.fetchSummaries(days: 7) { recentSummaries in
            let cal = Calendar.current
            let now = Date()
            let hour = cal.component(.hour, from: now)
            let timeGreet = hour < 12 ? "早安" : (hour < 18 ? "下午好" : "晚上好")

            var lines: [String] = []
            let isMorningBriefing = hour < 10 && (health.steps < 1000 && health.exerciseMinutes < 5)
            if isMorningBriefing {
                lines.append("🌅 \(timeGreet)！这是你的晨间简报：\n")
            } else {
                lines.append("🌅 \(timeGreet)！今天的生活全景：\n")
            }

            var hasData = false

            // --- Calendar Events (iOS native schedule, full day to include upcoming events) ---
            let calDayInterval = Self.calendarInterval(for: .today)
            let calendarEvents = context.calendarService.fetchEvents(from: calDayInterval.start, to: calDayInterval.end)
            if !calendarEvents.isEmpty {
                hasData = true
                let timedEvents = calendarEvents.filter { !$0.isAllDay }
                let allDayEvents = calendarEvents.filter { $0.isAllDay }
                let totalMinutes = timedEvents.reduce(0.0) { $0 + $1.duration } / 60.0

                lines.append("📅 **日程**  共 \(calendarEvents.count) 个事件")

                // Show all-day events
                if !allDayEvents.isEmpty {
                    let names = allDayEvents.prefix(2).map { $0.title }.joined(separator: "、")
                    lines.append("  🏷️ 全天：\(names)")
                }

                // Show busy level
                if totalMinutes >= 360 {
                    lines.append("  🔴 日程密集，约 \(Self.formatDuration(totalMinutes)) 有安排")
                } else if totalMinutes >= 120 {
                    lines.append("  🟡 日程适中，约 \(Self.formatDuration(totalMinutes)) 有安排")
                }

                // Next upcoming event for today
                let upcoming = timedEvents.filter { $0.endDate > now }.sorted { $0.startDate < $1.startDate }
                if let next = upcoming.first {
                    let minutesUntil = next.startDate.timeIntervalSince(now) / 60
                    if minutesUntil > 0 && minutesUntil <= 480 {
                        let timeStr = minutesUntil < 60
                            ? "\(Int(minutesUntil)) 分钟后"
                            : "\(Int(minutesUntil / 60)) 小时后"
                        lines.append("  ⏰ 接下来：\(timeStr)「\(next.title)」")
                    } else if minutesUntil <= 0 {
                        lines.append("  🔴 正在进行「\(next.title)」")
                    }
                } else if !timedEvents.isEmpty {
                    lines.append("  ✅ 日程已全部结束")
                }

                // Detect back-to-back meetings (no gap or <10 min gap)
                let sorted = timedEvents.sorted { $0.startDate < $1.startDate }
                var backToBackCount = 0
                for i in 0..<(sorted.count - 1) {
                    let gap = sorted[i + 1].startDate.timeIntervalSince(sorted[i].endDate) / 60
                    if gap < 10 { backToBackCount += 1 }
                }
                if backToBackCount > 0 {
                    lines.append("  ⚠️ \(backToBackCount) 组会议背靠背，注意留出休息时间")
                }
            }

            // --- Health Data (enriched with weekly context) ---
            let hasHealthData = health.steps > 0 || health.exerciseMinutes > 0 || health.sleepHours > 0
                || health.activeCalories > 0 || health.distanceKm > 0.01 || health.flightsClimbed > 0
                || health.heartRate > 0

            // --- Morning Briefing: Yesterday's Activity Recap ---
            // Before 10am, today's activity data (steps/exercise) is usually near-zero.
            // Instead of showing "0 steps", show yesterday's recap so the morning greeting
            // is actually useful: sleep + yesterday's activity + today's calendar.
            if isMorningBriefing {
                let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now))!
                let yesterdaySummary = recentSummaries.first { cal.isDate($0.date, inSameDayAs: yesterday) }
                if let yd = yesterdaySummary, yd.hasData,
                   (yd.steps > 0 || yd.exerciseMinutes > 0) {
                    hasData = true
                    lines.append("\n📋 **昨日活动**")
                    if yd.steps > 0 {
                        let stepGoal = 8000.0
                        let goalTag = yd.steps >= stepGoal ? " ✅" : ""
                        lines.append("  👟 \(Int(yd.steps).formatted()) 步\(goalTag)")
                    }
                    if yd.exerciseMinutes > 0 {
                        let goalTag = yd.exerciseMinutes >= 30 ? " ✅" : ""
                        lines.append("  ⏱ 运动 \(Int(yd.exerciseMinutes)) 分钟\(goalTag)")
                    }
                    if !yd.workouts.isEmpty {
                        let workoutDesc = yd.workouts.sorted { $0.duration > $1.duration }
                            .prefix(3)
                            .map { "\($0.typeEmoji)\($0.typeName) \($0.durationFormatted)" }
                            .joined(separator: "  ")
                        lines.append("     \(workoutDesc)")
                    }
                    if yd.activeCalories > 0 {
                        lines.append("  🔥 消耗 \(Int(yd.activeCalories).formatted()) 千卡")
                    }
                    if yd.distanceKm > 0.1 {
                        lines.append("  📏 步行 \(String(format: "%.1f", yd.distanceKm)) 公里")
                    }
                    // Quick verdict for yesterday
                    var ydScore = 0
                    if yd.steps >= 8000 { ydScore += 1 }
                    if yd.exerciseMinutes >= 30 { ydScore += 1 }
                    if ydScore == 2 {
                        lines.append("  🏅 昨天步数和运动都达标了！")
                    } else if ydScore == 0 && yd.steps > 0 {
                        lines.append("  💡 昨天活动量偏低，今天动起来吧")
                    }
                }
            }

            if hasHealthData {
                hasData = true
                // Compute 7-day averages for comparison (exclude today)
                let pastDays = recentSummaries.filter { !cal.isDateInToday($0.date) && $0.hasData }
                let avgSteps = pastDays.isEmpty ? 0 : pastDays.reduce(0) { $0 + $1.steps } / Double(pastDays.count)
                let avgExercise = pastDays.isEmpty ? 0 : pastDays.reduce(0) { $0 + $1.exerciseMinutes } / Double(pastDays.count)

                // In morning briefing mode, label this section differently since it's mostly sleep/recovery
                let healthHeader = isMorningBriefing ? "\n😴 **今晨状态**" : "\n🏃 **健康**"
                lines.append(healthHeader)

                // Steps with goal progress
                if health.steps > 0 {
                    let stepGoal = 8000.0
                    let progress = min(health.steps / stepGoal, 1.0)
                    let barFilled = Int(progress * 8)
                    let bar = String(repeating: "▓", count: barFilled) + String(repeating: "░", count: 8 - barFilled)
                    let goalTag = health.steps >= stepGoal ? " ✅" : ""
                    lines.append("  👟 \(Int(health.steps).formatted()) 步 \(bar)\(goalTag)")
                    // Compare to weekly average
                    if avgSteps > 0 {
                        let diff = ((health.steps - avgSteps) / avgSteps) * 100
                        if abs(diff) >= 15 {
                            let arrow = diff > 0 ? "↑" : "↓"
                            lines.append("     较近 7 日均值 \(arrow)\(abs(Int(diff)))%")
                        }
                    }
                }

                // Exercise with goal progress
                if health.exerciseMinutes > 0 {
                    let exGoal = 30.0
                    let progress = min(health.exerciseMinutes / exGoal, 1.0)
                    let barFilled = Int(progress * 8)
                    let bar = String(repeating: "▓", count: barFilled) + String(repeating: "░", count: 8 - barFilled)
                    let goalTag = health.exerciseMinutes >= exGoal ? " ✅" : ""
                    lines.append("  ⏱ 运动 \(Int(health.exerciseMinutes)) 分钟 \(bar)\(goalTag)")
                    if avgExercise > 0 {
                        let diff = ((health.exerciseMinutes - avgExercise) / avgExercise) * 100
                        if abs(diff) >= 20 {
                            let arrow = diff > 0 ? "↑" : "↓"
                            lines.append("     较近 7 日均值 \(arrow)\(abs(Int(diff)))%")
                        }
                    }
                }

                // Today's workout details — show what the user actually did, not just minutes
                if !health.workouts.isEmpty {
                    let sorted = health.workouts.sorted { $0.startDate < $1.startDate }
                    if sorted.count <= 3 {
                        // Few workouts: show each with detail
                        for w in sorted {
                            var detail = "     \(w.typeEmoji) \(w.typeName) \(w.durationFormatted)"
                            if w.totalCalories > 0 { detail += "·\(Int(w.totalCalories))kcal" }
                            if w.totalDistance > 500 {
                                let km = w.totalDistance / 1000
                                detail += "·\(String(format: "%.1f", km))km"
                            }
                            lines.append(detail)
                        }
                    } else {
                        // Many workouts: compact one-liner per workout
                        let compact = sorted.map { "\($0.typeEmoji)\($0.typeName) \($0.durationFormatted)" }
                            .joined(separator: "  ")
                        lines.append("     \(compact)")
                    }
                }

                // Calories
                if health.activeCalories > 0 {
                    lines.append("  🔥 消耗 \(Int(health.activeCalories).formatted()) 千卡")
                }

                // Distance
                if health.distanceKm > 0.1 {
                    lines.append("  📏 步行 \(String(format: "%.1f", health.distanceKm)) 公里")
                }

                // Flights climbed
                if health.flightsClimbed > 0 {
                    lines.append("  🏢 爬楼 \(Int(health.flightsClimbed)) 层")
                }

                // Sleep (from last night)
                if health.sleepHours > 0 {
                    var sleepLine = "  😴 昨晚 \(String(format: "%.1f", health.sleepHours))h"
                    if health.sleepHours >= 7 && health.sleepHours <= 9 {
                        sleepLine += " ✅"
                    } else if health.sleepHours < 6 {
                        sleepLine += " ⚠️ 偏少"
                    } else if health.sleepHours > 9.5 {
                        sleepLine += " 💤 偏多"
                    }
                    // Append sleep phase summary if available
                    if health.hasSleepPhases {
                        let deepPct = health.sleepHours > 0
                            ? Int(health.sleepDeepHours / health.sleepHours * 100) : 0
                        sleepLine += "（深睡 \(String(format: "%.1f", health.sleepDeepHours))h·\(deepPct)%）"
                    }
                    lines.append(sleepLine)
                    // Show bedtime/wake time if available
                    if let onset = health.sleepOnset, let wake = health.wakeTime {
                        let timeFmt = DateFormatter()
                        timeFmt.dateFormat = "HH:mm"
                        lines.append("     🕐 \(timeFmt.string(from: onset)) 入睡 → \(timeFmt.string(from: wake)) 醒来")
                    }
                }

                // Heart rate — prefer resting HR (more meaningful) over average
                if health.restingHeartRate > 0 {
                    // Compare RHR to 7-day baseline for trend insight
                    let baselineRHR = pastDays.filter { $0.restingHeartRate > 0 }
                    if baselineRHR.count >= 2 {
                        let avgRHR = baselineRHR.reduce(0) { $0 + $1.restingHeartRate } / Double(baselineRHR.count)
                        let diff = health.restingHeartRate - avgRHR
                        if diff >= 5 {
                            lines.append("  🫀 静息心率 \(Int(health.restingHeartRate)) BPM ⬆ 比近期高 \(Int(diff))，恢复可能不充分")
                        } else if diff <= -3 {
                            lines.append("  🫀 静息心率 \(Int(health.restingHeartRate)) BPM ⬇ 比近期低 \(Int(-diff))，恢复良好")
                        } else {
                            lines.append("  🫀 静息心率 \(Int(health.restingHeartRate)) BPM")
                        }
                    } else {
                        lines.append("  🫀 静息心率 \(Int(health.restingHeartRate)) BPM")
                    }

                    // HRV with personal baseline context — the best recovery signal
                    if health.hrv > 0 {
                        let baselineHRV = pastDays.filter { $0.hrv > 0 }
                        if baselineHRV.count >= 2 {
                            let avgHRV = baselineHRV.reduce(0) { $0 + $1.hrv } / Double(baselineHRV.count)
                            let ratio = health.hrv / avgHRV
                            let pctDiff = Int((ratio - 1) * 100)
                            if ratio >= 1.1 {
                                lines.append("  📳 HRV \(Int(health.hrv)) ms ↑ 高于基线 +\(pctDiff)%，状态很好")
                            } else if ratio < 0.8 {
                                lines.append("  📳 HRV \(Int(health.hrv)) ms ↓ 低于基线 \(pctDiff)%，身体在恢复中")
                            } else {
                                lines.append("  📳 HRV \(Int(health.hrv)) ms")
                            }
                        } else {
                            lines.append("  📳 HRV \(Int(health.hrv)) ms")
                        }
                    }
                } else if health.heartRate > 0 {
                    lines.append("  ❤️ 平均心率 \(Int(health.heartRate)) BPM")
                }

                // Quick health score
                var score = 0
                var total = 0
                if health.steps > 0 { total += 1; if health.steps >= 8000 { score += 1 } }
                if health.exerciseMinutes > 0 { total += 1; if health.exerciseMinutes >= 30 { score += 1 } }
                if health.sleepHours > 0 { total += 1; if health.sleepHours >= 7 && health.sleepHours <= 9 { score += 1 } }
                if total >= 2 {
                    if score == total {
                        lines.append("  🏅 全部达标，状态很棒！")
                    } else if score == 0 {
                        lines.append("  💡 今天几项指标还没达标，加油！")
                    }
                }
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

            // --- Photos Today ---
            if context.photoService.isAuthorized {
                let todayPhotos = context.photoService.fetchMetadata(from: interval.start, to: interval.end)
                if !todayPhotos.isEmpty {
                    hasData = true
                    let favCount = todayPhotos.filter { $0.isFavorite }.count
                    var photoLine = "\n📷 **照片**  今天拍了 \(todayPhotos.count) 张"
                    if favCount > 0 { photoLine += "（\(favCount) 张收藏）" }
                    lines.append(photoLine)

                    // Peak shooting time if enough photos
                    if todayPhotos.count >= 3 {
                        var hourCount = [Int: Int]()
                        todayPhotos.forEach {
                            let h = cal.component(.hour, from: $0.date)
                            hourCount[h, default: 0] += 1
                        }
                        if let (hour, count) = hourCount.max(by: { $0.value < $1.value }), count >= 2 {
                            let period = Self.photoTimeOfDay(hour: hour)
                            lines.append("  ⏰ 拍照高峰：\(period)（\(count) 张）")
                        }
                    }

                    // Photo content breakdown from Vision index
                    let contentLines = self.buildPhotoContentSummary(interval: interval, context: context)
                    lines.append(contentsOf: contentLines)
                }
            }

            // --- Cross-Data Intelligence ---
            // Correlate health + calendar + location to produce insights no single data source can
            if hasData {
                let crossInsights = Self.buildCrossDataInsights(
                    health: health,
                    calendarEvents: calendarEvents,
                    locations: locations,
                    recentHealth: recentSummaries,
                    now: now,
                    cal: cal
                )
                if !crossInsights.isEmpty {
                    lines.append("\n💡 **今日洞察**")
                    crossInsights.forEach { lines.append("  \($0)") }
                }
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
        } // end fetchSummaries
        } // end fetchDailySummary
    }

    // MARK: - Weekly Insight

    private func respondWeeklyInsight(context: SkillContext, completion: @escaping (String) -> Void) {
        let interval = QueryTimeRange.thisWeek.interval
        let events = CDLifeEvent.fetch(from: interval.start, to: interval.end, in: context.coreDataContext)
        let locations = CDLocationRecord.fetch(from: interval.start, to: interval.end, in: context.coreDataContext)

        // Fetch 14 days to enable week-over-week comparison
        context.healthService.fetchSummaries(days: 14) { allSummaries in
            let cal = Calendar.current
            let filtered = allSummaries.filter { interval.contains($0.date) }

            // Last week's data for comparison
            let lastWeekEnd = interval.start
            let lastWeekStart = cal.date(byAdding: .day, value: -7, to: lastWeekEnd) ?? lastWeekEnd
            let lastWeekHealth = allSummaries.filter { $0.date >= lastWeekStart && $0.date < lastWeekEnd }

            var lines: [String] = ["📊 本周生活洞察：\n"]
            var hasAnyData = false

            // --- Calendar Events (full week to include upcoming events) ---
            let calWeekInterval = Self.calendarInterval(for: .thisWeek)
            let calendarEvents = context.calendarService.fetchEvents(from: calWeekInterval.start, to: calWeekInterval.end)
            // Last week's calendar for comparison
            let lastWeekCalEvents = context.calendarService.fetchEvents(from: lastWeekStart, to: lastWeekEnd)

            if !calendarEvents.isEmpty {
                hasAnyData = true
                let timedEvents = calendarEvents.filter { !$0.isAllDay }
                let totalMinutes = timedEvents.reduce(0.0) { $0 + $1.duration } / 60.0

                lines.append("📅 **日程**")
                var calLine = "  共 \(calendarEvents.count) 个事件，约 \(Self.formatDuration(totalMinutes)) 有安排"
                // Week-over-week calendar comparison
                if !lastWeekCalEvents.isEmpty {
                    let lastCount = lastWeekCalEvents.count
                    let delta = calendarEvents.count - lastCount
                    if delta > 0 {
                        calLine += "（比上周多 \(delta) 个）"
                    } else if delta < 0 {
                        calLine += "（比上周少 \(-delta) 个）"
                    }
                }
                lines.append(calLine)

                // Find busiest day
                let dateFmt = DateFormatter()
                dateFmt.dateFormat = "EEEE"
                dateFmt.locale = Locale(identifier: "zh_CN")
                let grouped = Dictionary(grouping: timedEvents) { cal.startOfDay(for: $0.startDate) }
                if let busiestDay = grouped.max(by: { $0.value.count < $1.value.count }),
                   busiestDay.value.count > 1 {
                    lines.append("  最忙的一天：\(dateFmt.string(from: busiestDay.key))（\(busiestDay.value.count) 个会议）")
                }

                // Days with no events = free days
                let daysWithEvents = Set(grouped.keys.map { cal.startOfDay(for: $0) })
                let totalDays = max(1, cal.dateComponents([.day], from: interval.start, to: interval.end).day ?? 7)
                let freeDays = totalDays - daysWithEvents.count
                if freeDays > 0 {
                    lines.append("  💚 \(freeDays) 天完全空闲")
                }

                // Average meetings per busy day
                if !grouped.isEmpty {
                    let avgPerDay = Double(timedEvents.count) / Double(grouped.count)
                    if avgPerDay >= 4 {
                        lines.append("  ⚠️ 工作日日均 \(String(format: "%.1f", avgPerDay)) 个会议，节奏较紧")
                    }
                }
            }

            // --- Health Data (enriched weekly overview with week-over-week comparison) ---
            let withData = filtered.filter { $0.hasData }
            let lastWeekWithData = lastWeekHealth.filter { $0.hasData }
            let hasLastWeek = !lastWeekWithData.isEmpty

            if !withData.isEmpty {
                hasAnyData = true
                let dayCount = Double(max(withData.count, 1))
                let avgSteps = withData.reduce(0) { $0 + $1.steps } / dayCount
                let totalExercise = withData.reduce(0) { $0 + $1.exerciseMinutes }
                let avgExercise = totalExercise / dayCount
                let totalCalories = withData.reduce(0) { $0 + $1.activeCalories }
                let totalDistance = withData.reduce(0) { $0 + $1.distanceKm }
                let sleepDays = withData.filter { $0.sleepHours > 0 }
                let avgSleep = sleepDays.isEmpty ? 0 : sleepDays.reduce(0) { $0 + $1.sleepHours } / Double(sleepDays.count)
                let goalDays = withData.filter { $0.steps >= 8000 }.count
                let exerciseGoalDays = withData.filter { $0.exerciseMinutes >= 30 }.count
                let totalFlights = withData.reduce(0) { $0 + $1.flightsClimbed }

                // Last week baselines for comparison
                let lwDayCount = Double(max(lastWeekWithData.count, 1))
                let lwAvgSteps = hasLastWeek ? lastWeekWithData.reduce(0) { $0 + $1.steps } / lwDayCount : 0
                let lwAvgExercise = hasLastWeek ? lastWeekWithData.reduce(0) { $0 + $1.exerciseMinutes } / lwDayCount : 0
                let lwSleepDays = lastWeekWithData.filter { $0.sleepHours > 0 }
                let lwAvgSleep = lwSleepDays.isEmpty ? 0 : lwSleepDays.reduce(0) { $0 + $1.sleepHours } / Double(lwSleepDays.count)
                let lwTotalCalories = hasLastWeek ? lastWeekWithData.reduce(0) { $0 + $1.activeCalories } : 0
                let lwGoalDays = lastWeekWithData.filter { $0.steps >= 8000 }.count

                lines.append("\n🏃 **健康**")

                // Steps with week-over-week delta
                var stepsLine = "  👟 日均 \(Int(avgSteps).formatted()) 步，\(goalDays)/\(withData.count) 天达标（≥8000）"
                if hasLastWeek && lwAvgSteps > 0 {
                    let delta = Self.formatDelta(current: avgSteps, previous: lwAvgSteps)
                    stepsLine += " \(delta)"
                }
                lines.append(stepsLine)

                // Goal attainment comparison
                if hasLastWeek && lwGoalDays != goalDays {
                    let diff = goalDays - lwGoalDays
                    if diff > 0 {
                        lines.append("     达标天数比上周多 \(diff) 天 📈")
                    } else if diff < 0 {
                        lines.append("     达标天数比上周少 \(-diff) 天 📉")
                    }
                }

                if totalExercise > 0 {
                    var exLine = "  ⏱ 日均运动 \(Int(avgExercise)) 分钟，\(exerciseGoalDays) 天达标（≥30min）"
                    if hasLastWeek && lwAvgExercise > 0 {
                        exLine += " \(Self.formatDelta(current: avgExercise, previous: lwAvgExercise))"
                    }
                    lines.append(exLine)
                }

                // Weekly workout type breakdown — what did the user actually do this week?
                let allWorkouts = withData.flatMap { $0.workouts }
                if !allWorkouts.isEmpty {
                    // Group by type
                    var typeStats: [String: (emoji: String, count: Int, totalMin: Double, totalCal: Double)] = [:]
                    for w in allWorkouts {
                        let key = w.typeName
                        var stat = typeStats[key] ?? (emoji: w.typeEmoji, count: 0, totalMin: 0, totalCal: 0)
                        stat.count += 1
                        stat.totalMin += w.duration / 60.0
                        stat.totalCal += w.totalCalories
                        typeStats[key] = stat
                    }
                    let sortedTypes = typeStats.sorted { $0.value.totalMin > $1.value.totalMin }

                    if sortedTypes.count == 1 {
                        let t = sortedTypes[0]
                        lines.append("  \(t.value.emoji) 本周 \(t.value.count) 次\(t.key)，共 \(Int(t.value.totalMin)) 分钟")
                    } else {
                        let summary = sortedTypes.prefix(4).map { t in
                            "\(t.value.emoji)\(t.key)×\(t.value.count)"
                        }.joined(separator: "  ")
                        lines.append("  🗂️ 运动组合：\(summary)")

                        // Highlight dominant workout type
                        if let top = sortedTypes.first {
                            let topPct = Int(top.value.totalMin / allWorkouts.reduce(0) { $0 + $1.duration / 60.0 } * 100)
                            if topPct >= 50 && sortedTypes.count >= 2 {
                                lines.append("     \(top.key)占比 \(topPct)%，是本周主力运动")
                            }
                        }
                    }

                    // Week-over-week workout variety comparison
                    if hasLastWeek {
                        let lwWorkouts = lastWeekWithData.flatMap { $0.workouts }
                        if !lwWorkouts.isEmpty {
                            let thisTypes = Set(allWorkouts.map { $0.typeName })
                            let lastTypes = Set(lwWorkouts.map { $0.typeName })
                            let newTypes = thisTypes.subtracting(lastTypes)
                            if !newTypes.isEmpty {
                                lines.append("     🆕 新尝试：\(newTypes.joined(separator: "、"))")
                            }
                        }
                    }
                }

                if totalCalories > 0 {
                    var calLine = "  🔥 累计消耗 \(Int(totalCalories).formatted()) 千卡"
                    if lwTotalCalories > 0 {
                        calLine += " \(Self.formatDelta(current: totalCalories, previous: lwTotalCalories))"
                    }
                    lines.append(calLine)
                }
                if totalDistance > 0.5 {
                    lines.append("  📏 累计步行 \(String(format: "%.1f", totalDistance)) 公里")
                }
                if totalFlights > 0 {
                    lines.append("  🏢 累计爬楼 \(Int(totalFlights)) 层")
                }
                if avgSleep > 0 {
                    let goodSleepDays = sleepDays.filter { $0.sleepHours >= 7 && $0.sleepHours <= 9 }.count
                    var sleepLine = "  😴 均睡 \(String(format: "%.1f", avgSleep))h，\(goodSleepDays)/\(sleepDays.count) 晚在健康范围"
                    if lwAvgSleep > 0 {
                        let sleepDiff = avgSleep - lwAvgSleep
                        if abs(sleepDiff) >= 0.3 {
                            let arrow = sleepDiff > 0 ? "↑" : "↓"
                            sleepLine += "（\(arrow)\(String(format: "%.1f", abs(sleepDiff)))h vs 上周）"
                        }
                    }
                    lines.append(sleepLine)

                    // Sleep consistency — standard deviation of nightly sleep hours
                    if sleepDays.count >= 3 {
                        let sleepValues = sleepDays.map { $0.sleepHours }
                        let mean = sleepValues.reduce(0, +) / Double(sleepValues.count)
                        let variance = sleepValues.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(sleepValues.count)
                        let stdDev = sqrt(variance)
                        if stdDev < 0.5 {
                            lines.append("  🟢 作息规律：波动仅 ±\(String(format: "%.1f", stdDev))h，生物钟很稳定")
                        } else if stdDev < 1.0 {
                            lines.append("  🟡 作息尚可：波动 ±\(String(format: "%.1f", stdDev))h，可以更规律")
                        } else {
                            lines.append("  🟠 作息波动大：±\(String(format: "%.1f", stdDev))h —— 规律作息有助于提升睡眠质量")
                        }
                    }

                    // Sleep phase quality summary when Apple Watch data available
                    let phaseDays = sleepDays.filter { $0.hasSleepPhases }
                    if phaseDays.count >= 2 {
                        let avgDeep = phaseDays.reduce(0) { $0 + $1.sleepDeepHours } / Double(phaseDays.count)
                        let avgREM = phaseDays.reduce(0) { $0 + $1.sleepREMHours } / Double(phaseDays.count)
                        let avgCore = phaseDays.reduce(0) { $0 + $1.sleepCoreHours } / Double(phaseDays.count)
                        let deepPct = avgSleep > 0 ? Int(avgDeep / avgSleep * 100) : 0
                        let remPct = avgSleep > 0 ? Int(avgREM / avgSleep * 100) : 0

                        var phaseDesc = "  🧠 睡眠结构：深睡 \(String(format: "%.1f", avgDeep))h（\(deepPct)%）"
                        phaseDesc += "｜REM \(String(format: "%.1f", avgREM))h（\(remPct)%）"
                        phaseDesc += "｜浅睡 \(String(format: "%.1f", avgCore))h"
                        lines.append(phaseDesc)

                        // Interpret sleep quality based on phase distribution
                        if deepPct >= 15 && remPct >= 20 {
                            lines.append("     ✅ 深睡+REM 占比健康，恢复效率不错")
                        } else if deepPct < 10 {
                            lines.append("     💡 深睡占比偏低（理想≥15%），试试睡前避免屏幕和咖啡因")
                        } else if remPct < 15 {
                            lines.append("     💡 REM 偏少（理想≥20%），可能与压力或酒精有关")
                        }
                    }
                }

                // Recovery metrics: HRV + Resting HR trends
                let recoveryLines = Self.buildRecoveryMetrics(
                    withData: withData,
                    prevSummaries: lastWeekWithData
                )
                lines.append(contentsOf: recoveryLines)

                // Best and worst day for steps
                if withData.count >= 3, let best = withData.max(by: { $0.steps < $1.steps }),
                   let worst = withData.filter({ $0.steps > 0 }).min(by: { $0.steps < $1.steps }),
                   best.steps > worst.steps {
                    let fmt = DateFormatter()
                    fmt.dateFormat = "E"
                    fmt.locale = Locale(identifier: "zh_CN")
                    lines.append("  🏆 最活跃：\(fmt.string(from: best.date)) \(Int(best.steps).formatted())步")
                    lines.append("  📉 最低调：\(fmt.string(from: worst.date)) \(Int(worst.steps).formatted())步")
                }

                // Overall weekly health verdict with trend context + recovery awareness
                let hrvDaysW = withData.filter { $0.hrv > 0 }
                let avgHRVW = hrvDaysW.isEmpty ? 0.0 : hrvDaysW.reduce(0) { $0 + $1.hrv } / Double(hrvDaysW.count)
                let rhrDaysW = withData.filter { $0.restingHeartRate > 0 }
                let avgRHRW = rhrDaysW.isEmpty ? 0.0 : rhrDaysW.reduce(0) { $0 + $1.restingHeartRate } / Double(rhrDaysW.count)
                let recoveryGoodW = (avgHRVW > 0 && avgHRVW >= 40) || (avgRHRW > 0 && avgRHRW <= 65)
                let recoveryPoorW = (avgHRVW > 0 && avgHRVW < 25) || (avgRHRW > 0 && avgRHRW >= 80)

                var score = 0
                if avgSteps >= 8000 { score += 1 }
                if avgExercise >= 30 { score += 1 }
                if avgSleep >= 7 && avgSleep <= 9 { score += 1 }

                // Detect improvement trend vs last week
                var lwScore = 0
                if hasLastWeek {
                    if lwAvgSteps >= 8000 { lwScore += 1 }
                    if lwAvgExercise >= 30 { lwScore += 1 }
                    if lwAvgSleep >= 7 && lwAvgSleep <= 9 { lwScore += 1 }
                }

                if score == 3 && recoveryGoodW {
                    lines.append("  ✅ 活动、睡眠、恢复全线达标，本周状态极佳！🎉")
                } else if score == 3 {
                    if hasLastWeek && lwScore < 3 {
                        lines.append("  ✅ 本周步数、运动、睡眠全面达标！比上周更好 🎉")
                    } else {
                        lines.append("  ✅ 本周步数、运动、睡眠全面达标！")
                    }
                } else if score >= 2 && recoveryPoorW {
                    lines.append("  ⚠️ 活动量不错但恢复指标偏低，下周适当减量、优先睡眠")
                } else if score >= 2 {
                    if hasLastWeek && score > lwScore {
                        lines.append("  💪 本周状态比上周有进步，继续加油！")
                    } else if hasLastWeek && score < lwScore {
                        lines.append("  💡 本周表现比上周略有下滑，下周试试找回节奏")
                    } else {
                        lines.append("  💪 本周状态不错，还有一项可以提升")
                    }
                } else if recoveryPoorW {
                    lines.append("  ⚠️ 恢复指标偏低，下周建议优先保证睡眠质量和休息")
                } else if score == 1 {
                    lines.append("  💡 有提升空间，下周试试从最容易的一项开始")
                }
            }

            if !events.isEmpty {
                hasAnyData = true
                var moodCount: [MoodType: Int] = [:]
                events.forEach { moodCount[$0.mood, default: 0] += 1 }
                if let dominant = moodCount.max(by: { $0.value < $1.value })?.key {
                    lines.append("\n\(dominant.emoji) 主要心情：\(dominant.label)（共 \(moodCount[dominant] ?? 0) 次）")
                }
            }

            if !locations.isEmpty {
                hasAnyData = true
                var placeCount: [String: Int] = [:]
                locations.forEach { placeCount[$0.displayName, default: 0] += 1 }
                if let topPlace = placeCount.max(by: { $0.value < $1.value }) {
                    lines.append("\n📍 最常去：\(topPlace.key)（\(topPlace.value) 次）")
                }
                // Compare location diversity with last week
                let lastWeekLocations = CDLocationRecord.fetch(from: lastWeekStart, to: lastWeekEnd, in: context.coreDataContext)
                if !lastWeekLocations.isEmpty {
                    let thisPlaces = Set(locations.map { $0.displayName }).count
                    let lastPlaces = Set(lastWeekLocations.map { $0.displayName }).count
                    if thisPlaces > lastPlaces {
                        lines.append("  📈 探索了 \(thisPlaces) 个地方，比上周多 \(thisPlaces - lastPlaces) 个")
                    } else if thisPlaces < lastPlaces {
                        lines.append("  📉 本周去了 \(thisPlaces) 个地方，比上周少 \(lastPlaces - thisPlaces) 个")
                    }
                }
            }

            if !events.isEmpty {
                hasAnyData = true
                let lastWeekEvents = CDLifeEvent.fetch(from: lastWeekStart, to: lastWeekEnd, in: context.coreDataContext)
                var eventLine = "📝 共记录 \(events.count) 条生活事件"
                if !lastWeekEvents.isEmpty {
                    let delta = events.count - lastWeekEvents.count
                    if delta > 0 {
                        eventLine += "（比上周多 \(delta) 条）"
                    } else if delta < 0 {
                        eventLine += "（比上周少 \(-delta) 条）"
                    }
                }
                lines.append("\n\(eventLine)")
            }

            // --- Photo Activity This Week ---
            if context.photoService.isAuthorized {
                let thisWeekPhotos = context.photoService.fetchMetadata(from: interval.start, to: interval.end)
                if !thisWeekPhotos.isEmpty {
                    hasAnyData = true
                    let activeDays = Set(thisWeekPhotos.map { cal.startOfDay(for: $0.date) }).count
                    let favCount = thisWeekPhotos.filter { $0.isFavorite }.count

                    var photoLine = "\n📷 本周拍了 \(thisWeekPhotos.count) 张照片，\(activeDays) 天有拍照"
                    // Compare with last week
                    let lastWeekPhotos = context.photoService.fetchMetadata(from: lastWeekStart, to: lastWeekEnd)
                    if !lastWeekPhotos.isEmpty {
                        let delta = thisWeekPhotos.count - lastWeekPhotos.count
                        if delta > 0 {
                            photoLine += "（比上周多 \(delta) 张）"
                        } else if delta < 0 {
                            photoLine += "（比上周少 \(-delta) 张）"
                        }
                    }
                    lines.append(photoLine)

                    if favCount > 0 {
                        lines.append("  ❤️ \(favCount) 张标记收藏")
                    }

                    // Most active day for photos
                    if activeDays >= 2 {
                        var dayPhotoCount: [Date: Int] = [:]
                        thisWeekPhotos.forEach { dayPhotoCount[cal.startOfDay(for: $0.date), default: 0] += 1 }
                        if let (bestDay, count) = dayPhotoCount.max(by: { $0.value < $1.value }) {
                            let dayFmt = DateFormatter()
                            dayFmt.dateFormat = "EEEE"
                            dayFmt.locale = Locale(identifier: "zh_CN")
                            lines.append("  🏆 拍照最多：\(dayFmt.string(from: bestDay))（\(count) 张）")
                        }
                    }

                    // Photo content breakdown from Vision index
                    let contentLines = self.buildPhotoContentSummary(interval: interval, context: context)
                    lines.append(contentsOf: contentLines)
                }
            }

            // --- Weekly Cross-Data Pattern Discovery ---
            if hasAnyData {
                let weeklyInsights = Self.buildWeeklyCrossInsights(
                    healthSummaries: filtered,
                    calendarEvents: calendarEvents,
                    locations: locations,
                    cal: cal
                )
                if !weeklyInsights.isEmpty {
                    lines.append("\n💡 **本周发现**")
                    weeklyInsights.forEach { lines.append("  \($0)") }
                }
            }

            // --- Actionable Next-Week Suggestions ---
            if hasAnyData {
                let suggestions = Self.buildNextWeekSuggestions(
                    healthSummaries: withData,
                    calendarEvents: calendarEvents,
                    locations: locations,
                    nextWeekCalendar: context.calendarService,
                    cal: cal
                )
                if !suggestions.isEmpty {
                    lines.append("\n🎯 **下周建议**")
                    suggestions.forEach { lines.append("  \($0)") }
                }
            }

            if !hasAnyData {
                lines.append("本周数据较少，建议开启健康、日历、位置权限并多与我分享，让周报更丰富！")
            }

            completion(lines.joined(separator: "\n"))
        }
    }

    // MARK: - Calendar Interval

    /// Returns a full-period interval for calendar queries.
    /// `.today` extends to end of day so upcoming events are included;
    /// `.thisWeek` extends to end of week; `.thisMonth` to end of month.
    /// Health/location data use `range.interval` (ending at now) which is correct
    /// for retrospective data, but calendar must include future events in the period.
    private static func calendarInterval(for range: QueryTimeRange) -> DateInterval {
        let cal = Calendar.current
        let now = Date()
        let todayStart = cal.startOfDay(for: now)
        switch range {
        case .today:
            let endOfDay = cal.date(byAdding: .day, value: 1, to: todayStart)!
            return DateInterval(start: todayStart, end: endOfDay)
        case .thisWeek:
            let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
            let weekStart = cal.date(from: comps)!
            let weekEnd = cal.date(byAdding: .day, value: 7, to: weekStart)!
            return DateInterval(start: weekStart, end: weekEnd)
        case .thisMonth:
            let monthComps = cal.dateComponents([.year, .month], from: now)
            let monthStart = cal.date(from: monthComps)!
            let nextMonth = cal.date(byAdding: .month, value: 1, to: monthStart)!
            return DateInterval(start: monthStart, end: nextMonth)
        default:
            return range.interval
        }
    }

    // MARK: - Helpers

    private static func formatDuration(_ minutes: Double) -> String {
        let h = Int(minutes) / 60
        let m = Int(minutes) % 60
        if h > 0 && m > 0 { return "\(h) 小时 \(m) 分钟" }
        if h > 0 { return "\(h) 小时" }
        return "\(m) 分钟"
    }

    // MARK: - Recovery Metrics (HRV + Resting HR)

    /// Builds HRV and resting heart rate trend lines for the period summary.
    /// These are the most important recovery/stress indicators from Apple Watch.
    private static func buildRecoveryMetrics(
        withData: [HealthSummary],
        prevSummaries: [HealthSummary]
    ) -> [String] {
        var lines: [String] = []
        let hrvDays = withData.filter { $0.hrv > 0 }
        let rhrDays = withData.filter { $0.restingHeartRate > 0 }

        // Need at least one recovery metric to show this section
        guard !hrvDays.isEmpty || !rhrDays.isEmpty else { return [] }

        // HRV average + trend vs previous period
        if !hrvDays.isEmpty {
            let avgHRV = hrvDays.reduce(0) { $0 + $1.hrv } / Double(hrvDays.count)
            var hrvLine = "  📳 HRV 均值 \(Int(avgHRV)) ms"

            // Trend within the period: first half vs second half
            if hrvDays.count >= 4 {
                let mid = hrvDays.count / 2
                let firstHalf = hrvDays.prefix(mid).reduce(0) { $0 + $1.hrv } / Double(mid)
                let secondHalf = hrvDays.suffix(from: mid).reduce(0) { $0 + $1.hrv } / Double(hrvDays.count - mid)
                let trendPct = ((secondHalf - firstHalf) / firstHalf) * 100
                if trendPct > 10 {
                    hrvLine += " 📈"
                } else if trendPct < -10 {
                    hrvLine += " 📉"
                }
            }

            // Compare vs previous period
            let prevHRVDays = prevSummaries.filter { $0.hrv > 0 }
            if !prevHRVDays.isEmpty {
                let prevAvgHRV = prevHRVDays.reduce(0) { $0 + $1.hrv } / Double(prevHRVDays.count)
                let delta = ((avgHRV - prevAvgHRV) / prevAvgHRV) * 100
                if abs(delta) >= 10 {
                    let arrow = delta > 0 ? "↑" : "↓"
                    hrvLine += "（\(arrow)\(Int(abs(delta)))% vs 上期）"
                }
            }

            // Interpret the HRV level
            if avgHRV >= 50 {
                hrvLine += " — 恢复状态很好"
            } else if avgHRV >= 30 {
                hrvLine += " — 恢复正常"
            } else {
                hrvLine += " — 压力偏高，注意休息"
            }
            lines.append(hrvLine)
        }

        // Resting HR average + trend (lower is better for cardiovascular fitness)
        if !rhrDays.isEmpty {
            let avgRHR = rhrDays.reduce(0) { $0 + $1.restingHeartRate } / Double(rhrDays.count)
            var rhrLine = "  ❤️ 静息心率 \(Int(avgRHR)) BPM"

            // Compare vs previous period
            let prevRHRDays = prevSummaries.filter { $0.restingHeartRate > 0 }
            if !prevRHRDays.isEmpty {
                let prevAvgRHR = prevRHRDays.reduce(0) { $0 + $1.restingHeartRate } / Double(prevRHRDays.count)
                let delta = avgRHR - prevAvgRHR
                if abs(delta) >= 2 {
                    // For resting HR, lower is better, so down arrow is positive
                    let arrow = delta < 0 ? "↓" : "↑"
                    let sentiment = delta < 0 ? "👍" : ""
                    rhrLine += "（\(arrow)\(Int(abs(delta))) vs 上期）\(sentiment)"
                }
            }
            lines.append(rhrLine)
        }

        return lines
    }

    // MARK: - Sleep Quality Breakdown

    /// Breaks down sleep quality beyond total hours: deep sleep %, REM %, efficiency.
    /// These phases matter more than raw duration for actual rest quality.
    private static func buildSleepQualityBreakdown(
        sleepDays: [HealthSummary],
        prevSleepDays: [HealthSummary]
    ) -> [String] {
        var lines: [String] = []
        let daysWithPhases = sleepDays.filter { $0.sleepDeepHours > 0 || $0.sleepREMHours > 0 }
        guard !daysWithPhases.isEmpty else { return [] }

        let count = Double(daysWithPhases.count)
        let avgDeep = daysWithPhases.reduce(0) { $0 + $1.sleepDeepHours } / count
        let avgREM = daysWithPhases.reduce(0) { $0 + $1.sleepREMHours } / count
        let avgTotal = daysWithPhases.reduce(0) { $0 + $1.sleepHours } / count

        guard avgTotal > 0 else { return [] }

        let deepPct = (avgDeep / avgTotal) * 100
        let remPct = (avgREM / avgTotal) * 100

        // Build compact phase breakdown
        var phaseLine = "    🌙 睡眠结构：深睡 \(String(format: "%.0f", deepPct))%"
        phaseLine += " · REM \(String(format: "%.0f", remPct))%"

        // Assess quality: ideal deep sleep 15-25%, ideal REM 20-25%
        let deepGood = deepPct >= 15
        let remGood = remPct >= 18
        if deepGood && remGood {
            phaseLine += " ✅"
        } else if !deepGood && !remGood {
            phaseLine += " — 深睡和REM均偏低"
        } else if !deepGood {
            phaseLine += " — 深睡偏少"
        } else {
            phaseLine += " — REM偏少"
        }
        lines.append(phaseLine)

        // Sleep efficiency: actual sleep / time in bed
        let daysWithInBed = daysWithPhases.filter { $0.inBedHours > 0 }
        if !daysWithInBed.isEmpty {
            let avgInBed = daysWithInBed.reduce(0) { $0 + $1.inBedHours } / Double(daysWithInBed.count)
            let avgActualSleep = daysWithInBed.reduce(0) { $0 + $1.sleepHours } / Double(daysWithInBed.count)
            if avgInBed > 0 {
                let efficiency = (avgActualSleep / avgInBed) * 100
                var effLine = "    💤 睡眠效率 \(String(format: "%.0f", efficiency))%"
                if efficiency >= 90 {
                    effLine += " — 入睡快、中途醒来少"
                } else if efficiency >= 80 {
                    effLine += " — 正常范围"
                } else {
                    effLine += " — 偏低，可能辗转较多"
                }
                lines.append(effLine)
            }
        }

        // Compare sleep quality vs previous period
        let prevWithPhases = prevSleepDays.filter { $0.sleepDeepHours > 0 || $0.sleepREMHours > 0 }
        if !prevWithPhases.isEmpty {
            let prevCount = Double(prevWithPhases.count)
            let prevAvgDeep = prevWithPhases.reduce(0) { $0 + $1.sleepDeepHours } / prevCount
            let prevAvgTotal = prevWithPhases.reduce(0) { $0 + $1.sleepHours } / prevCount
            if prevAvgTotal > 0 {
                let prevDeepPct = (prevAvgDeep / prevAvgTotal) * 100
                let deepDelta = deepPct - prevDeepPct
                if abs(deepDelta) >= 3 {
                    let arrow = deepDelta > 0 ? "↑" : "↓"
                    let sentiment = deepDelta > 0 ? "睡眠质量提升" : "深睡比例下降"
                    lines.append("    \(arrow) 深睡占比 vs 上期 \(String(format: "%+.0f", deepDelta))%，\(sentiment)")
                }
            }
        }

        return lines
    }

    /// Formats a week-over-week percentage delta as a concise arrow string.
    /// Returns "" if the change is too small to be meaningful (<10%).
    private static func formatDelta(current: Double, previous: Double) -> String {
        guard previous > 0 else { return "" }
        let pct = ((current - previous) / previous) * 100
        guard abs(pct) >= 10 else { return "" }
        let arrow = pct > 0 ? "↑" : "↓"
        return "（vs 上周 \(arrow)\(Int(abs(pct)))%）"
    }

    /// Maps an hour (0-23) to a Chinese time-of-day label for photo insights.
    private static func photoTimeOfDay(hour: Int) -> String {
        switch hour {
        case 5..<9: return "清晨"
        case 9..<12: return "上午"
        case 12..<14: return "午间"
        case 14..<17: return "下午"
        case 17..<19: return "傍晚"
        case 19..<22: return "晚上"
        default: return "深夜"
        }
    }

    // MARK: - Cross-Data Intelligence

    /// Correlates health, calendar, and location data to produce insights
    /// that no single data source can provide on its own.
    /// This is the core value of iosclaw: connecting the dots across your life data.
    private static func buildCrossDataInsights(
        health: HealthSummary,
        calendarEvents: [CalendarEventItem],
        locations: [LocationRecord],
        recentHealth: [HealthSummary],
        now: Date,
        cal: Calendar
    ) -> [String] {
        var insights: [String] = []

        let timedEvents = calendarEvents.filter { !$0.isAllDay }
        let meetingCount = timedEvents.count
        let totalMeetingMin = timedEvents.reduce(0.0) { $0 + $1.duration } / 60.0
        let isBusyDay = meetingCount >= 4 || totalMeetingMin >= 240
        let isLightDay = meetingCount <= 1

        // Compute 7-day baselines (exclude today)
        let pastDays = recentHealth.filter { !cal.isDateInToday($0.date) && $0.hasData }
        let avgSteps = pastDays.isEmpty ? 0.0 : pastDays.reduce(0) { $0 + $1.steps } / Double(pastDays.count)
        let avgExercise = pastDays.isEmpty ? 0.0 : pastDays.reduce(0) { $0 + $1.exerciseMinutes } / Double(pastDays.count)

        // --- Insight 1: Calendar busy-ness vs activity level ---
        if isBusyDay && health.steps > 0 && avgSteps > 0 {
            let stepRatio = health.steps / avgSteps
            if stepRatio < 0.6 {
                // Busy day and significantly fewer steps than average
                let remaining = timedEvents.filter { $0.endDate > now }
                if remaining.isEmpty {
                    insights.append("📅↔️🏃 今天 \(meetingCount) 个会议，步数低于平时 —— 日程已结束，趁现在出去走走吧")
                } else {
                    insights.append("📅↔️🏃 会议密集的一天，步数比平时少 \(Int((1 - stepRatio) * 100))% —— 会议间隙起来走动几分钟")
                }
            } else if stepRatio >= 1.0 {
                insights.append("📅↔️🏃 今天会议很多但活动量依然充足，时间管理很棒 👏")
            }
        }

        // --- Insight 2: Free day + activity opportunity ---
        if isLightDay && health.exerciseMinutes < 15 {
            let hour = cal.component(.hour, from: now)
            if hour < 20 {
                insights.append("📅↔️⏱ 今天日程清闲，适合安排一次运动 —— 还有时间")
            }
        } else if isLightDay && health.exerciseMinutes >= 30 {
            insights.append("📅↔️⏱ 空闲日 + 充足运动 = 完美的一天 ✨")
        }

        // --- Insight 3: Sleep quality vs today's schedule ---
        if health.sleepHours > 0 && meetingCount > 0 {
            if health.sleepHours < 6 && isBusyDay {
                insights.append("😴↔️📅 昨晚睡不到 6 小时，今天又有 \(meetingCount) 个会议 —— 注意补充能量，下午可以小憩")
            } else if health.sleepHours >= 7.5 && isBusyDay {
                insights.append("😴↔️📅 昨晚睡得不错，应对今天的密集日程状态应该不差")
            }
        }

        // --- Insight 4: Movement pattern from locations + health ---
        if !locations.isEmpty && health.steps > 0 {
            let uniquePlaces = Set(locations.map { $0.displayName }).count
            if uniquePlaces >= 3 && health.steps >= 8000 {
                insights.append("📍↔️👟 去了 \(uniquePlaces) 个地方，步数也充足 —— 充实的一天")
            } else if uniquePlaces == 1 && health.steps < 3000 && health.steps > 0 {
                insights.append("📍↔️👟 一直待在同一个地方，活动量偏低 —— 换个环境走走？")
            }
        }

        // --- Insight 5: Today vs recent trend anomaly ---
        if health.steps > 0 && avgSteps > 0 {
            let deviation = (health.steps - avgSteps) / avgSteps
            if deviation >= 0.5 {
                insights.append("📈 今天步数比近 7 天均值高 \(Int(deviation * 100))%，状态很活跃！")
            } else if deviation <= -0.5 && !isBusyDay {
                // Only flag low activity if it's NOT because of a busy calendar
                insights.append("📉 今天步数比近 7 天均值低 \(Int(-deviation * 100))%，还好吗？")
            }
        }

        // --- Insight 6: HRV anomaly detection (stress/recovery signal) ---
        if health.hrv > 0 {
            let baselineHRVDays = pastDays.filter { $0.hrv > 0 }
            if baselineHRVDays.count >= 3 {
                let avgHRV = baselineHRVDays.reduce(0) { $0 + $1.hrv } / Double(baselineHRVDays.count)
                let ratio = health.hrv / avgHRV
                if ratio < 0.75 {
                    let pctDrop = Int((1 - ratio) * 100)
                    if isBusyDay {
                        insights.append("📳↔️📅 HRV 比基线低 \(pctDrop)%，密集日程下注意能量管理 —— 长任务拆成小块，中间留白")
                    } else {
                        insights.append("📳 HRV 比基线低 \(pctDrop)%，身体在应对某种压力 —— 今天适合放松恢复")
                    }
                } else if ratio >= 1.15 && health.exerciseMinutes < 15 {
                    insights.append("📳↔️🏃 HRV 高于基线 \(Int((ratio - 1) * 100))%，恢复很好 —— 今天身体状态适合挑战高强度运动")
                }
            }
        }

        // --- Insight 7: Exercise + sleep correlation from recent data ---
        if pastDays.count >= 5 {
            let exerciseDays = pastDays.filter { $0.exerciseMinutes >= 30 && $0.sleepHours > 0 }
            let restDays = pastDays.filter { $0.exerciseMinutes < 15 && $0.sleepHours > 0 }
            if exerciseDays.count >= 2 && restDays.count >= 2 {
                let sleepOnExercise = exerciseDays.reduce(0) { $0 + $1.sleepHours } / Double(exerciseDays.count)
                let sleepOnRest = restDays.reduce(0) { $0 + $1.sleepHours } / Double(restDays.count)
                let diff = sleepOnExercise - sleepOnRest
                if diff >= 0.5 {
                    insights.append("🏃↔️😴 最近运动日比休息日多睡 \(String(format: "%.1f", diff))h —— 运动在帮助你的睡眠")
                } else if diff <= -0.5 {
                    insights.append("🏃↔️😴 运动日反而少睡 \(String(format: "%.1f", -diff))h —— 试试把运动安排在更早的时间")
                }
            }
        }

        // Limit to top 3 most relevant insights to avoid information overload
        return Array(insights.prefix(3))
    }

    /// Discovers cross-data patterns across a full week of health, calendar, and location data.
    private static func buildWeeklyCrossInsights(
        healthSummaries: [HealthSummary],
        calendarEvents: [CalendarEventItem],
        locations: [LocationRecord],
        cal: Calendar
    ) -> [String] {
        var insights: [String] = []
        let withData = healthSummaries.filter { $0.hasData }
        guard !withData.isEmpty else { return [] }

        // --- Insight 1: Meeting-heavy days vs activity ---
        if !calendarEvents.isEmpty && withData.count >= 3 {
            let timedEvents = calendarEvents.filter { !$0.isAllDay }
            // Group meetings by day
            var meetingsPerDay: [Date: Int] = [:]
            for e in timedEvents {
                let day = cal.startOfDay(for: e.startDate)
                meetingsPerDay[day, default: 0] += 1
            }

            // Pair with health data
            var busyDaySteps: [Double] = []
            var freeDaySteps: [Double] = []
            for h in withData where h.steps > 0 {
                let day = cal.startOfDay(for: h.date)
                let meetings = meetingsPerDay[day] ?? 0
                if meetings >= 3 {
                    busyDaySteps.append(h.steps)
                } else if meetings <= 1 {
                    freeDaySteps.append(h.steps)
                }
            }

            if busyDaySteps.count >= 1 && freeDaySteps.count >= 1 {
                let busyAvg = busyDaySteps.reduce(0, +) / Double(busyDaySteps.count)
                let freeAvg = freeDaySteps.reduce(0, +) / Double(freeDaySteps.count)
                if freeAvg > 0 {
                    let diff = (busyAvg - freeAvg) / freeAvg * 100
                    if diff <= -25 {
                        insights.append("📅↔️🏃 会议多的日子步数少 \(Int(-diff))% —— 忙碌日记得会议间走动")
                    } else if diff >= 25 {
                        insights.append("📅↔️🏃 会议多的日子反而更活跃，可能是通勤和换场的功劳")
                    }
                }
            }
        }

        // --- Insight 2: Location variety correlates with activity ---
        if !locations.isEmpty && withData.count >= 3 {
            // Count unique places per day
            var placesPerDay: [Date: Set<String>] = [:]
            for loc in locations {
                let day = cal.startOfDay(for: loc.timestamp)
                placesPerDay[day, default: []].insert(loc.displayName)
            }

            var manyPlacesSteps: [Double] = []
            var fewPlacesSteps: [Double] = []
            for h in withData where h.steps > 0 {
                let day = cal.startOfDay(for: h.date)
                let places = placesPerDay[day]?.count ?? 0
                if places >= 3 {
                    manyPlacesSteps.append(h.steps)
                } else if places <= 1 && places >= 0 {
                    fewPlacesSteps.append(h.steps)
                }
            }

            if manyPlacesSteps.count >= 1 && fewPlacesSteps.count >= 1 {
                let manyAvg = manyPlacesSteps.reduce(0, +) / Double(manyPlacesSteps.count)
                let fewAvg = fewPlacesSteps.reduce(0, +) / Double(fewPlacesSteps.count)
                if fewAvg > 0 && manyAvg > fewAvg * 1.3 {
                    insights.append("📍↔️👟 去过多个地方的日子比宅家日多走 \(Int((manyAvg - fewAvg) / fewAvg * 100))% —— 出门就是运动")
                }
            }
        }

        // --- Insight 3: Best day pattern (which weekday is healthiest?) ---
        if withData.count >= 5 {
            var weekdayScores: [Int: (steps: Double, count: Int)] = [:]
            for h in withData where h.steps > 0 {
                let wd = cal.component(.weekday, from: h.date)
                let current = weekdayScores[wd] ?? (0, 0)
                weekdayScores[wd] = (current.steps + h.steps, current.count + 1)
            }

            if let best = weekdayScores.max(by: {
                ($0.value.count > 0 ? $0.value.steps / Double($0.value.count) : 0) <
                ($1.value.count > 0 ? $1.value.steps / Double($1.value.count) : 0)
            }), best.value.count > 0 {
                let avgSteps = best.value.steps / Double(best.value.count)
                let overallAvg = withData.reduce(0) { $0 + $1.steps } / Double(withData.count)
                if avgSteps > overallAvg * 1.2 {
                    let dayName = Self.weekdayName(best.key)
                    insights.append("🗓↔️🏃 \(dayName)是你本周最活跃的日子（均 \(Int(avgSteps).formatted()) 步）")
                }
            }
        }

        // --- Insight 4: Calendar density vs sleep quality ---
        let sleepDays = withData.filter { $0.sleepHours > 0 }
        if !calendarEvents.isEmpty && sleepDays.count >= 3 {
            let timedEvts = calendarEvents.filter { !$0.isAllDay }
            var meetingsPerDay: [Date: Int] = [:]
            for e in timedEvts {
                meetingsPerDay[cal.startOfDay(for: e.startDate), default: 0] += 1
            }

            var busyDaySleep: [Double] = []
            var lightDaySleep: [Double] = []
            for h in sleepDays {
                let day = cal.startOfDay(for: h.date)
                let meetings = meetingsPerDay[day] ?? 0
                if meetings >= 3 { busyDaySleep.append(h.sleepHours) }
                else if meetings <= 1 { lightDaySleep.append(h.sleepHours) }
            }

            if busyDaySleep.count >= 1 && lightDaySleep.count >= 1 {
                let busyAvg = busyDaySleep.reduce(0, +) / Double(busyDaySleep.count)
                let lightAvg = lightDaySleep.reduce(0, +) / Double(lightDaySleep.count)
                let diff = lightAvg - busyAvg
                if diff >= 0.5 {
                    insights.append("📅↔️😴 会议多的晚上平均少睡 \(String(format: "%.1f", diff))h —— 忙碌日留意放松入睡")
                } else if diff <= -0.5 {
                    insights.append("📅↔️😴 忙碌日反而睡得更好，可能是白天消耗帮助入睡")
                }
            }
        }

        // --- Insight 5: Exercise vs same-night sleep quality ---
        if sleepDays.count >= 4 {
            let exerciseDays = sleepDays.filter { $0.exerciseMinutes >= 30 }
            let restDays = sleepDays.filter { $0.exerciseMinutes < 15 }
            if exerciseDays.count >= 2 && restDays.count >= 1 {
                let sleepOnEx = exerciseDays.reduce(0) { $0 + $1.sleepHours } / Double(exerciseDays.count)
                let sleepOnRest = restDays.reduce(0) { $0 + $1.sleepHours } / Double(restDays.count)
                let diff = sleepOnEx - sleepOnRest
                if diff >= 0.5 {
                    insights.append("🏃↔️😴 运动日比休息日多睡 \(String(format: "%.1f", diff))h —— 运动助眠效果明显")
                } else if diff <= -0.5 {
                    insights.append("🏃↔️😴 运动日反而少睡 \(String(format: "%.1f", -diff))h —— 试试把运动提前到更早")
                }
            }
        }

        return Array(insights.prefix(3))
    }

    // MARK: - Next Week Suggestions

    /// Analyzes this week's weakest areas and generates 2-3 specific, data-driven
    /// action items for the upcoming week. Looks at next week's calendar to give
    /// context-aware advice (e.g., "busy Monday — plan a walk between meetings").
    private static func buildNextWeekSuggestions(
        healthSummaries: [HealthSummary],
        calendarEvents: [CalendarEventItem],
        locations: [LocationRecord],
        nextWeekCalendar: CalendarService,
        cal: Calendar
    ) -> [String] {
        var suggestions: [String] = []
        guard !healthSummaries.isEmpty else { return [] }

        let dayCount = Double(max(healthSummaries.count, 1))

        // Compute this week's key metrics
        let avgSteps = healthSummaries.reduce(0) { $0 + $1.steps } / dayCount
        let avgExercise = healthSummaries.reduce(0) { $0 + $1.exerciseMinutes } / dayCount
        let sleepDays = healthSummaries.filter { $0.sleepHours > 0 }
        let avgSleep = sleepDays.isEmpty ? 0.0 : sleepDays.reduce(0) { $0 + $1.sleepHours } / Double(sleepDays.count)
        let stepGoalDays = healthSummaries.filter { $0.steps >= 8000 }.count
        let exerciseGoalDays = healthSummaries.filter { $0.exerciseMinutes >= 30 }.count

        // Sleep consistency
        var sleepStdDev: Double = 0
        if sleepDays.count >= 3 {
            let mean = sleepDays.reduce(0) { $0 + $1.sleepHours } / Double(sleepDays.count)
            let variance = sleepDays.reduce(0) { $0 + ($1.sleepHours - mean) * ($1.sleepHours - mean) } / Double(sleepDays.count)
            sleepStdDev = sqrt(variance)
        }

        // Find weakest days (lowest step days) — what weekday patterns are weak?
        let sorted = healthSummaries.sorted { $0.steps < $1.steps }
        let weakDayNames: [String] = sorted.prefix(2).compactMap { day in
            guard day.steps > 0, day.steps < avgSteps * 0.6 else { return nil }
            let fmt = DateFormatter()
            fmt.dateFormat = "EEEE"
            fmt.locale = Locale(identifier: "zh_CN")
            return fmt.string(from: day.date)
        }

        // Peek at next week's calendar for context-aware suggestions
        let nextWeekStart = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))!
        let nextWeekEnd = cal.date(byAdding: .day, value: 7, to: nextWeekStart)!
        let nextEvents = nextWeekCalendar.fetchEvents(from: nextWeekStart, to: nextWeekEnd)
        let nextTimedEvents = nextEvents.filter { !$0.isAllDay }
        let nextWeekBusy = !nextTimedEvents.isEmpty

        // Group next week's events by day to find busiest day
        var nextMeetingsPerDay: [Date: Int] = [:]
        for e in nextTimedEvents {
            nextMeetingsPerDay[cal.startOfDay(for: e.startDate), default: 0] += 1
        }
        let busiestNextDay = nextMeetingsPerDay.max(by: { $0.value < $1.value })

        // --- Priority 1: Steps improvement (if below goal) ---
        if avgSteps < 8000 {
            let deficit = Int(8000 - avgSteps)
            if deficit > 3000 {
                suggestions.append("👟 日均步数差 \(deficit) 步达标，试试每天饭后散步 20 分钟（约 2000 步）")
            } else if !weakDayNames.isEmpty {
                suggestions.append("👟 \(weakDayNames.joined(separator: "和"))步数偏低，下周这几天安排一次午间散步")
            } else {
                suggestions.append("👟 再多走 \(deficit) 步就能日均达标，试试提前一站下车走路")
            }
        } else if stepGoalDays < healthSummaries.count && stepGoalDays > 0 {
            let missedDays = healthSummaries.count - stepGoalDays
            suggestions.append("👟 本周有 \(missedDays) 天步数未达标，试试把散步加入固定日程")
        }

        // --- Priority 2: Exercise consistency ---
        if avgExercise < 15 {
            suggestions.append("🏃 本周运动时间偏少，下周试试每天 15 分钟快走或拉伸起步")
        } else if avgExercise < 30 && exerciseGoalDays < 3 {
            let gap = 30 - Int(avgExercise)
            suggestions.append("🏃 每天再多运动 \(gap) 分钟就能达标，可以拆分成 2 段短时运动")
        } else if exerciseGoalDays >= 3 {
            // Exercise is OK — suggest variety if doing same type
            let allWorkouts = healthSummaries.flatMap { $0.workouts }
            let uniqueTypes = Set(allWorkouts.map { $0.typeName })
            if uniqueTypes.count == 1, let onlyType = uniqueTypes.first {
                suggestions.append("🏃 本周都是\(onlyType)，下周试试搭配不同类型来均衡发展")
            }
        }

        // --- Priority 3: Sleep regularity ---
        if avgSleep > 0 && avgSleep < 6.5 {
            suggestions.append("😴 均睡 \(String(format: "%.1f", avgSleep))h 偏少，下周试试提前 30 分钟上床")
        } else if sleepStdDev >= 1.0 {
            suggestions.append("😴 作息波动大（±\(String(format: "%.1f", sleepStdDev))h），固定就寝时间能显著改善睡眠质量")
        } else if avgSleep > 9.5 {
            suggestions.append("😴 均睡超过 9.5h，适当减少赖床可以提升白天精力")
        }

        // --- Priority 4: Calendar-aware tips (use next week's schedule) ---
        if let (busiestDay, meetingCount) = busiestNextDay, meetingCount >= 4 {
            let fmt = DateFormatter()
            fmt.dateFormat = "EEEE"
            fmt.locale = Locale(identifier: "zh_CN")
            let dayName = fmt.string(from: busiestDay)
            suggestions.append("📅 下周\(dayName)有 \(meetingCount) 个会议，提前规划会议间的活动时间")
        } else if nextWeekBusy && avgExercise < 30 {
            suggestions.append("📅 下周有日程安排，记得提前预留运动时间段")
        }

        // --- Priority 5: Location-based suggestion ---
        if !locations.isEmpty {
            let uniquePlaces = Set(locations.map { $0.displayName }).count
            if uniquePlaces <= 2 {
                suggestions.append("📍 本周活动范围较集中，周末可以探索一个新地方")
            }
        }

        // Cap at 3 most relevant suggestions
        return Array(suggestions.prefix(3))
    }

    /// Discovers cross-data patterns for arbitrary time periods (used by respondSummary).
    /// Reuses similar logic to weekly insights but adapted for variable-length ranges.
    private static func buildPeriodCrossInsights(
        healthSummaries: [HealthSummary],
        calendarEvents: [CalendarEventItem],
        locations: [LocationRecord],
        cal: Calendar
    ) -> [String] {
        var insights: [String] = []
        guard !healthSummaries.isEmpty else { return [] }

        // --- Insight 1: Meeting-heavy days vs step count ---
        if !calendarEvents.isEmpty && healthSummaries.count >= 3 {
            let timedEvents = calendarEvents.filter { !$0.isAllDay }
            var meetingsPerDay: [Date: Int] = [:]
            for e in timedEvents {
                let day = cal.startOfDay(for: e.startDate)
                meetingsPerDay[day, default: 0] += 1
            }
            var busyDaySteps: [Double] = []
            var freeDaySteps: [Double] = []
            for h in healthSummaries where h.steps > 0 {
                let day = cal.startOfDay(for: h.date)
                let meetings = meetingsPerDay[day] ?? 0
                if meetings >= 3 { busyDaySteps.append(h.steps) }
                else if meetings <= 1 { freeDaySteps.append(h.steps) }
            }
            if busyDaySteps.count >= 1 && freeDaySteps.count >= 1 {
                let busyAvg = busyDaySteps.reduce(0, +) / Double(busyDaySteps.count)
                let freeAvg = freeDaySteps.reduce(0, +) / Double(freeDaySteps.count)
                if freeAvg > 0 {
                    let diff = (busyAvg - freeAvg) / freeAvg * 100
                    if diff <= -25 {
                        insights.append("📅↔️🏃 会议多的日子步数少 \(Int(-diff))% —— 忙碌日记得会间走动")
                    } else if diff >= 25 {
                        insights.append("📅↔️🏃 会议多的日子反而更活跃，通勤换场的功劳")
                    }
                }
            }
        }

        // --- Insight 2: Location variety vs activity ---
        if !locations.isEmpty && healthSummaries.count >= 3 {
            var placesPerDay: [Date: Set<String>] = [:]
            for loc in locations {
                let day = cal.startOfDay(for: loc.timestamp)
                placesPerDay[day, default: []].insert(loc.displayName)
            }
            var manySteps: [Double] = []
            var fewSteps: [Double] = []
            for h in healthSummaries where h.steps > 0 {
                let day = cal.startOfDay(for: h.date)
                let places = placesPerDay[day]?.count ?? 0
                if places >= 3 { manySteps.append(h.steps) }
                else if places <= 1 { fewSteps.append(h.steps) }
            }
            if manySteps.count >= 1 && fewSteps.count >= 1 {
                let manyAvg = manySteps.reduce(0, +) / Double(manySteps.count)
                let fewAvg = fewSteps.reduce(0, +) / Double(fewSteps.count)
                if fewAvg > 0 && manyAvg > fewAvg * 1.3 {
                    insights.append("📍↔️👟 外出多的日子比宅家日多走 \(Int((manyAvg - fewAvg) / fewAvg * 100))% —— 出门就是运动")
                }
            }
        }

        // --- Insight 3: Exercise-sleep correlation ---
        let withSleep = healthSummaries.filter { $0.sleepHours > 0 }
        if withSleep.count >= 4 {
            let exerciseDays = withSleep.filter { $0.exerciseMinutes >= 30 }
            let restDays = withSleep.filter { $0.exerciseMinutes < 15 }
            if exerciseDays.count >= 2 && restDays.count >= 2 {
                let sleepOnEx = exerciseDays.reduce(0) { $0 + $1.sleepHours } / Double(exerciseDays.count)
                let sleepOnRest = restDays.reduce(0) { $0 + $1.sleepHours } / Double(restDays.count)
                let diff = sleepOnEx - sleepOnRest
                if diff >= 0.5 {
                    insights.append("🏃↔️😴 运动日比休息日多睡 \(String(format: "%.1f", diff))h —— 运动助眠效果明显")
                } else if diff <= -0.5 {
                    insights.append("🏃↔️😴 运动日反而少睡 \(String(format: "%.1f", -diff))h —— 试试把运动提前到更早")
                }
            }
        }

        // --- Insight 4: Most active weekday ---
        if healthSummaries.count >= 5 {
            var weekdayScores: [Int: (steps: Double, count: Int)] = [:]
            for h in healthSummaries where h.steps > 0 {
                let wd = cal.component(.weekday, from: h.date)
                let cur = weekdayScores[wd] ?? (0, 0)
                weekdayScores[wd] = (cur.steps + h.steps, cur.count + 1)
            }
            if let best = weekdayScores.max(by: {
                ($0.value.count > 0 ? $0.value.steps / Double($0.value.count) : 0) <
                ($1.value.count > 0 ? $1.value.steps / Double($1.value.count) : 0)
            }), best.value.count > 0 {
                let avgSteps = best.value.steps / Double(best.value.count)
                let overallAvg = healthSummaries.reduce(0) { $0 + $1.steps } / Double(healthSummaries.count)
                if avgSteps > overallAvg * 1.2 {
                    let dayName = weekdayName(best.key)
                    insights.append("🗓↔️🏃 \(dayName)是你最活跃的日子（均 \(Int(avgSteps).formatted()) 步）")
                }
            }
        }

        return Array(insights.prefix(3))
    }

    /// Returns Chinese weekday name from Calendar weekday number (1=Sun, 7=Sat).
    private static func weekdayName(_ weekday: Int) -> String {
        switch weekday {
        case 1: return "周日"
        case 2: return "周一"
        case 3: return "周二"
        case 4: return "周三"
        case 5: return "周四"
        case 6: return "周五"
        case 7: return "周六"
        default: return "未知"
        }
    }

    // MARK: - Photo Content Summary (Vision Tags)

    /// Semantic categories for classifying Vision tags — aligned with PhotoSkill's categories.
    private static let photoTagCategories: [(label: String, emoji: String, tags: Set<String>)] = [
        ("自拍",   "🤳", ["selfie", "portrait", "face"]),
        ("合照",   "👥", ["group", "people", "crowd"]),
        ("美食",   "🍜", ["food", "meal", "restaurant", "dish", "dessert", "cake", "coffee", "drink", "fruit"]),
        ("风景",   "🏞️", ["landscape", "scenery", "nature", "mountain", "hill", "valley", "field"]),
        ("海边",   "🏖️", ["beach", "ocean", "sea", "coast", "wave"]),
        ("天空",   "🌤️", ["sky", "cloud", "sunset", "sunrise"]),
        ("花草",   "🌸", ["flower", "plant", "garden", "tree", "forest"]),
        ("动物",   "🐾", ["animal", "cat", "dog", "bird", "pet", "kitten", "puppy", "fish"]),
        ("建筑",   "🏛️", ["building", "architecture", "house", "tower", "bridge", "church"]),
        ("城市",   "🏙️", ["city", "street", "urban", "road", "traffic"]),
        ("夜景",   "🌃", ["night", "light", "neon"]),
        ("户外",   "⛰️", ["outdoor", "hiking", "camping", "park"]),
        ("雪景",   "❄️", ["snow", "winter", "skiing", "ice"]),
    ]

    /// Queries CDPhotoIndex for the given date interval and returns a compact content breakdown line.
    /// Returns nil if no indexed photos exist for the period.
    ///
    /// Example output: "  🏷️ 美食 5张 · 风景 3张 · 自拍 2张"
    private func buildPhotoContentSummary(interval: DateInterval, context: SkillContext) -> [String] {
        let request = NSFetchRequest<CDPhotoIndex>(entityName: "CDPhotoIndex")
        request.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate <= %@",
            interval.start as NSDate, interval.end as NSDate
        )

        guard let indexed = try? context.coreDataContext.fetch(request),
              !indexed.isEmpty else {
            return []
        }

        // Classify each indexed photo into semantic categories
        var categoryCounts: [String: Int] = [:]
        var selfieCount = 0
        var groupCount = 0

        for entry in indexed {
            let entryTags = (entry.tags ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            let tagSet = Set(entryTags)

            // Face-based classification
            let faces = Int(entry.faceCount)
            if faces == 1 && entry.isFrontCamera {
                selfieCount += 1
            } else if faces >= 2 {
                groupCount += 1
            }

            // Tag-based classification — first match only to avoid inflation
            for category in Self.photoTagCategories {
                if !tagSet.isDisjoint(with: category.tags) {
                    categoryCounts[category.label, default: 0] += 1
                    break
                }
            }
        }

        // Add face-based categories
        if selfieCount > 0 { categoryCounts["自拍", default: 0] += selfieCount }
        if groupCount > 0 { categoryCounts["合照", default: 0] += groupCount }

        guard !categoryCounts.isEmpty else { return [] }

        // Sort by count descending, take top entries
        let sorted = categoryCounts.sorted { $0.value > $1.value }
        let topCategories = sorted.prefix(4)

        var lines: [String] = []

        // Compact one-liner: "🏷️ 美食 5张 · 风景 3张 · 自拍 2张"
        let parts = topCategories.map { (label, count) -> String in
            let emoji = Self.photoTagCategories.first { $0.label == label }?.emoji ?? "📷"
            return "\(emoji)\(label) \(count)张"
        }
        lines.append("  🏷️ \(parts.joined(separator: " · "))")

        // Fun insight if one category dominates (≥40% of indexed photos)
        if let top = topCategories.first {
            let pct = Double(top.value) / Double(indexed.count) * 100
            if pct >= 40 {
                let insight = photoContentInsight(category: top.key, pct: Int(pct))
                if !insight.isEmpty {
                    lines.append("  \(insight)")
                }
            }
        }

        return lines
    }

    /// Returns a brief personality-style comment when a photo category dominates.
    private func photoContentInsight(category: String, pct: Int) -> String {
        switch category {
        case "美食": return "🍽️ 这段时间是个美食记录者"
        case "风景": return "📸 一直在用镜头捕捉风景"
        case "自拍": return "✨ 自拍最多，记录每个精彩瞬间"
        case "合照": return "🎉 合照不少，社交生活很丰富"
        case "动物": return "🐱 萌宠出镜率很高"
        case "海边": return "🌊 海风与阳光的记忆"
        case "花草": return "🌿 生活充满自然气息"
        case "建筑": return "🏛️ 对城市空间有独特审美"
        case "夜景": return "🌃 夜色中的光影猎手"
        default: return ""
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

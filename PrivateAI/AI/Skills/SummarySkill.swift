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

        // Calculate fetch days to cover the full requested range
        let fetchDays = max(Calendar.current.dateComponents([.day], from: interval.start, to: Date()).day ?? 7, 1) + 1
        context.healthService.fetchSummaries(days: fetchDays) { allSummaries in
            // Filter health summaries to the requested interval
            let summaries = allSummaries.filter { interval.contains($0.date) }
            var lines: [String] = ["📋 \(range.label)的生活总结：\n"]
            var hasAnyData = false

            // --- Calendar Events (use full-period interval to include upcoming events) ---
            let calInterval = Self.calendarInterval(for: range)
            let calendarEvents = context.calendarService.fetchEvents(from: calInterval.start, to: calInterval.end)
            if !calendarEvents.isEmpty {
                hasAnyData = true
                let timedEvents = calendarEvents.filter { !$0.isAllDay }
                let totalMinutes = timedEvents.reduce(0.0) { $0 + $1.duration } / 60.0
                lines.append("📅 日程：\(calendarEvents.count) 个事件\(totalMinutes >= 60 ? "，约 \(Self.formatDuration(totalMinutes)) 有安排" : "")")
            }

            if !events.isEmpty {
                hasAnyData = true
                let byCategory = Dictionary(grouping: events, by: { $0.category })
                lines.append("\n📌 生活事件（共 \(events.count) 条）")
                byCategory.forEach { cat, evts in
                    lines.append("  \(cat.label)：\(evts.count) 条")
                }
            }

            if !locations.isEmpty {
                hasAnyData = true
                let uniquePlaces = Set(locations.map { $0.displayName }).count
                lines.append("\n📍 去过 \(uniquePlaces) 个地点，共记录 \(locations.count) 次")
            }

            let totalSteps = summaries.reduce(0) { $0 + $1.steps }
            let totalExercise = summaries.reduce(0) { $0 + $1.exerciseMinutes }
            if totalSteps > 0 || totalExercise > 0 {
                hasAnyData = true
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

            if !hasAnyData {
                lines.append("暂无足够的数据生成总结。\n请多与我互动，记录生活点滴，或开启日历权限让总结更完整！")
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
            lines.append("🌅 \(timeGreet)！今天的生活全景：\n")

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
            if hasHealthData {
                hasData = true
                // Compute 7-day averages for comparison (exclude today)
                let pastDays = recentSummaries.filter { !cal.isDateInToday($0.date) && $0.hasData }
                let avgSteps = pastDays.isEmpty ? 0 : pastDays.reduce(0) { $0 + $1.steps } / Double(pastDays.count)
                let avgExercise = pastDays.isEmpty ? 0 : pastDays.reduce(0) { $0 + $1.exerciseMinutes } / Double(pastDays.count)

                lines.append("\n🏃 **健康**")

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
                }

                // Heart rate — prefer resting HR (more meaningful) over average
                if health.restingHeartRate > 0 {
                    lines.append("  🫀 静息心率 \(Int(health.restingHeartRate)) BPM")
                    if health.hrv > 0 {
                        lines.append("  📳 HRV \(Int(health.hrv)) ms")
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
                }

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

                // Overall weekly health verdict with trend context
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

                if score == 3 {
                    if hasLastWeek && lwScore < 3 {
                        lines.append("  ✅ 本周步数、运动、睡眠全面达标！比上周更好 🎉")
                    } else {
                        lines.append("  ✅ 本周步数、运动、睡眠全面达标！")
                    }
                } else if score >= 2 {
                    if hasLastWeek && score > lwScore {
                        lines.append("  💪 本周状态比上周有进步，继续加油！")
                    } else if hasLastWeek && score < lwScore {
                        lines.append("  💡 本周表现比上周略有下滑，下周试试找回节奏")
                    } else {
                        lines.append("  💪 本周状态不错，还有一项可以提升")
                    }
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

    /// Formats a week-over-week percentage delta as a concise arrow string.
    /// Returns "" if the change is too small to be meaningful (<10%).
    private static func formatDelta(current: Double, previous: Double) -> String {
        guard previous > 0 else { return "" }
        let pct = ((current - previous) / previous) * 100
        guard abs(pct) >= 10 else { return "" }
        let arrow = pct > 0 ? "↑" : "↓"
        return "（vs 上周 \(arrow)\(Int(abs(pct)))%）"
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

        // --- Insight 6: Exercise + sleep correlation from recent data ---
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

        return Array(insights.prefix(2))
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

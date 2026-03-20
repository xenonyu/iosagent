import Foundation

/// Handles calendar and schedule queries via EventKit.
/// Provides rich insights: busy-ness scoring, next event, free slots, conflict detection.
struct CalendarSkill: ClawSkill {

    let id = "calendar"

    func canHandle(intent: QueryIntent) -> Bool {
        switch intent {
        case .calendar, .calendarNext, .calendarSearch: return true
        default: return false
        }
    }

    func execute(intent: QueryIntent, context: SkillContext, completion: @escaping (String) -> Void) {
        if case .calendarNext = intent {
            completion(buildNextEventResponse(context: context))
            return
        }
        if case .calendarSearch(let keyword, let range) = intent {
            completion(buildCalendarSearchResponse(keyword: keyword, range: range, context: context))
            return
        }
        guard case .calendar(let range) = intent else { return }

        // For today/tomorrow schedule, enrich with health context (sleep + activity + HRV readiness)
        let cal = Calendar.current
        let isTodayQuery = (range == .today)
        let isTomorrowQuery = (range == .tomorrow)
        if (isTodayQuery || isTomorrowQuery) && context.healthService.isHealthDataAvailable {
            // Fetch 7 days in one call — provides today, yesterday, AND personal baseline
            context.healthService.fetchSummaries(days: 7) { summaries in
                let todaySummary = summaries.first { cal.isDateInToday($0.date) }
                    ?? HealthSummary(date: Date())
                let yesterday = cal.date(byAdding: .day, value: -1, to: Date()) ?? Date()
                let sleepSummary = summaries.first { cal.isDate($0.date, inSameDayAs: yesterday) }
                    ?? HealthSummary(date: yesterday)
                // Baseline: past days excluding today, with actual data
                let baseline = summaries.filter { !cal.isDateInToday($0.date) && $0.hasData }

                var response = self.buildResponse(range: range, context: context)

                if isTodayQuery {
                    let healthContext = self.buildHealthReadiness(
                        lastNightSleep: sleepSummary,
                        todayActivity: todaySummary,
                        baseline: baseline,
                        events: context.calendarService.todayEvents()
                    )
                    if !healthContext.isEmpty {
                        response += "\n\n" + healthContext
                    }
                } else {
                    // Tomorrow: use today's data to give preparation advice
                    let tomorrowStart = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))!
                    let tomorrowEnd = cal.date(byAdding: .day, value: 1, to: tomorrowStart)!
                    let tomorrowEvents = context.calendarService.fetchEvents(from: tomorrowStart, to: tomorrowEnd)
                    let prepContext = self.buildTomorrowPreparation(
                        todaySleep: sleepSummary,
                        todayActivity: todaySummary,
                        baseline: baseline,
                        tomorrowEvents: tomorrowEvents
                    )
                    if !prepContext.isEmpty {
                        response += "\n\n" + prepContext
                    }
                }
                completion(response)
            }
        } else {
            completion(buildResponse(range: range, context: context))
        }
    }

    // MARK: - Next Event Response

    /// Builds a focused "what's next" response showing the next few upcoming events from NOW.
    /// Unlike the full-day overview, this answers "接下来有什么" with minimal, actionable info.
    private func buildNextEventResponse(context: SkillContext) -> String {
        guard context.calendarService.isAuthorized else {
            return """
            📅 日历权限未开启，无法查看接下来的安排。

            请前往「设置 → iosclaw → 日历」开启权限。
            """
        }

        let now = Date()
        let cal = Calendar.current

        // Look ahead: rest of today + tomorrow (covers overnight events and next-morning meetings)
        let todayEnd = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
        let tomorrowEnd = cal.date(byAdding: .day, value: 1, to: todayEnd)!

        // Fetch today's events from start-of-day (not now) so all-day events are reliably included,
        // since some EventKit implementations may exclude all-day events whose start < query start.
        let todayStart = cal.startOfDay(for: now)
        let todayEvents = context.calendarService.fetchEvents(from: todayStart, to: todayEnd)
        let tomorrowEvents = context.calendarService.fetchEvents(from: todayEnd, to: tomorrowEnd)

        // Split into timed (ongoing/upcoming) and all-day events
        let timedToday = todayEvents.filter { !$0.isAllDay }
        let allDayToday = todayEvents.filter { $0.isAllDay }
        let ongoing = timedToday.filter { $0.startDate <= now && $0.endDate > now }
        let upcoming = timedToday.filter { $0.startDate > now }
        let remainingCount = ongoing.count + upcoming.count

        // Nothing left today (timed)
        if remainingCount == 0 {
            var msg = ""

            // Show today's all-day events — these are still "active" context
            if !allDayToday.isEmpty {
                msg += "🏷️ 今天的全天事件：\n"
                for event in allDayToday {
                    msg += "  • \(event.title)\(calendarTag(event.calendar))\n"
                }
                msg += "\n"
            }

            // Check tomorrow
            let timedTomorrow = tomorrowEvents.filter { !$0.isAllDay }
            let allDayTomorrow = tomorrowEvents.filter { $0.isAllDay }

            if timedTomorrow.isEmpty && allDayTomorrow.isEmpty {
                msg += "✅ 今天的安排已经全部结束了，明天也暂时没有日程。\n\n好好休息吧 🌙"
                return msg
            }

            msg += "✅ 今天的定时安排已经全部结束了。\n\n"

            // Show tomorrow's all-day events
            if !allDayTomorrow.isEmpty {
                msg += "🏷️ 明天的全天事件：\n"
                for event in allDayTomorrow {
                    msg += "  • \(event.title)\(calendarTag(event.calendar))\n"
                }
            }

            // Show tomorrow's first timed event
            if !timedTomorrow.isEmpty {
                let first = timedTomorrow.sorted { $0.startDate < $1.startDate }.first!
                let timeFmt = DateFormatter()
                timeFmt.dateFormat = "HH:mm"
                msg += "📅 明天最早的安排：\(timeFmt.string(from: first.startDate)) 「\(first.title)」"
                if let atLabel = first.attendeeLabel { msg += "  \(atLabel)" }
                if !first.location.isEmpty { msg += "\n  📍 \(first.location)" }
                if timedTomorrow.count > 1 {
                    msg += "\n  明天共有 \(timedTomorrow.count) 个定时事件。"
                }
            }

            return msg
        }

        var lines: [String] = []
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"

        // Today's all-day events as context (birthdays, holidays, deadlines)
        if !allDayToday.isEmpty {
            lines.append("🏷️ 今天的全天事件：")
            for event in allDayToday {
                lines.append("  • \(event.title)\(calendarTag(event.calendar))")
            }
            lines.append("")
        }

        // Ongoing events
        for event in ongoing {
            let remainMin = Int(event.endDate.timeIntervalSince(now) / 60)
            let orgTag = organizerTag(event)
            var line = "🔴 正在进行：「\(event.title)」（\(event.timeDisplay)）\(orgTag)"
            if let atLabel = event.attendeeLabel { line += "  \(atLabel)" }
            if remainMin > 0 {
                line += "\n  还剩 \(formatDuration(Double(remainMin)))"
            }
            if !event.location.isEmpty { line += "  📍 \(event.location)" }
            lines.append(line)
        }

        // Next upcoming events (show up to 3)
        let sortedUpcoming = upcoming.sorted { $0.startDate < $1.startDate }
        for (i, event) in sortedUpcoming.prefix(3).enumerated() {
            let minutesUntil = event.startDate.timeIntervalSince(now) / 60

            let countdown: String
            if minutesUntil < 1 {
                countdown = "马上开始"
            } else if minutesUntil < 60 {
                countdown = "\(Int(minutesUntil)) 分钟后"
            } else {
                let hours = Int(minutesUntil / 60)
                let mins = Int(minutesUntil.truncatingRemainder(dividingBy: 60))
                countdown = mins > 0 ? "\(hours) 小时 \(mins) 分钟后" : "\(hours) 小时后"
            }

            let prefix = (i == 0 && ongoing.isEmpty) ? "⏰ 下一个" : "  📋"
            let orgTag = organizerTag(event)
            var line = "\(prefix)：\(countdown) — 「\(event.title)」（\(event.timeDisplay)）\(orgTag)"
            if let atLabel = event.attendeeLabel { line += "  \(atLabel)" }
            if !event.location.isEmpty { line += "\n    📍 \(event.location)" }

            // Duration hint for the next event
            if i == 0 {
                let durationMin = event.duration / 60
                if durationMin >= 30 {
                    line += "\n    时长 \(formatDuration(durationMin))"
                }
            }

            lines.append(line)
        }

        // Remaining count if there are more
        if sortedUpcoming.count > 3 {
            lines.append("\n  …之后还有 \(sortedUpcoming.count - 3) 个安排")
        }

        // Summary line: how many left, when done
        if let lastEvent = sortedUpcoming.last ?? ongoing.last {
            let doneTime = timeFmt.string(from: lastEvent.endDate)
            if remainingCount == 1 {
                if !ongoing.isEmpty {
                    lines.append("\n这是今天最后一个安排，\(doneTime) 结束后就自由了。")
                } else {
                    lines.append("\n这是今天最后一个安排了。")
                }
            } else {
                // Find the actual last event of the day
                let allRemaining = (ongoing + sortedUpcoming).sorted { $0.endDate < $1.endDate }
                if let trueLast = allRemaining.last {
                    let finalTime = timeFmt.string(from: trueLast.endDate)
                    lines.append("\n今天还剩 \(remainingCount) 个安排，预计 \(finalTime) 全部结束。")
                }
            }
        }

        // Gap analysis: time until next event (if ongoing, show gap after it ends)
        if let currentEnd = ongoing.first?.endDate, let nextStart = sortedUpcoming.first?.startDate {
            let gapMin = nextStart.timeIntervalSince(currentEnd) / 60
            if gapMin >= 15 && gapMin <= 180 {
                lines.append("💚 当前事件结束后有 \(formatDuration(gapMin)) 的空隙。")
            }
        } else if ongoing.isEmpty, let next = sortedUpcoming.first {
            let gapMin = next.startDate.timeIntervalSince(now) / 60
            if gapMin >= 30 {
                lines.append("💚 距下一个安排还有 \(formatDuration(gapMin))，可以专注做点事。")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Time-of-Day Filter

    /// Represents a user's time-of-day focus for calendar queries.
    /// Parsed from natural language like "今天下午有什么安排", "明天早上有会吗".
    private enum TimeOfDayFilter {
        case morning    // 早上/上午: 6:00-12:00
        case afternoon  // 下午: 12:00-18:00
        case evening    // 晚上/今晚: 18:00-23:59

        var label: String {
            switch self {
            case .morning:   return "上午"
            case .afternoon: return "下午"
            case .evening:   return "晚上"
            }
        }

        var hourRange: Range<Int> {
            switch self {
            case .morning:   return 6..<12
            case .afternoon: return 12..<18
            case .evening:   return 18..<24
            }
        }

        /// Checks whether an event overlaps with this time-of-day period on the given date.
        /// All-day events are excluded here since they're displayed separately.
        func matches(event: CalendarEventItem, on date: Date) -> Bool {
            if event.isAllDay { return false }
            let cal = Calendar.current
            let startHour = cal.component(.hour, from: event.startDate)
            let endHour = cal.component(.hour, from: event.endDate)
            let endMin = cal.component(.minute, from: event.endDate)

            // Event overlaps this period if it starts before the period ends
            // AND ends after the period starts.
            // An event ending exactly at period start (e.g. 12:00 for afternoon) doesn't count.
            let periodStart = hourRange.lowerBound
            let periodEnd = hourRange.upperBound

            let eventEndsAfterPeriodStart = endHour > periodStart || (endHour == periodStart && endMin > 0)
            let eventStartsBeforePeriodEnd = startHour < periodEnd

            return eventEndsAfterPeriodStart && eventStartsBeforePeriodEnd
        }
    }

    /// Parses the user's query for time-of-day keywords.
    private func parseTimeOfDayFilter(from query: String) -> TimeOfDayFilter? {
        let lower = query.lowercased()
        // Morning
        if lower.contains("早上") || lower.contains("上午") || lower.contains("早晨")
            || lower.contains("今早") || lower.contains("明早")
            || lower.contains("morning") {
            return .morning
        }
        // Afternoon
        if lower.contains("下午") || lower.contains("午后")
            || lower.contains("afternoon") {
            return .afternoon
        }
        // Evening
        if lower.contains("晚上") || lower.contains("今晚") || lower.contains("明晚")
            || lower.contains("傍晚") || lower.contains("晚间") || lower.contains("夜里")
            || lower.contains("evening") || lower.contains("tonight") {
            return .evening
        }
        return nil
    }

    // MARK: - Response Builder

    private func buildResponse(range: QueryTimeRange, context: SkillContext) -> String {
        // Calendar queries need the FULL period, not truncated at "now".
        // QueryTimeRange.today/.thisWeek/.thisMonth end at Date() which is correct
        // for health/location data, but calendar users asking "今天有什么安排" at 9am
        // need to see their 2pm meeting. Extend the interval to cover the full period.
        let interval = calendarInterval(for: range)
        let events = context.calendarService.fetchEvents(from: interval.start, to: interval.end)

        if events.isEmpty {
            return buildEmptyResponse(range: range, isAuthorized: context.calendarService.isAuthorized)
        }

        let cal = Calendar.current
        let spanDays = max(1, cal.dateComponents([.day], from: interval.start, to: interval.end).day ?? 1)

        // Parse time-of-day filter from the user's original query
        let todFilter = parseTimeOfDayFilter(from: context.originalQuery)

        if spanDays <= 1 {
            return buildSingleDayResponse(events: events, range: range, date: interval.start, timeOfDay: todFilter, context: context)
        } else {
            return buildMultiDayResponse(events: events, range: range, interval: interval, spanDays: spanDays, context: context)
        }
    }

    // MARK: - Calendar Search Response

    /// Searches for events matching a keyword across a time range and builds a focused response.
    /// Answers questions like "我什么时候有面试", "下次1:1是什么时候", "有没有设计评审".
    private func buildCalendarSearchResponse(keyword: String, range: QueryTimeRange, context: SkillContext) -> String {
        guard context.calendarService.isAuthorized else {
            return """
            📅 日历权限未开启，无法搜索日程。

            请前往「设置 → iosclaw → 日历」开启权限。
            """
        }

        let cal = Calendar.current
        let now = Date()

        // Build search interval: past 7 days + forward range (default 30 days)
        let searchInterval = calendarInterval(for: range)
        // Also look back 7 days to find recent past occurrences for context
        let lookbackStart = cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: now))!
        let effectiveStart = min(searchInterval.start, lookbackStart)
        // For future-oriented searches, extend to at least 30 days ahead
        let minFutureEnd = cal.date(byAdding: .day, value: 30, to: cal.startOfDay(for: now))!
        let effectiveEnd = max(searchInterval.end, minFutureEnd)

        let allEvents = context.calendarService.fetchEvents(from: effectiveStart, to: effectiveEnd)

        // Match events by keyword (case-insensitive, partial match on title/location/notes/calendar)
        let lowerKeyword = keyword.lowercased()
        let matched = allEvents.filter { event in
            event.title.lowercased().contains(lowerKeyword) ||
            event.location.lowercased().contains(lowerKeyword) ||
            event.notes.lowercased().contains(lowerKeyword) ||
            event.calendar.lowercased().contains(lowerKeyword)
        }

        if matched.isEmpty {
            return buildSearchEmptyResponse(keyword: keyword, range: range)
        }

        var lines: [String] = []
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "M月d日（E）"
        dateFmt.locale = Locale(identifier: "zh_CN")
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"

        // Split into past and future events
        let pastEvents = matched.filter { $0.endDate < now }
        let futureEvents = matched.filter { $0.startDate >= now || ($0.startDate < now && $0.endDate > now) }

        // Header
        lines.append("🔍 搜索「\(keyword)」相关日程：")
        lines.append("找到 \(matched.count) 个匹配事件\(futureEvents.isEmpty ? "" : "，其中 \(futureEvents.count) 个即将到来")。\n")

        // --- Upcoming events (most important) ---
        if !futureEvents.isEmpty {
            let sortedFuture = futureEvents.sorted { $0.startDate < $1.startDate }

            // Highlight the next occurrence
            if let next = sortedFuture.first {
                let isOngoing = next.startDate <= now && next.endDate > now
                if isOngoing {
                    let remainMin = Int(next.endDate.timeIntervalSince(now) / 60)
                    var line = "🔴 正在进行：「\(next.title)」（\(next.timeDisplay)）"
                    if let atLabel = next.attendeeLabel { line += "  \(atLabel)" }
                    if remainMin > 0 { line += "，还剩 \(formatDuration(Double(remainMin)))" }
                    if !next.location.isEmpty { line += "\n  📍 \(next.location)" }
                    lines.append(line)
                } else {
                    let daysUntil = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: next.startDate)).day ?? 0
                    let countdown: String
                    if daysUntil == 0 {
                        let minUntil = next.startDate.timeIntervalSince(now) / 60
                        countdown = minUntil < 60
                            ? "\(Int(minUntil)) 分钟后"
                            : "\(Int(minUntil / 60)) 小时 \(Int(minUntil.truncatingRemainder(dividingBy: 60))) 分钟后"
                    } else if daysUntil == 1 {
                        countdown = "明天"
                    } else if daysUntil == 2 {
                        countdown = "后天"
                    } else {
                        countdown = "\(daysUntil) 天后"
                    }

                    let orgTag = organizerTag(next)
                    var line = "⏰ 最近一次：\(countdown) — \(dateFmt.string(from: next.startDate)) \(next.timeDisplay)"
                    line += "\n  「\(next.title)」\(orgTag)"
                    if let atLabel = next.attendeeLabel { line += "  \(atLabel)" }
                    if !next.location.isEmpty { line += "  📍 \(next.location)" }
                    if !next.calendar.isEmpty { line += "  [\(next.calendar)]" }
                    let durationMin = next.duration / 60
                    if durationMin >= 30 && !next.isAllDay {
                        line += "\n  时长 \(formatDuration(durationMin))"
                    }
                    lines.append(line)
                }
            }

            // Show additional upcoming occurrences (up to 4 more)
            if sortedFuture.count > 1 {
                lines.append("")
                lines.append("📋 后续安排：")
                for event in sortedFuture.dropFirst().prefix(4) {
                    let dayLabel = cal.isDateInToday(event.startDate) ? "今天"
                        : cal.isDateInTomorrow(event.startDate) ? "明天"
                        : dateFmt.string(from: event.startDate)
                    let timeStr = event.isAllDay ? "全天" : event.timeDisplay
                    let recurTag = event.isRecurring ? " 🔄" : ""
                    var line = "  • \(dayLabel) \(timeStr) 「\(event.title)」\(recurTag)"
                    if !event.location.isEmpty { line += "  📍\(event.location)" }
                    lines.append(line)
                }
                if sortedFuture.count > 5 {
                    lines.append("  …还有 \(sortedFuture.count - 5) 个后续安排")
                }
            }
        }

        // --- Past events (secondary context) ---
        if !pastEvents.isEmpty && futureEvents.count <= 3 {
            let sortedPast = pastEvents.sorted { $0.startDate > $1.startDate } // Most recent first
            lines.append("")
            lines.append("📜 最近的记录：")
            for event in sortedPast.prefix(3) {
                let daysAgo = cal.dateComponents([.day], from: cal.startOfDay(for: event.startDate), to: cal.startOfDay(for: now)).day ?? 0
                let agoLabel = daysAgo == 0 ? "今天" : daysAgo == 1 ? "昨天" : "\(daysAgo)天前"
                let timeStr = event.isAllDay ? "全天" : event.timeDisplay
                lines.append("  · \(agoLabel) \(dateFmt.string(from: event.startDate)) \(timeStr) 「\(event.title)」")
            }
        }

        // --- Frequency insight ---
        if matched.count >= 3 {
            let insight = buildSearchFrequencyInsight(events: matched, keyword: keyword)
            if !insight.isEmpty {
                lines.append("")
                lines.append(contentsOf: insight)
            }
        }

        // --- Recurring detection ---
        let recurringMatches = matched.filter { $0.isRecurring }
        if !recurringMatches.isEmpty && futureEvents.count <= 1 {
            lines.append("")
            lines.append("🔄 这是一个周期性日程，会定期出现在你的日历中。")
        }

        return lines.joined(separator: "\n")
    }

    /// Builds a friendly empty response when no events match the search keyword.
    private func buildSearchEmptyResponse(keyword: String, range: QueryTimeRange) -> String {
        var msg = "🔍 没有找到与「\(keyword)」相关的日程。\n"
        msg += "\n可能的原因：\n"
        msg += "  • 日历中没有标题包含「\(keyword)」的事件\n"
        msg += "  • 事件可能使用了不同的名称\n"
        msg += "\n💡 试试换个关键词，比如：\n"
        msg += "  • 会议组织者的名字\n"
        msg += "  • 会议类型（如：1:1、review、standup）\n"
        msg += "  • 日历名称"
        return msg
    }

    /// Analyzes frequency and timing patterns for matched events.
    private func buildSearchFrequencyInsight(events: [CalendarEventItem], keyword: String) -> [String] {
        let cal = Calendar.current
        var lines: [String] = []

        // Group by weekday to find patterns
        var weekdayCounts: [Int: Int] = [:]  // weekday (1=Sun..7=Sat) → count
        for event in events {
            let wd = cal.component(.weekday, from: event.startDate)
            weekdayCounts[wd, default: 0] += 1
        }

        let weekdayNames = [1: "周日", 2: "周一", 3: "周二", 4: "周三", 5: "周四", 6: "周五", 7: "周六"]

        // Find dominant weekday (if >50% on one day, it's a pattern)
        let total = events.count
        if let (dominantDay, count) = weekdayCounts.max(by: { $0.value < $1.value }),
           Double(count) / Double(total) >= 0.5, count >= 2 {
            let dayName = weekdayNames[dominantDay] ?? "未知"
            lines.append("📊 时间规律：「\(keyword)」多在\(dayName)出现（\(count)/\(total) 次）")
        }

        // Average duration
        let timedEvents = events.filter { !$0.isAllDay }
        if timedEvents.count >= 2 {
            let avgDuration = timedEvents.reduce(0.0) { $0 + $1.duration } / Double(timedEvents.count) / 60.0
            if avgDuration >= 15 {
                lines.append("⏱️ 平均时长：\(formatDuration(avgDuration))")
            }
        }

        // Time-of-day preference
        let hours = timedEvents.map { cal.component(.hour, from: $0.startDate) }
        if !hours.isEmpty {
            let avgHour = hours.reduce(0, +) / hours.count
            let timeOfDay: String
            if avgHour < 12 { timeOfDay = "上午" }
            else if avgHour < 18 { timeOfDay = "下午" }
            else { timeOfDay = "晚上" }
            if timedEvents.count >= 3 {
                lines.append("🕐 通常在\(timeOfDay)（平均 \(String(format: "%02d:00", avgHour)) 左右）")
            }
        }

        return lines
    }

    /// Extends the time interval to the end of the period for calendar-specific queries.
    /// `.today` → start of today … end of today (not "now")
    /// `.thisWeek` → start of week … end of week (not "now")
    /// `.thisMonth` → start of month … end of month (not "now")
    /// `.thisWeekend` → Saturday 00:00 … Monday 00:00 (full weekend, not truncated at "now")
    /// Other ranges (yesterday, lastWeek, tomorrow, etc.) are already correct.
    private func calendarInterval(for range: QueryTimeRange) -> DateInterval {
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
        case .thisWeekend, .nextWeekend, .lastWeekend:
            // Weekend intervals are already computed as full Sat-Mon ranges in QueryTimeRange,
            // but .thisWeekend.interval truncates at "now" if we're still in the weekend.
            // Use the range.interval directly — it already covers Sat 00:00 to Mon 00:00.
            return range.interval
        default:
            return range.interval
        }
    }

    // MARK: - Weekend Detection

    /// Returns true when the given date falls on Saturday or Sunday.
    private func isWeekend(_ date: Date) -> Bool {
        let wd = Calendar.current.component(.weekday, from: date)
        return wd == 1 || wd == 7  // 1 = Sunday, 7 = Saturday
    }

    /// Returns a short Chinese weekday name for weekend-context messaging.
    private func weekdayLabel(_ date: Date) -> String {
        let wd = Calendar.current.component(.weekday, from: date)
        switch wd {
        case 1: return "周日"
        case 7: return "周六"
        default: return ""
        }
    }

    // MARK: - Empty State

    private func buildEmptyResponse(range: QueryTimeRange, isAuthorized: Bool) -> String {
        // Permission not granted — guide user to enable it instead of falsely claiming "no events"
        if !isAuthorized {
            return """
            📅 日历权限未开启，无法查看你的日程。

            请前往「设置 → iosclaw → 日历」开启权限。
            开启后我就能帮你查看日程、分析会议安排、找空闲时段了。
            """
        }

        // Permission granted but no events in the requested range
        if range.isFuture || range == .today {
            // Weekend-specific celebration for free weekend days
            let targetDate = range.interval.start
            if isWeekend(targetDate) {
                return "📅 \(range.label)没有任何日程安排。\n\n🏖️ \(weekdayLabel(targetDate))完全属于自己！好好享受休息时光吧。"
            }
            return "📅 \(range.label)没有任何日程安排。\n\n✨ 这段时间完全自由！可以用来做自己想做的事。"
        }
        let interval = range.interval
        let cal = Calendar.current
        let now = Date()
        if interval.end >= cal.startOfDay(for: now) {
            let targetDate = interval.start
            if isWeekend(targetDate) {
                return "📅 \(range.label)没有任何日程安排。\n\n🏖️ \(weekdayLabel(targetDate))完全属于自己！好好享受休息时光吧。"
            }
            return "📅 \(range.label)没有任何日程安排。\n\n✨ 这段时间完全自由！可以用来做自己想做的事。"
        }
        return "📅 \(range.label)的日历里没有事件记录。"
    }

    // MARK: - Single Day Response (Today / Tomorrow / Specific Day)

    private func buildSingleDayResponse(events: [CalendarEventItem], range: QueryTimeRange, date: Date, timeOfDay: TimeOfDayFilter? = nil, context: SkillContext? = nil) -> String {
        var lines: [String] = []
        let now = Date()
        let cal = Calendar.current
        let isToday = cal.isDateInToday(date)
        let isFutureDay = range.isFuture

        // --- Header with busy-ness ---
        let timedEvents = events.filter { !$0.isAllDay }
        let allDayEvents = events.filter { $0.isAllDay }

        // When user asks about a specific time-of-day, split events into focused + rest
        let focusedTimedEvents: [CalendarEventItem]
        let otherTimedEvents: [CalendarEventItem]
        if let tod = timeOfDay {
            focusedTimedEvents = timedEvents.filter { tod.matches(event: $0, on: date) }
            otherTimedEvents = timedEvents.filter { !tod.matches(event: $0, on: date) }
        } else {
            focusedTimedEvents = timedEvents
            otherTimedEvents = []
        }

        let totalMeetingMinutes = timedEvents.reduce(0.0) { $0 + $1.duration } / 60.0
        let busyLevel = busyScore(timedCount: timedEvents.count, totalMinutes: totalMeetingMinutes)

        // Adjust header to reflect time-of-day focus
        if let tod = timeOfDay {
            let focusedMinutes = focusedTimedEvents.reduce(0.0) { $0 + $1.duration } / 60.0
            let focusBusy = busyScore(timedCount: focusedTimedEvents.count, totalMinutes: focusedMinutes)
            lines.append("📅 \(range.label)\(tod.label)的日程 \(focusBusy.emoji)")
            if focusedTimedEvents.isEmpty {
                lines.append("\(tod.label)没有安排，完全自由！\n")
            } else {
                lines.append("\(tod.label)有 \(focusedTimedEvents.count) 个事件\(focusedMinutes >= 60 ? "，约 \(formatDuration(focusedMinutes)) 有安排" : "")。\n")
            }
        } else {
            lines.append("📅 \(range.label)的日程 \(busyLevel.emoji)")
            lines.append("\(busyLevel.description)，共 \(events.count) 个事件\(totalMeetingMinutes >= 60 ? "，约 \(formatDuration(totalMeetingMinutes)) 有安排" : "")。\n")
        }

        // --- Next upcoming event (only for today) ---
        // When time-of-day filter is active, scope "next event" to the focused period.
        if isToday {
            let relevantEvents = timeOfDay != nil ? focusedTimedEvents : timedEvents
            let upcoming = relevantEvents.filter { $0.endDate > now }.sorted { $0.startDate < $1.startDate }
            if let next = upcoming.first {
                let minutesUntil = next.startDate.timeIntervalSince(now) / 60
                if minutesUntil > 0 && minutesUntil <= 480 {
                    let timeStr = minutesUntil < 60
                        ? "\(Int(minutesUntil)) 分钟后"
                        : "\(Int(minutesUntil / 60)) 小时\(Int(minutesUntil.truncatingRemainder(dividingBy: 60))) 分钟后"
                    var nextLine = "⏰ 接下来：\(timeStr)有「\(next.title)」（\(next.timeDisplay)）"
                    if let atLabel = next.attendeeLabel { nextLine += "  \(atLabel)" }
                    if !next.location.isEmpty { nextLine += "  📍\(next.location)" }
                    lines.append(nextLine + "\n")
                } else if minutesUntil <= 0 && next.startDate <= now && next.endDate > now {
                    let remainMin = Int(next.endDate.timeIntervalSince(now) / 60)
                    var ongoingLine = "🔴 正在进行：「\(next.title)」（\(next.timeDisplay)）"
                    if let atLabel = next.attendeeLabel { ongoingLine += "  \(atLabel)" }
                    if remainMin > 0 { ongoingLine += "，还剩 \(formatDuration(Double(remainMin)))" }
                    if !next.location.isEmpty { ongoingLine += "  📍\(next.location)" }
                    lines.append(ongoingLine + "\n")
                }
            } else if !relevantEvents.isEmpty {
                if let tod = timeOfDay {
                    lines.append("✅ \(tod.label)的日程已全部结束。\n")
                } else {
                    lines.append("✅ 今天的日程已全部结束。\n")
                }
            }
        }

        // --- First event preview for future days ---
        if isFutureDay {
            let previewEvents = timeOfDay != nil ? focusedTimedEvents : timedEvents
            if !previewEvents.isEmpty {
                let sorted = previewEvents.sorted { $0.startDate < $1.startDate }
                if let first = sorted.first {
                    let label = timeOfDay != nil ? "\(timeOfDay!.label)最早的安排" : "最早的安排"
                    lines.append("⏰ \(label)：\(first.timeDisplay)「\(first.title)」\n")
                }
            }
        }

        // --- All-day events ---
        if !allDayEvents.isEmpty {
            lines.append("🏷️ 全天事件：")
            allDayEvents.forEach { lines.append("  • \($0.title)\(calendarTag($0.calendar))") }
            lines.append("")
        }

        // --- Timed events list ---
        // When time-of-day filter is active, show focused events prominently,
        // then show remaining events as secondary context.
        if timeOfDay != nil && !focusedTimedEvents.isEmpty {
            lines.append("🕐 \(timeOfDay!.label)安排：")
            focusedTimedEvents.forEach { event in
                let recurTag = event.isRecurring ? " 🔄" : ""
                let atTag = event.attendeeLabel.map { "  \($0)" } ?? ""
                let orgTag = organizerTag(event)
                var line = "  • \(event.timeDisplay) \(event.title)\(recurTag)\(orgTag)\(atTag)"
                if !event.location.isEmpty { line += "  📍\(event.location)" }
                lines.append(line)
                if let preview = notesPreview(event.notes) {
                    lines.append("    💬 \(preview)")
                }
            }
            lines.append("")

            // Show other events as secondary context
            if !otherTimedEvents.isEmpty {
                lines.append("📋 其他时段还有 \(otherTimedEvents.count) 个安排：")
                otherTimedEvents.forEach { event in
                    let recurTag = event.isRecurring ? " 🔄" : ""
                    let atTag = event.attendeeLabel.map { "  \($0)" } ?? ""
                    let orgTag = organizerTag(event)
                    var line = "  · \(event.timeDisplay) \(event.title)\(recurTag)\(orgTag)\(atTag)"
                    if !event.location.isEmpty { line += "  📍\(event.location)" }
                    lines.append(line)
                }
                lines.append("")
            }
        } else if !timedEvents.isEmpty {
            lines.append("🕐 时间安排：")
            timedEvents.forEach { event in
                let recurTag = event.isRecurring ? " 🔄" : ""
                let atTag = event.attendeeLabel.map { "  \($0)" } ?? ""
                let orgTag = organizerTag(event)
                var line = "  • \(event.timeDisplay) \(event.title)\(recurTag)\(orgTag)\(atTag)"
                if !event.location.isEmpty { line += "  📍\(event.location)" }
                lines.append(line)
                if let preview = notesPreview(event.notes) {
                    lines.append("    💬 \(preview)")
                }
            }
            lines.append("")
        }

        // --- Back-to-back & location change warnings ---
        let scheduleWarnings = detectScheduleWarnings(events: timedEvents)
        if !scheduleWarnings.isEmpty {
            lines.append("🏃 日程提醒：")
            scheduleWarnings.forEach { lines.append("  • \($0)") }
            lines.append("")
        }

        // --- Time conflicts ---
        let conflicts = detectConflicts(events: timedEvents)
        if !conflicts.isEmpty {
            lines.append("⚠️ 时间冲突：")
            conflicts.forEach { lines.append("  • \($0)") }
            lines.append("")
        }

        // --- Weekend context insight ---
        if isWeekend(date) && !timedEvents.isEmpty {
            let weekendMeetingMin = timedEvents.reduce(0.0) { $0 + $1.duration } / 60.0
            let dayLabel = weekdayLabel(date)
            if timedEvents.count >= 3 || weekendMeetingMin >= 180 {
                lines.append("🏖️ \(dayLabel)安排了 \(timedEvents.count) 个事项（\(formatDuration(weekendMeetingMin))），周末节奏偏紧 — 记得给自己留出放松时间。")
            } else {
                lines.append("🏖️ \(dayLabel)有 \(timedEvents.count) 个安排，处理完就好好休息吧。")
            }
            lines.append("")
        }

        // --- Free time slots (for today and future days) ---
        if isToday || isFutureDay {
            let freeSlots = findFreeSlots(events: timedEvents, date: date, onlyFuture: isToday)
            if !freeSlots.isEmpty {
                lines.append("💚 空闲时段：")
                freeSlots.prefix(5).forEach { lines.append("  • \($0)") }
            }
        }

        // --- Deep work & focus analysis ---
        let focusInsight = buildFocusInsight(events: timedEvents, date: date, onlyFuture: isToday)
        if !focusInsight.isEmpty {
            lines.append("")
            lines.append(contentsOf: focusInsight)
        }

        // --- Single-day organizer summary (compact) ---
        let meetingsWithAttendees = timedEvents.filter { $0.hasAttendees }
        if meetingsWithAttendees.count >= 2 {
            let orgCount = meetingsWithAttendees.filter { $0.isOrganizer }.count
            let attCount = meetingsWithAttendees.count - orgCount
            if orgCount > 0 && attCount > 0 {
                lines.append("")
                lines.append("👑 今天 \(orgCount) 个会议由你发起，\(attCount) 个由他人邀请。")
            }
        }

        // --- Day-over-day comparison (when user asks "今天比昨天忙吗" etc.) ---
        if let ctx = context {
            let compInsight = buildDayComparison(
                currentEvents: timedEvents,
                currentDate: date,
                range: range,
                context: ctx
            )
            if !compInsight.isEmpty {
                lines.append("")
                lines.append(contentsOf: compInsight)
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Multi-Day Response (This Week / Range)

    /// Detects whether the user's original query is focused on finding free time.
    /// "这周什么时候有空", "本周哪天比较空闲", "下周有没有空" → true
    private func isFreeTimeFocusedQuery(_ query: String) -> Bool {
        let lower = query.lowercased()
        let freeTimeKeywords = ["有空", "空闲", "空不空", "哪天空", "什么时候空",
                                "有没有空", "哪天有时间", "什么时候有时间",
                                "哪天轻松", "哪天不忙", "比较闲", "比较空",
                                "free time", "available", "which day", "when am i free"]
        return freeTimeKeywords.contains(where: { lower.contains($0) })
    }

    private func buildMultiDayResponse(events: [CalendarEventItem], range: QueryTimeRange, interval: DateInterval, spanDays: Int, context: SkillContext) -> String {
        var lines: [String] = []
        let cal = Calendar.current
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "M月d日（E）"
        dateFmt.locale = Locale(identifier: "zh_CN")

        let timedEvents = events.filter { !$0.isAllDay }
        let totalMinutes = timedEvents.reduce(0.0) { $0 + $1.duration } / 60.0

        // --- Group by day ---
        let grouped = Dictionary(grouping: events) { cal.startOfDay(for: $0.startDate) }
        let sortedDays = grouped.keys.sorted()

        let isFreeTimeFocus = isFreeTimeFocusedQuery(context.originalQuery)

        // --- Summary header ---
        if isFreeTimeFocus {
            lines.append("📅 \(range.label)空闲时间一览")
        } else {
            lines.append("📅 \(range.label)日程总览")
        }
        // Count weekend events to surface in summary
        let weekendEvents = timedEvents.filter { isWeekend($0.startDate) }
        var headerSuffix = ""
        if !weekendEvents.isEmpty {
            headerSuffix = "（其中周末 \(weekendEvents.count) 个）"
        }
        lines.append("共 \(events.count) 个事件，跨 \(spanDays) 天\(totalMinutes >= 60 ? "，约 \(formatDuration(totalMinutes)) 有安排" : "")\(headerSuffix)。")

        // --- Meeting scale breakdown (only when events have attendee data) ---
        let eventsWithAttendees = timedEvents.filter { $0.hasAttendees }
        if eventsWithAttendees.count >= 2 {
            let oneOnOnes = eventsWithAttendees.filter { $0.attendeeCount <= 2 }.count
            let smallGroup = eventsWithAttendees.filter { $0.attendeeCount > 2 && $0.attendeeCount <= 5 }.count
            let largeMeetings = eventsWithAttendees.filter { $0.attendeeCount > 5 }.count
            var scaleParts: [String] = []
            if oneOnOnes > 0 { scaleParts.append("1:1 × \(oneOnOnes)") }
            if smallGroup > 0 { scaleParts.append("小会 × \(smallGroup)") }
            if largeMeetings > 0 { scaleParts.append("大会 × \(largeMeetings)") }
            if !scaleParts.isEmpty {
                lines.append("👥 会议规模：\(scaleParts.joined(separator: "、"))")
            }
        }

        // --- Organizer vs Attendee role analysis ---
        let organizerInsight = buildOrganizerInsight(events: timedEvents, spanDays: spanDays)
        if !organizerInsight.isEmpty {
            lines.append(contentsOf: organizerInsight)
        }

        lines.append("")

        // --- Free-time-focused: show cross-day free slots prominently ---
        if isFreeTimeFocus {
            let freeOverview = buildMultiDayFreeSlots(
                grouped: grouped, interval: interval, spanDays: spanDays
            )
            if !freeOverview.isEmpty {
                lines.append(contentsOf: freeOverview)
                lines.append("")
            }
        }

        // --- Busiest day insight (by total meeting duration, not just count) ---
        if sortedDays.count > 1 && !isFreeTimeFocus {
            let dayDurations: [(day: Date, count: Int, totalMin: Double)] = sortedDays.compactMap { day in
                guard let dayEvents = grouped[day] else { return nil }
                let dayTimed = dayEvents.filter { !$0.isAllDay }
                let totalMin = dayTimed.reduce(0.0) { $0 + $1.duration } / 60.0
                return (day: day, count: dayTimed.count, totalMin: totalMin)
            }
            if let busiest = dayDurations.max(by: { $0.totalMin < $1.totalMin }),
               busiest.count > 1 {
                var busiestLine = "📊 最忙的一天：\(dateFmt.string(from: busiest.day))（\(busiest.count) 个事件"
                if busiest.totalMin >= 60 {
                    busiestLine += "，共 \(formatDuration(busiest.totalMin))"
                }
                busiestLine += "）"
                lines.append(busiestLine)
            }

            // --- Peak meeting hours analysis ---
            let peakHoursInsight = buildPeakHoursInsight(timedEvents: timedEvents, spanDays: spanDays)
            lines.append(contentsOf: peakHoursInsight)

            if !lines.last!.isEmpty { lines.append("") }
        }

        // --- Day-by-day listing ---
        let maxDisplayDays = isFreeTimeFocus ? 10 : 7
        for day in sortedDays.prefix(maxDisplayDays) {
            guard let dayEvents = grouped[day] else { continue }
            let dayTimed = dayEvents.filter { !$0.isAllDay }
            let dayBusy = busyScore(timedCount: dayTimed.count, totalMinutes: dayTimed.reduce(0.0) { $0 + $1.duration } / 60.0)
            let weekendTag = isWeekend(day) ? " 🏖️" : ""
            lines.append("📌 \(dateFmt.string(from: day)) \(dayBusy.emoji)\(weekendTag)")
            dayEvents.forEach { event in
                let recurTag = event.isRecurring ? " 🔄" : ""
                let atTag = event.attendeeLabel.map { "  \($0)" } ?? ""
                let orgTag = organizerTag(event)
                var line = "  • \(event.isAllDay ? "全天" : event.timeDisplay) \(event.title)\(recurTag)\(orgTag)\(atTag)"
                if !event.location.isEmpty { line += "  📍\(event.location)" }
                lines.append(line)
                // In free-time-focused mode, skip notes to keep output concise
                if !isFreeTimeFocus, let preview = notesPreview(event.notes) {
                    lines.append("    💬 \(preview)")
                }
            }
        }

        // --- Remaining days summary (when truncated) ---
        if sortedDays.count > maxDisplayDays {
            let remaining = Array(sortedDays.dropFirst(maxDisplayDays))
            let remainingEventCount = remaining.reduce(0) { $0 + (grouped[$1]?.count ?? 0) }
            let shortFmt = DateFormatter()
            shortFmt.dateFormat = "M/d"
            let dateList = remaining.prefix(5).map { shortFmt.string(from: $0) }.joined(separator: "、")
            let tail = remaining.count > 5 ? " 等" : ""
            lines.append("\n📋 还有 \(remaining.count) 天有安排（共 \(remainingEventCount) 个事件）：\(dateList)\(tail)")
        }

        // --- Days with no events ---
        if sortedDays.count < spanDays {
            let freeDays = spanDays - sortedDays.count
            if isFreeTimeFocus {
                // In free-time mode, identify WHICH days are free
                let freeDaysList = findFreeDates(grouped: grouped, interval: interval, spanDays: spanDays)
                if !freeDaysList.isEmpty {
                    let shortFmt = DateFormatter()
                    shortFmt.dateFormat = "M月d日（E）"
                    shortFmt.locale = Locale(identifier: "zh_CN")
                    let isFuture = interval.start >= Calendar.current.startOfDay(for: Date())
                    let futureFree = isFuture
                        ? freeDaysList.filter { $0 >= Calendar.current.startOfDay(for: Date()) }
                        : freeDaysList
                    if !futureFree.isEmpty {
                        lines.append("\n🟢 完全空闲的日子（\(futureFree.count) 天）：")
                        futureFree.prefix(7).forEach { lines.append("  • \(shortFmt.string(from: $0))") }
                        if futureFree.count > 7 {
                            lines.append("  …还有 \(futureFree.count - 7) 天")
                        }
                    } else {
                        lines.append("\n💚 其中 \(freeDays) 天没有安排，可以自由支配。")
                    }
                } else {
                    lines.append("\n💚 其中 \(freeDays) 天没有安排，可以自由支配。")
                }
            } else {
                lines.append("\n💚 其中 \(freeDays) 天没有安排，可以自由支配。")
            }
        }

        // --- Multi-day free slots (non-focus mode: appended at end) ---
        if !isFreeTimeFocus {
            let freeOverview = buildMultiDayFreeSlots(
                grouped: grouped, interval: interval, spanDays: spanDays
            )
            if !freeOverview.isEmpty {
                lines.append("")
                lines.append(contentsOf: freeOverview)
            }
        }

        // --- Multi-day schedule health: conflicts, back-to-back chains, marathon days ---
        if !isFreeTimeFocus {
            let scheduleHealth = buildMultiDayScheduleHealth(grouped: grouped, sortedDays: sortedDays, dateFmt: dateFmt)
            if !scheduleHealth.isEmpty {
                lines.append("")
                lines.append(contentsOf: scheduleHealth)
            }
        }

        // --- Recurring vs one-off event breakdown ---
        let recurringInsight = buildRecurringBreakdown(events: events, spanDays: spanDays)
        if !recurringInsight.isEmpty {
            lines.append("")
            lines.append(contentsOf: recurringInsight)
        }

        // --- Meeting type time analysis (how time is distributed across categories) ---
        if !isFreeTimeFocus {
            let meetingDiet = buildMeetingTypeDiet(events: events, spanDays: spanDays)
            if !meetingDiet.isEmpty {
                lines.append("")
                lines.append(contentsOf: meetingDiet)
            }
        }

        // --- Week-over-week comparison ---
        let comparison = buildPeriodComparison(
            currentEvents: events,
            currentInterval: interval,
            spanDays: spanDays,
            context: context
        )
        if !comparison.isEmpty {
            lines.append("")
            lines.append(contentsOf: comparison)
        }

        // --- Weekly focus & rhythm analysis ---
        let rhythmInsight = buildWeeklyRhythm(grouped: grouped, sortedDays: sortedDays, dateFmt: dateFmt, spanDays: spanDays)
        if !rhythmInsight.isEmpty {
            lines.append("")
            lines.append(contentsOf: rhythmInsight)
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Multi-Day Free Slots

    /// Identifies which days in the range have no events (completely free).
    private func findFreeDates(grouped: [Date: [CalendarEventItem]], interval: DateInterval, spanDays: Int) -> [Date] {
        let cal = Calendar.current
        let startDay = cal.startOfDay(for: interval.start)
        var freeDates: [Date] = []
        for offset in 0..<spanDays {
            guard let day = cal.date(byAdding: .day, value: offset, to: startDay) else { continue }
            let dayStart = cal.startOfDay(for: day)
            if grouped[dayStart] == nil || grouped[dayStart]?.isEmpty == true {
                freeDates.append(dayStart)
            }
        }
        return freeDates
    }

    /// Builds a cross-day free time overview: best free slots across all days in the range.
    /// Answers the core question: "When am I free this week?"
    private func buildMultiDayFreeSlots(
        grouped: [Date: [CalendarEventItem]],
        interval: DateInterval,
        spanDays: Int
    ) -> [String] {
        let cal = Calendar.current
        let now = Date()
        let startDay = cal.startOfDay(for: interval.start)

        struct DayFreeInfo {
            let date: Date
            let totalFreeMin: Double
            let longestBlockMin: Double
            let longestBlockStart: Date
            let slots: [String]  // formatted slot strings
        }

        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"
        let dayLabelFmt = DateFormatter()
        dayLabelFmt.dateFormat = "M月d日（E）"
        dayLabelFmt.locale = Locale(identifier: "zh_CN")

        var dayFreeInfos: [DayFreeInfo] = []

        for offset in 0..<spanDays {
            guard let day = cal.date(byAdding: .day, value: offset, to: startDay) else { continue }
            let dayStart = cal.startOfDay(for: day)
            let isToday = cal.isDateInToday(day)

            // Skip past days (except today)
            if !isToday && dayStart < cal.startOfDay(for: now) { continue }

            let workStart = cal.date(bySettingHour: 8, minute: 0, second: 0, of: day) ?? day
            let workEnd = cal.date(bySettingHour: 22, minute: 0, second: 0, of: day) ?? day
            let effectiveStart = (isToday && now > workStart) ? now : workStart
            guard effectiveStart < workEnd else { continue }

            let dayEvents = (grouped[dayStart] ?? []).filter { !$0.isAllDay }

            // Build occupied intervals
            let sorted = dayEvents.sorted { $0.startDate < $1.startDate }
            var occupied: [(Date, Date)] = []
            for event in sorted {
                let s = max(event.startDate, workStart)
                let e = min(event.endDate, workEnd)
                guard s < e else { continue }
                if let last = occupied.last, s <= last.1 {
                    occupied[occupied.count - 1].1 = max(last.1, e)
                } else {
                    occupied.append((s, e))
                }
            }

            // Find gaps
            var slots: [String] = []
            var totalFreeMin = 0.0
            var longestBlockMin = 0.0
            var longestBlockStart = effectiveStart
            var cursor = effectiveStart

            for (start, end) in occupied {
                if start > cursor {
                    let gapMin = start.timeIntervalSince(cursor) / 60
                    if gapMin >= 30 {
                        slots.append("\(timeFmt.string(from: cursor))–\(timeFmt.string(from: start))（\(formatDuration(gapMin))）")
                        totalFreeMin += gapMin
                        if gapMin > longestBlockMin {
                            longestBlockMin = gapMin
                            longestBlockStart = cursor
                        }
                    }
                }
                cursor = max(cursor, end)
            }
            // Tail gap
            if cursor < workEnd {
                let gapMin = workEnd.timeIntervalSince(cursor) / 60
                if gapMin >= 30 {
                    slots.append("\(timeFmt.string(from: cursor))–\(timeFmt.string(from: workEnd))（\(formatDuration(gapMin))）")
                    totalFreeMin += gapMin
                    if gapMin > longestBlockMin {
                        longestBlockMin = gapMin
                        longestBlockStart = cursor
                    }
                }
            }

            // If no events at all, the entire day is free
            if dayEvents.isEmpty {
                totalFreeMin = workEnd.timeIntervalSince(effectiveStart) / 60
                longestBlockMin = totalFreeMin
                longestBlockStart = effectiveStart
                // Don't list individual slots for fully free days — handled elsewhere
            }

            if totalFreeMin >= 30 {
                dayFreeInfos.append(DayFreeInfo(
                    date: day,
                    totalFreeMin: totalFreeMin,
                    longestBlockMin: longestBlockMin,
                    longestBlockStart: longestBlockStart,
                    slots: slots
                ))
            }
        }

        guard !dayFreeInfos.isEmpty else { return [] }

        var lines: [String] = []
        lines.append("💚 空闲时段总览：")

        // Sort by longest free block descending — most useful days first
        let bestDays = dayFreeInfos
            .filter { !$0.slots.isEmpty }
            .sorted { $0.longestBlockMin > $1.longestBlockMin }

        if bestDays.isEmpty { return [] }

        // Show top recommendation
        if let best = bestDays.first {
            let blockLabel: String
            if best.longestBlockMin >= 180 {
                blockLabel = "非常充裕"
            } else if best.longestBlockMin >= 120 {
                blockLabel = "适合深度工作"
            } else if best.longestBlockMin >= 60 {
                blockLabel = "适合中等任务"
            } else {
                blockLabel = "可处理简单事务"
            }
            lines.append("  🏆 最佳空闲日：\(dayLabelFmt.string(from: best.date)) — 连续 \(formatDuration(best.longestBlockMin)) 空闲（\(blockLabel)）")
        }

        // Per-day free slots (up to 5 days)
        for info in bestDays.prefix(5) {
            let dayLabel = dayLabelFmt.string(from: info.date)
            lines.append("  📍 \(dayLabel)：空闲 \(formatDuration(info.totalFreeMin))")
            info.slots.prefix(3).forEach { lines.append("    · \($0)") }
            if info.slots.count > 3 {
                lines.append("    …还有 \(info.slots.count - 3) 个空闲段")
            }
        }

        if bestDays.count > 5 {
            lines.append("  …还有 \(bestDays.count - 5) 天有空闲时段")
        }

        return lines
    }

    // MARK: - Recurring vs One-off Breakdown

    /// Analyzes recurring vs one-off events to show how much time is "locked in" to
    /// repeating commitments vs flexible one-time events. This helps users understand
    /// their true schedule flexibility.
    private func buildRecurringBreakdown(events: [CalendarEventItem], spanDays: Int) -> [String] {
        let timedEvents = events.filter { !$0.isAllDay }
        guard timedEvents.count >= 3 else { return [] } // Need enough events for meaningful analysis

        let recurring = timedEvents.filter { $0.isRecurring }
        let oneOff = timedEvents.filter { !$0.isRecurring }

        // Skip if there's no mix — all recurring or all one-off isn't insightful
        guard !recurring.isEmpty else { return [] }

        let recurringMinutes = recurring.reduce(0.0) { $0 + $1.duration } / 60.0
        let oneOffMinutes = oneOff.reduce(0.0) { $0 + $1.duration } / 60.0
        let totalMinutes = recurringMinutes + oneOffMinutes
        guard totalMinutes > 0 else { return [] }

        let recurringPct = Int(recurringMinutes / totalMinutes * 100)

        var lines: [String] = []
        lines.append("🔄 日程结构分析：")

        // Summary line: recurring vs one-off count and time
        lines.append("  固定日程：\(recurring.count) 个（\(formatDuration(recurringMinutes))）")
        if !oneOff.isEmpty {
            lines.append("  临时安排：\(oneOff.count) 个（\(formatDuration(oneOffMinutes))）")
        }

        // Visual bar showing recurring vs flexible ratio
        let recurBlocks = max(1, min(10, Int(Double(recurringPct) / 10.0)))
        let flexBlocks = 10 - recurBlocks
        let bar = String(repeating: "🔵", count: recurBlocks) + String(repeating: "⚪", count: flexBlocks)
        lines.append("  \(bar) 固定 \(recurringPct)%")

        // Top recurring events by total time commitment
        let recurringByTitle = Dictionary(grouping: recurring) { $0.title }
        let topRecurring = recurringByTitle
            .map { (title: $0.key, count: $0.value.count, totalMin: $0.value.reduce(0.0) { $0 + $1.duration } / 60.0) }
            .sorted { $0.totalMin > $1.totalMin }

        if topRecurring.count > 1 || (topRecurring.count == 1 && topRecurring[0].count > 1) {
            lines.append("")
            lines.append("  📌 固定日程明细：")
            for item in topRecurring.prefix(5) {
                let freq = item.count > 1 ? "×\(item.count)" : ""
                lines.append("  · \(item.title) \(freq)  \(formatDuration(item.totalMin))")
            }
        }

        // Flexibility insight
        if recurringPct >= 70 {
            // Weekly projection: if span < 7 days, extrapolate
            let weeklyRecurringHours = spanDays >= 5
                ? recurringMinutes / 60.0
                : recurringMinutes / Double(max(1, spanDays)) * 5.0
            if weeklyRecurringHours >= 15 {
                lines.append("\n  ⚠️ 固定会议每周约 \(String(format: "%.0f", weeklyRecurringHours)) 小时，灵活时间有限 — 可考虑合并或减少频次")
            } else {
                lines.append("\n  💡 大部分日程是固定安排，调整空间有限")
            }
        } else if recurringPct <= 30 && !oneOff.isEmpty {
            lines.append("\n  ✨ 日程以临时安排为主，时间灵活度较高")
        }

        return lines
    }

    // MARK: - Busy-ness Scoring

    private struct BusyLevel {
        let emoji: String
        let description: String
    }

    // MARK: - Peak Meeting Hours

    /// Analyzes which time-of-day slots are most meeting-heavy across a multi-day period.
    /// Returns lines like "⏰ 会议高峰：14:00-16:00（占 42% 的会议时间）"
    private func buildPeakHoursInsight(timedEvents: [CalendarEventItem], spanDays: Int) -> [String] {
        // Need enough data to identify patterns
        guard timedEvents.count >= 3 else { return [] }

        let cal = Calendar.current

        // Accumulate meeting minutes per hour slot (0-23)
        var hourMinutes: [Int: Double] = [:]
        for event in timedEvents {
            let startHour = cal.component(.hour, from: event.startDate)
            let startMin = cal.component(.minute, from: event.startDate)
            let endHour = cal.component(.hour, from: event.endDate)
            let endMin = cal.component(.minute, from: event.endDate)

            // Distribute event duration across hour slots it spans
            if startHour == endHour {
                // Event fits within a single hour
                hourMinutes[startHour, default: 0] += Double(endMin - startMin)
            } else {
                // First partial hour
                hourMinutes[startHour, default: 0] += Double(60 - startMin)
                // Full middle hours
                for h in (startHour + 1)..<min(endHour, 24) {
                    hourMinutes[h, default: 0] += 60
                }
                // Last partial hour
                if endHour < 24 && endMin > 0 {
                    hourMinutes[endHour, default: 0] += Double(endMin)
                }
            }
        }

        let totalMinutes = hourMinutes.values.reduce(0, +)
        guard totalMinutes >= 60 else { return [] }

        // Find peak 2-hour window by sliding window
        var bestWindow = (startHour: 0, minutes: 0.0)
        for h in 6..<22 { // business hours 6:00-23:00
            let windowMin = (hourMinutes[h] ?? 0) + (hourMinutes[h + 1] ?? 0)
            if windowMin > bestWindow.minutes {
                bestWindow = (startHour: h, minutes: windowMin)
            }
        }

        guard bestWindow.minutes >= 30 else { return [] }

        let peakPct = Int((bestWindow.minutes / totalMinutes) * 100)

        // Only show if there's meaningful concentration (>25% of meeting time in 2-hour window)
        guard peakPct >= 25 else { return [] }

        let startStr = String(format: "%02d:00", bestWindow.startHour)
        let endStr = String(format: "%02d:00", bestWindow.startHour + 2)

        var lines: [String] = []
        var peakLine = "⏰ 会议高峰：\(startStr)-\(endStr)"
        if peakPct >= 50 {
            peakLine += "（集中了 \(peakPct)% 的会议时间）"
        } else {
            peakLine += "（占 \(peakPct)% 的会议时间）"
        }
        lines.append(peakLine)

        // Add scheduling suggestion if peak is very concentrated
        if peakPct >= 60 && spanDays >= 5 {
            lines.append("  💡 会议集中度较高，可考虑在其他时段安排专注工作时间")
        }

        // Morning vs afternoon distribution
        let morningMin = (6..<12).reduce(0.0) { $0 + (hourMinutes[$1] ?? 0) }
        let afternoonMin = (12..<18).reduce(0.0) { $0 + (hourMinutes[$1] ?? 0) }
        let eveningMin = (18..<24).reduce(0.0) { $0 + (hourMinutes[$1] ?? 0) }

        if morningMin + afternoonMin + eveningMin >= 120 {
            let morningPct = Int((morningMin / totalMinutes) * 100)
            let afternoonPct = Int((afternoonMin / totalMinutes) * 100)

            if morningPct >= 65 {
                lines.append("  🌅 你的会议偏上午型，下午相对自由")
            } else if afternoonPct >= 65 {
                lines.append("  🌆 你的会议偏下午型，上午适合深度工作")
            } else if eveningMin > morningMin && eveningMin > afternoonMin {
                lines.append("  🌙 晚间会议较多，注意工作生活平衡")
            }
        }

        return lines
    }

    private func busyScore(timedCount: Int, totalMinutes: Double) -> BusyLevel {
        if timedCount == 0 {
            return BusyLevel(emoji: "🟢", description: "非常清闲")
        } else if timedCount <= 2 && totalMinutes < 180 {
            return BusyLevel(emoji: "🟢", description: "比较轻松")
        } else if timedCount <= 4 && totalMinutes < 360 {
            return BusyLevel(emoji: "🟡", description: "适中")
        } else if timedCount <= 6 && totalMinutes < 480 {
            return BusyLevel(emoji: "🟠", description: "比较忙碌")
        } else {
            return BusyLevel(emoji: "🔴", description: "非常忙碌")
        }
    }

    // MARK: - Conflict Detection

    private func detectConflicts(events: [CalendarEventItem]) -> [String] {
        let sorted = events.sorted { $0.startDate < $1.startDate }
        var conflicts: [String] = []
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"

        for i in 0..<sorted.count {
            for j in (i + 1)..<sorted.count {
                let a = sorted[i], b = sorted[j]
                if b.startDate < a.endDate {
                    let overlapStart = max(a.startDate, b.startDate)
                    let overlapEnd = min(a.endDate, b.endDate)
                    let overlapMin = Int(overlapEnd.timeIntervalSince(overlapStart) / 60)
                    if overlapMin > 0 {
                        conflicts.append("「\(a.title)」和「\(b.title)」重叠 \(overlapMin) 分钟")
                    }
                }
            }
        }
        return conflicts
    }

    // MARK: - Free Slots

    private func findFreeSlots(events: [CalendarEventItem], date: Date, onlyFuture: Bool) -> [String] {
        let cal = Calendar.current
        let now = Date()

        // Define working hours 8:00 - 22:00
        let dayStart = cal.date(bySettingHour: 8, minute: 0, second: 0, of: date) ?? date
        let dayEnd = cal.date(bySettingHour: 22, minute: 0, second: 0, of: date) ?? date

        let effectiveStart = (onlyFuture && now > dayStart) ? now : dayStart
        guard effectiveStart < dayEnd else { return [] }

        // Merge overlapping events to find occupied intervals
        let sorted = events.sorted { $0.startDate < $1.startDate }
        var occupied: [(Date, Date)] = []
        for event in sorted {
            let s = max(event.startDate, dayStart)
            let e = min(event.endDate, dayEnd)
            guard s < e else { continue }
            if let last = occupied.last, s <= last.1 {
                occupied[occupied.count - 1].1 = max(last.1, e)
            } else {
                occupied.append((s, e))
            }
        }

        // Find gaps
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"
        var slots: [String] = []
        var cursor = effectiveStart

        for (start, end) in occupied {
            if start > cursor {
                let gapMin = Int(start.timeIntervalSince(cursor) / 60)
                if gapMin >= 30 {
                    slots.append("\(timeFmt.string(from: cursor))–\(timeFmt.string(from: start))（\(formatDuration(Double(gapMin)))）")
                }
            }
            cursor = max(cursor, end)
        }

        // Final gap until end of day
        if cursor < dayEnd {
            let gapMin = Int(dayEnd.timeIntervalSince(cursor) / 60)
            if gapMin >= 30 {
                slots.append("\(timeFmt.string(from: cursor))–\(timeFmt.string(from: dayEnd))（\(formatDuration(Double(gapMin)))）")
            }
        }

        return slots
    }

    // MARK: - Deep Work & Focus Analysis

    /// Analyzes a single day's schedule for focus time quality.
    private func buildFocusInsight(events: [CalendarEventItem], date: Date, onlyFuture: Bool) -> [String] {
        let cal = Calendar.current
        let now = Date()
        let dayStart = cal.date(bySettingHour: 8, minute: 0, second: 0, of: date) ?? date
        let dayEnd = cal.date(bySettingHour: 22, minute: 0, second: 0, of: date) ?? date
        let effectiveStart = (onlyFuture && now > dayStart) ? now : dayStart
        guard effectiveStart < dayEnd else { return [] }

        let totalAvailableMin = dayEnd.timeIntervalSince(effectiveStart) / 60
        guard totalAvailableMin > 0 else { return [] }

        let meetingMin = events.reduce(0.0) { total, e in
            let s = max(e.startDate, effectiveStart)
            let e2 = min(e.endDate, dayEnd)
            return s < e2 ? total + e2.timeIntervalSince(s) / 60 : total
        }

        // Find longest uninterrupted free block
        let sorted = events.sorted { $0.startDate < $1.startDate }
        var occupied: [(Date, Date)] = []
        for event in sorted {
            let s = max(event.startDate, effectiveStart)
            let e = min(event.endDate, dayEnd)
            guard s < e else { continue }
            if let last = occupied.last, s <= last.1 {
                occupied[occupied.count - 1].1 = max(last.1, e)
            } else {
                occupied.append((s, e))
            }
        }

        var longestFreeMin = 0.0
        var longestFreeStart = effectiveStart
        var cursor = effectiveStart
        for (start, end) in occupied {
            if start > cursor {
                let gap = start.timeIntervalSince(cursor) / 60
                if gap > longestFreeMin {
                    longestFreeMin = gap
                    longestFreeStart = cursor
                }
            }
            cursor = max(cursor, end)
        }
        // Check tail gap
        if cursor < dayEnd {
            let gap = dayEnd.timeIntervalSince(cursor) / 60
            if gap > longestFreeMin {
                longestFreeMin = gap
                longestFreeStart = cursor
            }
        }

        let focusRatio = max(0, (totalAvailableMin - meetingMin)) / totalAvailableMin
        let fragmentationScore = computeFragmentation(events: events, effectiveStart: effectiveStart, dayEnd: dayEnd)

        // Classify meeting types
        let typeBreakdown = classifyMeetingTypes(events: events)

        var lines: [String] = []
        lines.append("🧠 专注力分析：")

        // Focus ratio bar
        let filledBlocks = Int(focusRatio * 10)
        let bar = String(repeating: "▓", count: filledBlocks) + String(repeating: "░", count: 10 - filledBlocks)
        lines.append("  专注时间占比：[\(bar)] \(Int(focusRatio * 100))%")

        // Longest deep work block
        if longestFreeMin >= 30 {
            let timeFmt = DateFormatter()
            timeFmt.dateFormat = "HH:mm"
            let blockLabel: String
            if longestFreeMin >= 120 {
                blockLabel = "🟢 非常适合深度工作"
            } else if longestFreeMin >= 60 {
                blockLabel = "🟡 可做中等难度任务"
            } else {
                blockLabel = "🟠 仅够处理简单事务"
            }
            lines.append("  最长连续空闲：\(formatDuration(longestFreeMin))（\(timeFmt.string(from: longestFreeStart)) 起）\(blockLabel)")
        } else if events.isEmpty {
            lines.append("  整天都是自由时间，适合安排深度工作 🟢")
        } else {
            lines.append("  ⚠️ 没有超过 30 分钟的连续空闲，难以进入专注状态")
        }

        // Fragmentation insight
        if events.count >= 2 {
            let fragDesc: String
            if fragmentationScore < 0.3 {
                fragDesc = "日程集中，上下文切换少 👍"
            } else if fragmentationScore < 0.6 {
                fragDesc = "日程较分散，注意切换成本"
            } else {
                fragDesc = "日程非常碎片化，建议合并或移动会议 ⚠️"
            }
            lines.append("  碎片化程度：\(fragDesc)")
        }

        // Meeting type breakdown
        if !typeBreakdown.isEmpty && events.count >= 2 {
            let typeStr = typeBreakdown.map { "\($0.value)个\($0.key)" }.joined(separator: "、")
            lines.append("  会议类型：\(typeStr)")
        }

        return lines
    }

    /// Computes fragmentation: how scattered meetings are across the day.
    /// Returns 0.0 (all clustered) to 1.0 (maximally fragmented).
    private func computeFragmentation(events: [CalendarEventItem], effectiveStart: Date, dayEnd: Date) -> Double {
        let sorted = events.filter {
            max($0.startDate, effectiveStart) < min($0.endDate, dayEnd)
        }.sorted { $0.startDate < $1.startDate }
        guard sorted.count >= 2 else { return 0 }

        let totalSpan = dayEnd.timeIntervalSince(effectiveStart)
        guard totalSpan > 0 else { return 0 }

        // Count gaps between meetings (not counting before first or after last)
        var gapSum: TimeInterval = 0
        var gapCount = 0
        for i in 0..<(sorted.count - 1) {
            let gap = sorted[i + 1].startDate.timeIntervalSince(sorted[i].endDate)
            if gap > 0 {
                gapSum += gap
                gapCount += 1
            }
        }

        guard gapCount > 0 else { return 0 }
        // Fragmentation = (inter-meeting gap time / total span) * number of context switches
        let gapRatio = gapSum / totalSpan
        let switchFactor = min(Double(gapCount) / 5.0, 1.0) // normalize: 5+ switches = max
        return min(gapRatio * 0.5 + switchFactor * 0.5, 1.0)
    }

    /// Classifies a single event into a meeting type category by parsing its title.
    /// Covers common patterns in both Chinese and English work environments.
    private func classifyEventType(_ title: String) -> String {
        let t = title.lowercased()
        // Standup / daily sync
        if t.contains("standup") || t.contains("站会") || t.contains("晨会")
            || t.contains("daily") || t.contains("早会") || t.contains("日会")
            || t.contains("morning sync") {
            return "站会/日常"
        }
        // 1:1 / one-on-one
        if t.contains("1:1") || t.contains("1v1") || t.contains("one on one")
            || t.contains("单聊") || t.contains("一对一") || t.contains("1-on-1") {
            return "1:1"
        }
        // Review / retro
        if t.contains("review") || t.contains("评审") || t.contains("复盘")
            || t.contains("回顾") || t.contains("retro") || t.contains("retrospective")
            || t.contains("代码审查") || t.contains("code review") || t.contains("demo") {
            return "评审/回顾"
        }
        // Interview
        if t.contains("面试") || t.contains("interview") || t.contains("候选人") {
            return "面试"
        }
        // Training / sharing / workshop
        if t.contains("培训") || t.contains("training") || t.contains("workshop")
            || t.contains("分享") || t.contains("讲座") || t.contains("tech talk")
            || t.contains("brown bag") || t.contains("learning") || t.contains("学习") {
            return "培训/分享"
        }
        // Sync / alignment
        if t.contains("sync") || t.contains("同步") || t.contains("对齐")
            || t.contains("沟通") || t.contains("碰头") || t.contains("touch base")
            || t.contains("check-in") || t.contains("check in") || t.contains("catchup")
            || t.contains("catch up") || t.contains("catch-up") {
            return "同步会"
        }
        // Planning / sprint
        if t.contains("planning") || t.contains("规划") || t.contains("sprint")
            || t.contains("kickoff") || t.contains("kick-off") || t.contains("启动")
            || t.contains("排期") || t.contains("迭代") || t.contains("iteration") {
            return "规划会"
        }
        // All-hands / team meeting
        if t.contains("all-hands") || t.contains("all hands") || t.contains("全员")
            || t.contains("team meeting") || t.contains("部门会") || t.contains("周会")
            || t.contains("月会") || t.contains("例会") || t.contains("组会") {
            return "团队例会"
        }
        // Design / brainstorm
        if t.contains("design") || t.contains("brainstorm") || t.contains("头脑风暴")
            || t.contains("设计") || t.contains("方案") || t.contains("讨论") {
            return "讨论/脑暴"
        }
        // Lunch / social
        if t.contains("lunch") || t.contains("午餐") || t.contains("dinner")
            || t.contains("晚餐") || t.contains("聚餐") || t.contains("团建")
            || t.contains("social") || t.contains("happy hour") || t.contains("下午茶") {
            return "社交/聚餐"
        }
        return "其他会议"
    }

    /// Classifies meeting types by parsing event titles (count-based, for single-day view).
    private func classifyMeetingTypes(events: [CalendarEventItem]) -> [String: Int] {
        var types: [String: Int] = [:]
        for event in events {
            let type = classifyEventType(event.title)
            types[type, default: 0] += 1
        }
        return types
    }

    // MARK: - Meeting Type Time Analysis (Multi-Day)

    /// Represents a meeting type's aggregate stats across a multi-day period.
    private struct MeetingTypeStat {
        let type: String
        var count: Int
        var totalMinutes: Double
    }

    /// Builds a meeting type time analysis for multi-day calendar views.
    /// Shows how the user's time is distributed across different meeting categories,
    /// revealing patterns like "60% of your meeting time goes to syncs" or "1:1s only 10%".
    private func buildMeetingTypeDiet(events: [CalendarEventItem], spanDays: Int) -> [String] {
        let timedEvents = events.filter { !$0.isAllDay }
        // Need at least 4 timed events for a meaningful breakdown
        guard timedEvents.count >= 4 else { return [] }

        // Aggregate count + duration per type
        var statsMap: [String: MeetingTypeStat] = [:]
        for event in timedEvents {
            let type = classifyEventType(event.title)
            let durationMin = event.duration / 60.0
            if var stat = statsMap[type] {
                stat.count += 1
                stat.totalMinutes += durationMin
                statsMap[type] = stat
            } else {
                statsMap[type] = MeetingTypeStat(type: type, count: 1, totalMinutes: durationMin)
            }
        }

        let totalMeetingMin = timedEvents.reduce(0.0) { $0 + $1.duration } / 60.0
        guard totalMeetingMin > 0 else { return [] }

        // Sort by total time descending
        let sorted = statsMap.values.sorted { $0.totalMinutes > $1.totalMinutes }

        // Skip if everything is "其他会议" — no meaningful classification
        if sorted.count == 1 && sorted[0].type == "其他会议" { return [] }

        var lines: [String] = []
        lines.append("📊 会议类型分布：")

        // Show each type with visual bar, percentage, and time
        for stat in sorted {
            let pct = Int(stat.totalMinutes / totalMeetingMin * 100)
            let barBlocks = max(1, min(8, Int(Double(pct) / 12.5)))
            let bar = String(repeating: "▓", count: barBlocks) + String(repeating: "░", count: 8 - barBlocks)
            let timeStr = formatDuration(stat.totalMinutes)
            let countStr = stat.count > 1 ? "×\(stat.count)" : ""
            lines.append("  [\(bar)] \(stat.type) \(pct)%  \(timeStr)\(countStr)")
        }

        // Insight: identify dominant category and suggest balance
        if let top = sorted.first, sorted.count >= 2 {
            let topPct = Int(top.totalMinutes / totalMeetingMin * 100)

            if topPct >= 50 {
                let insight: String
                switch top.type {
                case "站会/日常":
                    insight = "日常会议占比过半，可考虑缩短时长或合并频次"
                case "同步会":
                    insight = "超过一半时间在同步信息 — 试试异步沟通（文档/消息）替代部分同步会"
                case "1:1":
                    insight = "1:1 投入充分，关系维护做得好 👍"
                case "评审/回顾":
                    insight = "评审时间占比高，确保每次评审都有明确产出"
                case "面试":
                    insight = "面试投入大量时间，注意平衡日常工作"
                case "团队例会":
                    insight = "例会时间较多，确认是否每场都需要参加"
                case "讨论/脑暴":
                    insight = "讨论时间充裕，记得及时将想法转化为行动"
                default:
                    insight = "\(top.type)占据了大部分会议时间"
                }
                lines.append("  💡 \(insight)")
            }

            // Check for missing 1:1s in a busy schedule
            let has1on1 = sorted.contains { $0.type == "1:1" }
            if !has1on1 && timedEvents.count >= 8 && spanDays >= 5 {
                lines.append("  💬 本周没有 1:1，工作忙碌之余也别忘了和团队成员单独沟通")
            }

            // Check weekly meeting hours burden
            if spanDays >= 5 {
                let weeklyHours = totalMeetingMin / 60.0
                let weeklyProjection = spanDays >= 5 ? weeklyHours : weeklyHours / Double(spanDays) * 5
                if weeklyProjection >= 25 {
                    lines.append("  ⚠️ 每周约 \(String(format: "%.0f", weeklyProjection)) 小时在会议中 — 仅剩不到 50% 时间做实际工作")
                } else if weeklyProjection >= 15 {
                    lines.append("  📈 每周约 \(String(format: "%.0f", weeklyProjection)) 小时会议，在可控范围内")
                }
            }
        }

        return lines
    }

    /// Analyzes multi-day schedule rhythm: per-day focus time, best day for deep work.
    private func buildWeeklyRhythm(grouped: [Date: [CalendarEventItem]], sortedDays: [Date], dateFmt: DateFormatter, spanDays: Int) -> [String] {
        guard spanDays > 1 else { return [] }

        let cal = Calendar.current
        var dayFocusData: [(date: Date, focusRatio: Double, longestBlock: Double, meetingCount: Int)] = []

        // Analyze all days in the span (including days with no events)
        let firstDay = sortedDays.first ?? Date()
        for offset in 0..<spanDays {
            guard let day = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: firstDay)) else { continue }
            let dayStart = cal.date(bySettingHour: 8, minute: 0, second: 0, of: day) ?? day
            let dayEnd = cal.date(bySettingHour: 22, minute: 0, second: 0, of: day) ?? day
            let totalMin = dayEnd.timeIntervalSince(dayStart) / 60

            let dayEvents = (grouped[cal.startOfDay(for: day)] ?? []).filter { !$0.isAllDay }
            let meetingMin = dayEvents.reduce(0.0) { total, e in
                let s = max(e.startDate, dayStart)
                let e2 = min(e.endDate, dayEnd)
                return s < e2 ? total + e2.timeIntervalSince(s) / 60 : total
            }

            let focusRatio = totalMin > 0 ? max(0, (totalMin - meetingMin)) / totalMin : 1.0

            // Longest free block
            let sorted = dayEvents.sorted { $0.startDate < $1.startDate }
            var occupied: [(Date, Date)] = []
            for event in sorted {
                let s = max(event.startDate, dayStart)
                let e = min(event.endDate, dayEnd)
                guard s < e else { continue }
                if let last = occupied.last, s <= last.1 {
                    occupied[occupied.count - 1].1 = max(last.1, e)
                } else {
                    occupied.append((s, e))
                }
            }
            var longest = 0.0
            var cursor = dayStart
            for (start, end) in occupied {
                if start > cursor {
                    longest = max(longest, start.timeIntervalSince(cursor) / 60)
                }
                cursor = max(cursor, end)
            }
            if cursor < dayEnd {
                longest = max(longest, dayEnd.timeIntervalSince(cursor) / 60)
            }

            dayFocusData.append((day, focusRatio, longest, dayEvents.count))
        }

        guard !dayFocusData.isEmpty else { return [] }

        var lines: [String] = []
        lines.append("🧠 本周专注力节奏：")

        // Per-day focus bar visualization
        let shortFmt = DateFormatter()
        shortFmt.dateFormat = "E"
        shortFmt.locale = Locale(identifier: "zh_CN")

        for data in dayFocusData.prefix(7) {
            let blocks = Int(data.focusRatio * 8)
            let bar = String(repeating: "▓", count: blocks) + String(repeating: "░", count: 8 - blocks)
            let dayLabel = shortFmt.string(from: data.date)
            let meetingNote = data.meetingCount > 0 ? " \(data.meetingCount)个会" : " 无会议"
            lines.append("  \(dayLabel) [\(bar)] \(Int(data.focusRatio * 100))%\(meetingNote)")
        }

        // Best day for deep work (longest continuous free block)
        if let bestDay = dayFocusData.max(by: { $0.longestBlock < $1.longestBlock }),
           bestDay.longestBlock >= 60 {
            lines.append("\n  💡 最适合深度工作：\(dateFmt.string(from: bestDay.date))（连续 \(formatDuration(bestDay.longestBlock)) 空闲）")
        }

        // Weekly meeting load
        let totalMeetings = dayFocusData.reduce(0) { $0 + $1.meetingCount }
        let avgFocus = dayFocusData.reduce(0.0) { $0 + $1.focusRatio } / Double(dayFocusData.count)
        if totalMeetings > 0 {
            let verdict: String
            if avgFocus >= 0.7 {
                verdict = "整体节奏健康，专注时间充裕 👍"
            } else if avgFocus >= 0.5 {
                verdict = "会议占比适中，注意保护连续空闲"
            } else {
                verdict = "会议过密，建议合并或推迟部分会议 ⚠️"
            }
            lines.append("  📊 平均专注率 \(Int(avgFocus * 100))%，\(verdict)")
        }

        // Weekday vs weekend balance insight
        let weekdayData = dayFocusData.filter { !isWeekend($0.date) }
        let weekendData = dayFocusData.filter { isWeekend($0.date) }
        let weekendMeetings = weekendData.reduce(0) { $0 + $1.meetingCount }
        let weekdayMeetings = weekdayData.reduce(0) { $0 + $1.meetingCount }
        if weekendMeetings > 0 && !weekendData.isEmpty {
            let weekendAvg = Double(weekendMeetings) / Double(weekendData.count)
            let weekdayAvg = weekdayData.isEmpty ? 0 : Double(weekdayMeetings) / Double(weekdayData.count)
            if weekendMeetings >= 3 {
                lines.append("  🏖️ 周末有 \(weekendMeetings) 个会议，休息时间被压缩 — 注意工作生活平衡")
            } else if weekdayAvg > 0 && weekendAvg >= weekdayAvg * 0.8 {
                lines.append("  🏖️ 周末日程密度接近工作日，建议适当减少周末安排")
            } else {
                lines.append("  🏖️ 周末有少量安排（\(weekendMeetings) 个），整体节奏合理")
            }
        } else if !weekendData.isEmpty && weekendMeetings == 0 && totalMeetings > 0 {
            lines.append("  🏖️ 周末完全空闲，工作生活边界清晰 👍")
        }

        return lines
    }

    // MARK: - Day-over-Day Comparison

    /// Compares a single day's calendar load against the previous day.
    /// Triggered when the user's query contains comparison keywords routed from SkillRouter
    /// (e.g., "今天比昨天忙吗", "明天比今天安排多吗").
    private func buildDayComparison(
        currentEvents: [CalendarEventItem],
        currentDate: Date,
        range: QueryTimeRange,
        context: SkillContext
    ) -> [String] {
        // Only trigger when the user's query has comparison intent
        let query = context.originalQuery.lowercased()
        let comparisonKeywords = ["比昨天", "比前天", "比今天", "比上周", "比之前", "比以前",
                                  "跟昨天比", "和昨天比", "跟前天比", "和前天比", "跟今天比", "和今天比",
                                  "对比", "比较", "更忙", "更闲", "更空",
                                  "compared", "busier", "less busy"]
        guard comparisonKeywords.contains(where: { query.contains($0) }) else { return [] }

        // Determine the comparison day
        let cal = Calendar.current
        let prevDate: Date
        let prevLabel: String
        if query.contains("比前天") || query.contains("跟前天") || query.contains("和前天") {
            prevDate = cal.date(byAdding: .day, value: -2, to: cal.startOfDay(for: currentDate))!
            prevLabel = "前天"
        } else if range == .tomorrow {
            // "明天比今天忙吗" → compare tomorrow vs today
            prevDate = cal.startOfDay(for: Date())
            prevLabel = "今天"
        } else {
            // Default: compare with previous day
            prevDate = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: currentDate))!
            prevLabel = range == .today ? "昨天" : "前一天"
        }

        let prevEnd = cal.date(byAdding: .day, value: 1, to: prevDate)!
        let prevEvents = context.calendarService.fetchEvents(from: prevDate, to: prevEnd)
            .filter { !$0.isAllDay }

        let curCount = currentEvents.count
        let prevCount = prevEvents.count
        let curMinutes = currentEvents.reduce(0.0) { $0 + $1.duration } / 60.0
        let prevMinutes = prevEvents.reduce(0.0) { $0 + $1.duration } / 60.0

        // Skip if both days are empty
        guard curCount > 0 || prevCount > 0 else { return [] }

        var lines: [String] = ["📈 与\(prevLabel)对比："]

        // Event count comparison
        let countDiff = curCount - prevCount
        if countDiff > 0 {
            lines.append("  • 日程数：\(curCount) 个（比\(prevLabel)多 \(countDiff) 个）")
        } else if countDiff < 0 {
            lines.append("  • 日程数：\(curCount) 个（比\(prevLabel)少 \(-countDiff) 个）")
        } else {
            lines.append("  • 日程数：\(curCount) 个（与\(prevLabel)相同）")
        }

        // Meeting time comparison
        let timeDiff = curMinutes - prevMinutes
        if abs(timeDiff) >= 15 {
            let direction = timeDiff > 0 ? "多" : "少"
            lines.append("  • 安排时长：\(formatDuration(curMinutes))（比\(prevLabel)\(direction) \(formatDuration(abs(timeDiff)))）")
        }

        // Overall busyness verdict
        if curCount == 0 && prevCount > 0 {
            lines.append("  💚 \(range.label)完全空闲，比\(prevLabel)轻松多了！")
        } else if curCount > 0 && prevCount == 0 {
            lines.append("  📋 \(prevLabel)没有日程，\(range.label)则有 \(curCount) 个安排")
        } else if curMinutes > prevMinutes * 1.5 && prevMinutes > 30 {
            lines.append("  ⚡ \(range.label)比\(prevLabel)忙了不少，注意安排好节奏")
        } else if curMinutes < prevMinutes * 0.5 && curMinutes > 0 {
            lines.append("  💚 \(range.label)比\(prevLabel)从容，可以安排深度工作")
        }

        return lines
    }

    // MARK: - Period-over-Period Comparison

    /// Compares current period's calendar load against the previous period of equal length.
    /// e.g. "本周" vs last week, "过去7天" vs the 7 days before that.
    private func buildPeriodComparison(
        currentEvents: [CalendarEventItem],
        currentInterval: DateInterval,
        spanDays: Int,
        context: SkillContext
    ) -> [String] {
        // Only compare for ranges of 3–31 days (skip single-day or very long ranges)
        guard spanDays >= 3, spanDays <= 31 else { return [] }

        // Compute previous period of same length
        let cal = Calendar.current
        guard let prevStart = cal.date(byAdding: .day, value: -spanDays, to: currentInterval.start) else { return [] }
        let prevEnd = currentInterval.start

        let prevEvents = context.calendarService.fetchEvents(from: prevStart, to: prevEnd)

        // Current period stats
        let curTimed = currentEvents.filter { !$0.isAllDay }
        let curMeetingMin = curTimed.reduce(0.0) { $0 + $1.duration } / 60.0
        let curCount = curTimed.count

        // Previous period stats
        let prevTimed = prevEvents.filter { !$0.isAllDay }
        let prevMeetingMin = prevTimed.reduce(0.0) { $0 + $1.duration } / 60.0
        let prevCount = prevTimed.count

        // Skip comparison if previous period was completely empty
        guard prevCount > 0 || curCount > 0 else { return [] }
        // If both periods are identical (unlikely but possible with 0 events), skip
        guard prevCount > 0 else {
            // Previous had nothing, current has something — just note it
            return ["📈 上个同期没有日程记录，本期有 \(curCount) 个安排。"]
        }

        var lines: [String] = []
        lines.append("📈 与上期对比：")

        // Event count delta
        let countDelta = curCount - prevCount
        let countPct = prevCount > 0 ? abs(countDelta) * 100 / prevCount : 0
        let countArrow: String
        if countDelta > 0 {
            countArrow = "↑ 增加 \(countDelta) 个"
            if countPct >= 30 { lines.append("  • 日程数：\(curCount) 个（\(countArrow)，+\(countPct)%）⚠️ 明显增多") }
            else { lines.append("  • 日程数：\(curCount) 个（\(countArrow)）") }
        } else if countDelta < 0 {
            countArrow = "↓ 减少 \(abs(countDelta)) 个"
            if countPct >= 30 { lines.append("  • 日程数：\(curCount) 个（\(countArrow)，-\(countPct)%）👍 更从容") }
            else { lines.append("  • 日程数：\(curCount) 个（\(countArrow)）") }
        } else {
            lines.append("  • 日程数：\(curCount) 个（与上期持平）")
        }

        // Meeting time delta
        let timeDelta = curMeetingMin - prevMeetingMin
        let timePct = prevMeetingMin > 0 ? Int(abs(timeDelta) / prevMeetingMin * 100) : 0
        if abs(timeDelta) >= 30 { // Only show if difference is >= 30 min
            let timeDir: String
            if timeDelta > 0 {
                timeDir = "多了 \(formatDuration(abs(timeDelta)))"
            } else {
                timeDir = "少了 \(formatDuration(abs(timeDelta)))"
            }
            lines.append("  • 会议时长：\(formatDuration(curMeetingMin))（比上期\(timeDir)\(timePct >= 20 ? "，\(timeDelta > 0 ? "+" : "-")\(timePct)%" : "")）")
        }

        // Average meetings per day comparison
        let curAvg = Double(curCount) / Double(spanDays)
        let prevAvg = Double(prevCount) / Double(spanDays)
        if curAvg >= 3 && curAvg > prevAvg * 1.3 {
            lines.append("  • ⚡ 日均 \(String(format: "%.1f", curAvg)) 个会议，节奏偏紧，注意留出休息时间")
        } else if curAvg < prevAvg * 0.7 && prevAvg >= 2 {
            lines.append("  • 💚 日均会议从 \(String(format: "%.1f", prevAvg)) 降到 \(String(format: "%.1f", curAvg))，有更多自由时间")
        }

        // Overall trend summary
        if countDelta > 2 && timeDelta > 60 {
            lines.append("  📊 整体趋势：日程明显加密，建议关注精力管理")
        } else if countDelta < -2 && timeDelta < -60 {
            lines.append("  📊 整体趋势：节奏放缓，适合安排深度工作或个人项目")
        }

        return lines
    }

    // MARK: - Helpers

    private func formatDuration(_ minutes: Double) -> String {
        let h = Int(minutes) / 60
        let m = Int(minutes) % 60
        if h > 0 && m > 0 { return "\(h) 小时 \(m) 分钟" }
        if h > 0 { return "\(h) 小时" }
        return "\(m) 分钟"
    }

    private func calendarTag(_ calendar: String) -> String {
        calendar.isEmpty ? "" : "  [\(calendar)]"
    }

    /// Returns a small organizer badge for events the user organized.
    /// Only shown when the event has attendees (to distinguish from personal events).
    private func organizerTag(_ event: CalendarEventItem) -> String {
        event.isOrganizer && event.hasAttendees ? " 👑" : ""
    }

    // MARK: - Organizer Role Analysis

    /// Analyzes the user's role across multi-day events: organizer vs attendee.
    /// Surfaces how much meeting time the user controls, average duration differences,
    /// and actionable insights about meeting ownership patterns.
    private func buildOrganizerInsight(events: [CalendarEventItem], spanDays: Int) -> [String] {
        // Only analyze events with attendee data (skip personal/all-day events)
        let meetingEvents = events.filter { $0.hasAttendees && !$0.isAllDay }
        guard meetingEvents.count >= 3 else { return [] }

        let organized = meetingEvents.filter { $0.isOrganizer }
        let attended = meetingEvents.filter { !$0.isOrganizer }

        // Skip if all organized or all attended — no meaningful role contrast
        guard !organized.isEmpty && !attended.isEmpty else {
            // Still show a summary if all organized (user is a heavy meeting creator)
            if organized.count >= 3 && attended.isEmpty {
                let totalMin = organized.reduce(0.0) { $0 + $1.duration } / 60.0
                return ["👑 全部 \(organized.count) 个会议都由你发起（共 \(formatDuration(totalMin))）— 你是主要的会议组织者"]
            }
            return []
        }

        var lines: [String] = []
        lines.append("👑 会议角色分析：")

        let organizedMin = organized.reduce(0.0) { $0 + $1.duration } / 60.0
        let attendedMin = attended.reduce(0.0) { $0 + $1.duration } / 60.0
        let totalMin = organizedMin + attendedMin

        // Role distribution with visual bar
        let orgPct = Int(organizedMin / totalMin * 100)
        let orgBlocks = max(1, min(10, Int(Double(orgPct) / 10.0)))
        let attBlocks = 10 - orgBlocks
        let bar = String(repeating: "👑", count: orgBlocks) + String(repeating: "·", count: attBlocks)
        lines.append("  [\(bar)] 发起 \(orgPct)%")
        lines.append("  发起 \(organized.count) 个（\(formatDuration(organizedMin))）· 参加 \(attended.count) 个（\(formatDuration(attendedMin))）")

        // Average duration comparison — do organized meetings tend to be longer?
        let avgOrgMin = organizedMin / Double(organized.count)
        let avgAttMin = attendedMin / Double(attended.count)
        if abs(avgOrgMin - avgAttMin) >= 10 {
            if avgOrgMin > avgAttMin {
                lines.append("  ⏱ 你发起的会议平均 \(Int(avgOrgMin)) 分钟，比参加的（\(Int(avgAttMin)) 分钟）更长")
            } else {
                lines.append("  ⏱ 你参加的会议平均 \(Int(avgAttMin)) 分钟，比你发起的（\(Int(avgOrgMin)) 分钟）更长")
            }
        }

        // Attendee scale comparison — do organized meetings tend to be larger or smaller?
        let orgAvgAttendees = organized.reduce(0) { $0 + $1.attendeeCount } / organized.count
        let attAvgAttendees = attended.filter { $0.attendeeCount > 0 }.isEmpty ? 0 :
            attended.filter { $0.attendeeCount > 0 }.reduce(0) { $0 + $1.attendeeCount } / attended.filter { $0.attendeeCount > 0 }.count
        if orgAvgAttendees > 0 && attAvgAttendees > 0 && abs(orgAvgAttendees - attAvgAttendees) >= 2 {
            if orgAvgAttendees > attAvgAttendees {
                lines.append("  👥 你发起的会议规模更大（平均 \(orgAvgAttendees) 人 vs \(attAvgAttendees) 人）")
            } else {
                lines.append("  👥 你参加的会议规模更大（平均 \(attAvgAttendees) 人 vs \(orgAvgAttendees) 人）")
            }
        }

        // Actionable insight based on organizer ratio
        if orgPct >= 60 {
            lines.append("  💡 你主导了大部分会议 — 如果感到时间紧张，可以考虑缩短或委托部分会议")
        } else if orgPct <= 25 {
            lines.append("  💡 大部分会议由他人发起 — 评估哪些是必须参加的，适当拒绝低优先级邀请")
        }

        // Check if organized meetings cluster on specific days (meeting-heavy organizer days)
        if organized.count >= 3 && spanDays >= 5 {
            let cal = Calendar.current
            let orgDays = Dictionary(grouping: organized) { cal.startOfDay(for: $0.startDate) }
            if let busiestDay = orgDays.max(by: { $0.value.count < $1.value.count }),
               busiestDay.value.count >= 3 {
                let dateFmt = DateFormatter()
                dateFmt.dateFormat = "E"
                dateFmt.locale = Locale(identifier: "zh_CN")
                lines.append("  📅 \(dateFmt.string(from: busiestDay.key))集中发起了 \(busiestDay.value.count) 个会议 — 可以分散到其他天减轻负担")
            }
        }

        return lines
    }

    // MARK: - Back-to-Back & Location Change Detection

    /// Detects back-to-back meetings (gap < 15 min) and location changes between consecutive events.
    private func detectScheduleWarnings(events: [CalendarEventItem]) -> [String] {
        let sorted = events.sorted { $0.startDate < $1.startDate }
        guard sorted.count >= 2 else { return [] }

        var warnings: [String] = []
        var backToBackCount = 0

        for i in 0..<(sorted.count - 1) {
            let current = sorted[i]
            let next = sorted[i + 1]
            let gapMinutes = Int(next.startDate.timeIntervalSince(current.endDate) / 60)

            // Back-to-back: gap < 15 minutes (but not overlapping, which is a conflict)
            if gapMinutes >= 0 && gapMinutes < 15 {
                backToBackCount += 1
                let gapDesc = gapMinutes <= 0 ? "无间隔" : "仅隔 \(gapMinutes) 分钟"
                warnings.append("「\(current.title)」→「\(next.title)」\(gapDesc)，注意安排休息")

                // Location change with tight schedule
                if !current.location.isEmpty && !next.location.isEmpty
                    && current.location != next.location {
                    warnings.append("  ↳ 地点变化：\(current.location) → \(next.location)，请预留路程时间")
                }
            }
        }

        if backToBackCount >= 3 {
            warnings.insert("⚡ 有 \(backToBackCount) 组连续日程，注意节奏", at: 0)
        }

        return warnings
    }

    // MARK: - Multi-Day Schedule Health

    /// Aggregates schedule warnings across multiple days: conflicts, back-to-back chains,
    /// and "marathon days" (days where meetings fill most of the working hours with no break ≥30min).
    /// Surfaces the information that single-day views show per-day but multi-day views previously missed.
    private func buildMultiDayScheduleHealth(
        grouped: [Date: [CalendarEventItem]],
        sortedDays: [Date],
        dateFmt: DateFormatter
    ) -> [String] {
        var lines: [String] = []
        let cal = Calendar.current

        // Track totals across all days
        var totalConflicts = 0
        var totalBackToBack = 0
        var conflictDays: [String] = []       // day labels with conflicts
        var marathonDays: [String] = []       // days with no ≥30min break in working hours
        var backToBackDays: [String] = []     // days with ≥2 back-to-back pairs

        for day in sortedDays {
            guard let dayEvents = grouped[day] else { continue }
            let timed = dayEvents.filter { !$0.isAllDay }
            guard timed.count >= 2 else { continue }

            let sorted = timed.sorted { $0.startDate < $1.startDate }
            let dayLabel = dateFmt.string(from: day)

            // --- Conflicts on this day ---
            var dayConflictCount = 0
            for i in 0..<sorted.count {
                for j in (i + 1)..<sorted.count {
                    let a = sorted[i], b = sorted[j]
                    if b.startDate < a.endDate {
                        let overlapEnd = min(a.endDate, b.endDate)
                        let overlapMin = Int(overlapEnd.timeIntervalSince(b.startDate) / 60)
                        if overlapMin > 0 { dayConflictCount += 1 }
                    }
                }
            }
            if dayConflictCount > 0 {
                totalConflicts += dayConflictCount
                conflictDays.append(dayLabel)
            }

            // --- Back-to-back on this day ---
            var dayBackToBack = 0
            for i in 0..<(sorted.count - 1) {
                let gapMin = Int(sorted[i + 1].startDate.timeIntervalSince(sorted[i].endDate) / 60)
                if gapMin >= 0 && gapMin < 15 {
                    dayBackToBack += 1
                }
            }
            if dayBackToBack > 0 {
                totalBackToBack += dayBackToBack
                if dayBackToBack >= 2 {
                    backToBackDays.append(dayLabel)
                }
            }

            // --- Marathon day detection (no ≥30min break during 9:00-18:00) ---
            let dayStart = cal.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
            let dayEnd = cal.date(bySettingHour: 18, minute: 0, second: 0, of: day) ?? day
            let workHourEvents = sorted.filter { $0.endDate > dayStart && $0.startDate < dayEnd }
            if workHourEvents.count >= 3 {
                // Merge overlapping intervals
                var occupied: [(Date, Date)] = []
                for event in workHourEvents {
                    let s = max(event.startDate, dayStart)
                    let e = min(event.endDate, dayEnd)
                    guard s < e else { continue }
                    if let last = occupied.last, s <= last.1 {
                        occupied[occupied.count - 1].1 = max(last.1, e)
                    } else {
                        occupied.append((s, e))
                    }
                }

                // Check for any ≥30min gap
                var hasLongBreak = false
                var cursor = dayStart
                for (start, end) in occupied {
                    let gapMin = start.timeIntervalSince(cursor) / 60
                    if gapMin >= 30 { hasLongBreak = true; break }
                    cursor = end
                }
                // Check gap after last meeting until end of work hours
                if !hasLongBreak {
                    let tailGapMin = dayEnd.timeIntervalSince(cursor) / 60
                    if tailGapMin >= 30 { hasLongBreak = true }
                }
                if !hasLongBreak {
                    marathonDays.append(dayLabel)
                }
            }
        }

        // Only show if there's something noteworthy
        guard totalConflicts > 0 || !marathonDays.isEmpty || totalBackToBack >= 3 else { return [] }

        lines.append("⚠️ 日程健康提醒：")

        if totalConflicts > 0 {
            let dayList = conflictDays.prefix(3).joined(separator: "、")
            let suffix = conflictDays.count > 3 ? " 等" : ""
            lines.append("  🔴 \(totalConflicts) 处时间冲突（\(dayList)\(suffix)）— 建议调整或选择优先级")
        }

        if !marathonDays.isEmpty {
            let dayList = marathonDays.prefix(3).joined(separator: "、")
            let suffix = marathonDays.count > 3 ? " 等" : ""
            lines.append("  🟠 \(dayList)\(suffix) 工作时段几乎无休，注意安排短暂休息")
        }

        if totalBackToBack >= 3 {
            if !backToBackDays.isEmpty {
                let dayList = backToBackDays.prefix(3).joined(separator: "、")
                lines.append("  🟡 \(totalBackToBack) 组连续日程（密集日：\(dayList)），留意精力分配")
            } else {
                lines.append("  🟡 \(totalBackToBack) 组连续日程，留意精力分配")
            }
        }

        return lines
    }

    // MARK: - Notes Preview

    /// Returns a truncated preview of event notes, or nil if empty.
    private func notesPreview(_ notes: String) -> String? {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Collapse newlines to spaces, take first 50 characters
        let singleLine = trimmed.components(separatedBy: .newlines).joined(separator: " ")
        if singleLine.count <= 50 { return singleLine }
        return String(singleLine.prefix(47)) + "..."
    }

    // MARK: - Tomorrow Preparation (Cross-Data Insight)

    /// Builds a preparation note for tomorrow's calendar view.
    /// Uses today's sleep, activity, and recovery data to advise the user
    /// on how to prepare for tomorrow's schedule density.
    private func buildTomorrowPreparation(
        todaySleep: HealthSummary,
        todayActivity: HealthSummary,
        baseline: [HealthSummary],
        tomorrowEvents: [CalendarEventItem]
    ) -> String {
        let sleepHours = todaySleep.sleepHours
        let steps = todayActivity.steps
        let exerciseMin = todayActivity.exerciseMinutes
        let todayHRV = todayActivity.hrv
        let todayRHR = todayActivity.restingHeartRate

        // Need at least some health data to show this section
        guard sleepHours > 0 || steps > 100 || exerciseMin > 0 || todayHRV > 0 || todayRHR > 0 else { return "" }

        var lines: [String] = []
        lines.append("🌙 明天准备建议：")

        // --- Assess tomorrow's schedule density ---
        let timedEvents = tomorrowEvents.filter { !$0.isAllDay }
        let meetingCount = timedEvents.count
        let totalMeetingMin = timedEvents.reduce(0.0) { $0 + $1.duration } / 60.0
        let isBusyTomorrow = meetingCount >= 4 || totalMeetingMin >= 300
        let isLightTomorrow = meetingCount <= 1

        // --- Sleep trend ---
        if sleepHours > 0 {
            let baselineSleepDays = baseline.filter { $0.sleepHours > 0 }
            let avgSleep = baselineSleepDays.isEmpty ? 7.0
                : baselineSleepDays.reduce(0) { $0 + $1.sleepHours } / Double(baselineSleepDays.count)
            let sleepDebt = avgSleep - sleepHours

            if sleepDebt > 1.0 {
                if isBusyTomorrow {
                    lines.append("  🔴 昨晚睡眠偏少（\(String(format: "%.1f", sleepHours))h），明天有 \(meetingCount) 个安排 — 今晚建议早睡补回来")
                } else {
                    lines.append("  🟡 昨晚睡了 \(String(format: "%.1f", sleepHours))h，低于你的平均水平 — 今晚早点休息")
                }
            } else if sleepHours >= 7.5 {
                lines.append("  🟢 昨晚睡眠充足（\(String(format: "%.1f", sleepHours))h），保持这个节奏就好")
            } else {
                lines.append("  🟡 昨晚睡了 \(String(format: "%.1f", sleepHours))h，还行，今晚争取更早入睡")
            }
        }

        // --- HRV recovery assessment ---
        let baselineHRVDays = baseline.filter { $0.hrv > 0 }
        if todayHRV > 0 && baselineHRVDays.count >= 2 {
            let avgHRV = baselineHRVDays.reduce(0) { $0 + $1.hrv } / Double(baselineHRVDays.count)
            let ratio = todayHRV / avgHRV

            if ratio < 0.8 {
                lines.append("  🟡 HRV 偏低（\(Int(todayHRV)) ms），身体在恢复中 — 今晚避免剧烈运动，让身体充分恢复")
            } else if ratio >= 1.1 {
                lines.append("  🟢 HRV 状态很好（\(Int(todayHRV)) ms），恢复充分，明天可以安心面对挑战")
            }
        }

        // --- RHR trend ---
        let baselineRHRDays = baseline.filter { $0.restingHeartRate > 0 }
        if todayRHR > 0 && baselineRHRDays.count >= 2 {
            let avgRHR = baselineRHRDays.reduce(0) { $0 + $1.restingHeartRate } / Double(baselineRHRDays.count)
            if todayRHR - avgRHR >= 5 {
                lines.append("  🟡 静息心率偏高（\(Int(todayRHR)) bpm），可能有疲劳积累 — 今晚放松为主")
            }
        }

        // --- Today's activity load ---
        if exerciseMin > 60 || steps > 15000 {
            if isBusyTomorrow {
                lines.append("  💡 今天已经运动 \(Int(exerciseMin)) 分钟，明天日程紧凑 — 让身体好好恢复")
            } else {
                lines.append("  💡 今天运动充分（\(Int(exerciseMin)) 分钟），明天轻松日适合主动恢复")
            }
        }

        // --- Cross-data: preparation advice based on schedule × recovery ---
        let hasLowHRV: Bool = {
            guard todayHRV > 0, baselineHRVDays.count >= 2 else { return false }
            let avgHRV = baselineHRVDays.reduce(0) { $0 + $1.hrv } / Double(baselineHRVDays.count)
            return todayHRV / avgHRV < 0.8
        }()
        let hasPoorSleep = sleepHours > 0 && sleepHours < 6.0
        let hasGoodRecovery = !hasLowHRV && sleepHours >= 7.0

        // Only add the summary line if we haven't already covered it above
        if lines.count > 1 { // Has more than just the header
            if isBusyTomorrow && (hasPoorSleep || hasLowHRV) {
                lines.append("  ⚡ 明天日程密集，今晚是关键恢复窗口 — 早睡、少刺激、轻松过渡")
            } else if isBusyTomorrow && hasGoodRecovery {
                lines.append("  ✅ 身体状态不错，明天 \(meetingCount) 个安排应该游刃有余")
            } else if isLightTomorrow && hasGoodRecovery {
                lines.append("  🌟 恢复好 + 日程轻松 — 明天适合安排需要深度思考的工作")
            } else if isLightTomorrow && (hasPoorSleep || hasLowHRV) {
                lines.append("  💚 明天不忙，正好给身体一个缓冲的机会")
            }
        }

        return lines.count > 1 ? lines.joined(separator: "\n") : ""
    }

    // MARK: - Health Readiness (Cross-Data Insight)

    /// Builds a brief health readiness note for today's calendar view.
    /// Connects last night's sleep, today's activity, and HRV/RHR vs personal baseline
    /// with schedule density to provide a holistic "how ready am I" insight.
    private func buildHealthReadiness(
        lastNightSleep: HealthSummary,
        todayActivity: HealthSummary,
        baseline: [HealthSummary],
        events: [CalendarEventItem]
    ) -> String {
        let sleepHours = lastNightSleep.sleepHours
        let steps = todayActivity.steps
        let exerciseMin = todayActivity.exerciseMinutes
        let todayHRV = todayActivity.hrv
        let todayRHR = todayActivity.restingHeartRate

        // Need at least some health data to show this section
        guard sleepHours > 0 || steps > 100 || exerciseMin > 0 || todayHRV > 0 || todayRHR > 0 else { return "" }

        var lines: [String] = []
        lines.append("💪 今日状态速览：")

        // --- Sleep quality assessment ---
        if sleepHours > 0 {
            let sleepEmoji: String
            let sleepVerdict: String
            if sleepHours >= 7.5 {
                sleepEmoji = "🟢"
                sleepVerdict = "充足"
            } else if sleepHours >= 6.0 {
                sleepEmoji = "🟡"
                sleepVerdict = "尚可"
            } else {
                sleepEmoji = "🔴"
                sleepVerdict = "不足"
            }
            var sleepLine = "  \(sleepEmoji) 昨晚睡眠 \(String(format: "%.1f", sleepHours)) 小时（\(sleepVerdict)）"

            // Add phase detail if available
            let deep = lastNightSleep.sleepDeepHours
            let rem = lastNightSleep.sleepREMHours
            if deep > 0 || rem > 0 {
                var phases: [String] = []
                if deep > 0 { phases.append("深睡 \(String(format: "%.1f", deep))h") }
                if rem > 0 { phases.append("REM \(String(format: "%.1f", rem))h") }
                sleepLine += "  " + phases.joined(separator: " · ")
            }
            lines.append(sleepLine)
        }

        // --- HRV cognitive readiness (the best single indicator of recovery) ---
        // Compare today's HRV against personal 7-day baseline — not population averages.
        // Higher HRV = parasympathetic dominance = better focus, creativity, stress tolerance.
        let baselineHRVDays = baseline.filter { $0.hrv > 0 }
        if todayHRV > 0 && baselineHRVDays.count >= 2 {
            let avgHRV = baselineHRVDays.reduce(0) { $0 + $1.hrv } / Double(baselineHRVDays.count)
            let ratio = todayHRV / avgHRV
            let pctDiff = Int((ratio - 1) * 100)

            let hrvEmoji: String
            let hrvVerdict: String
            if ratio >= 1.1 {
                hrvEmoji = "🟢"
                hrvVerdict = "高于基线（+\(pctDiff)%），专注力和压力耐受力很好"
            } else if ratio >= 0.9 {
                hrvEmoji = "🟢"
                hrvVerdict = "接近基线，状态正常"
            } else if ratio >= 0.75 {
                hrvEmoji = "🟡"
                hrvVerdict = "低于基线（\(pctDiff)%），认知负荷能力可能下降"
            } else {
                hrvEmoji = "🔴"
                hrvVerdict = "明显偏低（\(pctDiff)%），身体可能在应对压力或疲劳"
            }
            lines.append("  \(hrvEmoji) HRV \(Int(todayHRV)) ms — \(hrvVerdict)")
        } else if todayHRV > 0 {
            // HRV available but not enough baseline — show raw value with general guidance
            let hrvEmoji = todayHRV >= 50 ? "🟢" : (todayHRV >= 30 ? "🟡" : "🔴")
            lines.append("  \(hrvEmoji) HRV \(Int(todayHRV)) ms（基线建立中，持续佩戴 Apple Watch 即可）")
        }

        // --- Today's activity progress ---
        if steps > 100 || exerciseMin > 0 {
            var actParts: [String] = []
            if steps > 100 {
                actParts.append("👟 \(Int(steps).formatted()) 步")
            }
            if exerciseMin > 0 {
                actParts.append("🏃 \(Int(exerciseMin)) 分钟运动")
            }
            lines.append("  " + actParts.joined(separator: "  "))
        }

        // --- Resting heart rate with baseline comparison ---
        let baselineRHRDays = baseline.filter { $0.restingHeartRate > 0 }
        if todayRHR > 0 && baselineRHRDays.count >= 2 {
            let avgRHR = baselineRHRDays.reduce(0) { $0 + $1.restingHeartRate } / Double(baselineRHRDays.count)
            let diff = todayRHR - avgRHR
            if diff >= 5 {
                lines.append("  🔴 静息心率 \(Int(todayRHR)) bpm（比基线高 \(Int(diff))），恢复可能不充分")
            } else if diff <= -3 {
                lines.append("  🟢 静息心率 \(Int(todayRHR)) bpm（比基线低 \(Int(-diff))），恢复很好")
            } else if todayRHR <= 55 {
                lines.append("  🟢 静息心率 \(Int(todayRHR)) bpm，心肺状态很好")
            }
            // Normal range near baseline — don't clutter with neutral info
        } else if todayRHR > 0 {
            if todayRHR > 80 {
                lines.append("  ❤️ 静息心率偏高（\(Int(todayRHR)) bpm），身体可能需要更多休息")
            } else if todayRHR <= 55 {
                lines.append("  ❤️ 静息心率 \(Int(todayRHR)) bpm，心肺状态很好")
            }
        }

        // --- Cross-data insight: health × HRV × schedule density ---
        let timedEvents = events.filter { !$0.isAllDay }
        let meetingCount = timedEvents.count
        let totalMeetingMin = timedEvents.reduce(0.0) { $0 + $1.duration } / 60.0
        let isBusyDay = meetingCount >= 4 || totalMeetingMin >= 300

        // Compute a quick readiness signal combining sleep + HRV
        let hasLowHRV: Bool = {
            guard todayHRV > 0, baselineHRVDays.count >= 2 else { return false }
            let avgHRV = baselineHRVDays.reduce(0) { $0 + $1.hrv } / Double(baselineHRVDays.count)
            return todayHRV / avgHRV < 0.8
        }()
        let hasPoorSleep = sleepHours > 0 && sleepHours < 6.0
        let hasGoodSleep = sleepHours >= 7.5

        if isBusyDay && (hasPoorSleep || hasLowHRV) {
            if hasPoorSleep && hasLowHRV {
                lines.append("  ⚡ 睡眠不足 + HRV 偏低，今天 \(meetingCount) 个安排会比较吃力 — 优先处理重要事项，简化低优先级")
            } else if hasLowHRV {
                lines.append("  ⚡ HRV 低于基线遇上密集日程 — 长会议前深呼吸 1 分钟，保持节奏")
            } else {
                lines.append("  ⚡ 今天有 \(meetingCount) 个安排但昨晚睡眠偏少，记得安排小憩和补充水分")
            }
        } else if isBusyDay && hasGoodSleep && !hasLowHRV {
            lines.append("  ✅ 睡眠充足、身体恢复好，精力够应对今天的 \(meetingCount) 个安排")
        } else if !isBusyDay && (hasPoorSleep || hasLowHRV) {
            if hasLowHRV && hasPoorSleep {
                lines.append("  💡 身体在恢复中，好在今天不忙 — 适合轻度活动和早点休息")
            } else if hasLowHRV {
                lines.append("  💡 HRV 偏低但日程轻松，让身体自然恢复")
            } else {
                lines.append("  💡 昨晚睡得少，好在今天不太忙，可以找时间补个午休")
            }
        } else if meetingCount == 0 && hasGoodSleep && !hasLowHRV {
            lines.append("  🌟 精力充沛又没有会议，适合做需要深度专注的事")
        }

        return lines.joined(separator: "\n")
    }
}

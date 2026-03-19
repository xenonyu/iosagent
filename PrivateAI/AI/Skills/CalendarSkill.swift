import Foundation

/// Handles calendar and schedule queries via EventKit.
/// Provides rich insights: busy-ness scoring, next event, free slots, conflict detection.
struct CalendarSkill: ClawSkill {

    let id = "calendar"

    func canHandle(intent: QueryIntent) -> Bool {
        switch intent {
        case .calendar, .calendarNext: return true
        default: return false
        }
    }

    func execute(intent: QueryIntent, context: SkillContext, completion: @escaping (String) -> Void) {
        if case .calendarNext = intent {
            completion(buildNextEventResponse(context: context))
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

        let todayEvents = context.calendarService.fetchEvents(from: now, to: todayEnd)
        let tomorrowEvents = context.calendarService.fetchEvents(from: todayEnd, to: tomorrowEnd)

        // Split into ongoing and upcoming (today only)
        let timedToday = todayEvents.filter { !$0.isAllDay }
        let ongoing = timedToday.filter { $0.startDate <= now && $0.endDate > now }
        let upcoming = timedToday.filter { $0.startDate > now }
        let remainingCount = ongoing.count + upcoming.count

        // Nothing left today
        if remainingCount == 0 {
            // Check tomorrow
            let timedTomorrow = tomorrowEvents.filter { !$0.isAllDay }
            if timedTomorrow.isEmpty {
                return "✅ 今天的安排已经全部结束了，明天也暂时没有日程。\n\n好好休息吧 🌙"
            }
            let first = timedTomorrow.sorted { $0.startDate < $1.startDate }.first!
            let timeFmt = DateFormatter()
            timeFmt.dateFormat = "HH:mm"
            var msg = "✅ 今天的安排已经全部结束了。\n\n"
            msg += "📅 明天最早的安排：\(timeFmt.string(from: first.startDate)) 「\(first.title)」"
            if !first.location.isEmpty { msg += "\n  📍 \(first.location)" }
            if timedTomorrow.count > 1 {
                msg += "\n  明天共有 \(timedTomorrow.count) 个事件。"
            }
            return msg
        }

        var lines: [String] = []
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"

        // Ongoing events
        for event in ongoing {
            let remainMin = Int(event.endDate.timeIntervalSince(now) / 60)
            var line = "🔴 正在进行：「\(event.title)」（\(event.timeDisplay)）"
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
            var line = "\(prefix)：\(countdown) — 「\(event.title)」（\(event.timeDisplay)）"
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
            return buildSingleDayResponse(events: events, range: range, date: interval.start, timeOfDay: todFilter)
        } else {
            return buildMultiDayResponse(events: events, range: range, interval: interval, spanDays: spanDays, context: context)
        }
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

    private func buildSingleDayResponse(events: [CalendarEventItem], range: QueryTimeRange, date: Date, timeOfDay: TimeOfDayFilter? = nil) -> String {
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
                    if !next.location.isEmpty { nextLine += "  📍\(next.location)" }
                    lines.append(nextLine + "\n")
                } else if minutesUntil <= 0 && next.startDate <= now && next.endDate > now {
                    let remainMin = Int(next.endDate.timeIntervalSince(now) / 60)
                    var ongoingLine = "🔴 正在进行：「\(next.title)」（\(next.timeDisplay)）"
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
                var line = "  • \(event.timeDisplay) \(event.title)\(recurTag)"
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
                    var line = "  · \(event.timeDisplay) \(event.title)\(recurTag)"
                    if !event.location.isEmpty { line += "  📍\(event.location)" }
                    lines.append(line)
                }
                lines.append("")
            }
        } else if !timedEvents.isEmpty {
            lines.append("🕐 时间安排：")
            timedEvents.forEach { event in
                let recurTag = event.isRecurring ? " 🔄" : ""
                var line = "  • \(event.timeDisplay) \(event.title)\(recurTag)"
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
        lines.append("共 \(events.count) 个事件，跨 \(spanDays) 天\(totalMinutes >= 60 ? "，约 \(formatDuration(totalMinutes)) 有安排" : "")\(headerSuffix)。\n")

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

        // --- Busiest day insight ---
        if sortedDays.count > 1 && !isFreeTimeFocus {
            let busiestDay = sortedDays.max { (grouped[$0]?.count ?? 0) < (grouped[$1]?.count ?? 0) }
            if let busiest = busiestDay, let count = grouped[busiest]?.count, count > 1 {
                lines.append("📊 最忙的一天：\(dateFmt.string(from: busiest))（\(count) 个事件）\n")
            }
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
                var line = "  • \(event.isAllDay ? "全天" : event.timeDisplay) \(event.title)\(recurTag)"
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

        // --- Recurring vs one-off event breakdown ---
        let recurringInsight = buildRecurringBreakdown(events: events, spanDays: spanDays)
        if !recurringInsight.isEmpty {
            lines.append("")
            lines.append(contentsOf: recurringInsight)
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

    /// Classifies meeting types by parsing event titles.
    private func classifyMeetingTypes(events: [CalendarEventItem]) -> [String: Int] {
        var types: [String: Int] = [:]
        for event in events {
            let t = event.title.lowercased()
            let type: String
            if t.contains("standup") || t.contains("站会") || t.contains("晨会") || t.contains("daily") {
                type = "站会"
            } else if t.contains("1:1") || t.contains("1v1") || t.contains("one on one") || t.contains("单聊") {
                type = "1:1"
            } else if t.contains("review") || t.contains("评审") || t.contains("复盘") || t.contains("回顾") {
                type = "评审"
            } else if t.contains("面试") || t.contains("interview") {
                type = "面试"
            } else if t.contains("培训") || t.contains("training") || t.contains("workshop") || t.contains("分享") {
                type = "培训/分享"
            } else if t.contains("sync") || t.contains("同步") || t.contains("对齐") || t.contains("沟通") {
                type = "同步会"
            } else if t.contains("planning") || t.contains("规划") || t.contains("sprint") {
                type = "规划会"
            } else {
                type = "会议"
            }
            types[type, default: 0] += 1
        }
        return types
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

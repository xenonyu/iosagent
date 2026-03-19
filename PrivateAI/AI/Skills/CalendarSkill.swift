import Foundation

/// Handles calendar and schedule queries via EventKit.
/// Provides rich insights: busy-ness scoring, next event, free slots, conflict detection.
struct CalendarSkill: ClawSkill {

    let id = "calendar"

    func canHandle(intent: QueryIntent) -> Bool {
        if case .calendar = intent { return true }
        return false
    }

    func execute(intent: QueryIntent, context: SkillContext, completion: @escaping (String) -> Void) {
        guard case .calendar(let range) = intent else { return }
        completion(buildResponse(range: range, context: context))
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
        default:
            return range.interval
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
            return "📅 \(range.label)没有任何日程安排。\n\n✨ 这段时间完全自由！可以用来做自己想做的事。"
        }
        let interval = range.interval
        let cal = Calendar.current
        let now = Date()
        if interval.end >= cal.startOfDay(for: now) {
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
                var line = "  • \(event.timeDisplay) \(event.title)"
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
                    var line = "  · \(event.timeDisplay) \(event.title)"
                    if !event.location.isEmpty { line += "  📍\(event.location)" }
                    lines.append(line)
                }
                lines.append("")
            }
        } else if !timedEvents.isEmpty {
            lines.append("🕐 时间安排：")
            timedEvents.forEach { event in
                var line = "  • \(event.timeDisplay) \(event.title)"
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

    private func buildMultiDayResponse(events: [CalendarEventItem], range: QueryTimeRange, interval: DateInterval, spanDays: Int, context: SkillContext) -> String {
        var lines: [String] = []
        let cal = Calendar.current
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "M月d日（E）"
        dateFmt.locale = Locale(identifier: "zh_CN")

        let timedEvents = events.filter { !$0.isAllDay }
        let totalMinutes = timedEvents.reduce(0.0) { $0 + $1.duration } / 60.0

        // --- Summary header ---
        lines.append("📅 \(range.label)日程总览")
        lines.append("共 \(events.count) 个事件，跨 \(spanDays) 天\(totalMinutes >= 60 ? "，约 \(formatDuration(totalMinutes)) 有安排" : "")。\n")

        // --- Group by day ---
        let grouped = Dictionary(grouping: events) { cal.startOfDay(for: $0.startDate) }
        let sortedDays = grouped.keys.sorted()

        // --- Busiest day insight ---
        if sortedDays.count > 1 {
            let busiestDay = sortedDays.max { (grouped[$0]?.count ?? 0) < (grouped[$1]?.count ?? 0) }
            if let busiest = busiestDay, let count = grouped[busiest]?.count, count > 1 {
                lines.append("📊 最忙的一天：\(dateFmt.string(from: busiest))（\(count) 个事件）\n")
            }
        }

        // --- Day-by-day listing ---
        for day in sortedDays.prefix(7) {
            guard let dayEvents = grouped[day] else { continue }
            let dayTimed = dayEvents.filter { !$0.isAllDay }
            let dayBusy = busyScore(timedCount: dayTimed.count, totalMinutes: dayTimed.reduce(0.0) { $0 + $1.duration } / 60.0)
            lines.append("📌 \(dateFmt.string(from: day)) \(dayBusy.emoji)")
            dayEvents.forEach { event in
                var line = "  • \(event.isAllDay ? "全天" : event.timeDisplay) \(event.title)"
                if !event.location.isEmpty { line += "  📍\(event.location)" }
                lines.append(line)
                if let preview = notesPreview(event.notes) {
                    lines.append("    💬 \(preview)")
                }
            }
        }

        // --- Days with no events ---
        if sortedDays.count < spanDays {
            let freeDays = spanDays - sortedDays.count
            lines.append("\n💚 其中 \(freeDays) 天没有安排，可以自由支配。")
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
}

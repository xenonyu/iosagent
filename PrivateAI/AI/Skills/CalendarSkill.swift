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

    // MARK: - Response Builder

    private func buildResponse(range: QueryTimeRange, context: SkillContext) -> String {
        let interval = range.interval
        let events = context.calendarService.fetchEvents(from: interval.start, to: interval.end)

        if events.isEmpty {
            return buildEmptyResponse(range: range)
        }

        let cal = Calendar.current
        let spanDays = max(1, cal.dateComponents([.day], from: interval.start, to: interval.end).day ?? 1)

        if spanDays <= 1 {
            return buildSingleDayResponse(events: events, range: range, date: interval.start)
        } else {
            return buildMultiDayResponse(events: events, range: range, interval: interval, spanDays: spanDays)
        }
    }

    // MARK: - Empty State

    private func buildEmptyResponse(range: QueryTimeRange) -> String {
        if range.isFuture || range == .today {
            return "📅 \(range.label)没有任何日程安排。\n\n✨ 这段时间完全自由！可以用来做自己想做的事。"
        }
        let interval = range.interval
        let cal = Calendar.current
        let now = Date()
        if interval.end >= cal.startOfDay(for: now) {
            return "📅 \(range.label)没有任何日程安排。\n\n✨ 这段时间完全自由！可以用来做自己想做的事。"
        }
        return "📅 \(range.label)的日历里没有事件记录。\n请确认已开启日历权限，或者前往日历 App 添加行程。"
    }

    // MARK: - Single Day Response (Today / Tomorrow / Specific Day)

    private func buildSingleDayResponse(events: [CalendarEventItem], range: QueryTimeRange, date: Date) -> String {
        var lines: [String] = []
        let now = Date()
        let cal = Calendar.current
        let isToday = cal.isDateInToday(date)
        let isFutureDay = range.isFuture

        // --- Header with busy-ness ---
        let timedEvents = events.filter { !$0.isAllDay }
        let allDayEvents = events.filter { $0.isAllDay }
        let totalMeetingMinutes = timedEvents.reduce(0.0) { $0 + $1.duration } / 60.0
        let busyLevel = busyScore(timedCount: timedEvents.count, totalMinutes: totalMeetingMinutes)

        lines.append("📅 \(range.label)的日程 \(busyLevel.emoji)")
        lines.append("\(busyLevel.description)，共 \(events.count) 个事件\(totalMeetingMinutes >= 60 ? "，约 \(formatDuration(totalMeetingMinutes)) 有安排" : "")。\n")

        // --- Next upcoming event (only for today) ---
        if isToday {
            let upcoming = timedEvents.filter { $0.endDate > now }.sorted { $0.startDate < $1.startDate }
            if let next = upcoming.first {
                let minutesUntil = next.startDate.timeIntervalSince(now) / 60
                if minutesUntil > 0 && minutesUntil <= 480 {
                    let timeStr = minutesUntil < 60
                        ? "\(Int(minutesUntil)) 分钟后"
                        : "\(Int(minutesUntil / 60)) 小时\(Int(minutesUntil.truncatingRemainder(dividingBy: 60))) 分钟后"
                    lines.append("⏰ 接下来：\(timeStr)有「\(next.title)」（\(next.timeDisplay)）\n")
                } else if minutesUntil <= 0 && next.startDate <= now && next.endDate > now {
                    lines.append("🔴 正在进行：「\(next.title)」（\(next.timeDisplay)）\n")
                }
            } else if !timedEvents.isEmpty {
                lines.append("✅ 今天的日程已全部结束。\n")
            }
        }

        // --- First event preview for future days ---
        if isFutureDay && !timedEvents.isEmpty {
            let sorted = timedEvents.sorted { $0.startDate < $1.startDate }
            if let first = sorted.first {
                lines.append("⏰ 最早的安排：\(first.timeDisplay)「\(first.title)」\n")
            }
        }

        // --- All-day events ---
        if !allDayEvents.isEmpty {
            lines.append("🏷️ 全天事件：")
            allDayEvents.forEach { lines.append("  • \($0.title)\(calendarTag($0.calendar))") }
            lines.append("")
        }

        // --- Timed events list ---
        if !timedEvents.isEmpty {
            lines.append("🕐 时间安排：")
            timedEvents.forEach { event in
                var line = "  • \(event.timeDisplay) \(event.title)"
                if !event.location.isEmpty { line += "  📍\(event.location)" }
                lines.append(line)
            }
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

        return lines.joined(separator: "\n")
    }

    // MARK: - Multi-Day Response (This Week / Range)

    private func buildMultiDayResponse(events: [CalendarEventItem], range: QueryTimeRange, interval: DateInterval, spanDays: Int) -> String {
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
            }
        }

        // --- Days with no events ---
        if sortedDays.count < spanDays {
            let freeDays = spanDays - sortedDays.count
            lines.append("\n💚 其中 \(freeDays) 天没有安排，可以自由支配。")
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
}

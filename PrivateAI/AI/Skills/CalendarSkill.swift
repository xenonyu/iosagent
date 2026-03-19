import Foundation

/// Handles calendar and schedule queries via EventKit.
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

    private func buildResponse(range: QueryTimeRange, context: SkillContext) -> String {
        let interval = range.interval
        let events = context.calendarService.fetchEvents(from: interval.start, to: interval.end)

        if events.isEmpty {
            return "📅 \(range.label)的日历里没有事件。\n请确认已开启日历权限，或者前往日历 App 添加行程。"
        }

        var lines = ["📅 \(range.label)的日程（共 \(events.count) 个）：\n"]
        let fmt = DateFormatter()
        fmt.dateFormat = "M月d日"

        let grouped = Dictionary(grouping: events) { fmt.string(from: $0.startDate) }
        grouped.keys.sorted().prefix(7).forEach { dateStr in
            lines.append("📌 \(dateStr)")
            grouped[dateStr]?.forEach { event in
                lines.append("  • \(event.timeDisplay) \(event.title)")
                if !event.location.isEmpty { lines.append("    📍 \(event.location)") }
            }
        }

        return lines.joined(separator: "\n")
    }
}

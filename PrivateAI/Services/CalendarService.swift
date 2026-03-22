import Foundation
import EventKit

/// Reads iOS Calendar events for the AI to reference.
/// Read-only — never creates or modifies calendar data.
final class CalendarService: ObservableObject {

    private let store = EKEventStore()

    // MARK: - Permission

    func requestPermission(completion: @escaping (Bool) -> Void) {
        if #available(iOS 17.0, *) {
            store.requestFullAccessToEvents { granted, _ in
                DispatchQueue.main.async { completion(granted) }
            }
        } else {
            store.requestAccess(to: .event) { granted, _ in
                DispatchQueue.main.async { completion(granted) }
            }
        }
    }

    var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    var isAuthorized: Bool {
        let status = authorizationStatus
        if #available(iOS 17.0, *) {
            return status == .fullAccess
        } else {
            return status == .authorized
        }
    }

    // MARK: - Fetch

    /// Returns calendar events in the given date range.
    /// Cancelled events (EKEventStatus.canceled) are excluded — they would
    /// mislead GPT into telling the user about meetings that no longer exist.
    /// Tentative events (not yet accepted) are included but flagged so GPT
    /// can say "you have a tentative meeting" instead of a definitive one.
    func fetchEvents(from: Date, to: Date) -> [CalendarEventItem] {
        guard isAuthorized else { return [] }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: predicate)
            .filter { $0.status != .canceled }
            .map {
                CalendarEventItem(
                    id: $0.eventIdentifier ?? UUID().uuidString,
                    title: $0.title ?? "（无标题）",
                    startDate: $0.startDate,
                    endDate: $0.endDate,
                    isAllDay: $0.isAllDay,
                    calendar: $0.calendar?.title ?? "",
                    location: $0.location ?? "",
                    notes: $0.notes ?? "",
                    isRecurring: $0.hasRecurrenceRules,
                    recurrenceDescription: Self.describeRecurrence($0),
                    attendeeCount: $0.attendees?.count ?? 0,
                    isOrganizer: $0.organizer?.isCurrentUser ?? false,
                    hasAttendees: $0.attendees != nil && !($0.attendees?.isEmpty ?? true),
                    organizerName: Self.participantDisplayName($0.organizer),
                    attendeeNames: Self.extractAttendeeNames($0),
                    isTentative: $0.status == .tentative
                )
            }
            .sorted { $0.startDate < $1.startDate }
    }

    /// Extracts a display name from an EKParticipant (organizer or attendee).
    /// EKParticipant.name may be nil or contain a "mailto:" URL — handle both.
    private static func participantDisplayName(_ participant: EKParticipant?) -> String {
        guard let p = participant else { return "" }
        // .name is the preferred display name (e.g. "张三" or "John Smith")
        if let name = p.name, !name.isEmpty,
           !name.hasPrefix("mailto:"), !name.contains("@") {
            return name
        }
        // Fallback: extract name from the URL (mailto:email@example.com)
        // Show just the local part for brevity (e.g. "john.smith")
        let urlStr = p.url.absoluteString
            .replacingOccurrences(of: "mailto:", with: "")
        if !urlStr.isEmpty {
            return urlStr.components(separatedBy: "@").first ?? urlStr
        }
        return ""
    }

    /// Extracts attendee names from an EKEvent, limited to first 6 for prompt brevity.
    /// Marks declined attendees with a suffix so GPT can accurately answer "who's coming?"
    /// Excludes the organizer (shown separately) and the current user (implied).
    private static func extractAttendeeNames(_ event: EKEvent) -> [String] {
        guard let attendees = event.attendees, !attendees.isEmpty else { return [] }

        return attendees
            .filter { $0.participantRole != .nonParticipant }
            .prefix(8)  // cap at 8 to prevent prompt bloat for large meetings
            .compactMap { participant -> String? in
                let name = participantDisplayName(participant)
                guard !name.isEmpty else { return nil }
                // Mark declined attendees so GPT doesn't list them as confirmed
                if participant.participantStatus == .declined {
                    return "\(name)(已拒绝)"
                }
                if participant.participantStatus == .tentative {
                    return "\(name)(待确认)"
                }
                return name
            }
    }

    /// Extracts a human-readable recurrence description from an EKEvent's recurrence rules.
    /// Examples: "每周", "每天", "每两周 周一、周三", "每月 第1个周一", "每年"
    private static func describeRecurrence(_ event: EKEvent) -> String {
        guard let rules = event.recurrenceRules, let rule = rules.first else { return "" }

        let interval = rule.interval
        let weekdayNames = ["", "周日", "周一", "周二", "周三", "周四", "周五", "周六"]

        switch rule.frequency {
        case .daily:
            return interval == 1 ? "每天" : "每\(interval)天"
        case .weekly:
            let prefix = interval == 1 ? "每周" : "每\(interval)周"
            if let days = rule.daysOfTheWeek, !days.isEmpty {
                let dayNames = days.compactMap { d -> String? in
                    let idx = d.dayOfTheWeek.rawValue
                    guard idx >= 1 && idx <= 7 else { return nil }
                    return weekdayNames[idx]
                }
                if !dayNames.isEmpty {
                    return "\(prefix) \(dayNames.joined(separator: "、"))"
                }
            }
            return prefix
        case .monthly:
            let prefix = interval == 1 ? "每月" : "每\(interval)月"
            if let days = rule.daysOfTheWeek, let first = days.first {
                let idx = first.dayOfTheWeek.rawValue
                let dayName = (idx >= 1 && idx <= 7) ? weekdayNames[idx] : ""
                let weekNum = first.weekNumber
                if weekNum != 0 && !dayName.isEmpty {
                    return "\(prefix) 第\(weekNum)个\(dayName)"
                }
            }
            if let monthDays = rule.daysOfTheMonth, let first = monthDays.first {
                return "\(prefix) \(first)日"
            }
            return prefix
        case .yearly:
            return interval == 1 ? "每年" : "每\(interval)年"
        @unknown default:
            return "重复"
        }
    }

    /// Returns today's upcoming events.
    func todayEvents() -> [CalendarEventItem] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        return fetchEvents(from: start, to: end)
    }
}

// MARK: - Model

struct CalendarEventItem: Identifiable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let calendar: String
    let location: String
    let notes: String
    let isRecurring: Bool
    /// Human-readable recurrence description (e.g. "每周", "每天", "每两周 周一、周三").
    /// Empty string for non-recurring events.
    let recurrenceDescription: String
    /// Number of attendees (from EKEvent.attendees). 0 if no attendee data.
    let attendeeCount: Int
    /// Whether the current user is the organizer of this event.
    let isOrganizer: Bool
    /// Whether the event has any attendee data (distinguishes "0 attendees" from "no data").
    let hasAttendees: Bool
    /// Display name of the event organizer (e.g. "张三", "John Smith").
    /// Empty string if organizer info is unavailable or the current user is the organizer.
    let organizerName: String
    /// Names of attendees (up to 8), with status annotations for declined/tentative.
    /// Empty when no attendee data is available. Enables GPT to answer "谁参加了这个会？"
    let attendeeNames: [String]
    /// Whether the user hasn't accepted this event yet (EKEventStatus.tentative).
    /// GPT should communicate these as "待确认" so the user knows it's not finalized.
    let isTentative: Bool

    var duration: TimeInterval { endDate.timeIntervalSince(startDate) }

    var timeDisplay: String {
        if isAllDay { return "全天" }
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return "\(fmt.string(from: startDate))–\(fmt.string(from: endDate))"
    }

    /// A human-readable label describing the meeting scale and participants.
    /// Returns nil for events without attendee data (personal events, holidays, etc.).
    /// When attendee names are available, includes them so GPT can answer "谁参加了这个会？"
    var attendeeLabel: String? {
        guard hasAttendees else { return nil }
        // attendeeCount includes the user themselves in EKEvent
        let total = attendeeCount
        let scaleLabel: String
        if total <= 2 { scaleLabel = "1:1" }
        else if total <= 5 { scaleLabel = "👥\(total)人小会" }
        else if total <= 15 { scaleLabel = "👥\(total)人会议" }
        else { scaleLabel = "👥\(total)人大会" }

        // Build detailed label with organizer and attendee names when available
        var parts: [String] = [scaleLabel]

        // Show organizer when it's someone else (not the current user)
        if !isOrganizer && !organizerName.isEmpty {
            parts.append("组织者:\(organizerName)")
        }

        // List attendee names (already capped at 8 in extractAttendeeNames)
        let displayNames = attendeeNames.filter { !$0.isEmpty }
        if !displayNames.isEmpty {
            // For small meetings, show all names. For large ones, show first few + "等"
            let namesToShow = displayNames.prefix(5)
            var nameStr = "参会:\(namesToShow.joined(separator: "、"))"
            if displayNames.count > 5 {
                nameStr += "等\(displayNames.count)人"
            }
            parts.append(nameStr)
        }

        return parts.joined(separator: " ")
    }
}

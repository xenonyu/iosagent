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
    func fetchEvents(from: Date, to: Date) -> [CalendarEventItem] {
        guard isAuthorized else { return [] }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: predicate).map {
            CalendarEventItem(
                id: $0.eventIdentifier ?? UUID().uuidString,
                title: $0.title ?? "（无标题）",
                startDate: $0.startDate,
                endDate: $0.endDate,
                isAllDay: $0.isAllDay,
                calendar: $0.calendar?.title ?? "",
                location: $0.location ?? "",
                notes: $0.notes ?? ""
            )
        }
        .sorted { $0.startDate < $1.startDate }
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

    var duration: TimeInterval { endDate.timeIntervalSince(startDate) }

    var timeDisplay: String {
        if isAllDay { return "全天" }
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return "\(fmt.string(from: startDate))–\(fmt.string(from: endDate))"
    }
}

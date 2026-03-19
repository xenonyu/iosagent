import Foundation
import UserNotifications
import CoreData

/// Manages local push notifications — daily reminders and weekly summaries.
/// All notification content is generated on-device from local data.
final class NotificationService: ObservableObject {

    private let center = UNUserNotificationCenter.current()

    static let dailyReminderID = "pa_daily_reminder"
    static let weeklySummaryID = "pa_weekly_summary"

    // MARK: - Permission

    func requestPermission(completion: @escaping (Bool) -> Void) {
        center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    func checkPermission(completion: @escaping (Bool) -> Void) {
        center.getNotificationSettings { settings in
            DispatchQueue.main.async {
                completion(settings.authorizationStatus == .authorized)
            }
        }
    }

    // MARK: - Daily Reminder

    func scheduleDailyReminder(hour: Int, minute: Int) {
        center.removePendingNotificationRequests(withIdentifiers: [Self.dailyReminderID])

        let content = UNMutableNotificationContent()
        content.title = "今天怎么样？ ✨"
        content.body = dailyReminderBody()
        content.sound = .default

        var components = DateComponents()
        components.hour = hour
        components.minute = minute

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(
            identifier: Self.dailyReminderID,
            content: content,
            trigger: trigger
        )
        center.add(request)
    }

    func cancelDailyReminder() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.dailyReminderID])
    }

    // MARK: - Weekly Summary

    func scheduleWeeklySummary(context: NSManagedObjectContext) {
        center.removePendingNotificationRequests(withIdentifiers: [Self.weeklySummaryID])

        let interval = QueryTimeRange.lastWeek.interval
        let events = CDLifeEvent.fetch(from: interval.start, to: interval.end, in: context)
        let locations = CDLocationRecord.fetch(from: interval.start, to: interval.end, in: context)

        let content = UNMutableNotificationContent()
        content.title = "📖 你的本周生活回顾"
        content.body = buildWeeklySummaryBody(events: events, locations: locations)
        content.sound = .default

        // Every Sunday at 9:00 AM
        var components = DateComponents()
        components.weekday = 1
        components.hour = 9
        components.minute = 0

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(
            identifier: Self.weeklySummaryID,
            content: content,
            trigger: trigger
        )
        center.add(request)
    }

    func cancelWeeklySummary() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.weeklySummaryID])
    }

    func cancelAll() {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    // MARK: - Content Builders

    private func dailyReminderBody() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        let steps = UserDefaults(suiteName: "group.com.iosclaw.assistant")?
            .integer(forKey: "widget_today_steps") ?? 0

        switch hour {
        case 0..<12:
            return "早上好！记录一下今天的计划，让我帮你记住每个重要时刻。"
        case 12..<18:
            let stepsText = steps > 0 ? "已走 \(steps.formatted()) 步，" : ""
            return "下午好！\(stepsText)今天过得怎么样？来聊聊吧。"
        default:
            if steps >= 8000 {
                return "今天走了 \(steps.formatted()) 步，达成目标！🎉 来记录一下今天的精彩吧。"
            } else if steps > 0 {
                return "今天走了 \(steps.formatted()) 步。来聊聊今天发生了什么？"
            }
            return "今天发生了什么？记录一下，让我帮你记住这一天。"
        }
    }

    private func buildWeeklySummaryBody(events: [LifeEvent], locations: [LocationRecord]) -> String {
        var parts: [String] = []

        if events.isEmpty {
            parts.append("本周还没有事件记录")
        } else {
            parts.append("记录了 \(events.count) 件事")

            let dominant = Dictionary(grouping: events, by: { $0.mood })
                .max(by: { $0.value.count < $1.value.count })?.key
            if let mood = dominant {
                parts.append("整体心情\(mood.label) \(mood.emoji)")
            }
        }

        if !locations.isEmpty {
            let uniquePlaces = Set(locations.map { $0.displayName }).count
            parts.append("去了 \(uniquePlaces) 个地方")
        }

        return parts.joined(separator: "，") + " 点击查看详情 →"
    }
}

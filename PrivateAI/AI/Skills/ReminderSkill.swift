import Foundation
import UserNotifications

/// Schedules local notifications as timed reminders via chat.
/// Users can say "提醒我5分钟后喝水" or "30分钟后提醒我开会".
/// All data stays on-device — no network calls.
struct ReminderSkill: ClawSkill {

    let id = "reminder"

    private let center = UNUserNotificationCenter.current()
    private static let idPrefix = "claw_reminder_"

    func canHandle(intent: QueryIntent) -> Bool {
        if case .reminder = intent { return true }
        return false
    }

    func execute(intent: QueryIntent, context: SkillContext, completion: @escaping (String) -> Void) {
        guard case .reminder(let action) = intent else { return }

        switch action {
        case .set(let minutes, let message):
            scheduleReminder(minutes: minutes, message: message, completion: completion)
        case .list:
            listReminders(completion: completion)
        case .clear:
            clearReminders(completion: completion)
        }
    }

    // MARK: - Schedule

    private func scheduleReminder(minutes: Int, message: String, completion: @escaping (String) -> Void) {
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else {
                DispatchQueue.main.async {
                    completion("🔔 提醒功能需要通知权限。\n\n请前往 **设置 → 通知 → iosclaw** 开启通知权限后再试。")
                }
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "⏰ iosclaw 提醒"
            content.body = message
            content.sound = .default

            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: TimeInterval(minutes * 60),
                repeats: false
            )

            let identifier = Self.idPrefix + UUID().uuidString
            let request = UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: trigger
            )

            self.center.add(request) { error in
                DispatchQueue.main.async {
                    if let error = error {
                        completion("❌ 提醒设置失败：\(error.localizedDescription)")
                        return
                    }

                    let fireDate = Date().addingTimeInterval(TimeInterval(minutes * 60))
                    let fmt = DateFormatter()
                    fmt.dateFormat = "HH:mm"
                    let timeStr = fmt.string(from: fireDate)

                    let durationText = Self.formatDuration(minutes)

                    completion("""
                    ⏰ **提醒已设置！**

                    📌 内容：\(message)
                    🕐 \(durationText)后提醒（约 \(timeStr)）

                    到时候会收到通知提醒你哦 🔔
                    """)
                }
            }
        }
    }

    // MARK: - List

    private func listReminders(completion: @escaping (String) -> Void) {
        center.getPendingNotificationRequests { requests in
            let reminders = requests.filter { $0.identifier.hasPrefix(Self.idPrefix) }

            DispatchQueue.main.async {
                if reminders.isEmpty {
                    completion("📋 当前没有待触发的提醒。\n\n💡 试试说「提醒我10分钟后喝水」来设置一个吧！")
                    return
                }

                var lines: [String] = ["⏰ **待触发的提醒**\n"]

                for (i, req) in reminders.enumerated() {
                    let body = req.content.body
                    var timeInfo = ""
                    if let trigger = req.trigger as? UNTimeIntervalNotificationTrigger {
                        // Approximate remaining time
                        let remaining = Int(trigger.timeInterval)
                        timeInfo = "（\(Self.formatDuration(remaining / 60))）"
                    }
                    lines.append("  \(i + 1). 🔔 \(body) \(timeInfo)")
                }

                lines.append("\n共 \(reminders.count) 个提醒。说「清除提醒」可以全部取消。")
                completion(lines.joined(separator: "\n"))
            }
        }
    }

    // MARK: - Clear

    private func clearReminders(completion: @escaping (String) -> Void) {
        center.getPendingNotificationRequests { requests in
            let reminderIds = requests
                .filter { $0.identifier.hasPrefix(Self.idPrefix) }
                .map { $0.identifier }

            self.center.removePendingNotificationRequests(withIdentifiers: reminderIds)

            DispatchQueue.main.async {
                if reminderIds.isEmpty {
                    completion("📋 当前没有待触发的提醒，无需清除。")
                } else {
                    completion("🧹 已清除 \(reminderIds.count) 个提醒。")
                }
            }
        }
    }

    // MARK: - Helpers

    private static func formatDuration(_ minutes: Int) -> String {
        if minutes < 60 {
            return "\(minutes) 分钟"
        }
        let hours = minutes / 60
        let remaining = minutes % 60
        if remaining == 0 {
            return "\(hours) 小时"
        }
        return "\(hours) 小时 \(remaining) 分钟"
    }
}

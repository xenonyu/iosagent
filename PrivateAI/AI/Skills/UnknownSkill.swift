import Foundation
import CoreLocation

/// Fallback skill for unrecognized queries.
/// Provides context-aware, time-sensitive, **permission-aware** suggestions that prioritize
/// core iOS data skills (health, location, calendar, photos) over utility tools.
/// Only suggests features the user can actually use; guides them to enable missing permissions.
struct UnknownSkill: ClawSkill {

    let id = "unknown"

    func canHandle(intent: QueryIntent) -> Bool {
        if case .unknown = intent { return true }
        return false
    }

    func execute(intent: QueryIntent, context: SkillContext, completion: @escaping (String) -> Void) {
        let query = context.originalQuery
        let contextMemory = context.contextMemory

        // --- Context-aware opening ---
        var opening = ""
        if let memory = contextMemory {
            // Only reference recent topic if it was within the last 5 messages
            let recentTopics = memory.mentionedTopics
            let msgCount = memory.recentMessages.count
            if !recentTopics.isEmpty && msgCount <= 5 {
                opening = "基于你刚才聊的「\(recentTopics.last ?? "")」，这个我暂时还不太擅长。\n\n"
            }
        }

        // --- Concise, friendly intro (no robotic "收到！") ---
        let intros = [
            "🤔 「\(query)」——这个我还不太能回答",
            "💭 关于「\(query)」，目前超出了我的能力范围",
            "🙂 「\(query)」——还不在我的技能树上"
        ]
        let intro = intros[Int.random(in: 0..<intros.count)]

        // --- Permission-aware, time-sensitive suggestions ---
        let permissions = detectPermissions(context: context)
        let coreSuggestions = buildTimeSensitiveSuggestions(permissions: permissions)
        let permissionGuide = buildPermissionGuide(permissions: permissions)

        // --- New user guide ---
        let isNewUser = contextMemory?.recentMessages.isEmpty ?? true
        let newUserGuide = isNewUser
            ? "\n\n💡 第一次用？试试告诉我：「今天去健身了，感觉很好」——我会帮你记录生活点滴。"
            : ""

        var response = """
        \(intro)

        \(opening)不过，我最擅长帮你了解「自己」：

        \(coreSuggestions.joined(separator: "\n"))

        💬 你也可以直接告诉我今天做了什么，我帮你记下来。\(newUserGuide)
        """

        // Append permission guide if any core permissions are missing
        if !permissionGuide.isEmpty {
            response += "\n\n" + permissionGuide
        }

        completion(response.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Permission Detection

    /// Checks which core data permissions are available.
    private struct PermissionState {
        var hasHealth: Bool
        var hasCalendar: Bool
        var hasPhotos: Bool
        var hasLocation: Bool

        /// Number of enabled permissions (0–4)
        var enabledCount: Int {
            [hasHealth, hasCalendar, hasPhotos, hasLocation].filter { $0 }.count
        }
    }

    private func detectPermissions(context: SkillContext) -> PermissionState {
        let locStatus = context.locationService.authorizationStatus
        let hasLocation = (locStatus == .authorizedAlways || locStatus == .authorizedWhenInUse)

        return PermissionState(
            hasHealth: context.healthService.isHealthDataAvailable,
            hasCalendar: context.calendarService.isAuthorized,
            hasPhotos: context.photoService.isAuthorized,
            hasLocation: hasLocation
        )
    }

    // MARK: - Permission-Aware Suggestions

    /// Builds time-sensitive suggestions, prioritizing features the user has access to.
    /// When a permission is missing, that category's suggestion slot is replaced by
    /// an enabled category instead of showing an inaccessible feature.
    private func buildTimeSensitiveSuggestions(permissions: PermissionState) -> [String] {
        let hour = Calendar.current.component(.hour, from: Date())

        // Define suggestion pools per category
        // Each pool has time-of-day variants: [morning, afternoon, evening, lateNight]
        struct CategorySuggestion {
            let suggestions: [Int: [String]] // hour-range start → suggestions
        }

        let healthSuggestions: [String]
        let calendarSuggestions: [String]
        let photoSuggestions: [String]
        let locationSuggestions: [String]

        // Health suggestions by time of day
        switch hour {
        case 6..<12:
            healthSuggestions = [
                "🛌 「昨晚睡得怎么样？」— 查看睡眠质量",
                "🏃 「这周运动了多少？」— 查看运动数据"
            ]
        case 12..<18:
            healthSuggestions = [
                "🏃 「今天走了多少步？」— 查看运动数据",
                "❤️ 「我的心率怎么样？」— 查看健康指标"
            ]
        case 18..<23:
            healthSuggestions = [
                "🏃 「今天运动了多少？」— 查看运动情况",
                "🌙 「这周睡眠怎么样？」— 查看睡眠趋势"
            ]
        default:
            healthSuggestions = [
                "🌙 「这周睡眠怎么样？」— 查看睡眠数据",
                "🏃 「最近运动情况怎么样？」— 查看运动趋势"
            ]
        }

        // Calendar suggestions by time of day
        switch hour {
        case 6..<12:
            calendarSuggestions = ["📅 「今天有什么安排？」— 查看日历行程"]
        case 12..<18:
            calendarSuggestions = ["📅 「下午还有什么会？」— 查看剩余行程"]
        case 18..<23:
            calendarSuggestions = ["📅 「明天有什么安排？」— 提前看日程"]
        default:
            calendarSuggestions = ["📅 「明天有什么安排？」— 查看日程"]
        }

        // Photo suggestions by time of day
        switch hour {
        case 6..<12:
            photoSuggestions = ["📸 「最近拍了哪些照片？」— 浏览相册统计"]
        case 12..<18:
            photoSuggestions = ["📸 「帮我找海边的照片」— 搜索记忆"]
        case 18..<23:
            photoSuggestions = ["📸 「今天拍了什么照片？」— 浏览今天的记忆"]
        default:
            photoSuggestions = ["📸 「这个月拍了多少照片？」— 相册统计"]
        }

        // Location suggestions by time of day
        switch hour {
        case 6..<12:
            locationSuggestions = ["📍 「最近去过哪些地方？」— 回顾足迹"]
        case 12..<18:
            locationSuggestions = ["📍 「这周去了哪些地方？」— 回顾足迹"]
        case 18..<23:
            locationSuggestions = ["📍 「今天去了哪些地方？」— 回顾足迹"]
        default:
            locationSuggestions = ["📍 「最近常去哪些地方？」— 回顾常去场所"]
        }

        // Summary suggestion (always available — works even with partial data)
        let summarySuggestion: String
        switch hour {
        case 18..<23:
            summarySuggestion = "📋 「帮我总结今天」— 回顾一天的数据"
        default:
            summarySuggestion = "📋 「帮我总结这周」— 一周数据回顾"
        }

        // Build final list: only include enabled categories, fill up to 5 suggestions
        var result: [String] = []

        // Priority order varies by time of day for more natural feel
        let isEvening = hour >= 18 && hour < 23
        let isMorning = hour >= 6 && hour < 12

        // Always add summary as first option in evening, otherwise add at end
        if isEvening {
            result.append(summarySuggestion)
        }

        // Health (highest priority — most common query)
        if permissions.hasHealth {
            result.append(contentsOf: healthSuggestions.prefix(isMorning ? 2 : 1))
        }

        // Calendar
        if permissions.hasCalendar {
            result.append(contentsOf: calendarSuggestions)
        }

        // Location
        if permissions.hasLocation {
            result.append(contentsOf: locationSuggestions)
        }

        // Photos
        if permissions.hasPhotos {
            result.append(contentsOf: photoSuggestions)
        }

        // Add summary if not already added (non-evening)
        if !isEvening {
            result.append(summarySuggestion)
        }

        // If very few permissions enabled, add extra suggestions from enabled categories
        if permissions.enabledCount <= 1 {
            // With few permissions, suggest the record feature more prominently
            result.append("📝 「记录：今天和朋友吃了火锅」— 记录生活事件")
        }

        // Cap at 5 suggestions to avoid overwhelming
        return Array(result.prefix(5))
    }

    // MARK: - Permission Guide

    /// Builds a gentle guide for missing permissions.
    /// Only shown when at least one core permission is missing.
    /// Uses a compact format to avoid being preachy.
    private func buildPermissionGuide(permissions: PermissionState) -> String {
        // If all permissions are enabled, no guide needed
        if permissions.enabledCount == 4 { return "" }

        // If no permissions at all, show a comprehensive onboarding guide
        if permissions.enabledCount == 0 {
            return """
            🔐 开启权限，解锁更多能力：
              • 健康 → 查看运动、睡眠、心率
              • 日历 → 查看日程安排
              • 照片 → 搜索和分析记忆
              • 位置 → 回顾去过的地方
            前往「设置 → iosclaw」一键开启。
            """
        }

        // 1–3 permissions missing: show only the missing ones
        var missing: [String] = []
        if !permissions.hasHealth {
            missing.append("「健康」→ 运动/睡眠/心率")
        }
        if !permissions.hasCalendar {
            missing.append("「日历」→ 日程安排")
        }
        if !permissions.hasPhotos {
            missing.append("「照片」→ 记忆搜索")
        }
        if !permissions.hasLocation {
            missing.append("「位置」→ 足迹回顾")
        }

        if missing.count == 1 {
            return "💡 开启\(missing[0])权限，体验更完整。前往「设置 → iosclaw」开启。"
        }

        let items = missing.map { "  • \($0)" }.joined(separator: "\n")
        return "💡 还有 \(missing.count) 项权限未开启：\n\(items)\n前往「设置 → iosclaw」开启。"
    }
}

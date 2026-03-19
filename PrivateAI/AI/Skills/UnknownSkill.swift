import Foundation

/// Fallback skill for unrecognized queries.
/// Provides context-aware, time-sensitive suggestions that prioritize
/// core iOS data skills (health, location, calendar, photos) over utility tools.
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
            let recentTopics = memory.mentionedTopics
            if !recentTopics.isEmpty {
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

        // --- Time-of-day aware core suggestions ---
        let coreSuggestions = buildTimeSensitiveSuggestions()

        // --- New user guide ---
        let isNewUser = contextMemory?.recentMessages.isEmpty ?? true
        let newUserGuide = isNewUser
            ? "\n\n💡 第一次用？试试告诉我：「今天去健身了，感觉很好」——我会帮你记录生活点滴。"
            : ""

        let response = """
        \(intro)

        \(opening)不过，我最擅长帮你了解「自己」：

        \(coreSuggestions.joined(separator: "\n"))

        💬 你也可以直接告诉我今天做了什么，我帮你记下来。\(newUserGuide)
        """

        completion(response.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Time-Sensitive Suggestions

    /// Builds 5-6 focused suggestions based on current time of day.
    /// Morning → sleep review + today's calendar
    /// Afternoon → exercise + location + photos
    /// Evening → daily summary + week review
    /// Always includes core iOS data skills, never utility tools.
    private func buildTimeSensitiveSuggestions() -> [String] {
        let hour = Calendar.current.component(.hour, from: Date())

        // Always-present core suggestions (randomized order per category)
        var suggestions: [String] = []

        switch hour {
        case 6..<12:
            // Morning: sleep review, today's schedule, exercise check
            suggestions = [
                "🛌 「昨晚睡得怎么样？」— 查看睡眠质量",
                "📅 「今天有什么安排？」— 查看日历行程",
                "🏃 「这周运动了多少？」— 查看运动数据",
                "📍 「最近去过哪些地方？」— 回顾足迹",
                "📸 「最近拍了哪些照片？」— 浏览相册统计"
            ]
        case 12..<18:
            // Afternoon: exercise, location, photos, calendar
            suggestions = [
                "🏃 「今天走了多少步？」— 查看运动数据",
                "📅 「下午还有什么会？」— 查看剩余行程",
                "📍 「这周去了哪些地方？」— 回顾足迹",
                "📸 「帮我找海边的照片」— 搜索记忆",
                "❤️ 「我的心率怎么样？」— 查看健康指标"
            ]
        case 18..<23:
            // Evening: daily summary, reflection, next day prep
            suggestions = [
                "📋 「帮我总结今天」— 回顾一天的数据",
                "🏃 「今天运动了多少？」— 查看运动情况",
                "📅 「明天有什么安排？」— 提前看日程",
                "📍 「今天去了哪些地方？」— 回顾足迹",
                "🌙 「这周睡眠怎么样？」— 查看睡眠趋势"
            ]
        default:
            // Late night / early morning: sleep, weekly review, calm
            suggestions = [
                "🌙 「这周睡眠怎么样？」— 查看睡眠数据",
                "📋 「帮我总结这周」— 一周数据回顾",
                "🏃 「最近运动情况怎么样？」— 查看运动趋势",
                "📍 「最近常去哪些地方？」— 回顾常去场所",
                "📸 「这个月拍了多少照片？」— 相册统计"
            ]
        }

        return suggestions
    }
}

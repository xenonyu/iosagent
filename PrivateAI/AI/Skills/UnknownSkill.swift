import Foundation

/// Fallback skill for unrecognized queries.
/// Provides a context-aware help message with example queries.
struct UnknownSkill: ClawSkill {

    let id = "unknown"

    func canHandle(intent: QueryIntent) -> Bool {
        if case .unknown = intent { return true }
        return false
    }

    func execute(intent: QueryIntent, context: SkillContext, completion: @escaping (String) -> Void) {
        let query = context.originalQuery
        let contextMemory = context.contextMemory

        var opening = ""
        if let memory = contextMemory, let _ = memory.buildContextHint() {
            let recentTopics = memory.mentionedTopics
            if !recentTopics.isEmpty {
                opening = "基于你刚才提到的「\(recentTopics.last ?? "")」，我稍微有点没跟上这个问题。\n\n"
            } else if let hint = memory.buildContextHint() {
                opening = "（近期话题：\(hint)）\n\n"
            }
        }

        let intros = [
            "🤔 我理解你在问：「\(query)」",
            "💭 关于「\(query)」，我来帮你想想",
            "🙂 「\(query)」——让我看看我能做些什么",
            "🤖 收到！关于「\(query)」，我先说明一下我的能力范围"
        ]
        let intro = intros[Int.random(in: 0..<intros.count)]

        let isNewUser = contextMemory?.recentMessages.isEmpty ?? true
        let emptyDataGuide = isNewUser
            ? "\n\n💡 看起来你刚开始使用，先试着告诉我今天做了什么，比如：「今天去健身了，感觉很好」，我会帮你记录下来！"
            : ""

        let suggestions = [
            "• 「我上周做了什么运动？」",
            "• 「最近去过哪些地方？」",
            "• 「帮我总结这个月的生活」",
            "• 「我最近的心情怎么样？」",
            "• 「给老婆推荐礼物」",
            "• 「我今天的日历行程」",
            "• 「最近拍了多少照片」",
            "• 「今天跑步了5公里，感觉很棒」（记录事件）"
        ]

        completion("\(intro)\n\n\(opening)我目前最擅长回答：\n\n\(suggestions.joined(separator: "\n"))\(emptyDataGuide)\n\n或者直接告诉我你做了什么，我会帮你记录下来！")
    }
}

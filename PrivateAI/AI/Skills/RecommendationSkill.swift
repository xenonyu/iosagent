import Foundation

/// Handles personalized gift and lifestyle recommendation queries.
struct RecommendationSkill: ClawSkill {

    let id = "recommendation"

    func canHandle(intent: QueryIntent) -> Bool {
        if case .recommendation = intent { return true }
        return false
    }

    func execute(intent: QueryIntent, context: SkillContext, completion: @escaping (String) -> Void) {
        guard case .recommendation(let topic) = intent else { return }
        completion(buildResponse(topic: topic, profile: context.profile))
    }

    private func buildResponse(topic: String, profile: UserProfileData) -> String {
        switch topic {
        case "gift_wife":
            return buildGiftResponse(for: "老婆", profile: profile, defaults: [
                "💐 鲜花或精品护肤套装（了解她常用品牌）",
                "💍 定制首饰，刻上特别日期或名字",
                "📖 她喜欢的书籍或课程订阅",
                "🍽 预约一家她一直想去的餐厅",
                "✈️ 一次她一直想去的小旅行",
                "🛁 高品质浴室套装，让她放松一下",
                "💆‍♀️ 专业 SPA 或按摩体验"
            ])

        case "gift_husband":
            return buildGiftResponse(for: "老公", profile: profile, defaults: [
                "⌚ 他一直想要的手表或电子产品",
                "🎮 游戏或他感兴趣的装备",
                "👔 质感好的衬衫或西装",
                "🍺 精酿啤酒或威士忌套装",
                "🎯 他的兴趣爱好相关装备",
                "📚 专业书籍或在线课程",
                "🍳 高端厨具（如果他爱做饭）"
            ])

        case "gift_mother":
            return buildGiftResponse(for: "妈妈", profile: profile, defaults: [
                "💐 高档鲜花礼盒",
                "🧴 适合中年女性的护肤品",
                "👗 舒适时尚的衣物",
                "🎶 健康理疗仪器（颈椎按摩仪等）",
                "🍵 好茶叶套装",
                "📱 教她用好手机的实用课程",
                "🍽 一起吃一顿好饭"
            ])

        default:
            return "🎁 送礼建议：\n\n最好的礼物是了解对方真正需要什么。\n\n可以告诉我更多信息：\n• 对方的兴趣爱好\n• 预算范围\n• 场合/原因\n\n我会给你更精准的建议！"
        }
    }

    private func buildGiftResponse(for person: String, profile: UserProfileData, defaults: [String]) -> String {
        var lines = ["🎁 送\(person)礼物建议：\n"]

        let familyMember = profile.familyMembers.first {
            person.contains("老婆") || person.contains("妻") ? $0.relation.contains("妻") || $0.relation.contains("老婆") : false
        }
        if let member = familyMember, !member.notes.isEmpty {
            lines.append("💡 根据你的记录，她 \(member.notes)\n")
        }

        lines.append(contentsOf: defaults.map { "• \($0)" })
        lines.append("\n💬 告诉我更多她的喜好，我可以给出更个性化的建议！")
        return lines.joined(separator: "\n")
    }
}

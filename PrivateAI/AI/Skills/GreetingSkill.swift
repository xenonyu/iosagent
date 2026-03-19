import Foundation

/// Handles conversational greetings, thanks, farewells, and self-introduction.
/// Makes the assistant feel natural and responsive to everyday social cues.
struct GreetingSkill: ClawSkill {

    let id = "greeting"

    func canHandle(intent: QueryIntent) -> Bool {
        if case .greeting = intent { return true }
        return false
    }

    func execute(intent: QueryIntent, context: SkillContext, completion: @escaping (String) -> Void) {
        guard case .greeting(let type) = intent else {
            completion("你好！有什么可以帮你的吗？")
            return
        }

        let userName = context.profile.name.isEmpty ? "" : context.profile.name
        let hour = Calendar.current.component(.hour, from: Date())

        switch type {
        case .hello:
            completion(buildHelloResponse(userName: userName, hour: hour))
        case .thanks:
            completion(buildThanksResponse(userName: userName))
        case .farewell:
            completion(buildFarewellResponse(userName: userName, hour: hour))
        case .presence:
            completion(buildPresenceResponse(userName: userName))
        case .selfIntro:
            completion(buildSelfIntroResponse())
        case .howAreYou:
            completion(buildHowAreYouResponse(userName: userName))
        }
    }

    // MARK: - Response Builders

    private func buildHelloResponse(userName: String, hour: Int) -> String {
        let greeting: String
        switch hour {
        case 6..<12: greeting = "早上好"
        case 12..<14: greeting = "中午好"
        case 14..<18: greeting = "下午好"
        case 18..<22: greeting = "晚上好"
        default: greeting = "夜深了"
        }

        let name = userName.isEmpty ? "" : "，\(userName)"

        let tips = [
            "有什么我能帮到你的吗？",
            "今天想了解些什么？",
            "需要我帮你回顾一下最近的生活吗？",
            "想查看健康数据、日程安排还是其他？",
            "随时告诉我你需要什么帮助！"
        ]
        let tip = tips[Int.random(in: 0..<tips.count)]

        return "\(greeting)\(name)！😊 \(tip)"
    }

    private func buildThanksResponse(userName: String) -> String {
        let responses = [
            "不客气！随时都可以找我帮忙 😊",
            "很高兴能帮到你！还有什么需要的吗？",
            "不用谢！这是我应该做的 🤗",
            "客气啦！有任何问题随时问我 ✨",
            "能帮到你真好！下次有需要再叫我 😄"
        ]
        return responses[Int.random(in: 0..<responses.count)]
    }

    private func buildFarewellResponse(userName: String, hour: Int) -> String {
        let name = userName.isEmpty ? "" : "，\(userName)"

        if hour >= 22 || hour < 6 {
            let nightResponses = [
                "晚安\(name)！祝你做个好梦 🌙",
                "晚安\(name)！好好休息，明天见 💤",
                "晚安\(name)！早点休息哦 🌟"
            ]
            return nightResponses[Int.random(in: 0..<nightResponses.count)]
        }

        let responses = [
            "再见\(name)！下次聊 👋",
            "拜拜\(name)！随时都可以回来找我 😊",
            "下次见\(name)！祝你接下来一切顺利 ✨"
        ]
        return responses[Int.random(in: 0..<responses.count)]
    }

    private func buildPresenceResponse(userName: String) -> String {
        let name = userName.isEmpty ? "" : "，\(userName)"
        let responses = [
            "我在呢\(name)！有什么事吗？😊",
            "在的在的！需要帮忙吗？🙋",
            "我一直在\(name)！说吧，什么事？✨",
            "嗯嗯，我在！你说 😄"
        ]
        return responses[Int.random(in: 0..<responses.count)]
    }

    private func buildSelfIntroResponse() -> String {
        return """
        我是 iosclaw 🤖 —— 你的本地私人 AI 助理！

        我运行在你的 iPhone 上，所有数据都保存在本地，不会上传到任何服务器。

        我能帮你做这些事：
        • 📊 查看健康数据（步数、运动、睡眠）
        • 📍 回顾你去过的地方
        • 📅 查看日历行程
        • 📝 记录生活事件和心情
        • ✅ 管理待办事项
        • 🎯 追踪习惯打卡
        • ⏳ 倒计时重要日子
        • 🎲 随机决策（抛硬币、掷骰子、帮你选）
        • 💧 喝水追踪和提醒
        • 🔢 计算器和单位换算
        • 🧘 呼吸练习和放松冥想
        • 💡 生活建议和推荐
        • 📸 搜索和统计照片

        随便问我什么试试吧！
        """
    }

    private func buildHowAreYouResponse(userName: String) -> String {
        let responses = [
            "我很好呀，谢谢关心！😊 你今天过得怎么样？",
            "我一切正常，随时准备为你服务！你呢，今天感觉如何？",
            "我状态满分！💪 有什么我能帮到你的吗？",
            "谢谢你的关心！我一直都在这里等你呢 😄 你最近好吗？"
        ]
        return responses[Int.random(in: 0..<responses.count)]
    }
}

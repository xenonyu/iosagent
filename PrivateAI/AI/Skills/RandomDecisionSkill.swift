import Foundation

/// Helps users make random decisions — coin flips, dice rolls, picking from options, random numbers.
/// A fun and practical assistant feature, 100% local.
struct RandomDecisionSkill: ClawSkill {

    let id = "randomDecision"

    func canHandle(intent: QueryIntent) -> Bool {
        if case .randomDecision = intent { return true }
        return false
    }

    func execute(intent: QueryIntent, context: SkillContext, completion: @escaping (String) -> Void) {
        guard case .randomDecision(let action) = intent else {
            completion("🎲 需要帮你做随机决定吗？试试「抛硬币」「掷骰子」或「帮我选 A还是B」！")
            return
        }

        switch action {
        case .coinFlip:
            completion(coinFlip())
        case .diceRoll(let sides):
            completion(diceRoll(sides: sides))
        case .pickOne(let options):
            completion(pickOne(from: options))
        case .randomNumber(let min, let max):
            completion(randomNumber(min: min, max: max))
        }
    }

    // MARK: - Coin Flip

    private func coinFlip() -> String {
        let isHeads = Bool.random()
        let result = isHeads ? "正面 👑" : "反面 🌙"
        let comments = isHeads
            ? ["运气不错！", "正面朝上！", "看来今天运势不错哦！"]
            : ["反面朝上！", "命运之币给出了答案！", "嗯，反面！"]
        let comment = comments[Int.random(in: 0..<comments.count)]

        return """
        🪙 抛硬币结果：**\(result)**

        \(comment)
        """
    }

    // MARK: - Dice Roll

    private func diceRoll(sides: Int) -> String {
        let actualSides = max(2, min(sides, 100))
        let result = Int.random(in: 1...actualSides)

        let emoji: String
        if actualSides == 6 {
            let diceEmojis = ["⚀", "⚁", "⚂", "⚃", "⚄", "⚅"]
            emoji = diceEmojis[result - 1]
        } else {
            emoji = "🎲"
        }

        var response = "\(emoji) 掷骰子结果（\(actualSides)面）：**\(result)**"

        if actualSides == 6 {
            if result == 6 {
                response += "\n\n🎉 满分！今天运气爆棚！"
            } else if result == 1 {
                response += "\n\n😅 最小值...不过运气是守恒的！"
            }
        }

        return response
    }

    // MARK: - Pick One

    private func pickOne(from options: [String]) -> String {
        guard !options.isEmpty else {
            return "🤔 你想让我帮你从哪些选项中选呢？试试：「帮我选 火锅还是烧烤还是麻辣烫」"
        }

        if options.count == 1 {
            return "😄 只有一个选项「\(options[0])」，那就它了！不用纠结啦～"
        }

        let chosen = options[Int.random(in: 0..<options.count)]

        let intros = [
            "🎯 我替你做了选择：",
            "✨ 命运之轮转动后，结果是：",
            "🎪 当当当～选中的是：",
            "🔮 直觉告诉我，你应该选："
        ]
        let intro = intros[Int.random(in: 0..<intros.count)]

        var response = "\(intro)**\(chosen)**！"

        let optionList = options.enumerated().map { idx, opt in
            opt == chosen ? "• \(opt) ✅" : "• \(opt)"
        }.joined(separator: "\n")

        response += "\n\n候选项：\n\(optionList)"

        let encouragements = [
            "\n\n别犹豫，就它了！😊",
            "\n\n相信缘分的选择吧～",
            "\n\n如果不满意，可以再让我选一次！",
            "\n\n直觉很重要，试试看吧！"
        ]
        response += encouragements[Int.random(in: 0..<encouragements.count)]

        return response
    }

    // MARK: - Random Number

    private func randomNumber(min: Int, max: Int) -> String {
        let lo = Swift.min(min, max)
        let hi = Swift.max(min, max)
        let result = Int.random(in: lo...hi)

        return "🔢 随机数字（\(lo) ~ \(hi)）：**\(result)**"
    }
}

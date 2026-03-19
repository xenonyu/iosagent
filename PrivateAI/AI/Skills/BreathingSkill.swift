import Foundation

/// Guided breathing exercise skill for relaxation and stress relief.
/// Provides multiple breathing techniques with step-by-step text instructions.
/// All processing is local — no network calls.
struct BreathingSkill: ClawSkill {

    let id = "breathing"

    func canHandle(intent: QueryIntent) -> Bool {
        if case .breathing = intent { return true }
        return false
    }

    func execute(intent: QueryIntent, context: SkillContext, completion: @escaping (String) -> Void) {
        guard case .breathing(let type) = intent else {
            completion(buildOverview())
            return
        }

        switch type {
        case .calm478:
            completion(build478Guide())
        case .boxBreathing:
            completion(buildBoxBreathingGuide())
        case .deepBreath:
            completion(buildDeepBreathGuide())
        case .energize:
            completion(buildEnergizeGuide())
        case .sleepAid:
            completion(buildSleepAidGuide())
        case .overview:
            completion(buildOverview())
        }
    }

    // MARK: - Technique Guides

    private func build478Guide() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        let timeNote = hour >= 21 ? "\n\n🌙 睡前做这个练习特别有效，能帮助你更快入睡。" : ""

        return """
        🧘 **4-7-8 呼吸法**（放松与减压）

        这是由安德鲁·韦尔博士推广的经典放松技巧，能快速缓解焦虑。

        📋 步骤（重复 4 轮）：

        1️⃣ 准备：找一个舒适的坐姿，闭上眼睛
        2️⃣ 吸气 — 用鼻子慢慢吸气，心中默数 4 秒
           「1... 2... 3... 4...」
        3️⃣ 屏息 — 温柔地屏住呼吸，默数 7 秒
           「1... 2... 3... 4... 5... 6... 7...」
        4️⃣ 呼气 — 用嘴巴缓慢呼出，默数 8 秒
           「1... 2... 3... 4... 5... 6... 7... 8...」
        5️⃣ 重复以上步骤，共做 4 轮

        ⏱ 总时长约 3 分钟
        💡 初次练习屏息困难，可以先按 2-3.5-4 秒比例尝试\(timeNote)

        做完后告诉我感觉怎么样吧！😊
        """
    }

    private func buildBoxBreathingGuide() -> String {
        return """
        📦 **方块呼吸法**（专注与平静）

        这是美国海豹突击队使用的压力管理技巧，帮助在高压环境下保持冷静和专注。

        📋 步骤（重复 4-6 轮）：

        1️⃣ 吸气 — 用鼻子慢慢吸气，默数 4 秒
           ⬆️「1... 2... 3... 4...」
        2️⃣ 屏息 — 吸满后屏住呼吸，默数 4 秒
           ➡️「1... 2... 3... 4...」
        3️⃣ 呼气 — 慢慢呼出，默数 4 秒
           ⬇️「1... 2... 3... 4...」
        4️⃣ 屏息 — 呼完后再屏住，默数 4 秒
           ⬅️「1... 2... 3... 4...」

        🔄 完成一个"方块"！重复 4-6 次

        ⏱ 总时长约 2-4 分钟
        💡 适合工作间隙、考试前或会议前使用

        做完告诉我你的感受！✨
        """
    }

    private func buildDeepBreathGuide() -> String {
        return """
        🌊 **深呼吸练习**（简单有效）

        最简单的放松方式，随时随地都能做。

        📋 步骤（重复 5-8 次）：

        1️⃣ 坐直或站立，肩膀放松
        2️⃣ 吸气 — 慢慢用鼻子深吸一口气，感受腹部鼓起
           「吸... 吸... 吸...」（约 4 秒）
        3️⃣ 短暂停顿 — 在最高点稍停 1 秒
        4️⃣ 呼气 — 用嘴巴缓慢呼出，比吸气时间更长
           「呼... 呼... 呼... 呼...」（约 6 秒）
        5️⃣ 重复 5-8 次

        ⏱ 总时长约 1-2 分钟
        💡 诀窍：呼气要比吸气长，这样能激活副交感神经，帮助放松

        感觉好些了吗？告诉我吧！😊
        """
    }

    private func buildEnergizeGuide() -> String {
        return """
        ⚡ **活力呼吸法**（提神醒脑）

        感到困倦时，用这个快节奏呼吸法唤醒身体。

        📋 步骤：

        🔥 第一阶段 — 快速呼吸（30 秒）
        1️⃣ 用鼻子快速短促地吸气和呼气
        2️⃣ 每秒约 2 次呼吸，像小狗喘气但用鼻子
        3️⃣ 保持 15-20 次快速呼吸

        ❄️ 第二阶段 — 深度恢复（30 秒）
        4️⃣ 深吸一口气，屏住 10-15 秒
        5️⃣ 缓慢呼出
        6️⃣ 正常呼吸几次

        🔄 重复 2-3 轮

        ⏱ 总时长约 3 分钟
        ⚠️ 注意：如果感到头晕请立即停止并正常呼吸
        💡 不建议在睡前练习，因为会让你更清醒！

        精神有没有好一点？💪
        """
    }

    private func buildSleepAidGuide() -> String {
        return """
        🌙 **助眠呼吸法**（入睡必备）

        睡不着的时候，试试这个放松呼吸序列：

        📋 步骤：

        🛏 第一步 — 身体放松
        1️⃣ 躺在床上，闭上眼睛
        2️⃣ 从头到脚逐渐放松每个部位
        3️⃣ 感受身体沉入床铺

        🌬 第二步 — 4-7-8 呼吸
        4️⃣ 用鼻子吸气 4 秒
        5️⃣ 屏住呼吸 7 秒
        6️⃣ 用嘴呼气 8 秒（发出"呼——"的声音）
        7️⃣ 重复 4 轮

        🧠 第三步 — 思维清空
        8️⃣ 继续缓慢呼吸
        9️⃣ 每次呼气时心中默念"放松"
        🔟 如果脑中有杂念，温柔地把注意力带回呼吸

        ⏱ 整个过程约 5-10 分钟
        💡 坚持几天，你的身体会形成"呼吸→入睡"的条件反射

        祝你好梦！💤
        """
    }

    private func buildOverview() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        let recommendation: String
        switch hour {
        case 6..<10:
            recommendation = "💡 早晨推荐：试试「活力呼吸」唤醒身体"
        case 10..<17:
            recommendation = "💡 工作时间推荐：试试「方块呼吸」保持专注"
        case 17..<21:
            recommendation = "💡 傍晚推荐：试试「深呼吸」缓解一天的疲劳"
        default:
            recommendation = "💡 夜间推荐：试试「助眠呼吸」帮助入睡"
        }

        return """
        🧘 **呼吸练习中心**

        选择适合你的呼吸技巧：

        🌊 **深呼吸** — 最简单，随时随地（1-2 分钟）
           说「深呼吸练习」

        🧘 **4-7-8 呼吸法** — 经典减压技巧（3 分钟）
           说「478呼吸」或「帮我放松」

        📦 **方块呼吸法** — 高效专注力训练（2-4 分钟）
           说「方块呼吸」或「box breathing」

        ⚡ **活力呼吸法** — 快速提神醒脑（3 分钟）
           说「提神呼吸」或「醒醒神」

        🌙 **助眠呼吸法** — 失眠时的救星（5-10 分钟）
           说「睡前呼吸」或「睡不着」

        \(recommendation)
        """
    }
}

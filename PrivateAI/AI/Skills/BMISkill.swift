import Foundation

/// Handles BMI (Body Mass Index) calculation queries.
/// Users can provide height and weight in natural language (Chinese or English)
/// and receive their BMI value with health category and personalized advice.
struct BMISkill: ClawSkill {

    let id = "bmi"

    func canHandle(intent: QueryIntent) -> Bool {
        if case .bmi = intent { return true }
        return false
    }

    func execute(intent: QueryIntent, context: SkillContext, completion: @escaping (String) -> Void) {
        guard case .bmi(let heightCM, let weightKG) = intent else { return }

        // Validate inputs
        guard heightCM > 0, weightKG > 0 else {
            completion(usageHint())
            return
        }

        guard heightCM >= 50, heightCM <= 300 else {
            completion("⚠️ 身高数据似乎不太对哦（\(formatNum(heightCM)) cm）\n\n请输入合理的身高，例如：「我身高170体重65」")
            return
        }

        guard weightKG >= 10, weightKG <= 500 else {
            completion("⚠️ 体重数据似乎不太对哦（\(formatNum(weightKG)) kg）\n\n请输入合理的体重，例如：「我身高170体重65」")
            return
        }

        let heightM = heightCM / 100.0
        let bmi = weightKG / (heightM * heightM)
        let category = bmiCategory(bmi)

        var lines: [String] = []
        lines.append("📊 **BMI 计算结果**\n")
        lines.append("身高：\(formatNum(heightCM)) cm")
        lines.append("体重：\(formatNum(weightKG)) kg")
        lines.append("BMI：**\(String(format: "%.1f", bmi))**")
        lines.append("")
        lines.append("\(category.emoji) 分类：**\(category.name)**")
        lines.append("")
        lines.append(category.advice)

        // Healthy weight range
        let lowWeight = 18.5 * heightM * heightM
        let highWeight = 24.0 * heightM * heightM
        lines.append("")
        lines.append("📏 你的健康体重范围：\(formatNum(lowWeight)) ~ \(formatNum(highWeight)) kg")

        // Personalized note using profile name
        if !context.profile.name.isEmpty {
            lines.append("")
            lines.append("💡 \(context.profile.name)，BMI 仅供参考，实际健康状况还需结合体脂率、肌肉量等指标综合判断哦！")
        } else {
            lines.append("")
            lines.append("💡 BMI 仅供参考，实际健康状况还需结合体脂率、肌肉量等指标综合判断哦！")
        }

        completion(lines.joined(separator: "\n"))
    }

    // MARK: - Category

    private struct BMICategory {
        let name: String
        let emoji: String
        let advice: String
    }

    /// WHO standard BMI categories adapted for Asian populations.
    private func bmiCategory(_ bmi: Double) -> BMICategory {
        switch bmi {
        case ..<18.5:
            return BMICategory(
                name: "偏瘦",
                emoji: "🔵",
                advice: "你的体重偏轻，建议适当增加营养摄入，保证蛋白质和碳水化合物的均衡，同时配合适度的力量训练。"
            )
        case 18.5..<24.0:
            return BMICategory(
                name: "正常",
                emoji: "🟢",
                advice: "你的体重在健康范围内，继续保持良好的饮食和运动习惯吧！💪"
            )
        case 24.0..<28.0:
            return BMICategory(
                name: "偏胖",
                emoji: "🟡",
                advice: "体重稍微偏高，建议控制饮食、减少高热量食物，增加有氧运动如快走、跑步或游泳。"
            )
        case 28.0..<35.0:
            return BMICategory(
                name: "肥胖",
                emoji: "🟠",
                advice: "建议关注体重管理，制定合理的减重计划。可以从每天步行 30 分钟开始，逐步增加运动量，同时注意饮食结构。"
            )
        default:
            return BMICategory(
                name: "重度肥胖",
                emoji: "🔴",
                advice: "建议尽早咨询医生或营养师，制定科学的健康管理方案。循序渐进地改善饮食和运动习惯。"
            )
        }
    }

    // MARK: - Helpers

    private func formatNum(_ value: Double) -> String {
        if value == value.rounded() {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }

    private func usageHint() -> String {
        return """
        📊 **BMI 计算器**

        告诉我你的身高和体重，我来帮你计算 BMI！

        💬 试试这样说：
        • 「我身高175体重70」
        • 「身高165cm 体重55kg」
        • 「BMI 180 75」
        • 「calculate BMI height 170 weight 65」
        """
    }
}

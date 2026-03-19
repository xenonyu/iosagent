import Foundation

/// Calculates optimal sleep/wake times based on 90-minute sleep cycles.
///
/// Sleep science: each cycle is ~90 minutes. Waking between cycles feels more refreshed.
/// Recommended: 5–6 cycles (7.5–9 hours) per night, plus ~15 min to fall asleep.
///
/// Supported queries:
/// - "几点睡觉" / "我想6点起床" → suggests bedtimes for a target wake time
/// - "我打算11点睡" / "现在睡觉几点起" → suggests wake times for a target bedtime
/// - "睡眠计算" (no specific time) → shows both directions with current time defaults
struct SleepCalculatorSkill: ClawSkill {

    let id = "sleepCalculator"

    func canHandle(intent: QueryIntent) -> Bool {
        if case .sleepCalc = intent { return true }
        return false
    }

    func execute(intent: QueryIntent, context: SkillContext, completion: @escaping (String) -> Void) {
        guard case .sleepCalc(let query) = intent else { return }

        switch query {
        case .bedtimeFor(let wakeHour, let wakeMin):
            completion(suggestBedtimes(wakeHour: wakeHour, wakeMin: wakeMin, context: context))
        case .wakeTimeFor(let sleepHour, let sleepMin):
            completion(suggestWakeTimes(sleepHour: sleepHour, sleepMin: sleepMin, context: context))
        case .overview:
            completion(overviewResponse(context: context))
        }
    }

    // MARK: - Bedtime Suggestions (given wake-up time)

    private func suggestBedtimes(wakeHour: Int, wakeMin: Int, context: SkillContext) -> String {
        let fallAsleepMinutes = 15
        let cycleDuration = 90 // minutes
        let cycles = [6, 5, 4, 3] // prefer more cycles first

        var lines: [String] = []
        lines.append("🌙 **睡眠时间计算器**\n")
        lines.append("⏰ 目标起床时间：**\(formatTime(wakeHour, wakeMin))**\n")
        lines.append("以下是建议的入睡时间（含约 15 分钟入睡时间）：\n")

        for c in cycles {
            let totalMin = c * cycleDuration + fallAsleepMinutes
            let (h, m) = subtractMinutes(fromHour: wakeHour, minute: wakeMin, minutes: totalMin)
            let hours = Double(c * cycleDuration) / 60.0
            let emoji = c >= 5 ? "💚" : (c == 4 ? "💛" : "🟠")
            lines.append("\(emoji) **\(formatTime(h, m))** → \(c) 个周期（\(String(format: "%.1f", hours)) 小时）")
        }

        lines.append("")
        lines.append("💡 **建议**：成年人每晚 5~6 个睡眠周期（7.5~9 小时）最佳。")
        lines.append("尽量在完整周期结束时醒来，会感觉更清爽！")

        if !context.profile.name.isEmpty {
            lines.append("")
            lines.append("😴 \(context.profile.name)，祝你今晚好梦！")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Wake Time Suggestions (given bedtime)

    private func suggestWakeTimes(sleepHour: Int, sleepMin: Int, context: SkillContext) -> String {
        let fallAsleepMinutes = 15
        let cycleDuration = 90 // minutes
        let cycles = [3, 4, 5, 6] // ascending order for wake times

        var lines: [String] = []
        lines.append("☀️ **起床时间计算器**\n")
        lines.append("🛏️ 计划入睡时间：**\(formatTime(sleepHour, sleepMin))**\n")
        lines.append("以下是建议的起床时间（含约 15 分钟入睡时间）：\n")

        for c in cycles {
            let totalMin = c * cycleDuration + fallAsleepMinutes
            let (h, m) = addMinutes(toHour: sleepHour, minute: sleepMin, minutes: totalMin)
            let hours = Double(c * cycleDuration) / 60.0
            let emoji = c >= 5 ? "💚" : (c == 4 ? "💛" : "🟠")
            lines.append("\(emoji) **\(formatTime(h, m))** → \(c) 个周期（\(String(format: "%.1f", hours)) 小时）")
        }

        lines.append("")
        lines.append("💡 **建议**：尽量选择 5~6 个周期的起床时间，避免在深度睡眠中被闹钟吵醒。")

        if !context.profile.name.isEmpty {
            lines.append("")
            lines.append("😴 \(context.profile.name)，晚安好梦！")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Overview

    private func overviewResponse(context: SkillContext) -> String {
        // Default: assume wake at 7:00, sleep now
        let cal = Calendar.current
        let now = Date()
        let currentHour = cal.component(.hour, from: now)
        let currentMin = cal.component(.minute, from: now)

        var lines: [String] = []
        lines.append("🌙 **睡眠周期计算器**\n")
        lines.append("每个睡眠周期约 **90 分钟**，在周期结束时醒来会更精神。\n")

        lines.append("━━━━━━━━━━━━━━━━━━━━")
        lines.append("📌 **如果你现在就睡（\(formatTime(currentHour, currentMin))）**\n")

        let fallAsleep = 15
        let cycleDuration = 90
        for c in [4, 5, 6] {
            let totalMin = c * cycleDuration + fallAsleep
            let (h, m) = addMinutes(toHour: currentHour, minute: currentMin, minutes: totalMin)
            let hours = Double(c * cycleDuration) / 60.0
            let emoji = c >= 5 ? "💚" : "💛"
            lines.append("  \(emoji) \(formatTime(h, m))  ← \(c) 个周期（\(String(format: "%.1f", hours))h）")
        }

        lines.append("")
        lines.append("━━━━━━━━━━━━━━━━━━━━")
        lines.append("💬 **更精确的计算，试试这样说：**")
        lines.append("  • 「我想7点起床，几点睡」")
        lines.append("  • 「我打算11点睡，几点起」")
        lines.append("  • 「6点半起床要几点睡」")
        lines.append("  • 「现在睡几点起最好」")

        return lines.joined(separator: "\n")
    }

    // MARK: - Time Arithmetic

    private func addMinutes(toHour hour: Int, minute: Int, minutes: Int) -> (Int, Int) {
        let totalMinutes = hour * 60 + minute + minutes
        let h = (totalMinutes / 60) % 24
        let m = totalMinutes % 60
        return (h, m)
    }

    private func subtractMinutes(fromHour hour: Int, minute: Int, minutes: Int) -> (Int, Int) {
        var totalMinutes = hour * 60 + minute - minutes
        while totalMinutes < 0 { totalMinutes += 24 * 60 }
        let h = (totalMinutes / 60) % 24
        let m = totalMinutes % 60
        return (h, m)
    }

    private func formatTime(_ hour: Int, _ minute: Int) -> String {
        let period: String
        if hour < 6 {
            period = "凌晨"
        } else if hour < 12 {
            period = "上午"
        } else if hour < 14 {
            period = "中午"
        } else if hour < 18 {
            period = "下午"
        } else if hour < 22 {
            period = "晚上"
        } else {
            period = "深夜"
        }
        return String(format: "%@ %d:%02d", period, hour, minute)
    }
}

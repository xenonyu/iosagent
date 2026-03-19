import Foundation

/// Handles mood and emotion analysis queries.
struct MoodSkill: ClawSkill {

    let id = "mood"

    func canHandle(intent: QueryIntent) -> Bool {
        if case .mood = intent { return true }
        return false
    }

    func execute(intent: QueryIntent, context: SkillContext, completion: @escaping (String) -> Void) {
        guard case .mood(let range) = intent else { return }
        let interval = range.interval
        let events = CDLifeEvent.fetch(from: interval.start, to: interval.end, in: context.coreDataContext)

        if events.isEmpty {
            completion("😊 \(range.label)暂无心情记录。\n通过对话告诉我你今天的心情，我会帮你记录下来！")
            return
        }

        var moodCount: [MoodType: Int] = [:]
        events.forEach { moodCount[$0.mood, default: 0] += 1 }

        let dominant = moodCount.max(by: { $0.value < $1.value })?.key ?? .neutral

        var lines: [String] = ["💭 \(range.label)的心情状态：\n"]
        lines.append("\(dominant.emoji) 主要状态：\(dominant.label)\n")

        MoodType.allCases.forEach { mood in
            if let count = moodCount[mood], count > 0 {
                let bar = String(repeating: "▓", count: min(count, 10))
                lines.append("\(mood.emoji) \(mood.label) \(bar) \(count)次")
            }
        }

        let moodEvents = events.prefix(3)
        if !moodEvents.isEmpty {
            lines.append("\n最近记录：")
            moodEvents.forEach {
                lines.append("• \($0.timestamp.shortDisplay) \($0.mood.emoji) \($0.title)")
            }
        }

        completion(lines.joined(separator: "\n"))
    }
}

import Foundation

/// Stores all registered ClawSkills and routes QueryIntents to the correct one.
/// Skills are matched in registration order — register higher-priority skills first.
final class SkillRegistry {

    private var skills: [ClawSkill] = []

    // MARK: - Registration

    func register(_ skill: ClawSkill) {
        skills.append(skill)
    }

    // MARK: - Execution

    /// Finds the first skill that can handle `intent` and executes it.
    /// Falls back to a generic "不明白" message if no skill matches (defensive).
    func execute(intent: QueryIntent, context: SkillContext, completion: @escaping (String) -> Void) {
        if let matched = skills.first(where: { $0.canHandle(intent: intent) }) {
            matched.execute(intent: intent, context: context, completion: completion)
        } else {
            completion("🤖 无法处理该请求，请尝试换一种方式提问。")
        }
    }
}

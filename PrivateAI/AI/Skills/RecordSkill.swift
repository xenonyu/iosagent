import Foundation

/// Handles saving new life events to CoreData.
struct RecordSkill: ClawSkill {

    let id = "record"

    func canHandle(intent: QueryIntent) -> Bool {
        if case .addEvent = intent { return true }
        return false
    }

    func execute(intent: QueryIntent, context: SkillContext, completion: @escaping (String) -> Void) {
        guard case .addEvent(let title, let content, let mood) = intent else { return }

        let event = LifeEvent(title: title, content: content, mood: mood, category: .life)
        let ctx = context.coreDataContext

        ctx.perform {
            CDLifeEvent.create(from: event, context: ctx)
            try? ctx.save()
            DispatchQueue.main.async {
                completion("✅ 已记录！\n\n\(mood.emoji) \(title)\n\n我会帮你记住这个时刻。你可以随时问我「最近记录了什么」来回顾。")
            }
        }
    }
}

import Foundation
import CoreData

/// Searches life events by keyword, returning matching records sorted by date.
/// Supports fuzzy matching on title and content fields.
struct SearchSkill: ClawSkill {

    let id = "search"

    func canHandle(intent: QueryIntent) -> Bool {
        if case .search = intent { return true }
        return false
    }

    func execute(intent: QueryIntent, context: SkillContext, completion: @escaping (String) -> Void) {
        guard case .search(let keyword) = intent else { return }

        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion("🔍 请告诉我你想搜索什么，比如：「搜索健身」「查找读书」")
            return
        }

        let ctx = context.coreDataContext
        ctx.perform {
            let results = Self.searchEvents(keyword: trimmed, in: ctx)
            let response = Self.buildResponse(keyword: trimmed, results: results)
            DispatchQueue.main.async {
                completion(response)
            }
        }
    }

    // MARK: - CoreData Search

    /// Searches CDLifeEvent by keyword matching title OR content (case-insensitive).
    private static func searchEvents(keyword: String, in context: NSManagedObjectContext) -> [LifeEvent] {
        let request = CDLifeEvent.fetchRequest()
        request.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [
            NSPredicate(format: "title CONTAINS[cd] %@", keyword),
            NSPredicate(format: "content CONTAINS[cd] %@", keyword),
            NSPredicate(format: "tags CONTAINS[cd] %@", keyword)
        ])
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        request.fetchLimit = 20
        return (try? context.fetch(request))?.map { $0.toModel() } ?? []
    }

    // MARK: - Response Builder

    private static func buildResponse(keyword: String, results: [LifeEvent]) -> String {
        guard !results.isEmpty else {
            return "🔍 没有找到与「\(keyword)」相关的记录。\n\n你可以试试其他关键词，或者用更简短的词来搜索。"
        }

        let count = results.count
        let cappedResults = results.prefix(10)

        var lines: [String] = []
        lines.append("🔍 找到 \(count) 条与「\(keyword)」相关的记录：\n")

        for (index, event) in cappedResults.enumerated() {
            let dateStr = event.timestamp.shortDisplay
            let contentPreview = event.content.isEmpty
                ? ""
                : "  \(String(event.content.prefix(40)))\(event.content.count > 40 ? "..." : "")"
            lines.append("\(index + 1). \(event.mood.emoji) \(event.title)  ·  \(dateStr)\(contentPreview)")
        }

        if count > 10 {
            lines.append("\n…还有 \(count - 10) 条记录未显示")
        }

        // Add time span info
        if let oldest = cappedResults.last?.timestamp,
           let newest = cappedResults.first?.timestamp {
            let days = Calendar.current.dateComponents([.day], from: oldest, to: newest).day ?? 0
            if days > 0 {
                lines.append("\n📅 时间跨度：\(newest.shortDisplay) ~ \(oldest.shortDisplay)（\(days)天）")
            }
        }

        return lines.joined(separator: "\n")
    }
}

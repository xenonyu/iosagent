import Foundation

/// Manages simple todo / memo items stored in UserDefaults.
/// Supports adding, listing, completing, and clearing tasks — all local, no CoreData changes.
struct TodoSkill: ClawSkill {

    let id = "todo"

    func canHandle(intent: QueryIntent) -> Bool {
        if case .todo = intent { return true }
        return false
    }

    func execute(intent: QueryIntent, context: SkillContext, completion: @escaping (String) -> Void) {
        guard case .todo(let action, let content) = intent else { return }

        switch action {
        case .add:
            handleAdd(content: content, completion: completion)
        case .list:
            handleList(completion: completion)
        case .complete:
            handleComplete(content: content, completion: completion)
        case .clear:
            handleClear(completion: completion)
        }
    }

    // MARK: - Actions

    private func handleAdd(content: String, completion: @escaping (String) -> Void) {
        guard !content.isEmpty else {
            completion("📝 请告诉我你要添加什么待办事项？\n\n例如：「帮我记个待办：买牛奶」")
            return
        }

        var items = TodoStorage.load()
        let newItem = TodoItem(title: content, createdAt: Date())
        items.append(newItem)
        TodoStorage.save(items)

        let pending = items.filter { !$0.isDone }.count
        completion("✅ 已添加待办：**\(content)**\n\n📋 当前共有 \(pending) 项未完成的待办事项。")
    }

    private func handleList(completion: @escaping (String) -> Void) {
        let items = TodoStorage.load()

        if items.isEmpty {
            completion("📋 你还没有待办事项。\n\n试试说「帮我记个待办：买牛奶」来添加一条吧！")
            return
        }

        let pending = items.filter { !$0.isDone }
        let done = items.filter { $0.isDone }

        var lines: [String] = ["📋 **待办事项清单**\n"]

        if !pending.isEmpty {
            lines.append("📌 未完成（\(pending.count) 项）：")
            for (i, item) in pending.enumerated() {
                let timeStr = item.createdAt.shortDisplay
                lines.append("  \(i + 1). ⬜ \(item.title)  (\(timeStr))")
            }
        }

        if !done.isEmpty {
            lines.append("")
            lines.append("✅ 已完成（\(done.count) 项）：")
            for item in done.suffix(5) {
                lines.append("  ☑️ ~~\(item.title)~~")
            }
            if done.count > 5 {
                lines.append("  …还有 \(done.count - 5) 项已完成")
            }
        }

        completion(lines.joined(separator: "\n"))
    }

    private func handleComplete(content: String, completion: @escaping (String) -> Void) {
        var items = TodoStorage.load()
        let pending = items.filter { !$0.isDone }

        if pending.isEmpty {
            completion("🎉 太棒了，所有待办都已完成！没有需要勾选的项目。")
            return
        }

        // Try matching by index (e.g. "完成第1个待办")
        if let index = extractIndex(from: content), index > 0, index <= pending.count {
            let targetId = pending[index - 1].id
            if let realIndex = items.firstIndex(where: { $0.id == targetId }) {
                items[realIndex].isDone = true
                TodoStorage.save(items)
                completion("✅ 已完成：**\(items[realIndex].title)**\n\n还剩 \(pending.count - 1) 项未完成。")
                return
            }
        }

        // Try matching by keyword
        if !content.isEmpty {
            if let matchIndex = items.firstIndex(where: { !$0.isDone && $0.title.localizedCaseInsensitiveContains(content) }) {
                items[matchIndex].isDone = true
                TodoStorage.save(items)
                let remaining = items.filter { !$0.isDone }.count
                completion("✅ 已完成：**\(items[matchIndex].title)**\n\n还剩 \(remaining) 项未完成。")
                return
            }
        }

        // No match — show list for reference
        var lines = ["🤔 没找到匹配的待办事项。当前未完成的有：\n"]
        for (i, item) in pending.enumerated() {
            lines.append("  \(i + 1). \(item.title)")
        }
        lines.append("\n💡 试试说「完成第1个待办」或「完成 买牛奶」")
        completion(lines.joined(separator: "\n"))
    }

    private func handleClear(completion: @escaping (String) -> Void) {
        let items = TodoStorage.load()
        let doneCount = items.filter { $0.isDone }.count

        if doneCount == 0 {
            completion("📋 没有已完成的待办需要清理。")
            return
        }

        let remaining = items.filter { !$0.isDone }
        TodoStorage.save(remaining)
        completion("🧹 已清理 \(doneCount) 条已完成的待办事项。\n\n📋 还剩 \(remaining.count) 项未完成。")
    }

    // MARK: - Helpers

    private func extractIndex(from text: String) -> Int? {
        // Match patterns like "第1个", "1", "#1"
        let digits = text.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }
        if let num = Int(String(digits)), num > 0 { return num }
        return nil
    }
}

// MARK: - Todo Data Model (UserDefaults-backed)

enum TodoAction {
    case add
    case list
    case complete
    case clear
}

struct TodoItem: Codable, Identifiable {
    var id: UUID = UUID()
    var title: String
    var isDone: Bool = false
    var createdAt: Date
}

/// Simple persistence layer using UserDefaults — no CoreData changes needed.
enum TodoStorage {
    private static let key = "com.iosclaw.todoItems"

    static func load() -> [TodoItem] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([TodoItem].self, from: data) else {
            return []
        }
        return items
    }

    static func save(_ items: [TodoItem]) {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

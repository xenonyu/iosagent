import Foundation

/// Quick note / memo skill stored in UserDefaults.
/// Distinct from TodoSkill (task completion tracking) and RecordSkill (life events with mood).
/// Notes are simple text snippets for quick reference — ideas, passwords, addresses, etc.
struct NoteSkill: ClawSkill {

    let id = "note"

    func canHandle(intent: QueryIntent) -> Bool {
        if case .note = intent { return true }
        return false
    }

    func execute(intent: QueryIntent, context: SkillContext, completion: @escaping (String) -> Void) {
        guard case .note(let action, let content) = intent else { return }

        switch action {
        case .add:
            handleAdd(content: content, completion: completion)
        case .list:
            handleList(completion: completion)
        case .delete:
            handleDelete(content: content, completion: completion)
        case .search:
            handleSearch(keyword: content, completion: completion)
        }
    }

    // MARK: - Add

    private func handleAdd(content: String, completion: @escaping (String) -> Void) {
        guard !content.isEmpty else {
            completion("📝 请告诉我你想记什么？\n\n例如：\n• 「记个笔记：WiFi密码是abc123」\n• 「备忘：周五下午3点面试」\n• 「记住 会议室在3楼306」")
            return
        }

        var notes = NoteStorage.load()
        let newNote = NoteItem(content: content, createdAt: Date())
        notes.insert(newNote, at: 0) // newest first

        // Keep max 100 notes
        if notes.count > 100 {
            notes = Array(notes.prefix(100))
        }

        NoteStorage.save(notes)

        completion("📝 已记录笔记：\n\n「\(content)」\n\n📌 当前共有 \(notes.count) 条笔记。\n💡 说「查看笔记」可以查看所有记录。")
    }

    // MARK: - List

    private func handleList(completion: @escaping (String) -> Void) {
        let notes = NoteStorage.load()

        if notes.isEmpty {
            completion("📝 你还没有笔记。\n\n试试说「记个笔记：下周一交报告」来添加一条吧！")
            return
        }

        var lines: [String] = ["📝 **我的笔记**（共 \(notes.count) 条）\n"]

        let displayNotes = notes.prefix(15)
        for (i, note) in displayNotes.enumerated() {
            let timeStr = note.createdAt.shortDisplay
            let preview = note.content.count > 40
                ? String(note.content.prefix(40)) + "..."
                : note.content
            lines.append("  \(i + 1). \(preview)  (\(timeStr))")
        }

        if notes.count > 15 {
            lines.append("\n  …还有 \(notes.count - 15) 条更早的笔记")
        }

        lines.append("\n💡 说「搜索笔记 关键词」可以查找特定笔记")
        lines.append("💡 说「删除笔记 序号」可以删除笔记")

        completion(lines.joined(separator: "\n"))
    }

    // MARK: - Delete

    private func handleDelete(content: String, completion: @escaping (String) -> Void) {
        var notes = NoteStorage.load()

        if notes.isEmpty {
            completion("📝 没有笔记可以删除。")
            return
        }

        // Try matching by index number
        if let index = extractIndex(from: content), index > 0, index <= notes.count {
            let removed = notes.remove(at: index - 1)
            NoteStorage.save(notes)
            let preview = removed.content.count > 30
                ? String(removed.content.prefix(30)) + "..."
                : removed.content
            completion("🗑️ 已删除笔记：「\(preview)」\n\n📝 还剩 \(notes.count) 条笔记。")
            return
        }

        // Try matching by keyword
        if !content.isEmpty {
            if let matchIndex = notes.firstIndex(where: { $0.content.localizedCaseInsensitiveContains(content) }) {
                let removed = notes.remove(at: matchIndex)
                NoteStorage.save(notes)
                let preview = removed.content.count > 30
                    ? String(removed.content.prefix(30)) + "..."
                    : removed.content
                completion("🗑️ 已删除笔记：「\(preview)」\n\n📝 还剩 \(notes.count) 条笔记。")
                return
            }
        }

        // No match
        var lines = ["🤔 没找到匹配的笔记。最近的笔记有：\n"]
        for (i, note) in notes.prefix(5).enumerated() {
            let preview = note.content.count > 30
                ? String(note.content.prefix(30)) + "..."
                : note.content
            lines.append("  \(i + 1). \(preview)")
        }
        lines.append("\n💡 试试说「删除笔记 1」或「删除笔记 WiFi」")
        completion(lines.joined(separator: "\n"))
    }

    // MARK: - Search

    private func handleSearch(keyword: String, completion: @escaping (String) -> Void) {
        guard !keyword.isEmpty else {
            completion("🔍 请告诉我你想搜索什么？\n\n例如：「搜索笔记 密码」")
            return
        }

        let notes = NoteStorage.load()
        let matched = notes.filter { $0.content.localizedCaseInsensitiveContains(keyword) }

        if matched.isEmpty {
            completion("🔍 没有找到包含「\(keyword)」的笔记。\n\n📝 当前共有 \(notes.count) 条笔记，试试其他关键词？")
            return
        }

        var lines: [String] = ["🔍 找到 \(matched.count) 条包含「\(keyword)」的笔记：\n"]

        for (i, note) in matched.prefix(10).enumerated() {
            let timeStr = note.createdAt.shortDisplay
            lines.append("  \(i + 1). \(note.content)  (\(timeStr))")
        }

        if matched.count > 10 {
            lines.append("\n  …还有 \(matched.count - 10) 条匹配结果")
        }

        completion(lines.joined(separator: "\n"))
    }

    // MARK: - Helpers

    private func extractIndex(from text: String) -> Int? {
        let digits = text.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }
        if let num = Int(String(digits)), num > 0 { return num }
        return nil
    }
}

// MARK: - Note Data Model (UserDefaults-backed)

struct NoteItem: Codable, Identifiable {
    var id: UUID = UUID()
    var content: String
    var createdAt: Date
}

/// Simple persistence layer using UserDefaults — no CoreData changes needed.
enum NoteStorage {
    private static let key = "com.iosclaw.noteItems"

    static func load() -> [NoteItem] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([NoteItem].self, from: data) else {
            return []
        }
        return items
    }

    static func save(_ items: [NoteItem]) {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

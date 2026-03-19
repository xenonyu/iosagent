import Foundation

/// Tracks daily expenses stored in UserDefaults.
/// Supports adding, viewing daily/weekly/monthly summaries, and category breakdown.
/// All data stays on-device — no CoreData changes needed.
struct ExpenseSkill: ClawSkill {

    let id = "expense"

    func canHandle(intent: QueryIntent) -> Bool {
        if case .expense = intent { return true }
        return false
    }

    func execute(intent: QueryIntent, context: SkillContext, completion: @escaping (String) -> Void) {
        guard case .expense(let action, let amount, let category, let note) = intent else { return }

        switch action {
        case .add:
            handleAdd(amount: amount, category: category, note: note, completion: completion)
        case .today:
            handleToday(completion: completion)
        case .week:
            handleWeek(completion: completion)
        case .month:
            handleMonth(completion: completion)
        case .list:
            handleList(completion: completion)
        case .delete:
            handleDelete(completion: completion)
        }
    }

    // MARK: - Add Expense

    private func handleAdd(amount: Double, category: String, note: String, completion: @escaping (String) -> Void) {
        guard amount > 0 else {
            completion("💰 请告诉我金额，例如：「记一笔 午餐 35元」")
            return
        }

        var records = ExpenseStorage.load()
        let record = ExpenseRecord(
            amount: amount,
            category: category,
            note: note,
            createdAt: Date()
        )
        records.append(record)
        ExpenseStorage.save(records)

        let todayTotal = todaySum(records)
        let emoji = categoryEmoji(category)
        let noteStr = note.isEmpty ? "" : "（\(note)）"

        completion("""
        \(emoji) 已记录：**\(formatAmount(amount))** \(category)\(noteStr)

        📊 今日累计消费：**\(formatAmount(todayTotal))**
        """)
    }

    // MARK: - Today Summary

    private func handleToday(completion: @escaping (String) -> Void) {
        let records = ExpenseStorage.load()
        let cal = Calendar.current
        let todayRecords = records.filter { cal.isDateInToday($0.createdAt) }

        if todayRecords.isEmpty {
            completion("💰 今天还没有消费记录。\n\n试试说「记一笔 午餐 35元」来记账吧！")
            return
        }

        let total = todayRecords.reduce(0) { $0 + $1.amount }
        let categoryBreakdown = buildCategoryBreakdown(todayRecords)

        var lines: [String] = ["💰 **今日消费总结**\n"]
        lines.append("📊 总计：**\(formatAmount(total))**（\(todayRecords.count) 笔）\n")
        lines.append(categoryBreakdown)
        lines.append("")
        lines.append("📝 明细：")
        for record in todayRecords.suffix(10) {
            let emoji = categoryEmoji(record.category)
            let time = formatTime(record.createdAt)
            let noteStr = record.note.isEmpty ? "" : " · \(record.note)"
            lines.append("  \(emoji) \(time) \(record.category) \(formatAmount(record.amount))\(noteStr)")
        }

        completion(lines.joined(separator: "\n"))
    }

    // MARK: - Week Summary

    private func handleWeek(completion: @escaping (String) -> Void) {
        let records = ExpenseStorage.load()
        let cal = Calendar.current
        let weekAgo = cal.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let weekRecords = records.filter { $0.createdAt >= weekAgo }

        if weekRecords.isEmpty {
            completion("💰 本周还没有消费记录。")
            return
        }

        let total = weekRecords.reduce(0) { $0 + $1.amount }
        let dailyAvg = total / 7.0
        let categoryBreakdown = buildCategoryBreakdown(weekRecords)

        // Daily breakdown
        var dailyTotals: [(String, Double)] = []
        for dayOffset in (0..<7).reversed() {
            let date = cal.date(byAdding: .day, value: -dayOffset, to: Date()) ?? Date()
            let dayRecords = weekRecords.filter { cal.isDate($0.createdAt, inSameDayAs: date) }
            let dayTotal = dayRecords.reduce(0) { $0 + $1.amount }
            let fmt = DateFormatter()
            fmt.dateFormat = "M/d E"
            fmt.locale = Locale(identifier: "zh_CN")
            dailyTotals.append((fmt.string(from: date), dayTotal))
        }

        var lines: [String] = ["💰 **本周消费总结**\n"]
        lines.append("📊 总计：**\(formatAmount(total))**（\(weekRecords.count) 笔）")
        lines.append("📈 日均：\(formatAmount(dailyAvg))\n")
        lines.append(categoryBreakdown)
        lines.append("")
        lines.append("📅 每日消费：")
        for (day, amount) in dailyTotals {
            let bar = String(repeating: "▓", count: min(Int(amount / max(total / 7.0, 1) * 5), 20))
            lines.append("  \(day)  \(formatAmount(amount)) \(bar)")
        }

        completion(lines.joined(separator: "\n"))
    }

    // MARK: - Month Summary

    private func handleMonth(completion: @escaping (String) -> Void) {
        let records = ExpenseStorage.load()
        let cal = Calendar.current
        let now = Date()
        let monthRecords = records.filter {
            cal.isDate($0.createdAt, equalTo: now, toGranularity: .month)
        }

        if monthRecords.isEmpty {
            completion("💰 本月还没有消费记录。")
            return
        }

        let total = monthRecords.reduce(0) { $0 + $1.amount }
        let dayOfMonth = cal.component(.day, from: now)
        let dailyAvg = total / Double(dayOfMonth)
        let categoryBreakdown = buildCategoryBreakdown(monthRecords)

        // Top 5 single expenses
        let topExpenses = monthRecords.sorted { $0.amount > $1.amount }.prefix(5)

        var lines: [String] = ["💰 **本月消费总结**\n"]
        lines.append("📊 总计：**\(formatAmount(total))**（\(monthRecords.count) 笔）")
        lines.append("📈 日均：\(formatAmount(dailyAvg))\n")
        lines.append(categoryBreakdown)

        if !topExpenses.isEmpty {
            lines.append("")
            lines.append("🔝 最大开销 TOP 5：")
            for (i, record) in topExpenses.enumerated() {
                let emoji = categoryEmoji(record.category)
                let dateStr = record.createdAt.shortDisplay
                let noteStr = record.note.isEmpty ? "" : " · \(record.note)"
                lines.append("  \(i + 1). \(emoji) \(formatAmount(record.amount)) \(record.category)\(noteStr)  (\(dateStr))")
            }
        }

        completion(lines.joined(separator: "\n"))
    }

    // MARK: - List Recent Records

    private func handleList(completion: @escaping (String) -> Void) {
        let records = ExpenseStorage.load()

        if records.isEmpty {
            completion("💰 还没有消费记录。\n\n试试说「记一笔 午餐 35元」来开始记账！")
            return
        }

        let recent = records.suffix(15).reversed()
        var lines: [String] = ["💰 **最近消费记录**\n"]
        for record in recent {
            let emoji = categoryEmoji(record.category)
            let dateStr = record.createdAt.shortDisplay
            let noteStr = record.note.isEmpty ? "" : " · \(record.note)"
            lines.append("  \(emoji) \(dateStr) \(record.category) **\(formatAmount(record.amount))**\(noteStr)")
        }
        lines.append("")
        lines.append("共 \(records.count) 条记录")

        completion(lines.joined(separator: "\n"))
    }

    // MARK: - Delete Last

    private func handleDelete(completion: @escaping (String) -> Void) {
        var records = ExpenseStorage.load()

        if records.isEmpty {
            completion("💰 没有可以删除的消费记录。")
            return
        }

        let removed = records.removeLast()
        ExpenseStorage.save(records)
        let emoji = categoryEmoji(removed.category)
        completion("🗑️ 已删除最近一笔记录：\(emoji) \(removed.category) \(formatAmount(removed.amount))")
    }

    // MARK: - Helpers

    private func todaySum(_ records: [ExpenseRecord]) -> Double {
        let cal = Calendar.current
        return records.filter { cal.isDateInToday($0.createdAt) }.reduce(0) { $0 + $1.amount }
    }

    private func buildCategoryBreakdown(_ records: [ExpenseRecord]) -> String {
        var categoryTotals: [String: Double] = [:]
        for record in records {
            categoryTotals[record.category, default: 0] += record.amount
        }
        let total = records.reduce(0.0) { $0 + $1.amount }
        let sorted = categoryTotals.sorted { $0.value > $1.value }

        var lines: [String] = ["📂 分类明细："]
        for (cat, amount) in sorted {
            let emoji = categoryEmoji(cat)
            let pct = total > 0 ? Int(amount / total * 100) : 0
            lines.append("  \(emoji) \(cat)：\(formatAmount(amount))（\(pct)%）")
        }
        return lines.joined(separator: "\n")
    }

    private func categoryEmoji(_ category: String) -> String {
        switch category {
        case "餐饮": return "🍽️"
        case "交通": return "🚗"
        case "购物": return "🛒"
        case "娱乐": return "🎮"
        case "医疗": return "🏥"
        case "教育": return "📚"
        case "居住": return "🏠"
        default: return "💳"
        }
    }

    private func formatAmount(_ amount: Double) -> String {
        if amount == Double(Int(amount)) {
            return "¥\(Int(amount))"
        }
        return "¥\(String(format: "%.1f", amount))"
    }

    private func formatTime(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: date)
    }
}

// MARK: - Expense Data Model (UserDefaults-backed)

struct ExpenseRecord: Codable, Identifiable {
    var id: UUID = UUID()
    var amount: Double
    var category: String
    var note: String
    var createdAt: Date
}

/// Simple persistence layer using UserDefaults — no CoreData changes needed.
enum ExpenseStorage {
    private static let key = "com.iosclaw.expenseRecords"

    static func load() -> [ExpenseRecord] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let records = try? JSONDecoder().decode([ExpenseRecord].self, from: data) else {
            return []
        }
        return records
    }

    static func save(_ records: [ExpenseRecord]) {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

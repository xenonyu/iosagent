import Foundation

/// Handles location and places queries.
struct LocationSkill: ClawSkill {

    let id = "location"

    func canHandle(intent: QueryIntent) -> Bool {
        if case .location = intent { return true }
        return false
    }

    func execute(intent: QueryIntent, context: SkillContext, completion: @escaping (String) -> Void) {
        guard case .location(let range) = intent else { return }
        let interval = range.interval
        let records = CDLocationRecord.fetch(from: interval.start, to: interval.end, in: context.coreDataContext)

        if records.isEmpty {
            completion("📍 \(range.label)暂无位置记录。\n请确认已开启位置权限，并且在设置中允许后台定位。")
            return
        }

        var placeCount: [String: Int] = [:]
        for r in records {
            placeCount[r.displayName, default: 0] += 1
        }

        var lines: [String] = ["📍 \(range.label)去过的地方：\n"]
        placeCount.sorted { $0.value > $1.value }.prefix(8).forEach { name, count in
            let times = count > 1 ? "（\(count)次）" : ""
            lines.append("• \(name)\(times)")
        }

        if records.count > 8 {
            lines.append("\n共记录了 \(records.count) 个位置点")
        }

        completion(lines.joined(separator: "\n"))
    }
}

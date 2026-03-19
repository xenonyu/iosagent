import Foundation
import CoreLocation

/// Handles location and places queries with rich insights about movement patterns.
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
            completion("📍 \(range.label)暂无位置记录。\n请确认已开启位置权限，并且在设置中允许后台定位。\n\n💡 开启后，iosclaw 会在后台自动记录你去过的地方（不会持续耗电）。")
            return
        }

        let response = buildInsightfulResponse(records: records, range: range)
        completion(response)
    }

    // MARK: - Response Builder

    private func buildInsightfulResponse(records: [LocationRecord], range: QueryTimeRange) -> String {
        var sections: [String] = []

        // Header
        sections.append("📍 \(range.label)的足迹概览")

        // 1. Place frequency ranking with visit insights
        let placeSection = buildPlaceRanking(records: records)
        sections.append(placeSection)

        // 2. New places discovered (only for multi-day ranges)
        if let newPlaces = buildNewPlacesSection(records: records, range: range) {
            sections.append(newPlaces)
        }

        // 3. Time-of-day distribution
        if records.count >= 3 {
            let timeSection = buildTimeDistribution(records: records)
            sections.append(timeSection)
        }

        // 4. Activity summary
        let summary = buildActivitySummary(records: records, range: range)
        sections.append(summary)

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Place Ranking

    private func buildPlaceRanking(records: [LocationRecord]) -> String {
        // Group by place name, track first and last visit
        var placeInfo: [String: PlaceVisitInfo] = [:]
        for r in records {
            let name = r.displayName
            if var info = placeInfo[name] {
                info.count += 1
                if r.timestamp < info.firstVisit { info.firstVisit = r.timestamp }
                if r.timestamp > info.lastVisit { info.lastVisit = r.timestamp }
                placeInfo[name] = info
            } else {
                placeInfo[name] = PlaceVisitInfo(
                    name: name,
                    count: 1,
                    firstVisit: r.timestamp,
                    lastVisit: r.timestamp
                )
            }
        }

        let sorted = placeInfo.values.sorted { $0.count > $1.count }
        let totalPlaces = sorted.count

        var lines: [String] = []

        // Show top places with contextual labels
        for (index, info) in sorted.prefix(6).enumerated() {
            let badge: String
            if index == 0 && info.count >= 3 {
                badge = "📌 "  // Most frequent
            } else if info.count == 1 {
                badge = "🆕 "  // Only visited once
            } else {
                badge = "• "
            }

            let frequency = info.count > 1 ? "（\(info.count)次）" : ""
            let recency = formatRecency(info.lastVisit)
            lines.append("\(badge)\(info.name)\(frequency)\(recency)")
        }

        if totalPlaces > 6 {
            lines.append("  …还有 \(totalPlaces - 6) 个其他地点")
        }

        // Add top place insight
        if let top = sorted.first, top.count >= 3 {
            let percentage = Int(Double(top.count) / Double(records.count) * 100)
            lines.insert("你最常去的地方是 **\(top.name)**，占全部记录的 \(percentage)%\n", at: 0)
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - New Places

    private func buildNewPlacesSection(records: [LocationRecord], range: QueryTimeRange) -> String? {
        // Only meaningful for week+ ranges
        guard range != .today && range != .yesterday else { return nil }

        let cal = Calendar.current
        let interval = range.interval
        let midpoint = interval.start.addingTimeInterval(interval.duration / 2)

        // Places that appear only in the second half of the period
        var firstHalfPlaces = Set<String>()
        var secondHalfOnly: [String] = []

        for r in records {
            if r.timestamp < midpoint {
                firstHalfPlaces.insert(r.displayName)
            }
        }

        var seen = Set<String>()
        for r in records.sorted(by: { $0.timestamp < $1.timestamp }) {
            if r.timestamp >= midpoint && !firstHalfPlaces.contains(r.displayName) {
                if seen.insert(r.displayName).inserted {
                    secondHalfOnly.append(r.displayName)
                }
            }
        }

        guard !secondHalfOnly.isEmpty else { return nil }

        let header = "🗺️ 新探索的地方："
        let items = secondHalfOnly.prefix(4).map { "• \($0)" }
        return ([header] + items).joined(separator: "\n")
    }

    // MARK: - Time Distribution

    private func buildTimeDistribution(records: [LocationRecord]) -> String {
        let cal = Calendar.current
        var morning = 0   // 6-12
        var afternoon = 0 // 12-18
        var evening = 0   // 18-22
        var night = 0     // 22-6

        for r in records {
            let hour = cal.component(.hour, from: r.timestamp)
            switch hour {
            case 6..<12:  morning += 1
            case 12..<18: afternoon += 1
            case 18..<22: evening += 1
            default:      night += 1
            }
        }

        let total = records.count
        let periods: [(String, Int, String)] = [
            ("🌅 早晨", morning, "6-12点"),
            ("☀️ 下午", afternoon, "12-18点"),
            ("🌆 傍晚", evening, "18-22点"),
            ("🌙 夜间", night, "22-6点")
        ]

        // Find the most active period
        let mostActive = periods.max(by: { $0.1 < $1.1 })!
        let mostActivePercent = total > 0 ? Int(Double(mostActive.1) / Double(total) * 100) : 0

        // Build a compact bar chart
        var lines = ["⏰ 外出时段分布："]
        for (label, count, _) in periods where count > 0 {
            let barLength = max(1, Int(Double(count) / Double(total) * 10))
            let bar = String(repeating: "▓", count: barLength) + String(repeating: "░", count: max(0, 10 - barLength))
            let pct = Int(Double(count) / Double(total) * 100)
            lines.append("\(label) \(bar) \(pct)%")
        }

        if mostActivePercent >= 40 {
            lines.append("你\(mostActive.2)出门最多")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Activity Summary

    private func buildActivitySummary(records: [LocationRecord], range: QueryTimeRange) -> String {
        let cal = Calendar.current

        // Count unique days with location data
        var uniqueDays = Set<String>()
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "yyyy-MM-dd"
        for r in records {
            uniqueDays.insert(dayFmt.string(from: r.timestamp))
        }

        // Count unique places
        let uniquePlaces = Set(records.map { $0.displayName }).count

        // Find the most active day
        var dayCount: [String: Int] = [:]
        for r in records {
            let key = dayFmt.string(from: r.timestamp)
            dayCount[key, default: 0] += 1
        }

        var summaryParts: [String] = ["📊 "]

        // Core stats
        summaryParts.append("共 \(records.count) 条记录，\(uniquePlaces) 个不同地点，覆盖 \(uniqueDays.count) 天")

        // Most active day
        if let busiestDay = dayCount.max(by: { $0.value < $1.value }),
           busiestDay.value >= 3,
           let date = dayFmt.date(from: busiestDay.key) {
            let displayFmt = DateFormatter()
            displayFmt.dateFormat = "M月d日（E）"
            displayFmt.locale = Locale(identifier: "zh_CN")
            summaryParts.append("最活跃的一天是 \(displayFmt.string(from: date))，记录了 \(busiestDay.value) 个地点")
        }

        // Average places per day
        if uniqueDays.count >= 3 {
            let avg = Double(records.count) / Double(uniqueDays.count)
            summaryParts.append("平均每天到访 \(String(format: "%.1f", avg)) 个地点")
        }

        return summaryParts.joined(separator: "\n")
    }

    // MARK: - Helpers

    private func formatRecency(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm"
            return "  今天 \(fmt.string(from: date))"
        } else if cal.isDateInYesterday(date) {
            return "  昨天"
        }
        // For older dates, show nothing to keep it clean
        return ""
    }
}

// MARK: - Supporting Types

private struct PlaceVisitInfo {
    let name: String
    var count: Int
    var firstVisit: Date
    var lastVisit: Date
}

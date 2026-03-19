import Foundation
import CoreLocation

/// Handles location and places queries with rich insights about movement patterns.
/// Identifies routine places (home, work, regular spots) from visit time patterns.
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

        // Build enriched place profiles for all sections
        let profiles = buildPlaceProfiles(records: records)

        // 1. Routine places (home/work/regular spots) — the core insight
        if let routineSection = buildRoutinePlaces(profiles: profiles, totalRecords: records.count) {
            sections.append(routineSection)
        }

        // 2. Place frequency ranking with visit insights
        let placeSection = buildPlaceRanking(profiles: profiles, totalRecords: records.count)
        sections.append(placeSection)

        // 3. New places discovered (only for multi-day ranges)
        if let newPlaces = buildNewPlacesSection(records: records, range: range) {
            sections.append(newPlaces)
        }

        // 4. Time-of-day distribution
        if records.count >= 3 {
            let timeSection = buildTimeDistribution(records: records)
            sections.append(timeSection)
        }

        // 5. Activity summary
        let summary = buildActivitySummary(records: records, range: range)
        sections.append(summary)

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Place Profiling

    /// Builds detailed visit profiles for each place, tracking time-of-day and day-of-week patterns.
    /// Also clusters nearby locations (within 200m) that represent the same physical place.
    private func buildPlaceProfiles(records: [LocationRecord]) -> [PlaceProfile] {
        let cal = Calendar.current

        // Step 1: Cluster nearby records into the same place
        // Use the most common displayName as the cluster label
        var clusters: [PlaceCluster] = []

        for r in records {
            var merged = false
            for i in clusters.indices {
                if clusters[i].isNearby(lat: r.latitude, lon: r.longitude) {
                    clusters[i].add(record: r)
                    merged = true
                    break
                }
            }
            if !merged {
                var newCluster = PlaceCluster(anchorLat: r.latitude, anchorLon: r.longitude)
                newCluster.add(record: r)
                clusters.append(newCluster)
            }
        }

        // Step 2: Build a profile for each cluster
        return clusters.map { cluster in
            let name = cluster.bestName
            var profile = PlaceProfile(name: name, count: cluster.records.count)
            profile.firstVisit = cluster.records.map(\.timestamp).min() ?? Date()
            profile.lastVisit = cluster.records.map(\.timestamp).max() ?? Date()

            for r in cluster.records {
                let hour = cal.component(.hour, from: r.timestamp)
                let weekday = cal.component(.weekday, from: r.timestamp) // 1=Sun, 7=Sat

                // Time-of-day buckets
                switch hour {
                case 0..<6:   profile.lateNightCount += 1   // sleeping hours
                case 6..<9:   profile.earlyMorningCount += 1
                case 9..<12:  profile.morningCount += 1
                case 12..<14: profile.lunchCount += 1
                case 14..<18: profile.afternoonCount += 1
                case 18..<21: profile.eveningCount += 1
                default:      profile.nightCount += 1       // 21-24
                }

                // Day-of-week tracking
                let isWeekend = (weekday == 1 || weekday == 7)
                if isWeekend {
                    profile.weekendCount += 1
                } else {
                    profile.weekdayCount += 1
                }

                profile.weekdaySet.insert(weekday)
            }

            return profile
        }.sorted { $0.count > $1.count }
    }

    // MARK: - Routine Place Detection

    /// Identifies semantic places: home, work, and other routine spots.
    private func buildRoutinePlaces(profiles: [PlaceProfile], totalRecords: Int) -> String? {
        // Need enough data to detect routines
        guard profiles.count >= 2, totalRecords >= 5 else { return nil }

        var labels: [(String, PlaceProfile)] = [] // (emoji + label, profile)
        var usedIndices = Set<Int>()

        // Detect HOME: place with highest night + early morning ratio
        // Home is where you sleep — most visits during 22:00-8:00
        if let homeIdx = detectHome(profiles: profiles) {
            let p = profiles[homeIdx]
            let homeHours = p.lateNightCount + p.nightCount + p.earlyMorningCount
            let ratio = Double(homeHours) / Double(p.count)
            // Require at least 40% of visits during home hours, or it's the most frequent overall
            if ratio >= 0.4 || (homeIdx == 0 && p.count >= 3) {
                let pattern = describeHomePattern(p)
                labels.append(("🏠 \(p.name)" + pattern, p))
                usedIndices.insert(homeIdx)
            }
        }

        // Detect WORK: place with highest weekday 9-18 ratio, excluding home
        if let workIdx = detectWork(profiles: profiles, excludeIndices: usedIndices) {
            let p = profiles[workIdx]
            let workHours = p.morningCount + p.lunchCount + p.afternoonCount
            let weekdayRatio = p.count > 0 ? Double(p.weekdayCount) / Double(p.count) : 0
            if workHours >= 2 && weekdayRatio >= 0.6 {
                let pattern = describeWorkPattern(p)
                labels.append(("🏢 \(p.name)" + pattern, p))
                usedIndices.insert(workIdx)
            }
        }

        // Detect REGULAR spots: places with consistent patterns
        for (i, p) in profiles.enumerated() {
            guard !usedIndices.contains(i), p.count >= 2 else { continue }
            guard labels.count < 5 else { break }

            if let routineLabel = detectRoutinePattern(p) {
                labels.append((routineLabel, p))
                usedIndices.insert(i)
            }
        }

        guard !labels.isEmpty else { return nil }

        var lines = ["🏷️ 你的日常据点："]
        for (label, _) in labels {
            lines.append(label)
        }

        return lines.joined(separator: "\n")
    }

    /// Detects the most likely home location.
    private func detectHome(profiles: [PlaceProfile]) -> Int? {
        var bestIdx = -1
        var bestScore: Double = -1

        for (i, p) in profiles.enumerated() {
            guard p.count >= 2 else { continue }

            // Home score = night visits weight + early morning weight + weekend presence
            let nightScore = Double(p.lateNightCount + p.nightCount) * 3.0
            let morningScore = Double(p.earlyMorningCount) * 2.0
            let weekendBonus = Double(p.weekendCount) * 1.5
            let frequencyBonus = Double(p.count) * 0.5

            let score = nightScore + morningScore + weekendBonus + frequencyBonus

            if score > bestScore {
                bestScore = score
                bestIdx = i
            }
        }

        return bestIdx >= 0 ? bestIdx : nil
    }

    /// Detects the most likely work location.
    private func detectWork(profiles: [PlaceProfile], excludeIndices: Set<Int>) -> Int? {
        var bestIdx = -1
        var bestScore: Double = -1

        for (i, p) in profiles.enumerated() {
            guard !excludeIndices.contains(i), p.count >= 2 else { continue }

            // Work score = weekday daytime visits weight
            let daytimeScore = Double(p.morningCount + p.lunchCount + p.afternoonCount) * 3.0
            let weekdayBonus = Double(p.weekdayCount) * 2.0
            let consistencyBonus = Double(p.weekdaySet.count) * 1.0 // visits across different days

            let score = daytimeScore + weekdayBonus + consistencyBonus

            if score > bestScore {
                bestScore = score
                bestIdx = i
            }
        }

        return bestIdx >= 0 ? bestIdx : nil
    }

    /// Identifies routine patterns for non-home, non-work places.
    private func detectRoutinePattern(_ p: PlaceProfile) -> String? {
        let total = p.count
        guard total >= 2 else { return nil }

        // Evening regular (gym, restaurant, etc.)
        let eveningRatio = Double(p.eveningCount) / Double(total)
        if eveningRatio >= 0.5 && p.eveningCount >= 2 {
            let dayNote = p.weekendCount > p.weekdayCount ? "周末" : "工作日"
            return "🌆 \(p.name)  \(dayNote)傍晚常去（\(total)次）"
        }

        // Weekend spot
        let weekendRatio = total > 0 ? Double(p.weekendCount) / Double(total) : 0
        if weekendRatio >= 0.7 && p.weekendCount >= 2 {
            return "🎉 \(p.name)  周末常去（\(total)次）"
        }

        // Lunch spot
        let lunchRatio = Double(p.lunchCount) / Double(total)
        if lunchRatio >= 0.5 && p.lunchCount >= 2 {
            return "🍜 \(p.name)  午餐时段常去（\(total)次）"
        }

        // Morning routine (coffee shop, park, etc.)
        let earlyRatio = Double(p.earlyMorningCount + p.morningCount) / Double(total)
        if earlyRatio >= 0.6 && (p.earlyMorningCount + p.morningCount) >= 2 {
            return "☀️ \(p.name)  早晨常去（\(total)次）"
        }

        // General frequent place
        if total >= 3 {
            return "📍 \(p.name)  经常到访（\(total)次）"
        }

        return nil
    }

    /// Describes home visit pattern in natural language.
    private func describeHomePattern(_ p: PlaceProfile) -> String {
        var parts: [String] = []
        if p.weekendCount > 0 && p.weekdayCount > 0 {
            parts.append("几乎每天")
        } else if p.weekendCount > 0 {
            parts.append("周末")
        } else {
            parts.append("工作日")
        }
        return "  \(parts.joined())都在（\(p.count)次记录）"
    }

    /// Describes work visit pattern in natural language.
    private func describeWorkPattern(_ p: PlaceProfile) -> String {
        let daysCount = p.weekdaySet.subtracting([1, 7]).count // weekdays only
        if daysCount >= 5 {
            return "  每个工作日（\(p.count)次记录）"
        } else if daysCount >= 3 {
            return "  一周\(daysCount)天（\(p.count)次记录）"
        }
        return "  工作时段常去（\(p.count)次记录）"
    }

    // MARK: - Place Ranking

    private func buildPlaceRanking(profiles: [PlaceProfile], totalRecords: Int) -> String {
        let totalPlaces = profiles.count

        var lines: [String] = []

        // Show top places with contextual labels
        for (index, info) in profiles.prefix(6).enumerated() {
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
        if let top = profiles.first, top.count >= 3 {
            let percentage = Int(Double(top.count) / Double(totalRecords) * 100)
            lines.insert("你最常去的地方是 **\(top.name)**，占全部记录的 \(percentage)%\n", at: 0)
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - New Places

    private func buildNewPlacesSection(records: [LocationRecord], range: QueryTimeRange) -> String? {
        // Only meaningful for week+ ranges
        guard range != .today && range != .yesterday else { return nil }

        let interval = range.interval
        let midpoint = interval.start.addingTimeInterval(interval.duration / 2)

        // Places that appear only in the second half of the period
        var firstHalfPlaces = Set<String>()

        for r in records {
            if r.timestamp < midpoint {
                firstHalfPlaces.insert(r.displayName)
            }
        }

        var seen = Set<String>()
        var secondHalfOnly: [String] = []
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
        // For older dates, show the actual date so weekly/monthly queries are useful
        let days = cal.dateComponents([.day], from: date, to: Date()).day ?? 0
        if days <= 7 {
            return "  \(days)天前"
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "M月d日"
        fmt.locale = Locale(identifier: "zh_CN")
        return "  \(fmt.string(from: date))"
    }
}

// MARK: - Supporting Types

/// Tracks detailed visit patterns for a single place.
private struct PlaceProfile {
    let name: String
    var count: Int
    var firstVisit: Date = Date()
    var lastVisit: Date = Date()

    // Time-of-day distribution
    var lateNightCount: Int = 0    // 0-6 (sleeping hours)
    var earlyMorningCount: Int = 0 // 6-9
    var morningCount: Int = 0      // 9-12
    var lunchCount: Int = 0        // 12-14
    var afternoonCount: Int = 0    // 14-18
    var eveningCount: Int = 0      // 18-21
    var nightCount: Int = 0        // 21-24

    // Day-of-week distribution
    var weekdayCount: Int = 0
    var weekendCount: Int = 0
    var weekdaySet: Set<Int> = []  // which weekdays (1=Sun..7=Sat)
}

/// Clusters nearby location records into a single logical place.
/// Uses a 200m radius from the anchor point (first record's position).
private struct PlaceCluster {
    let anchorLat: Double
    let anchorLon: Double
    var records: [LocationRecord] = []

    /// Checks if a coordinate is within ~200m of this cluster's anchor.
    func isNearby(lat: Double, lon: Double) -> Bool {
        let distance = haversineDistance(
            lat1: anchorLat, lon1: anchorLon,
            lat2: lat, lon2: lon
        )
        return distance <= 200 // meters
    }

    mutating func add(record: LocationRecord) {
        records.append(record)
    }

    /// Returns the most common display name among clustered records.
    var bestName: String {
        var nameCount: [String: Int] = [:]
        for r in records {
            nameCount[r.displayName, default: 0] += 1
        }
        return nameCount.max(by: { $0.value < $1.value })?.key ?? records.first?.displayName ?? "未知地点"
    }

    /// Haversine formula for distance in meters between two coordinates.
    private func haversineDistance(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let R = 6371000.0 // Earth radius in meters
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) +
                cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) *
                sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return R * c
    }
}

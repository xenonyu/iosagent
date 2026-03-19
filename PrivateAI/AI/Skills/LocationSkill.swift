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

        let response = buildInsightfulResponse(records: records, range: range, context: context)
        completion(response)
    }

    // MARK: - Response Builder

    private func buildInsightfulResponse(records: [LocationRecord], range: QueryTimeRange, context: SkillContext) -> String {
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

        // 5. Travel distance & activity radius
        if records.count >= 2 {
            if let travelSection = buildTravelAnalysis(records: records, profiles: profiles) {
                sections.append(travelSection)
            }
        }

        // 6. Commute analysis (home ↔ work transitions)
        if let commuteSection = buildCommuteAnalysis(records: records, profiles: profiles, range: range) {
            sections.append(commuteSection)
        }

        // 7. Period-over-period comparison (only for multi-day ranges)
        if let comparison = buildPeriodComparison(currentRecords: records, currentProfiles: profiles, range: range, context: context) {
            sections.append(comparison)
        }

        // 8. Activity summary
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
        var profiles = clusters.map { cluster -> PlaceProfile in
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
        }

        // Step 3: Estimate dwell time per place using chronological record sequence
        estimateDwellTimes(profiles: &profiles, clusters: clusters, allRecords: records)

        return profiles.sorted { $0.count > $1.count }
    }

    // MARK: - Dwell Time Estimation

    /// Estimates how long the user spent at each place by analyzing the chronological
    /// sequence of location records. When record A is at place X and the next record B
    /// is at a different place Y, the dwell time at X = B.timestamp - A.timestamp.
    /// Consecutive records at the same place extend the current stay.
    /// The last record in the sequence gets a conservative default estimate.
    private func estimateDwellTimes(profiles: inout [PlaceProfile], clusters: [PlaceCluster], allRecords: [LocationRecord]) {
        let sorted = allRecords.sorted { $0.timestamp < $1.timestamp }
        guard sorted.count >= 2 else {
            // Single record: assign a default 30-minute estimate
            if !profiles.isEmpty && sorted.count == 1 {
                profiles[0].estimatedDwellMinutes = 30
            }
            return
        }

        // Map each record to its cluster index
        let clusterIndices = sorted.map { record -> Int in
            for (i, cluster) in clusters.enumerated() {
                if cluster.isNearby(lat: record.latitude, lon: record.longitude) {
                    return i
                }
            }
            return -1
        }

        // Accumulate dwell time per cluster
        var dwellPerCluster: [Int: Double] = [:]
        let maxReasonableDwell: Double = 12 * 60 // Cap at 12 hours per single stay

        for i in 0..<sorted.count {
            let clusterIdx = clusterIndices[i]
            guard clusterIdx >= 0 else { continue }

            if i < sorted.count - 1 {
                let nextIdx = clusterIndices[i + 1]
                let gap = sorted[i + 1].timestamp.timeIntervalSince(sorted[i].timestamp) / 60.0

                if nextIdx != clusterIdx {
                    // Moved to a different place — dwell time = gap (capped)
                    let dwell = min(gap, maxReasonableDwell)
                    dwellPerCluster[clusterIdx, default: 0] += dwell
                } else {
                    // Still at the same place — this record contributes gap to the ongoing stay
                    let dwell = min(gap, maxReasonableDwell)
                    dwellPerCluster[clusterIdx, default: 0] += dwell
                }
            } else {
                // Last record: estimate 30 minutes if today, otherwise skip
                let cal = Calendar.current
                if cal.isDateInToday(sorted[i].timestamp) {
                    // Use time since last record (capped at 2 hours) or 30 min default
                    let timeSinceRecord = Date().timeIntervalSince(sorted[i].timestamp) / 60.0
                    let estimate = min(timeSinceRecord, 120)
                    dwellPerCluster[clusterIdx, default: 0] += max(estimate, 30)
                } else {
                    // For past dates, use a conservative 30 min
                    dwellPerCluster[clusterIdx, default: 0] += 30
                }
            }
        }

        // Assign dwell times back to profiles (profiles are indexed same as clusters)
        for i in profiles.indices where i < clusters.count {
            profiles[i].estimatedDwellMinutes = dwellPerCluster[i] ?? 0
        }
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

        let dwellSuffix = p.estimatedDwellMinutes >= 30
            ? "，累计约 \(formatDwellTime(p.estimatedDwellMinutes))" : ""

        // Evening regular (gym, restaurant, etc.)
        let eveningRatio = Double(p.eveningCount) / Double(total)
        if eveningRatio >= 0.5 && p.eveningCount >= 2 {
            let dayNote = p.weekendCount > p.weekdayCount ? "周末" : "工作日"
            return "🌆 \(p.name)  \(dayNote)傍晚常去（\(total)次\(dwellSuffix)）"
        }

        // Weekend spot
        let weekendRatio = total > 0 ? Double(p.weekendCount) / Double(total) : 0
        if weekendRatio >= 0.7 && p.weekendCount >= 2 {
            return "🎉 \(p.name)  周末常去（\(total)次\(dwellSuffix)）"
        }

        // Lunch spot
        let lunchRatio = Double(p.lunchCount) / Double(total)
        if lunchRatio >= 0.5 && p.lunchCount >= 2 {
            return "🍜 \(p.name)  午餐时段常去（\(total)次\(dwellSuffix)）"
        }

        // Morning routine (coffee shop, park, etc.)
        let earlyRatio = Double(p.earlyMorningCount + p.morningCount) / Double(total)
        if earlyRatio >= 0.6 && (p.earlyMorningCount + p.morningCount) >= 2 {
            return "☀️ \(p.name)  早晨常去（\(total)次\(dwellSuffix)）"
        }

        // General frequent place
        if total >= 3 {
            return "📍 \(p.name)  经常到访（\(total)次\(dwellSuffix)）"
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
        let dwellNote = describeDwellAverage(p)
        return "  \(parts.joined())都在（\(p.count)次记录\(dwellNote)）"
    }

    /// Describes work visit pattern in natural language.
    private func describeWorkPattern(_ p: PlaceProfile) -> String {
        let daysCount = p.weekdaySet.subtracting([1, 7]).count // weekdays only
        let dwellNote = describeDwellAverage(p)
        if daysCount >= 5 {
            return "  每个工作日（\(p.count)次记录\(dwellNote)）"
        } else if daysCount >= 3 {
            return "  一周\(daysCount)天（\(p.count)次记录\(dwellNote)）"
        }
        return "  工作时段常去（\(p.count)次记录\(dwellNote)）"
    }

    /// Describes average dwell time per visit for a place.
    private func describeDwellAverage(_ p: PlaceProfile) -> String {
        guard p.estimatedDwellMinutes >= 30 && p.count >= 1 else { return "" }
        let avgMin = p.estimatedDwellMinutes / Double(p.count)
        guard avgMin >= 15 else { return "" }
        let formatted = formatDwellTime(avgMin)
        return "，平均每次约 \(formatted)"
    }

    // MARK: - Place Ranking

    private func buildPlaceRanking(profiles: [PlaceProfile], totalRecords: Int) -> String {
        let totalPlaces = profiles.count

        var lines: [String] = []

        // Show top places with contextual labels and dwell time
        for (index, info) in profiles.prefix(6).enumerated() {
            let badge: String
            if index == 0 && info.count >= 3 {
                badge = "📌 "  // Most frequent
            } else if info.count == 1 {
                badge = "🆕 "  // Only visited once
            } else {
                badge = "• "
            }

            let frequency = info.count > 1 ? "（\(info.count)次" : ""
            let dwellStr = formatDwellTime(info.estimatedDwellMinutes)
            let details: String
            if !frequency.isEmpty && !dwellStr.isEmpty {
                details = "\(frequency)，约 \(dwellStr)）"
            } else if !frequency.isEmpty {
                details = "\(frequency)）"
            } else if !dwellStr.isEmpty {
                details = "（约 \(dwellStr)）"
            } else {
                details = ""
            }
            let recency = formatRecency(info.lastVisit)
            lines.append("\(badge)\(info.name)\(details)\(recency)")
        }

        if totalPlaces > 6 {
            lines.append("  …还有 \(totalPlaces - 6) 个其他地点")
        }

        // Add top place insight with time proportion
        if let top = profiles.first, top.count >= 3 {
            let percentage = Int(Double(top.count) / Double(totalRecords) * 100)
            let dwellStr = formatDwellTime(top.estimatedDwellMinutes)
            let timeNote = !dwellStr.isEmpty ? "，累计约 \(dwellStr)" : ""
            lines.insert("你最常去的地方是 **\(top.name)**，占全部记录的 \(percentage)%\(timeNote)\n", at: 0)
        }

        // Time allocation breakdown (if enough data)
        let totalDwell = profiles.reduce(0.0) { $0 + $1.estimatedDwellMinutes }
        if totalDwell >= 60 && profiles.count >= 2 {
            lines.append("")
            lines.append("⏱️ 时间分配：")
            for info in profiles.prefix(5) where info.estimatedDwellMinutes >= 15 {
                let pct = Int(info.estimatedDwellMinutes / totalDwell * 100)
                let barLen = max(1, pct / 10)
                let bar = String(repeating: "▓", count: barLen) + String(repeating: "░", count: max(0, 10 - barLen))
                let dwell = formatDwellTime(info.estimatedDwellMinutes)
                lines.append("  \(info.name) [\(bar)] \(dwell)（\(pct)%）")
            }
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

    // MARK: - Travel Distance & Activity Radius

    /// Computes total sequential travel distance, activity radius from home/centroid,
    /// and identifies the farthest point reached during the period.
    private func buildTravelAnalysis(records: [LocationRecord], profiles: [PlaceProfile]) -> String? {
        let sorted = records.sorted { $0.timestamp < $1.timestamp }
        guard sorted.count >= 2 else { return nil }

        // 1. Total sequential travel distance (sum of hops between consecutive records)
        var totalDistanceM: Double = 0
        for i in 0..<(sorted.count - 1) {
            let a = sorted[i]
            let b = sorted[i + 1]
            totalDistanceM += haversine(lat1: a.latitude, lon1: a.longitude,
                                        lat2: b.latitude, lon2: b.longitude)
        }

        // 2. Determine anchor point (home if detected, otherwise centroid)
        let anchorLat: Double
        let anchorLon: Double
        let anchorLabel: String

        if let homeIdx = detectHome(profiles: profiles), homeIdx < profiles.count {
            // Use home cluster's average position
            let homeRecords = findRecordsForProfile(profiles[homeIdx], in: sorted)
            if !homeRecords.isEmpty {
                anchorLat = homeRecords.reduce(0.0) { $0 + $1.latitude } / Double(homeRecords.count)
                anchorLon = homeRecords.reduce(0.0) { $0 + $1.longitude } / Double(homeRecords.count)
                anchorLabel = "家"
            } else {
                // Fallback to centroid
                anchorLat = sorted.reduce(0.0) { $0 + $1.latitude } / Double(sorted.count)
                anchorLon = sorted.reduce(0.0) { $0 + $1.longitude } / Double(sorted.count)
                anchorLabel = "中心"
            }
        } else {
            anchorLat = sorted.reduce(0.0) { $0 + $1.latitude } / Double(sorted.count)
            anchorLon = sorted.reduce(0.0) { $0 + $1.longitude } / Double(sorted.count)
            anchorLabel = "中心"
        }

        // 3. Activity radius & farthest point
        var maxDistM: Double = 0
        var farthestRecord: LocationRecord?

        for r in sorted {
            let dist = haversine(lat1: anchorLat, lon1: anchorLon,
                                 lat2: r.latitude, lon2: r.longitude)
            if dist > maxDistM {
                maxDistM = dist
                farthestRecord = r
            }
        }

        // Only show if there's meaningful movement (> 500m total travel)
        guard totalDistanceM > 500 else { return nil }

        var lines: [String] = ["🧭 出行分析："]

        // Total travel distance
        let totalKm = totalDistanceM / 1000.0
        if totalKm >= 1.0 {
            lines.append("  总移动距离：\(String(format: "%.1f", totalKm)) 公里")
        } else {
            lines.append("  总移动距离：\(Int(totalDistanceM)) 米")
        }

        // Activity radius
        let radiusKm = maxDistM / 1000.0
        if radiusKm >= 1.0 {
            let radiusDesc: String
            if radiusKm < 5 {
                radiusDesc = "活动范围较集中，基本在附近区域"
            } else if radiusKm < 20 {
                radiusDesc = "活动范围适中，覆盖城市多个区域"
            } else if radiusKm < 100 {
                radiusDesc = "活动范围较广，跨区出行"
            } else {
                radiusDesc = "活动范围很大，可能有长途出行"
            }
            lines.append("  活动半径：距\(anchorLabel)最远 \(String(format: "%.1f", radiusKm)) 公里")
            lines.append("  💡 \(radiusDesc)")
        }

        // Farthest point
        if let farthest = farthestRecord, maxDistM > 1000 {
            let placeName = farthest.displayName
            if !placeName.isEmpty && placeName != "未知地点" {
                lines.append("  📌 最远到达：\(placeName)")
            }
        }

        // Daily average travel (if multi-day)
        let cal = Calendar.current
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "yyyy-MM-dd"
        let uniqueDays = Set(sorted.map { dayFmt.string(from: $0.timestamp) }).count
        if uniqueDays >= 3 {
            let avgKm = totalKm / Double(uniqueDays)
            lines.append("  日均移动：\(String(format: "%.1f", avgKm)) 公里")
        }

        return lines.joined(separator: "\n")
    }

    /// Finds the original records that belong to a given profile's place cluster.
    /// Matches by display name since profiles are built from clusters.
    private func findRecordsForProfile(_ profile: PlaceProfile, in records: [LocationRecord]) -> [LocationRecord] {
        // Cluster by proximity to any record matching this profile's name
        let nameMatches = records.filter { $0.displayName == profile.name }
        guard let anchor = nameMatches.first else { return nameMatches }

        // Include all records within 200m of the anchor (same clustering logic)
        return records.filter {
            haversine(lat1: anchor.latitude, lon1: anchor.longitude,
                      lat2: $0.latitude, lon2: $0.longitude) <= 200
        }
    }

    /// Haversine distance in meters (instance-level helper for travel analysis).
    private func haversine(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let R = 6371000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) +
                cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) *
                sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return R * c
    }

    // MARK: - Commute Analysis

    /// Analyzes home ↔ work commute patterns by detecting daily transitions.
    /// For each day with both home and work records, estimates the commute time
    /// as the gap between leaving one zone and arriving at the other.
    /// Requires at least 2 commute days to show meaningful patterns.
    private func buildCommuteAnalysis(records: [LocationRecord], profiles: [PlaceProfile], range: QueryTimeRange) -> String? {
        // Need enough data and at least home + work detected
        guard profiles.count >= 2, records.count >= 5 else { return nil }
        // Only meaningful for multi-day ranges
        guard range != .today && range != .yesterday else { return nil }

        guard let homeIdx = detectHome(profiles: profiles) else { return nil }
        let homeProfile = profiles[homeIdx]
        guard let workIdx = detectWork(profiles: profiles, excludeIndices: [homeIdx]) else { return nil }
        let workProfile = profiles[workIdx]

        // Get records belonging to home and work clusters
        let homeRecords = findRecordsForProfile(homeProfile, in: records)
        let workRecords = findRecordsForProfile(workProfile, in: records)
        guard !homeRecords.isEmpty && !workRecords.isEmpty else { return nil }

        let cal = Calendar.current
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "yyyy-MM-dd"

        // Group home and work records by day
        var homeByDay: [String: [LocationRecord]] = [:]
        var workByDay: [String: [LocationRecord]] = [:]
        for r in homeRecords {
            homeByDay[dayFmt.string(from: r.timestamp), default: []].append(r)
        }
        for r in workRecords {
            workByDay[dayFmt.string(from: r.timestamp), default: []].append(r)
        }

        // For each day with both home and work, estimate commute times
        var morningCommutes: [(day: String, weekday: Int, minutes: Double)] = []
        var eveningCommutes: [(day: String, weekday: Int, minutes: Double)] = []

        let commonDays = Set(homeByDay.keys).intersection(Set(workByDay.keys))
        for day in commonDays {
            guard let homeRecs = homeByDay[day], let workRecs = workByDay[day] else { continue }
            let sortedHome = homeRecs.sorted { $0.timestamp < $1.timestamp }
            let sortedWork = workRecs.sorted { $0.timestamp < $1.timestamp }

            guard let date = dayFmt.date(from: day) else { continue }
            let weekday = cal.component(.weekday, from: date)

            // Morning commute: last home record before noon → first work record
            // (leaving home in the morning, arriving at work)
            let morningHome = sortedHome.filter { cal.component(.hour, from: $0.timestamp) < 12 }
            let morningWork = sortedWork.filter { cal.component(.hour, from: $0.timestamp) < 14 }

            if let lastHome = morningHome.last, let firstWork = morningWork.first,
               firstWork.timestamp > lastHome.timestamp {
                let gap = firstWork.timestamp.timeIntervalSince(lastHome.timestamp) / 60.0
                // Reasonable commute: 5 min to 3 hours
                if gap >= 5 && gap <= 180 {
                    morningCommutes.append((day: day, weekday: weekday, minutes: gap))
                }
            }

            // Evening commute: last work record after noon → first home record in evening
            let eveningWork = sortedWork.filter { cal.component(.hour, from: $0.timestamp) >= 12 }
            let eveningHome = sortedHome.filter { cal.component(.hour, from: $0.timestamp) >= 15 }

            if let lastWork = eveningWork.last, let firstHome = eveningHome.first,
               firstHome.timestamp > lastWork.timestamp {
                let gap = firstHome.timestamp.timeIntervalSince(lastWork.timestamp) / 60.0
                if gap >= 5 && gap <= 180 {
                    eveningCommutes.append((day: day, weekday: weekday, minutes: gap))
                }
            }
        }

        let totalCommutes = morningCommutes.count + eveningCommutes.count
        guard totalCommutes >= 2 else { return nil }

        var lines: [String] = ["🚌 通勤分析"]
        lines.append("  🏠 \(homeProfile.name) ↔ 🏢 \(workProfile.name)")

        // Morning commute stats
        if morningCommutes.count >= 2 {
            let avgMorning = morningCommutes.reduce(0.0) { $0 + $1.minutes } / Double(morningCommutes.count)
            let minMorning = morningCommutes.min(by: { $0.minutes < $1.minutes })!
            let maxMorning = morningCommutes.max(by: { $0.minutes < $1.minutes })!
            lines.append("")
            lines.append("  ☀️ 早通勤（\(morningCommutes.count) 天数据）")
            lines.append("     平均 \(formatCommute(avgMorning))")
            if morningCommutes.count >= 3 {
                lines.append("     最快 \(formatCommute(minMorning.minutes)) · 最慢 \(formatCommute(maxMorning.minutes))")
            }

            // Weekday variation
            let weekdayMorning = morningCommutes.filter { $0.weekday >= 2 && $0.weekday <= 6 }
            if weekdayMorning.count >= 3 {
                let byWeekday = Dictionary(grouping: weekdayMorning, by: { $0.weekday })
                let avgByDay = byWeekday.mapValues { recs in
                    recs.reduce(0.0) { $0 + $1.minutes } / Double(recs.count)
                }
                if let fastest = avgByDay.min(by: { $0.value < $1.value }),
                   let slowest = avgByDay.max(by: { $0.value < $1.value }),
                   fastest.key != slowest.key && (slowest.value - fastest.value) >= 5 {
                    lines.append("     \(weekdayName(fastest.key))最快（\(formatCommute(fastest.value))），\(weekdayName(slowest.key))最慢（\(formatCommute(slowest.value))）")
                }
            }
        } else if morningCommutes.count == 1 {
            lines.append("")
            lines.append("  ☀️ 早通勤：约 \(formatCommute(morningCommutes[0].minutes))")
        }

        // Evening commute stats
        if eveningCommutes.count >= 2 {
            let avgEvening = eveningCommutes.reduce(0.0) { $0 + $1.minutes } / Double(eveningCommutes.count)
            let minEvening = eveningCommutes.min(by: { $0.minutes < $1.minutes })!
            let maxEvening = eveningCommutes.max(by: { $0.minutes < $1.minutes })!
            lines.append("")
            lines.append("  🌆 晚通勤（\(eveningCommutes.count) 天数据）")
            lines.append("     平均 \(formatCommute(avgEvening))")
            if eveningCommutes.count >= 3 {
                lines.append("     最快 \(formatCommute(minEvening.minutes)) · 最慢 \(formatCommute(maxEvening.minutes))")
            }
        } else if eveningCommutes.count == 1 {
            lines.append("")
            lines.append("  🌆 晚通勤：约 \(formatCommute(eveningCommutes[0].minutes))")
        }

        // Compare morning vs evening
        if morningCommutes.count >= 2 && eveningCommutes.count >= 2 {
            let avgMorning = morningCommutes.reduce(0.0) { $0 + $1.minutes } / Double(morningCommutes.count)
            let avgEvening = eveningCommutes.reduce(0.0) { $0 + $1.minutes } / Double(eveningCommutes.count)
            let diff = avgEvening - avgMorning
            if abs(diff) >= 5 {
                lines.append("")
                if diff > 0 {
                    lines.append("  💡 晚高峰比早高峰平均多花 \(formatCommute(diff)) — 下班路上更堵")
                } else {
                    lines.append("  💡 早高峰比晚高峰平均多花 \(formatCommute(-diff)) — 上班路上更堵")
                }
            }
        }

        // Total commute time burden
        let allCommutes = morningCommutes.map(\.minutes) + eveningCommutes.map(\.minutes)
        if allCommutes.count >= 4 {
            let avgRoundTrip: Double
            if morningCommutes.count >= 2 && eveningCommutes.count >= 2 {
                let m = morningCommutes.reduce(0.0) { $0 + $1.minutes } / Double(morningCommutes.count)
                let e = eveningCommutes.reduce(0.0) { $0 + $1.minutes } / Double(eveningCommutes.count)
                avgRoundTrip = m + e
            } else {
                let avg = allCommutes.reduce(0, +) / Double(allCommutes.count)
                avgRoundTrip = avg * 2
            }
            let weeklyHours = avgRoundTrip * 5 / 60
            lines.append("")
            lines.append("  📊 每日往返约 \(formatCommute(avgRoundTrip))，每周约 \(String(format: "%.1f", weeklyHours)) 小时在路上")
        }

        return lines.joined(separator: "\n")
    }

    /// Formats commute time in minutes to a human-readable string.
    private func formatCommute(_ minutes: Double) -> String {
        let mins = Int(minutes)
        if mins >= 60 {
            return "\(mins / 60)小时\(mins % 60)分钟"
        }
        return "\(mins)分钟"
    }

    /// Returns Chinese weekday name from Calendar weekday number (1=Sun..7=Sat).
    private func weekdayName(_ weekday: Int) -> String {
        switch weekday {
        case 1: return "周日"
        case 2: return "周一"
        case 3: return "周二"
        case 4: return "周三"
        case 5: return "周四"
        case 6: return "周五"
        case 7: return "周六"
        default: return ""
        }
    }

    // MARK: - Period-over-Period Comparison

    /// Compares current period's location activity against the previous period of equal length.
    /// Shows changes in unique places, movement range, and highlights new explorations.
    private func buildPeriodComparison(
        currentRecords: [LocationRecord],
        currentProfiles: [PlaceProfile],
        range: QueryTimeRange,
        context: SkillContext
    ) -> String? {
        let cal = Calendar.current
        let interval = range.interval
        let spanDays = max(1, cal.dateComponents([.day], from: interval.start, to: interval.end).day ?? 1)

        // Only compare for ranges of 3–31 days (skip single-day or very long ranges)
        guard spanDays >= 3, spanDays <= 31 else { return nil }

        // Fetch previous period of same length
        guard let prevStart = cal.date(byAdding: .day, value: -spanDays, to: interval.start) else { return nil }
        let prevEnd = interval.start

        let prevRecords = CDLocationRecord.fetch(from: prevStart, to: prevEnd, in: context.coreDataContext)

        // Need data in both periods for a meaningful comparison
        guard !prevRecords.isEmpty else {
            if currentRecords.count >= 3 {
                return "📈 上个同期没有位置记录，无法对比。"
            }
            return nil
        }

        let prevProfiles = buildPlaceProfiles(records: prevRecords)

        // --- Metrics ---
        let curPlaceCount = Set(currentRecords.map { $0.displayName }).count
        let prevPlaceCount = Set(prevRecords.map { $0.displayName }).count

        let curRecordCount = currentRecords.count
        let prevRecordCount = prevRecords.count

        // Activity radius: max distance from centroid
        let curRadius = computeActivityRadius(records: currentRecords)
        let prevRadius = computeActivityRadius(records: prevRecords)

        // Total sequential travel distance
        let curTravelM = computeTotalTravel(records: currentRecords)
        let prevTravelM = computeTotalTravel(records: prevRecords)

        // Unique days with location data
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "yyyy-MM-dd"
        let curActiveDays = Set(currentRecords.map { dayFmt.string(from: $0.timestamp) }).count
        let prevActiveDays = Set(prevRecords.map { dayFmt.string(from: $0.timestamp) }).count

        // New places: appeared this period but not last period
        let curPlaceNames = Set(currentRecords.map { $0.displayName })
        let prevPlaceNames = Set(prevRecords.map { $0.displayName })
        let newPlaces = curPlaceNames.subtracting(prevPlaceNames)
        let droppedPlaces = prevPlaceNames.subtracting(curPlaceNames)

        // --- Build response ---
        var lines: [String] = ["📈 与上期对比："]

        // Place count delta
        let placeDelta = curPlaceCount - prevPlaceCount
        if placeDelta > 0 {
            lines.append("  • 去了 \(curPlaceCount) 个地方（↑ 比上期多 \(placeDelta) 个）")
        } else if placeDelta < 0 {
            lines.append("  • 去了 \(curPlaceCount) 个地方（↓ 比上期少 \(abs(placeDelta)) 个）")
        } else {
            lines.append("  • 去了 \(curPlaceCount) 个地方（与上期持平）")
        }

        // Active days
        let dayDelta = curActiveDays - prevActiveDays
        if abs(dayDelta) >= 1 && curActiveDays >= 2 {
            let arrow = dayDelta > 0 ? "↑" : "↓"
            lines.append("  • 活跃 \(curActiveDays) 天（\(arrow) 上期 \(prevActiveDays) 天）")
        }

        // Travel distance comparison
        if curTravelM > 500 && prevTravelM > 500 {
            let curKm = curTravelM / 1000.0
            let prevKm = prevTravelM / 1000.0
            let travelDelta = curKm - prevKm
            let travelPct = prevKm > 0 ? Int(abs(travelDelta) / prevKm * 100) : 0
            if abs(travelDelta) >= 1.0 {
                let direction = travelDelta > 0 ? "多走了" : "少走了"
                var travelLine = "  • 移动距离 \(String(format: "%.1f", curKm)) 公里（\(direction) \(String(format: "%.1f", abs(travelDelta))) 公里"
                if travelPct >= 15 {
                    travelLine += "，\(travelDelta > 0 ? "+" : "-")\(travelPct)%"
                }
                travelLine += "）"
                lines.append(travelLine)
            }
        }

        // Activity radius comparison
        if curRadius > 500 && prevRadius > 500 {
            let curRadiusKm = curRadius / 1000.0
            let prevRadiusKm = prevRadius / 1000.0
            let radiusDelta = curRadiusKm - prevRadiusKm
            let radiusPct = prevRadiusKm > 0 ? Int(abs(radiusDelta) / prevRadiusKm * 100) : 0
            if radiusPct >= 20 {
                if radiusDelta > 0 {
                    lines.append("  • 活动半径扩大到 \(String(format: "%.1f", curRadiusKm)) 公里（+\(radiusPct)%）")
                } else {
                    lines.append("  • 活动半径缩小到 \(String(format: "%.1f", curRadiusKm)) 公里（-\(radiusPct)%）")
                }
            }
        }

        // New explorations
        let meaningfulNewPlaces = newPlaces.filter { $0 != "未知地点" && !$0.isEmpty }
        if !meaningfulNewPlaces.isEmpty {
            let preview = meaningfulNewPlaces.prefix(3).joined(separator: "、")
            let extra = meaningfulNewPlaces.count > 3 ? " 等 \(meaningfulNewPlaces.count) 个" : ""
            lines.append("  • 🆕 新探索：\(preview)\(extra)")
        }

        // Trend insight
        if lines.count <= 2 { return nil } // No meaningful deltas to show

        // Overall trend summary
        let moreActive = placeDelta > 0 && curTravelM > prevTravelM * 1.1
        let lessActive = placeDelta < 0 && curTravelM < prevTravelM * 0.9
        if moreActive {
            lines.append("  💡 整体更活跃，探索了更多地方")
        } else if lessActive {
            lines.append("  💡 活动范围收缩，以固定路线为主")
        } else if !meaningfulNewPlaces.isEmpty && meaningfulNewPlaces.count >= 2 {
            lines.append("  💡 保持探索节奏，发现了新地方 ✨")
        }

        return lines.joined(separator: "\n")
    }

    /// Computes the activity radius (max distance from centroid) for a set of records.
    private func computeActivityRadius(records: [LocationRecord]) -> Double {
        guard records.count >= 2 else { return 0 }
        let avgLat = records.reduce(0.0) { $0 + $1.latitude } / Double(records.count)
        let avgLon = records.reduce(0.0) { $0 + $1.longitude } / Double(records.count)
        var maxDist: Double = 0
        for r in records {
            let dist = haversine(lat1: avgLat, lon1: avgLon, lat2: r.latitude, lon2: r.longitude)
            maxDist = max(maxDist, dist)
        }
        return maxDist
    }

    /// Computes total sequential travel distance in meters.
    private func computeTotalTravel(records: [LocationRecord]) -> Double {
        let sorted = records.sorted { $0.timestamp < $1.timestamp }
        guard sorted.count >= 2 else { return 0 }
        var total: Double = 0
        for i in 0..<(sorted.count - 1) {
            total += haversine(lat1: sorted[i].latitude, lon1: sorted[i].longitude,
                               lat2: sorted[i + 1].latitude, lon2: sorted[i + 1].longitude)
        }
        return total
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

    /// Formats dwell time in minutes into a human-readable Chinese string.
    /// Returns empty string if the duration is negligible (< 10 min).
    private func formatDwellTime(_ minutes: Double) -> String {
        guard minutes >= 10 else { return "" }
        let hours = Int(minutes) / 60
        let mins = Int(minutes) % 60
        if hours >= 1 && mins >= 10 {
            return "\(hours)小时\(mins)分钟"
        } else if hours >= 1 {
            return "\(hours)小时"
        } else {
            return "\(Int(minutes))分钟"
        }
    }

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

    // Estimated dwell time (in minutes) across all visits
    var estimatedDwellMinutes: Double = 0
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

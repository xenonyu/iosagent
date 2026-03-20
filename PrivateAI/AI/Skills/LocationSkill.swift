import Foundation
import CoreLocation

/// Handles location and places queries with rich insights about movement patterns.
/// Identifies routine places (home, work, regular spots) from visit time patterns.
struct LocationSkill: ClawSkill {

    let id = "location"

    func canHandle(intent: QueryIntent) -> Bool {
        switch intent {
        case .location, .locationPlace: return true
        default: return false
        }
    }

    func execute(intent: QueryIntent, context: SkillContext, completion: @escaping (String) -> Void) {
        switch intent {
        case .locationPlace(let name, let range):
            respondPlaceSearch(name: name, range: range, context: context, completion: completion)
        case .location(let range):
            let interval = range.interval
            let records = CDLocationRecord.fetch(from: interval.start, to: interval.end, in: context.coreDataContext)

            if records.isEmpty {
                completion(buildEmptyLocationResponse(range: range, context: context))
                return
            }

            // For multi-day ranges, enrich with HealthKit data for cross-insights
            let cal = Calendar.current
            let spanDays = max(1, cal.dateComponents([.day], from: interval.start, to: interval.end).day ?? 1)
            let daysBack = max(1, cal.dateComponents([.day], from: interval.start, to: Date()).day ?? 0)

            if spanDays >= 3 && context.healthService.isHealthDataAvailable {
                context.healthService.fetchSummaries(days: daysBack + spanDays) { summaries in
                    // Filter summaries to match the query range
                    let rangeSummaries = summaries.filter { s in
                        s.date >= interval.start && s.date <= interval.end
                    }
                    let response = self.buildInsightfulResponse(
                        records: records, range: range, context: context,
                        healthSummaries: rangeSummaries
                    )
                    completion(response)
                }
            } else {
                let response = buildInsightfulResponse(
                    records: records, range: range, context: context,
                    healthSummaries: []
                )
                completion(response)
            }
        default:
            break
        }
    }

    // MARK: - Empty State

    /// Builds a context-aware empty response by checking location authorization status.
    /// Differentiates between: permission not granted, permission granted but no data for
    /// this period, and when-in-use only (no background tracking).
    private func buildEmptyLocationResponse(range: QueryTimeRange, context: SkillContext) -> String {
        let status = context.locationService.authorizationStatus

        switch status {
        case .notDetermined:
            return """
            📍 位置权限尚未开启。

            开启后，iosclaw 会在后台自动记录你去过的地方（不会持续耗电）。
            请前往「设置 → iosclaw → 位置」选择「始终允许」。
            """

        case .denied, .restricted:
            return """
            📍 位置权限已被关闭。

            无法获取你的位置数据。
            请前往「设置 → 隐私与安全 → 定位服务 → iosclaw」开启权限。

            💡 选择「始终允许」可以在后台自动记录足迹，不会持续耗电。
            """

        case .authorizedWhenInUse:
            // Has some permission but no background tracking → data will be sparse
            var msg = "📍 \(range.label)暂无位置记录。\n\n"
            msg += "当前位置权限为「使用 App 期间」，只有打开 iosclaw 时才会记录。\n"
            msg += "建议前往「设置 → iosclaw → 位置」改为「始终允许」，这样即使 App 在后台也能自动记录足迹。"
            if range == .today {
                msg += "\n\n💡 也可以试试「这周去了哪些地方」查看更长时间范围。"
            }
            return msg

        case .authorizedAlways:
            // Permission is fine — genuinely no data for this time range
            var msg = "📍 \(range.label)暂无位置记录。\n\n"
            msg += "位置权限已开启，但这段时间没有检测到显著的位置变化。"

            // Suggest broader range for short periods
            if range == .today {
                msg += "\niosclaw 使用省电模式追踪位置，短距离移动可能不会被记录。"
                msg += "\n\n💡 试试「昨天去了哪里」或「这周去了哪些地方」查看更多记录。"
            } else if range == .yesterday {
                msg += "\n可能昨天大部分时间待在同一个地方。"
                msg += "\n\n💡 试试「这周去了哪些地方」查看更长时间的足迹。"
            } else {
                // Longer range with no data — check if there's ANY data at all
                let allRecords = CDLocationRecord.fetch(
                    from: Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? Date(),
                    to: Date(),
                    in: context.coreDataContext
                )
                if allRecords.isEmpty {
                    msg += "\n最近 90 天内也没有找到任何位置记录。"
                    msg += "\n\n可能是刚开启定位服务，位置数据会从现在开始逐渐积累。"
                } else {
                    let fmt = DateFormatter()
                    fmt.dateFormat = "M月d日"
                    if let latest = allRecords.first {
                        msg += "\n\n最近一条记录是在 \(fmt.string(from: latest.timestamp))。"
                        msg += "\n试试调整时间范围再查看？"
                    }
                }
            }
            return msg

        @unknown default:
            return "📍 \(range.label)暂无位置记录。\n请前往「设置 → iosclaw → 位置」确认权限已开启。"
        }
    }

    // MARK: - Place-Specific Search

    /// Responds to queries about a specific place: "去过星巴克几次", "上次去公司是什么时候", etc.
    /// Searches all location records for matching place names and builds a focused profile.
    private func respondPlaceSearch(name: String, range: QueryTimeRange, context: SkillContext, completion: @escaping (String) -> Void) {
        // Search a wide window (up to 180 days) regardless of the parsed time range,
        // so we can answer "上次去X" even if no explicit time reference was given.
        let cal = Calendar.current
        let searchStart = cal.date(byAdding: .day, value: -180, to: Date()) ?? Date()
        let allRecords = CDLocationRecord.fetch(from: searchStart, to: Date(), in: context.coreDataContext)

        // Fuzzy match: record's displayName contains the search term, or vice versa
        let matches = allRecords.filter { record in
            let display = record.displayName.lowercased()
            let query = name.lowercased()
            return display.contains(query) || query.contains(display)
        }.sorted { $0.timestamp > $1.timestamp } // newest first

        if matches.isEmpty {
            var msg = "📍 在最近 180 天的位置记录中，没有找到「\(name)」相关的地点。\n"
            msg += "\n可能的原因："
            msg += "\n• 该地点名称和记录中的不完全一致（试试更短的关键词）"
            msg += "\n• 去的时候 iosclaw 没有在后台运行"
            msg += "\n• 短距离移动可能未被记录（iosclaw 使用省电模式追踪）"

            if !allRecords.isEmpty {
                // Suggest similar places
                let allNames = Set(allRecords.map { $0.displayName })
                    .filter { $0 != "未知地点" && !$0.isEmpty }
                let similar = allNames.filter { placeName in
                    // Check if any character overlap (crude similarity)
                    let query = name.lowercased()
                    let place = placeName.lowercased()
                    return query.contains(String(place.prefix(2))) || place.contains(String(query.prefix(2)))
                }.prefix(3)

                if !similar.isEmpty {
                    msg += "\n\n💡 你是不是想找："
                    for s in similar {
                        msg += "\n  • \(s)"
                    }
                }
            }
            completion(msg)
            return
        }

        // Build the place report
        var lines: [String] = []
        let totalVisits = matches.count
        let uniqueDays = Set(matches.map { cal.startOfDay(for: $0.timestamp) })
        let displayName = mostCommonName(in: matches)

        // Header
        lines.append("📍 关于「\(displayName)」的位置记录\n")

        // Visit count
        lines.append("📊 共到访 **\(totalVisits) 次**，涉及 \(uniqueDays.count) 天")

        // Time span
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "M月d日"
        dateFmt.locale = Locale(identifier: "zh_CN")
        if let first = matches.last, let last = matches.first {
            if cal.isDate(first.timestamp, inSameDayAs: last.timestamp) {
                lines.append("📅 记录日期：\(dateFmt.string(from: first.timestamp))")
            } else {
                lines.append("📅 首次到访：\(dateFmt.string(from: first.timestamp))")
                lines.append("📅 最近一次：\(dateFmt.string(from: last.timestamp))")
            }
        }

        // Days since last visit
        if let lastVisit = matches.first {
            let daysSince = cal.dateComponents([.day], from: cal.startOfDay(for: lastVisit.timestamp), to: cal.startOfDay(for: Date())).day ?? 0
            if daysSince == 0 {
                lines.append("⏰ 今天去过")
            } else if daysSince == 1 {
                lines.append("⏰ 昨天去过")
            } else if daysSince <= 7 {
                lines.append("⏰ \(daysSince) 天前去过")
            } else if daysSince <= 30 {
                lines.append("⏰ \(daysSince / 7) 周前去过")
            } else {
                lines.append("⏰ 已经 \(daysSince) 天没去了")
            }
        }

        // Visit frequency pattern (only if enough data)
        if uniqueDays.count >= 3 {
            let sortedDays = uniqueDays.sorted()
            var gaps: [Int] = []
            for i in 0..<(sortedDays.count - 1) {
                let gap = cal.dateComponents([.day], from: sortedDays[i], to: sortedDays[i + 1]).day ?? 0
                if gap > 0 { gaps.append(gap) }
            }
            if !gaps.isEmpty {
                let avgGap = gaps.reduce(0, +) / gaps.count
                let freqDesc: String
                if avgGap <= 1 {
                    freqDesc = "几乎每天"
                } else if avgGap <= 3 {
                    freqDesc = "每隔 \(avgGap) 天左右"
                } else if avgGap <= 8 {
                    freqDesc = "大约每周 \(max(1, 7 / avgGap)) 次"
                } else if avgGap <= 16 {
                    freqDesc = "大约两周一次"
                } else if avgGap <= 35 {
                    freqDesc = "大约每月一次"
                } else {
                    freqDesc = "偶尔去一次"
                }
                lines.append("🔄 到访频率：\(freqDesc)")
            }
        }

        // Time-of-day pattern
        var morningCount = 0, afternoonCount = 0, eveningCount = 0, nightCount = 0
        for r in matches {
            let hour = cal.component(.hour, from: r.timestamp)
            switch hour {
            case 6..<12:  morningCount += 1
            case 12..<18: afternoonCount += 1
            case 18..<22: eveningCount += 1
            default:      nightCount += 1
            }
        }
        if matches.count >= 3 {
            let periods: [(String, Int)] = [
                ("上午", morningCount), ("下午", afternoonCount),
                ("傍晚", eveningCount), ("夜间", nightCount)
            ].filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }

            if let top = periods.first, Double(top.1) / Double(matches.count) >= 0.4 {
                lines.append("🕐 通常在\(top.0)到访")
            }
        }

        // Day-of-week pattern
        if uniqueDays.count >= 5 {
            var weekdayVisits = 0, weekendVisits = 0
            for day in uniqueDays {
                let wd = cal.component(.weekday, from: day)
                if wd == 1 || wd == 7 { weekendVisits += 1 } else { weekdayVisits += 1 }
            }
            let total = weekdayVisits + weekendVisits
            if total >= 3 {
                let weekendRatio = Double(weekendVisits) / Double(total)
                if weekendRatio >= 0.6 {
                    lines.append("📆 以周末到访为主")
                } else if weekendRatio <= 0.2 && weekdayVisits >= 3 {
                    lines.append("📆 以工作日到访为主")
                }
            }
        }

        // Recent visit timeline (last 5 visits)
        let recentVisits = Array(matches.prefix(5))
        if recentVisits.count >= 2 {
            lines.append("\n🕰️ 最近到访记录：")
            let timeFmt = DateFormatter()
            timeFmt.dateFormat = "M月d日（E）HH:mm"
            timeFmt.locale = Locale(identifier: "zh_CN")
            for r in recentVisits {
                lines.append("  • \(timeFmt.string(from: r.timestamp))")
            }
            if matches.count > 5 {
                lines.append("  …还有 \(matches.count - 5) 条更早的记录")
            }
        }

        completion(lines.joined(separator: "\n"))
    }

    /// Returns the most common displayName among a set of records.
    private func mostCommonName(in records: [LocationRecord]) -> String {
        var counts: [String: Int] = [:]
        for r in records { counts[r.displayName, default: 0] += 1 }
        return counts.max(by: { $0.value < $1.value })?.key ?? records.first?.displayName ?? "未知"
    }

    // MARK: - Response Builder

    private func buildInsightfulResponse(records: [LocationRecord], range: QueryTimeRange, context: SkillContext, healthSummaries: [HealthSummary] = []) -> String {
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

        // 7. Daily rhythm analysis (lifestyle pattern from movement data)
        if let rhythmSection = buildDailyRhythm(records: records, profiles: profiles, range: range) {
            sections.append(rhythmSection)
        }

        // 8. Calendar-location correlation: explain WHY you visited each place
        if let calendarSection = buildCalendarLocationDiary(records: records, profiles: profiles, range: range, context: context) {
            sections.append(calendarSection)
        }

        // 9. Health-location cross-insights (steps/exercise vs. location patterns)
        if !healthSummaries.isEmpty {
            if let healthLocation = buildHealthLocationInsights(records: records, profiles: profiles, healthSummaries: healthSummaries) {
                sections.append(healthLocation)
            }
        }

        // 10. Period-over-period comparison (only for multi-day ranges)
        if let comparison = buildPeriodComparison(currentRecords: records, currentProfiles: profiles, range: range, context: context) {
            sections.append(comparison)
        }

        // 11. Activity summary
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

    // MARK: - Daily Rhythm Analysis

    /// Analyzes the user's daily movement rhythm by detecting departure/return times
    /// relative to home. Reveals lifestyle patterns: when you typically leave, how long
    /// you're out, weekday vs weekend differences, and rhythm consistency.
    /// Requires at least 3 days of multi-record data to produce meaningful insights.
    private func buildDailyRhythm(records: [LocationRecord], profiles: [PlaceProfile], range: QueryTimeRange) -> String? {
        // Only meaningful for multi-day ranges with enough data
        guard range != .today && range != .yesterday else { return nil }
        guard records.count >= 6 else { return nil }

        // Need a detected home to measure departure/return
        guard let homeIdx = detectHome(profiles: profiles) else { return nil }
        let homeProfile = profiles[homeIdx]
        let homeRecords = findRecordsForProfile(homeProfile, in: records)
        guard !homeRecords.isEmpty else { return nil }

        // Build a "home zone" anchor from the average of home records
        let homeLat = homeRecords.reduce(0.0) { $0 + $1.latitude } / Double(homeRecords.count)
        let homeLon = homeRecords.reduce(0.0) { $0 + $1.longitude } / Double(homeRecords.count)
        let homeRadius: Double = 250 // meters — slightly larger than cluster radius for buffer

        let cal = Calendar.current
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "yyyy-MM-dd"

        // Group all records by day
        var recordsByDay: [String: [LocationRecord]] = [:]
        for r in records {
            recordsByDay[dayFmt.string(from: r.timestamp), default: []].append(r)
        }

        // For each day, detect: first departure from home, last return to home, time spent outside
        struct DayRhythm {
            let dayKey: String
            let date: Date
            let weekday: Int          // 1=Sun..7=Sat
            let isWeekend: Bool
            let firstDeparture: Date?  // first record NOT near home
            let lastReturn: Date?      // last record near home
            let minutesOutside: Double // total time at non-home places
            let placesVisited: Int     // unique non-home places
        }

        var rhythms: [DayRhythm] = []

        for (dayKey, dayRecords) in recordsByDay {
            guard dayRecords.count >= 2 else { continue }
            let sorted = dayRecords.sorted { $0.timestamp < $1.timestamp }

            guard let date = dayFmt.date(from: dayKey) else { continue }
            let weekday = cal.component(.weekday, from: date)
            let isWeekend = (weekday == 1 || weekday == 7)

            // Classify each record as home or away
            let classifications: [(record: LocationRecord, isHome: Bool)] = sorted.map { r in
                let dist = haversine(lat1: homeLat, lon1: homeLon, lat2: r.latitude, lon2: r.longitude)
                return (r, dist <= homeRadius)
            }

            // First departure: first non-home record
            let firstAway = classifications.first { !$0.isHome }

            // Last return: last home record that comes after at least one away record
            var lastReturn: LocationRecord? = nil
            var sawAway = false
            for c in classifications {
                if !c.isHome { sawAway = true }
                if c.isHome && sawAway { lastReturn = c.record }
            }

            // Calculate minutes outside home
            var outsideMinutes: Double = 0
            for i in 0..<(sorted.count - 1) {
                let distA = haversine(lat1: homeLat, lon1: homeLon,
                                      lat2: sorted[i].latitude, lon2: sorted[i].longitude)
                if distA > homeRadius {
                    let gap = sorted[i + 1].timestamp.timeIntervalSince(sorted[i].timestamp) / 60.0
                    outsideMinutes += min(gap, 720) // cap at 12 hours per gap
                }
            }

            // Count unique non-home places
            let awayNames = Set(classifications.filter { !$0.isHome }.map { $0.record.displayName })

            rhythms.append(DayRhythm(
                dayKey: dayKey,
                date: date,
                weekday: weekday,
                isWeekend: isWeekend,
                firstDeparture: firstAway?.record.timestamp,
                lastReturn: lastReturn?.timestamp,
                minutesOutside: outsideMinutes,
                placesVisited: awayNames.count
            ))
        }

        // Need at least 3 days with departure data
        let daysWithDeparture = rhythms.filter { $0.firstDeparture != nil }
        guard daysWithDeparture.count >= 3 else { return nil }

        let weekdayRhythms = daysWithDeparture.filter { !$0.isWeekend }
        let weekendRhythms = daysWithDeparture.filter { $0.isWeekend }

        var lines: [String] = ["🕐 生活作息"]

        // --- Typical departure time ---
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"

        if weekdayRhythms.count >= 2 {
            let depTimes = weekdayRhythms.compactMap { $0.firstDeparture }
            let depMinutes = depTimes.map { minuteOfDay($0) }
            let avgDep = depMinutes.reduce(0, +) / depMinutes.count
            let depStdDev = standardDeviation(depMinutes)

            let retTimes = weekdayRhythms.compactMap { $0.lastReturn }
            let retMinutes = retTimes.map { minuteOfDay($0) }

            lines.append("")
            lines.append("  📅 工作日模式（\(weekdayRhythms.count) 天）")
            lines.append("    出门时间：通常 \(formatMinuteOfDay(avgDep))")

            if !retMinutes.isEmpty {
                let avgRet = retMinutes.reduce(0, +) / retMinutes.count
                lines.append("    回家时间：通常 \(formatMinuteOfDay(avgRet))")

                // Time spent outside
                let avgOutside = weekdayRhythms.reduce(0.0) { $0 + $1.minutesOutside } / Double(weekdayRhythms.count)
                if avgOutside >= 30 {
                    lines.append("    日均在外：约 \(formatDwellTime(avgOutside))")
                }
            }

            // Consistency score
            if depStdDev <= 30 {
                lines.append("    ✅ 作息非常规律（出门时间波动 ≤30分钟）")
            } else if depStdDev <= 60 {
                lines.append("    ⚡ 作息较规律（出门时间波动约 \(Int(depStdDev)) 分钟）")
            } else {
                lines.append("    🔀 作息不太固定（出门时间波动 \(Int(depStdDev)) 分钟）")
            }

            // Find the outlier day (earliest/latest departure if significantly different)
            if weekdayRhythms.count >= 3 {
                if let earliest = weekdayRhythms.min(by: { minuteOfDay($0.firstDeparture!) < minuteOfDay($1.firstDeparture!) }),
                   let latest = weekdayRhythms.max(by: { minuteOfDay($0.firstDeparture!) < minuteOfDay($1.firstDeparture!) }) {
                    let earliestMin = minuteOfDay(earliest.firstDeparture!)
                    let latestMin = minuteOfDay(latest.firstDeparture!)
                    if latestMin - earliestMin >= 90 {
                        let dayName = weekdayShortName(earliest.weekday)
                        let lateDayName = weekdayShortName(latest.weekday)
                        lines.append("    💡 \(dayName)出门最早（\(formatMinuteOfDay(earliestMin))），\(lateDayName)最晚（\(formatMinuteOfDay(latestMin))）")
                    }
                }
            }
        }

        // --- Weekend pattern ---
        if weekendRhythms.count >= 1 && weekdayRhythms.count >= 2 {
            let wkndDepTimes = weekendRhythms.compactMap { $0.firstDeparture }
            let wkndDepMinutes = wkndDepTimes.map { minuteOfDay($0) }

            if !wkndDepMinutes.isEmpty {
                let avgWkndDep = wkndDepMinutes.reduce(0, +) / wkndDepMinutes.count
                let wkdayDepMinutes = weekdayRhythms.compactMap { $0.firstDeparture }.map { minuteOfDay($0) }
                let avgWkdayDep = wkdayDepMinutes.isEmpty ? 0 : wkdayDepMinutes.reduce(0, +) / wkdayDepMinutes.count

                lines.append("")
                lines.append("  🎉 周末模式（\(weekendRhythms.count) 天）")
                lines.append("    出门时间：通常 \(formatMinuteOfDay(avgWkndDep))")

                let avgWkndOutside = weekendRhythms.reduce(0.0) { $0 + $1.minutesOutside } / Double(weekendRhythms.count)
                let avgWkdayOutside = weekdayRhythms.reduce(0.0) { $0 + $1.minutesOutside } / Double(weekdayRhythms.count)

                if avgWkndOutside >= 30 {
                    lines.append("    日均在外：约 \(formatDwellTime(avgWkndOutside))")
                }

                // Compare with weekday
                let depDiff = avgWkndDep - avgWkdayDep
                if abs(depDiff) >= 30 {
                    if depDiff > 0 {
                        lines.append("    💤 比工作日晚出门 \(formatDwellTime(Double(depDiff)))")
                    } else {
                        lines.append("    ⏰ 比工作日早出门 \(formatDwellTime(Double(-depDiff)))")
                    }
                }

                if avgWkndOutside >= 30 && avgWkdayOutside >= 30 {
                    let outsideDiff = avgWkndOutside - avgWkdayOutside
                    if abs(outsideDiff) >= 30 {
                        if outsideDiff > 0 {
                            lines.append("    🚶 周末在外时间比工作日多 \(formatDwellTime(outsideDiff))")
                        } else {
                            lines.append("    🏠 周末在外时间比工作日少 \(formatDwellTime(-outsideDiff))")
                        }
                    }
                }

                // Weekend activity variety
                let avgWkndPlaces = Double(weekendRhythms.reduce(0) { $0 + $1.placesVisited }) / Double(weekendRhythms.count)
                let avgWkdayPlaces = Double(weekdayRhythms.reduce(0) { $0 + $1.placesVisited }) / Double(weekdayRhythms.count)
                if avgWkndPlaces >= 2 && avgWkndPlaces > avgWkdayPlaces * 1.3 {
                    lines.append("    🗺️ 周末去的地方更多样（日均 \(String(format: "%.1f", avgWkndPlaces)) 个 vs 工作日 \(String(format: "%.1f", avgWkdayPlaces)) 个）")
                }
            }
        } else if weekendRhythms.count >= 2 && weekdayRhythms.count < 2 {
            // Only weekend data available
            let wkndDepTimes = weekendRhythms.compactMap { $0.firstDeparture }
            let wkndDepMinutes = wkndDepTimes.map { minuteOfDay($0) }
            if !wkndDepMinutes.isEmpty {
                let avgWkndDep = wkndDepMinutes.reduce(0, +) / wkndDepMinutes.count
                lines.append("")
                lines.append("  🎉 周末模式（\(weekendRhythms.count) 天）")
                lines.append("    出门时间：通常 \(formatMinuteOfDay(avgWkndDep))")
            }
        }

        // --- Overall lifestyle insight ---
        if daysWithDeparture.count >= 4 {
            let allDepMinutes = daysWithDeparture.compactMap { $0.firstDeparture }.map { minuteOfDay($0) }
            let avgDep = allDepMinutes.reduce(0, +) / allDepMinutes.count
            let allOutside = daysWithDeparture.map { $0.minutesOutside }
            let avgOutside = allOutside.reduce(0.0, +) / Double(allOutside.count)

            // Homebody vs explorer index
            let daysHome = rhythms.count - daysWithDeparture.count
            let stayHomeRatio = rhythms.count > 0 ? Double(daysHome) / Double(rhythms.count) : 0

            lines.append("")
            if stayHomeRatio >= 0.4 {
                let homeDays = Int(stayHomeRatio * 100)
                lines.append("💡 你有 \(homeDays)% 的天数主要待在家，属于居家型作息")
            } else if avgDep < 480 { // before 8:00
                lines.append("💡 你是个早起型的人，通常 8 点前就已出门")
            } else if avgDep >= 600 { // after 10:00
                lines.append("💡 你习惯晚出门（通常 10 点后），节奏比较从容")
            }

            if avgOutside >= 480 { // 8+ hours outside
                lines.append("💡 日均在外超过 8 小时，生活节奏紧凑")
            } else if avgOutside >= 240 && avgOutside < 480 {
                lines.append("💡 日均在外 \(Int(avgOutside / 60)) 小时左右，工作生活较平衡")
            }
        }

        // Only return if we generated meaningful content beyond the header
        return lines.count >= 3 ? lines.joined(separator: "\n") : nil
    }

    /// Extracts the minute-of-day (0..1439) from a Date.
    private func minuteOfDay(_ date: Date) -> Int {
        let cal = Calendar.current
        return cal.component(.hour, from: date) * 60 + cal.component(.minute, from: date)
    }

    /// Formats a minute-of-day value (e.g. 510 → "08:30").
    private func formatMinuteOfDay(_ minute: Int) -> String {
        let h = minute / 60
        let m = minute % 60
        return String(format: "%02d:%02d", h, m)
    }

    /// Computes the standard deviation of an array of Ints.
    private func standardDeviation(_ values: [Int]) -> Double {
        guard values.count >= 2 else { return 0 }
        let mean = Double(values.reduce(0, +)) / Double(values.count)
        let variance = values.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / Double(values.count)
        return sqrt(variance)
    }

    /// Returns short Chinese weekday name from Calendar weekday number.
    private func weekdayShortName(_ weekday: Int) -> String {
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

    // MARK: - Calendar-Location Correlation

    /// Cross-references location visits with calendar events to explain WHY the user
    /// was at each place. Matches location records to events by time overlap (within 30 min buffer).
    /// Produces a "足迹日记" that tells the story behind each visit.
    private func buildCalendarLocationDiary(
        records: [LocationRecord],
        profiles: [PlaceProfile],
        range: QueryTimeRange,
        context: SkillContext
    ) -> String? {
        let interval = range.interval
        let calendarEvents = context.calendarService.fetchEvents(from: interval.start, to: interval.end)

        // Only timed events — all-day events don't correlate meaningfully with location
        let timedEvents = calendarEvents.filter { !$0.isAllDay && !$0.title.isEmpty }
        guard !timedEvents.isEmpty else { return nil }

        let cal = Calendar.current
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "M月d日"
        dateFmt.locale = Locale(identifier: "zh_CN")

        // Buffer: a location record within 30 min before event start or during event matches
        let bufferSeconds: TimeInterval = 30 * 60

        // For each place profile, find matching calendar events
        struct PlaceEventMatch {
            let placeName: String
            var events: [(event: CalendarEventItem, locationTime: Date)] = []
        }

        var matches: [PlaceEventMatch] = []

        for profile in profiles {
            // Get all records belonging to this place
            let placeRecords = findRecordsForProfile(profile, in: records)
            guard !placeRecords.isEmpty else { continue }

            var matched: [(CalendarEventItem, Date)] = []
            var matchedEventIds = Set<String>()

            for record in placeRecords {
                for event in timedEvents {
                    guard !matchedEventIds.contains(event.id) else { continue }

                    // Check time overlap: record time falls within [event.start - buffer, event.end + buffer]
                    let eventWindowStart = event.startDate.addingTimeInterval(-bufferSeconds)
                    let eventWindowEnd = event.endDate.addingTimeInterval(bufferSeconds)

                    if record.timestamp >= eventWindowStart && record.timestamp <= eventWindowEnd {
                        matched.append((event, record.timestamp))
                        matchedEventIds.insert(event.id)
                    }
                }
            }

            if !matched.isEmpty {
                var pm = PlaceEventMatch(placeName: profile.name)
                pm.events = matched.sorted { $0.1 < $1.1 }
                matches.append(pm)
            }
        }

        guard !matches.isEmpty else { return nil }

        // Build the diary section
        var lines: [String] = ["📖 足迹日记"]

        let isSingleDay = (range == .today || range == .yesterday)
        var totalShown = 0
        let maxPlaces = 5
        let maxEventsPerPlace = 3

        for match in matches.prefix(maxPlaces) {
            let placeHeader: String
            if match.events.count == 1 {
                placeHeader = "📍 \(match.placeName)"
            } else {
                placeHeader = "📍 \(match.placeName)（\(match.events.count) 个日程）"
            }
            lines.append(placeHeader)

            for (event, locTime) in match.events.prefix(maxEventsPerPlace) {
                let timeStr = "\(timeFmt.string(from: event.startDate))–\(timeFmt.string(from: event.endDate))"
                let datePrefix = isSingleDay ? "" : "\(dateFmt.string(from: event.startDate)) "

                var eventLine = "  \(datePrefix)\(timeStr) \(event.title)"

                // Add event location if it exists and differs from the place name
                if !event.location.isEmpty && !match.placeName.contains(event.location)
                    && !event.location.contains(match.placeName) {
                    eventLine += "（\(event.location)）"
                }

                lines.append(eventLine)
                totalShown += 1
            }

            if match.events.count > maxEventsPerPlace {
                lines.append("  …还有 \(match.events.count - maxEventsPerPlace) 个日程")
            }
        }

        // Skip section if too few correlations (might be noise)
        guard totalShown >= 1 else { return nil }

        // Add insight based on correlation patterns
        let totalEventsMatched = matches.reduce(0) { $0 + $1.events.count }
        let totalTimedEvents = timedEvents.count
        let correlationRate = totalTimedEvents > 0 ? Double(totalEventsMatched) / Double(totalTimedEvents) : 0

        if correlationRate >= 0.5 && totalEventsMatched >= 3 {
            lines.append("")
            lines.append("💡 你的日程和出行高度关联，\(Int(correlationRate * 100))% 的日程都有对应的位置记录")
        } else if matches.count >= 2 {
            // Find the place with most calendar events — it's likely a meeting hub
            if let busiest = matches.max(by: { $0.events.count < $1.events.count }),
               busiest.events.count >= 2 {
                lines.append("")
                lines.append("💡 \(busiest.placeName)是你最主要的日程集中地")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Health × Location Cross-Insights

    /// Cross-references HealthKit data with location patterns to reveal how movement
    /// correlates with physical activity. Groups days by location behavior (explorer vs
    /// homebody, commute vs rest) and compares health metrics between the groups.
    private func buildHealthLocationInsights(
        records: [LocationRecord],
        profiles: [PlaceProfile],
        healthSummaries: [HealthSummary]
    ) -> String? {
        let cal = Calendar.current
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "yyyy-MM-dd"

        // Group location records by day → count unique places per day
        var placesByDay: [String: Set<String>] = [:]
        for r in records {
            let key = dayFmt.string(from: r.timestamp)
            placesByDay[key, default: []].insert(r.displayName)
        }

        // Map health summaries by day key
        var healthByDay: [String: HealthSummary] = [:]
        for s in healthSummaries where s.hasData {
            healthByDay[dayFmt.string(from: s.date)] = s
        }

        guard !healthByDay.isEmpty else { return nil }

        var insights: [String] = []

        // --- Insight 1: Explorer days (3+ places) vs. routine days (1 place) ---
        let explorerDays = placesByDay.filter { $0.value.count >= 3 }
            .compactMap { healthByDay[$0.key] }
        let routineDays = placesByDay.filter { $0.value.count <= 1 }
            .compactMap { healthByDay[$0.key] }

        if explorerDays.count >= 2 && routineDays.count >= 2 {
            let avgExplorerSteps = explorerDays.reduce(0.0) { $0 + $1.steps } / Double(explorerDays.count)
            let avgRoutineSteps = routineDays.reduce(0.0) { $0 + $1.steps } / Double(routineDays.count)

            if avgExplorerSteps > 0 && avgRoutineSteps > 0 {
                let diff = avgExplorerSteps - avgRoutineSteps
                let pct = avgRoutineSteps > 0 ? Int(abs(diff) / avgRoutineSteps * 100) : 0

                if pct >= 20 {
                    if diff > 0 {
                        insights.append("🚶 探索日（去 3+ 地方）平均 \(formatSteps(avgExplorerSteps)) 步，比单一地点日多 \(pct)%")
                    } else {
                        insights.append("🚶 待在一个地方的日子平均 \(formatSteps(avgRoutineSteps)) 步，比探索日反而多 \(pct)%")
                    }
                }
            }

            // Exercise comparison
            let avgExplorerExercise = explorerDays.reduce(0.0) { $0 + $1.exerciseMinutes } / Double(explorerDays.count)
            let avgRoutineExercise = routineDays.reduce(0.0) { $0 + $1.exerciseMinutes } / Double(routineDays.count)

            if avgExplorerExercise >= 10 && avgRoutineExercise >= 5 {
                let exDiff = avgExplorerExercise - avgRoutineExercise
                if abs(exDiff) >= 10 {
                    if exDiff > 0 {
                        insights.append("💪 探索日运动更多（\(Int(avgExplorerExercise)) 分钟 vs \(Int(avgRoutineExercise)) 分钟）")
                    } else {
                        insights.append("💪 待在固定地点的日子运动更多（\(Int(avgRoutineExercise)) 分钟 vs \(Int(avgExplorerExercise)) 分钟）")
                    }
                }
            }
        }

        // --- Insight 2: Commute days vs. non-commute days (needs home + work) ---
        if let homeIdx = detectHome(profiles: profiles),
           let workIdx = detectWork(profiles: profiles, excludeIndices: [homeIdx]) {
            let homeName = profiles[homeIdx].name
            let workName = profiles[workIdx].name

            var commuteDayKeys: [String] = []
            var nonCommuteDayKeys: [String] = []

            for (dayKey, places) in placesByDay {
                let placeNames = places.joined(separator: " ")
                let hasHome = placeNames.contains(homeName) || places.contains(homeName)
                let hasWork = placeNames.contains(workName) || places.contains(workName)

                if hasHome && hasWork {
                    commuteDayKeys.append(dayKey)
                } else if !hasWork {
                    nonCommuteDayKeys.append(dayKey)
                }
            }

            let commuteHealth = commuteDayKeys.compactMap { healthByDay[$0] }
            let nonCommuteHealth = nonCommuteDayKeys.compactMap { healthByDay[$0] }

            if commuteHealth.count >= 2 && nonCommuteHealth.count >= 2 {
                let avgCommuteSteps = commuteHealth.reduce(0.0) { $0 + $1.steps } / Double(commuteHealth.count)
                let avgHomeSteps = nonCommuteHealth.reduce(0.0) { $0 + $1.steps } / Double(nonCommuteHealth.count)

                if avgCommuteSteps > 0 && avgHomeSteps > 0 {
                    let diff = avgCommuteSteps - avgHomeSteps
                    let pct = avgHomeSteps > 0 ? Int(abs(diff) / avgHomeSteps * 100) : 0

                    if pct >= 15 {
                        if diff > 0 {
                            insights.append("🏢 通勤日平均 \(formatSteps(avgCommuteSteps)) 步，比非通勤日多 \(pct)%")
                        } else {
                            insights.append("🏠 非通勤日平均 \(formatSteps(avgHomeSteps)) 步，比通勤日多 \(pct)%")
                        }
                    }
                }

                // Sleep comparison: commute days vs. non-commute days
                let commuteSleep = commuteHealth.filter { $0.sleepHours > 0 }
                let nonCommuteSleep = nonCommuteHealth.filter { $0.sleepHours > 0 }
                if commuteSleep.count >= 2 && nonCommuteSleep.count >= 2 {
                    let avgCSleep = commuteSleep.reduce(0.0) { $0 + $1.sleepHours } / Double(commuteSleep.count)
                    let avgNSleep = nonCommuteSleep.reduce(0.0) { $0 + $1.sleepHours } / Double(nonCommuteSleep.count)
                    let sleepDiff = avgNSleep - avgCSleep
                    if abs(sleepDiff) >= 0.5 {
                        if sleepDiff > 0 {
                            insights.append("😴 非通勤日睡眠多 \(String(format: "%.1f", sleepDiff)) 小时（\(String(format: "%.1f", avgNSleep))h vs \(String(format: "%.1f", avgCSleep))h）")
                        } else {
                            insights.append("😴 通勤日反而睡得更多（\(String(format: "%.1f", avgCSleep))h vs \(String(format: "%.1f", avgNSleep))h）")
                        }
                    }
                }
            }
        }

        // --- Insight 3: Location variety → activity correlation ---
        // Compare days with 0 location records (stayed home all day) to active days
        let allDayKeys = Set(healthByDay.keys)
        let locationDayKeys = Set(placesByDay.keys)
        let stayHomeDayKeys = allDayKeys.subtracting(locationDayKeys)

        let stayHomeHealth = stayHomeDayKeys.compactMap { healthByDay[$0] }
        let activeHealth = locationDayKeys.compactMap { healthByDay[$0] }

        if stayHomeHealth.count >= 2 && activeHealth.count >= 2 {
            let avgStaySteps = stayHomeHealth.reduce(0.0) { $0 + $1.steps } / Double(stayHomeHealth.count)
            let avgActiveSteps = activeHealth.reduce(0.0) { $0 + $1.steps } / Double(activeHealth.count)

            if avgStaySteps > 0 && avgActiveSteps > 0 {
                let pct = avgStaySteps > 0 ? Int((avgActiveSteps - avgStaySteps) / avgStaySteps * 100) : 0
                if pct >= 30 {
                    insights.append("🏃 出门日比宅家日多走 \(pct)% 的步数（\(formatSteps(avgActiveSteps)) vs \(formatSteps(avgStaySteps))）")
                } else if pct <= -20 {
                    insights.append("🏠 宅家日步数反而更高，可能是室内运动的功劳")
                }
            }
        }

        // --- Insight 4: Best activity place (which place correlates with highest step days) ---
        if profiles.count >= 3 {
            var placeStepCorrelation: [(name: String, avgSteps: Double, days: Int)] = []

            for profile in profiles.prefix(8) {
                // Find days when user visited this place
                let visitDays = placesByDay.filter { $0.value.contains(profile.name) }
                    .compactMap { healthByDay[$0.key] }
                guard visitDays.count >= 2 else { continue }

                let avgSteps = visitDays.reduce(0.0) { $0 + $1.steps } / Double(visitDays.count)
                placeStepCorrelation.append((name: profile.name, avgSteps: avgSteps, days: visitDays.count))
            }

            if placeStepCorrelation.count >= 2 {
                let sorted = placeStepCorrelation.sorted { $0.avgSteps > $1.avgSteps }
                if let best = sorted.first, let worst = sorted.last,
                   best.avgSteps > worst.avgSteps * 1.3 && best.avgSteps >= 3000 {
                    insights.append("📍 去「\(best.name)」的日子步数最高（日均 \(formatSteps(best.avgSteps))），去「\(worst.name)」时最低（\(formatSteps(worst.avgSteps))）")
                }
            }
        }

        // Cap at 3 insights to avoid information overload
        guard !insights.isEmpty else { return nil }
        let selected = Array(insights.prefix(3))

        var lines: [String] = ["🔗 健康 × 位置关联"]
        lines.append(contentsOf: selected)

        return lines.joined(separator: "\n")
    }

    /// Formats step count for display (e.g. 8523 → "8,523")
    private func formatSteps(_ steps: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: steps)) ?? "\(Int(steps))"
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

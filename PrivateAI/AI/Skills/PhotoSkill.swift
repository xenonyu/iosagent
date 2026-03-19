import Foundation
import CoreData
import CoreLocation

/// Handles photo statistics, insights, and natural-language photo search.
struct PhotoSkill: ClawSkill {

    let id = "photo"

    func canHandle(intent: QueryIntent) -> Bool {
        switch intent {
        case .photos, .photoSearch:
            return true
        default:
            return false
        }
    }

    func execute(intent: QueryIntent, context: SkillContext, completion: @escaping (String) -> Void) {
        switch intent {
        case .photos(let range):
            completion(buildPhotoInsights(range: range, context: context))
        case .photoSearch(let query):
            completion(handlePhotoSearch(query: query, context: context))
        default:
            break
        }
    }

    // MARK: - Photo Insights (Stats + Patterns)

    private func buildPhotoInsights(range: QueryTimeRange, context: SkillContext) -> String {
        guard context.photoService.isAuthorized else {
            return "📷 相册权限未开启。\n请前往「设置 → iosclaw → 照片」，选择「所有照片」或「所选照片」。"
        }

        let interval = range.interval
        let photos = context.photoService.fetchMetadata(from: interval.start, to: interval.end)

        if photos.isEmpty {
            return "📷 \(range.label)没有找到照片。\n如果是有限访问权限，请在设置中选择更多照片，或者调整时间范围再试试。"
        }

        let cal = Calendar.current
        let withLocation = photos.filter { $0.hasLocation }.count
        let favorites = photos.filter { $0.isFavorite }.count

        // --- Day distribution ---
        var dayCount: [Date: Int] = [:]
        photos.forEach {
            let day = cal.startOfDay(for: $0.date)
            dayCount[day, default: 0] += 1
        }
        let sortedDays = dayCount.sorted { $0.key < $1.key }
        let mostActiveDay = dayCount.max(by: { $0.value < $1.value })

        // --- Hour distribution ---
        var hourCount = [Int: Int]()
        photos.forEach {
            let hour = cal.component(.hour, from: $0.date)
            hourCount[hour, default: 0] += 1
        }
        let peakHour = hourCount.max(by: { $0.value < $1.value })

        // --- Weekday vs weekend ---
        var weekdayPhotos = 0
        var weekendPhotos = 0
        photos.forEach {
            let wd = cal.component(.weekday, from: $0.date)
            if wd == 1 || wd == 7 { weekendPhotos += 1 } else { weekdayPhotos += 1 }
        }

        // --- Location clusters ---
        let locationClusters = buildLocationClusters(photos: photos.filter { $0.hasLocation })

        // --- Build response ---
        var lines = ["📷 \(range.label)的照片记录\n"]
        lines.append("共拍了 **\(photos.count) 张**照片")

        let totalDays = max(1, dayCount.count)
        let avgPerDay = Double(photos.count) / Double(totalDays)
        if totalDays > 1 {
            lines.append("活跃 \(totalDays) 天，平均每天 \(String(format: "%.1f", avgPerDay)) 张")
        }

        if favorites > 0 {
            lines.append("❤️ 其中 \(favorites) 张被标记为收藏")
        }

        // Peak shooting time
        if let (hour, count) = peakHour {
            let period = timeOfDayLabel(hour: hour)
            lines.append("\n⏰ **拍照高峰**: \(period)（\(hour):00 前后，\(count) 张）")
        }

        // Most active day
        if let (day, count) = mostActiveDay, totalDays > 1 {
            let df = DateFormatter()
            df.dateFormat = "M月d日（EEEE）"
            df.locale = Locale(identifier: "zh_CN")
            lines.append("🏆 最活跃的一天: \(df.string(from: day))（\(count) 张）")
        }

        // Weekend vs weekday pattern
        if weekdayPhotos > 0 && weekendPhotos > 0 && totalDays > 2 {
            let weekdayDays = max(1, sortedDays.filter { cal.component(.weekday, from: $0.key) != 1 && cal.component(.weekday, from: $0.key) != 7 }.count)
            let weekendDays = max(1, sortedDays.filter { let wd = cal.component(.weekday, from: $0.key); return wd == 1 || wd == 7 }.count)
            let weekdayAvg = Double(weekdayPhotos) / Double(weekdayDays)
            let weekendAvg = Double(weekendPhotos) / Double(weekendDays)

            if weekendAvg > weekdayAvg * 1.5 {
                lines.append("📊 周末拍照频率是工作日的 \(String(format: "%.1f", weekendAvg / max(0.1, weekdayAvg))) 倍")
            } else if weekdayAvg > weekendAvg * 1.5 {
                lines.append("📊 工作日拍照比周末更频繁")
            }
        }

        // Trend (first half vs second half)
        if sortedDays.count >= 4 {
            let mid = sortedDays.count / 2
            let firstHalfTotal = sortedDays[..<mid].reduce(0) { $0 + $1.value }
            let secondHalfTotal = sortedDays[mid...].reduce(0) { $0 + $1.value }
            if secondHalfTotal > firstHalfTotal + 3 {
                lines.append("📈 后半段拍照频率明显增加，你正变得更爱记录生活")
            } else if firstHalfTotal > secondHalfTotal + 3 {
                lines.append("📉 后半段拍照有所减少")
            }
        }

        // Location clusters
        if !locationClusters.isEmpty {
            lines.append("\n📍 **拍照地点分布**:")
            for cluster in locationClusters.prefix(5) {
                lines.append("  · \(cluster.name)（\(cluster.count) 张）")
            }
            if withLocation < photos.count {
                lines.append("  · 还有 \(photos.count - withLocation) 张没有位置信息")
            }
        } else if withLocation > 0 {
            lines.append("\n📍 \(withLocation) 张照片有位置信息")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Photo Search

    private func handlePhotoSearch(query: String, context: SkillContext) -> String {
        guard context.photoService.isAuthorized else {
            return "📷 相册权限未开启。\n请前往「设置 → iosclaw → 照片」开启访问权限。"
        }

        let lower = query.lowercased()
        var resultPhotos: [PhotoMetadataItem] = []
        var searchDescription = ""

        // --- Location-based search ---
        if let locationMatch = matchLocation(in: lower) {
            resultPhotos = context.photoService.fetchNearby(
                latitude: locationMatch.lat,
                longitude: locationMatch.lon,
                radiusMeters: locationMatch.radius
            )
            searchDescription = "在「\(locationMatch.name)」附近"
        }

        // --- Favorites search ---
        if containsAny(lower, ["收藏", "喜欢", "标记", "favorite", "最爱", "精选"]) {
            resultPhotos = context.photoService.fetchFavorites()
            searchDescription = "收藏的"
        }

        // --- Time-based search (use SkillRouter's time extraction if available) ---
        let timeRange = extractTimeRange(from: lower)
        if let range = timeRange {
            let interval = range.interval
            if !resultPhotos.isEmpty {
                // Filter existing results by time
                resultPhotos = resultPhotos.filter { interval.contains($0.date) }
                searchDescription += "\(range.label)"
            } else {
                resultPhotos = context.photoService.fetchMetadata(from: interval.start, to: interval.end)
                searchDescription = "\(range.label)"
            }
        }

        // --- If no specific filter matched, try location records from user's history ---
        if resultPhotos.isEmpty && searchDescription.isEmpty {
            // Try matching query against user's saved location names
            if let locationFromHistory = matchLocationFromHistory(query: lower, context: context) {
                resultPhotos = context.photoService.fetchNearby(
                    latitude: locationFromHistory.lat,
                    longitude: locationFromHistory.lon,
                    radiusMeters: 2000
                )
                searchDescription = "在「\(locationFromHistory.name)」附近"
            }
        }

        // --- Build response ---
        if resultPhotos.isEmpty && searchDescription.isEmpty {
            return buildSearchHelpText(query: query)
        }

        if resultPhotos.isEmpty {
            return "📷 没有找到\(searchDescription)的照片。\n\n可能是该时间段或地点没有拍过照片，试试其他描述？"
        }

        return buildSearchResults(photos: resultPhotos, description: searchDescription)
    }

    // MARK: - Search Results Formatting

    private func buildSearchResults(photos: [PhotoMetadataItem], description: String) -> String {
        let cal = Calendar.current
        let df = DateFormatter()
        df.dateFormat = "M月d日 HH:mm"
        df.locale = Locale(identifier: "zh_CN")

        var lines = ["📷 找到 **\(photos.count) 张**\(description)的照片\n"]

        // Date range
        if let earliest = photos.last?.date, let latest = photos.first?.date {
            let dayDf = DateFormatter()
            dayDf.dateFormat = "M月d日"
            if cal.isDate(earliest, inSameDayAs: latest) {
                lines.append("📅 拍摄于 \(dayDf.string(from: earliest))")
            } else {
                lines.append("📅 时间跨度: \(dayDf.string(from: earliest)) ~ \(dayDf.string(from: latest))")
            }
        }

        // Favorites among results
        let favCount = photos.filter { $0.isFavorite }.count
        if favCount > 0 {
            lines.append("❤️ 其中 \(favCount) 张是收藏")
        }

        // Location info
        let withLoc = photos.filter { $0.hasLocation }.count
        if withLoc > 0 && withLoc < photos.count {
            lines.append("📍 \(withLoc) 张有位置信息")
        }

        // Show most recent photos timeline
        lines.append("\n**最近拍摄**:")
        for photo in photos.prefix(8) {
            let timeStr = df.string(from: photo.date)
            let fav = photo.isFavorite ? " ❤️" : ""
            let loc = photo.hasLocation ? " 📍" : ""
            lines.append("  · \(timeStr)\(fav)\(loc)")
        }

        if photos.count > 8 {
            lines.append("  …还有 \(photos.count - 8) 张")
        }

        return lines.joined(separator: "\n")
    }

    private func buildSearchHelpText(query: String) -> String {
        return """
        📷 没能理解你要找什么类型的照片。

        试试这样问我：
        · 「找在北京拍的照片」— 按地点搜索
        · 「上周拍的照片」— 按时间搜索
        · 「我收藏的照片」— 查看收藏
        · 「上个月在上海拍的照片」— 时间 + 地点

        💡 我可以根据拍摄时间和地点帮你找到照片。
        """
    }

    // MARK: - Location Matching

    private struct LocationMatch {
        let name: String
        let lat: Double
        let lon: Double
        let radius: Double
    }

    private func matchLocation(in text: String) -> LocationMatch? {
        let knownLocations: [(keywords: [String], lat: Double, lon: Double, name: String, radius: Double)] = [
            // China
            (["北京", "天安门", "故宫", "长城"], 39.9042, 116.4074, "北京", 80_000),
            (["上海", "外滩", "陆家嘴"], 31.2304, 121.4737, "上海", 60_000),
            (["广州", "珠江"], 23.1291, 113.2644, "广州", 50_000),
            (["深圳"], 22.5431, 114.0579, "深圳", 40_000),
            (["杭州", "西湖"], 30.2741, 120.1551, "杭州", 40_000),
            (["成都", "春熙路", "太古里"], 30.5728, 104.0668, "成都", 40_000),
            (["西安", "兵马俑"], 34.3416, 108.9398, "西安", 40_000),
            (["南京", "夫子庙", "中山陵"], 32.0603, 118.7969, "南京", 40_000),
            (["重庆", "洪崖洞"], 29.5630, 106.5516, "重庆", 40_000),
            (["武汉", "黄鹤楼"], 30.5928, 114.3055, "武汉", 40_000),
            (["厦门", "鼓浪屿"], 24.4798, 118.0894, "厦门", 30_000),
            (["三亚", "亚龙湾"], 18.2528, 109.5120, "三亚", 30_000),
            (["丽江", "大理"], 26.8721, 100.2299, "丽江/大理", 50_000),
            (["黄山"], 30.1314, 118.1661, "黄山", 30_000),
            (["青岛"], 36.0671, 120.3826, "青岛", 30_000),
            (["苏州", "拙政园"], 31.2990, 120.5853, "苏州", 30_000),
            // International
            (["东京", "tokyo"], 35.6762, 139.6503, "东京", 50_000),
            (["大阪", "osaka"], 34.6937, 135.5023, "大阪", 40_000),
            (["京都", "kyoto"], 35.0116, 135.7681, "京都", 30_000),
            (["首尔", "seoul"], 37.5665, 126.9780, "首尔", 40_000),
            (["曼谷", "bangkok"], 13.7563, 100.5018, "曼谷", 40_000),
            (["新加坡", "singapore"], 1.3521, 103.8198, "新加坡", 30_000),
            (["纽约", "new york", "曼哈顿"], 40.7128, -74.0060, "纽约", 50_000),
            (["旧金山", "san francisco", "金门大桥"], 37.7749, -122.4194, "旧金山", 40_000),
            (["洛杉矶", "los angeles", "好莱坞"], 34.0522, -118.2437, "洛杉矶", 50_000),
            (["巴黎", "paris", "埃菲尔"], 48.8566, 2.3522, "巴黎", 40_000),
            (["伦敦", "london"], 51.5074, -0.1278, "伦敦", 40_000),
            (["悉尼", "sydney"], -33.8688, 151.2093, "悉尼", 40_000),
            (["富士山", "fuji"], 35.3606, 138.7274, "富士山", 30_000),
            // Scenes (use large radius as concept, not exact location)
            (["海边", "沙滩", "海滩", "beach"], 0, 0, "海边", 0),
            (["山", "mountain", "爬山", "登山"], 0, 0, "山上", 0),
        ]

        for loc in knownLocations {
            if containsAny(text, loc.keywords) {
                // Scene-based keywords (no specific coordinates)
                if loc.lat == 0 && loc.lon == 0 { return nil }
                return LocationMatch(name: loc.name, lat: loc.lat, lon: loc.lon, radius: loc.radius)
            }
        }
        return nil
    }

    /// Try to match query keywords against the user's actual location history.
    private func matchLocationFromHistory(query: String, context: SkillContext) -> LocationMatch? {
        let request = CDLocationRecord.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        request.fetchLimit = 200

        guard let records = try? context.coreDataContext.fetch(request) as? [CDLocationRecord] else { return nil }

        // Find location records whose placeName contains any word from the query
        // Extract meaningful words (2+ characters) from query
        let queryWords = query.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }

        for record in records {
            guard let name = record.placeName, !name.isEmpty,
                  record.latitude != 0, record.longitude != 0 else { continue }

            for word in queryWords {
                if name.lowercased().contains(word) || word.contains(name.lowercased()) {
                    return LocationMatch(
                        name: name,
                        lat: record.latitude,
                        lon: record.longitude,
                        radius: 2000
                    )
                }
            }
        }

        return nil
    }

    // MARK: - Time Range Extraction

    private func extractTimeRange(from text: String) -> QueryTimeRange? {
        if containsAny(text, ["今天", "today"]) { return .today }
        if containsAny(text, ["昨天", "yesterday"]) { return .yesterday }
        if containsAny(text, ["这周", "本周", "this week"]) { return .thisWeek }
        if containsAny(text, ["上周", "上个星期", "last week"]) { return .lastWeek }
        if containsAny(text, ["这个月", "本月", "this month"]) { return .thisMonth }
        if containsAny(text, ["上个月", "上月", "last month"]) { return .lastMonth }
        return nil
    }

    // MARK: - Location Clustering

    private struct LocationCluster {
        let name: String
        let count: Int
        let latitude: Double
        let longitude: Double
    }

    /// Groups photos by proximity into location clusters.
    private func buildLocationClusters(photos: [PhotoMetadataItem]) -> [LocationCluster] {
        guard !photos.isEmpty else { return [] }

        // Simple grid-based clustering (~5km cells)
        let gridSize = 0.05 // ~5km in degrees
        var grid: [String: (lat: Double, lon: Double, count: Int)] = [:]

        for photo in photos {
            guard let lat = photo.latitude, let lon = photo.longitude else { continue }
            let key = "\(Int(lat / gridSize)),\(Int(lon / gridSize))"
            if let existing = grid[key] {
                grid[key] = (existing.lat, existing.lon, existing.count + 1)
            } else {
                grid[key] = (lat, lon, 1)
            }
        }

        // Convert to clusters, sorted by count
        var clusters = grid.values.map { entry in
            LocationCluster(
                name: coordinateDescription(lat: entry.lat, lon: entry.lon),
                count: entry.count,
                latitude: entry.lat,
                longitude: entry.lon
            )
        }
        clusters.sort { $0.count > $1.count }

        return clusters
    }

    /// Simple coordinate to rough area description.
    private func coordinateDescription(lat: Double, lon: Double) -> String {
        // Provide a rough geographic label based on coordinates
        // This is a simplified offline lookup — real reverse geocoding would be async
        let latDir = lat >= 0 ? "N" : "S"
        let lonDir = lon >= 0 ? "E" : "W"
        return String(format: "%.1f°%@, %.1f°%@", abs(lat), latDir, abs(lon), lonDir)
    }

    // MARK: - Helpers

    private func timeOfDayLabel(hour: Int) -> String {
        switch hour {
        case 5..<9: return "清晨"
        case 9..<12: return "上午"
        case 12..<14: return "午间"
        case 14..<17: return "下午"
        case 17..<19: return "傍晚"
        case 19..<22: return "晚上"
        default: return "深夜"
        }
    }

    private func containsAny(_ text: String, _ keywords: [String]) -> Bool {
        keywords.contains { text.contains($0) }
    }
}

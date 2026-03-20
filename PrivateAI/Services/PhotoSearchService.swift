import Foundation
import CoreData
import CoreLocation

/// Parses natural-language photo queries and searches CDPhotoIndex.
/// Returns matching PHAsset identifiers for display.
final class PhotoSearchService {

    private let context: NSManagedObjectContext

    init(context: NSManagedObjectContext) {
        self.context = context
    }

    // MARK: - Query Model

    struct PhotoQuery {
        var keywords: [String] = []        // Vision tags to match
        var location: CLLocationCoordinate2D? // geographic center
        var locationRadius: Double = 50_000   // meters (default 50km)
        var locationName: String = ""
        var minFaces: Int? = nil
        var maxFaces: Int? = nil
        var isSelfie: Bool? = nil
        var dateFrom: Date? = nil
        var dateTo: Date? = nil
    }

    struct SearchResult {
        let assetId: String
        let tags: [String]
        let faceCount: Int
        let latitude: Double
        let longitude: Double
        let date: Date?
        var relevanceScore: Double = 0
    }

    // MARK: - Search

    func search(query: PhotoQuery, limit: Int = 50) -> [SearchResult] {
        var predicates: [NSPredicate] = []

        // Location filter
        if let loc = query.location {
            let radius = query.locationRadius
            let latDelta = radius / 111_000  // ~111km per degree latitude
            let lonDelta = radius / (111_000 * cos(loc.latitude * .pi / 180))
            predicates.append(NSPredicate(
                format: "latitude > %f AND latitude < %f AND longitude > %f AND longitude < %f AND latitude != 0",
                loc.latitude - latDelta, loc.latitude + latDelta,
                loc.longitude - lonDelta, loc.longitude + lonDelta
            ))
        }

        // Face count
        if let min = query.minFaces {
            predicates.append(NSPredicate(format: "faceCount >= %d", min))
        }
        if let max = query.maxFaces {
            predicates.append(NSPredicate(format: "faceCount <= %d", max))
        }

        // Selfie = front camera or (1 face + heuristic)
        if query.isSelfie == true {
            predicates.append(NSPredicate(format: "faceCount >= 1"))
        }

        // Date range
        if let from = query.dateFrom {
            predicates.append(NSPredicate(format: "creationDate >= %@", from as NSDate))
        }
        if let to = query.dateTo {
            predicates.append(NSPredicate(format: "creationDate <= %@", to as NSDate))
        }

        let req = NSFetchRequest<CDPhotoIndex>(entityName: "CDPhotoIndex")
        if !predicates.isEmpty {
            req.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        }
        req.fetchLimit = predicates.isEmpty ? limit : 500  // broader fetch for scoring

        guard let entries = try? context.fetch(req) else { return [] }

        // Score and rank by tag relevance
        var results = entries.map { entry -> SearchResult in
            let entryTags = (entry.tags ?? "").split(separator: ",").map { String($0) }
            var score: Double = 0

            // Tag keyword matching
            for kw in query.keywords {
                let kwLower = kw.lowercased()
                for tag in entryTags {
                    if tag.lowercased().contains(kwLower) || kwLower.contains(tag.lowercased()) {
                        score += 10
                    }
                }
            }

            // Selfie bonus
            if query.isSelfie == true && entry.faceCount == 1 {
                score += 5
            }

            // Location proximity bonus
            if let loc = query.location, entry.latitude != 0 {
                let dist = distance(lat1: loc.latitude, lon1: loc.longitude,
                                    lat2: entry.latitude, lon2: entry.longitude)
                if dist < 5_000 { score += 20 }       // <5km
                else if dist < 20_000 { score += 10 }  // <20km
                else if dist < query.locationRadius { score += 5 }
            }

            return SearchResult(
                assetId: entry.assetId ?? "",
                tags: entryTags,
                faceCount: Int(entry.faceCount),
                latitude: entry.latitude,
                longitude: entry.longitude,
                date: entry.creationDate,
                relevanceScore: score
            )
        }

        // Sort by relevance, then recency
        results.sort { a, b in
            if a.relevanceScore != b.relevanceScore { return a.relevanceScore > b.relevanceScore }
            return (a.date ?? .distantPast) > (b.date ?? .distantPast)
        }

        return Array(results.prefix(limit))
    }

    // MARK: - Natural Language Query Parser

    /// Parses a user's natural-language photo search query into a PhotoQuery struct.
    func parseQuery(_ text: String) -> PhotoQuery {
        let lower = text.lowercased()
        var q = PhotoQuery()

        // --- Selfie detection ---
        if containsAny(lower, ["自拍", "selfie", "自己"]) {
            q.isSelfie = true
            q.minFaces = 1
            q.maxFaces = 1
        }

        // --- Face count ---
        if containsAny(lower, ["单人", "一个人", "alone", "solo"]) {
            q.minFaces = 1; q.maxFaces = 1
        }
        if containsAny(lower, ["合照", "合影", "group", "大家"]) {
            q.minFaces = 2
        }

        // --- Animals ---
        if containsAny(lower, ["猫", "cat", "kitten", "小猫"]) {
            q.keywords.append(contentsOf: ["cat", "animal", "kitten"])
        }
        if containsAny(lower, ["狗", "dog", "puppy", "小狗"]) {
            q.keywords.append(contentsOf: ["dog", "animal", "puppy"])
        }
        if containsAny(lower, ["动物", "animal", "宠物", "pet"]) {
            q.keywords.append("animal")
        }

        // --- Scenes ---
        if containsAny(lower, ["海边", "沙滩", "海滩", "beach", "大海", "海洋"]) {
            q.keywords.append(contentsOf: ["beach", "ocean", "sea", "coast"])
        }
        if containsAny(lower, ["山", "mountain", "爬山", "登山"]) {
            q.keywords.append(contentsOf: ["mountain", "hill", "outdoor", "hiking"])
        }
        if containsAny(lower, ["雪", "snow", "滑雪"]) {
            q.keywords.append(contentsOf: ["snow", "winter", "skiing"])
        }
        if containsAny(lower, ["日落", "sunset", "夕阳"]) {
            q.keywords.append(contentsOf: ["sunset", "sky"])
        }
        if containsAny(lower, ["日出", "sunrise", "朝霞"]) {
            q.keywords.append(contentsOf: ["sunrise", "sky", "morning"])
        }
        if containsAny(lower, ["风景", "景色", "scenery", "landscape", "美景"]) {
            q.keywords.append(contentsOf: ["landscape", "scenery", "nature", "outdoor"])
        }
        if containsAny(lower, ["夜景", "夜晚", "night", "夜色", "灯光"]) {
            q.keywords.append(contentsOf: ["night", "city", "light"])
        }
        if containsAny(lower, ["建筑", "大楼", "building", "architecture", "楼"]) {
            q.keywords.append(contentsOf: ["building", "architecture", "city"])
        }
        if containsAny(lower, ["天空", "云", "sky", "cloud", "蓝天", "白云"]) {
            q.keywords.append(contentsOf: ["sky", "cloud"])
        }
        if containsAny(lower, ["湖", "lake", "河", "river", "溪", "水"]) {
            q.keywords.append(contentsOf: ["lake", "river", "water"])
        }
        if containsAny(lower, ["树", "forest", "森林", "tree", "林"]) {
            q.keywords.append(contentsOf: ["tree", "forest", "nature"])
        }
        if containsAny(lower, ["城市", "city", "街", "street", "街道", "街拍"]) {
            q.keywords.append(contentsOf: ["city", "street", "urban"])
        }
        if containsAny(lower, ["鸟", "bird", "飞鸟"]) {
            q.keywords.append(contentsOf: ["bird", "animal"])
        }

        // --- Food ---
        if containsAny(lower, ["食物", "美食", "吃", "food", "餐", "饭", "甜品", "蛋糕", "咖啡", "coffee"]) {
            q.keywords.append(contentsOf: ["food", "meal", "restaurant"])
        }

        // --- Known locations → geocode ---
        // Each entry includes a radius (meters) appropriate for the geographic scope:
        // cities ~50km, regions ~200-300km, countries ~500km+
        let knownLocations: [(keywords: [String], lat: Double, lon: Double, name: String, radius: Double)] = [
            // China cities
            (["北京", "天安门", "故宫"], 39.9042, 116.4074, "北京", 80_000),
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
            (["丽江", "大理"], 26.8721, 100.2299, "丽江", 50_000),
            (["黄山"], 30.1314, 118.1661, "黄山", 30_000),
            (["青岛"], 36.0671, 120.3826, "青岛", 30_000),
            (["苏州", "拙政园"], 31.2990, 120.5853, "苏州", 30_000),
            (["长城", "great wall"], 40.4319, 116.5704, "长城", 50_000),
            (["香港"], 22.3193, 114.1694, "香港", 30_000),
            (["台北"], 25.0330, 121.5654, "台北", 30_000),
            // International cities
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
            (["大峡谷", "grand canyon"], 36.1069, -112.1129, "大峡谷", 30_000),
            (["富士山", "fuji"], 35.3606, 138.7274, "富士山", 30_000),
            // Countries (large radius covers the entire country)
            (["日本", "japan"], 36.2048, 138.2529, "日本", 500_000),
            (["韩国", "korea"], 35.9078, 127.7669, "韩国", 300_000),
            (["泰国", "thailand"], 15.8700, 100.9925, "泰国", 500_000),
            (["越南", "vietnam"], 14.0583, 108.2772, "越南", 500_000),
            (["马来西亚", "malaysia"], 4.2105, 101.9758, "马来西亚", 500_000),
            (["印度尼西亚", "印尼", "indonesia", "巴厘岛", "bali"], -0.7893, 113.9213, "印尼", 1_000_000),
            (["菲律宾", "philippines"], 12.8797, 121.7740, "菲律宾", 500_000),
            (["美国", "america", "usa"], 37.0902, -95.7129, "美国", 2_500_000),
            (["英国", "uk", "britain"], 55.3781, -3.4360, "英国", 400_000),
            (["法国", "france"], 46.2276, 2.2137, "法国", 500_000),
            (["德国", "germany"], 51.1657, 10.4515, "德国", 400_000),
            (["意大利", "italy", "罗马", "rome", "威尼斯", "venice", "米兰", "milan"], 41.8719, 12.5674, "意大利", 500_000),
            (["西班牙", "spain", "巴塞罗那", "barcelona", "马德里", "madrid"], 40.4637, -3.7492, "西班牙", 500_000),
            (["澳大利亚", "australia", "墨尔本", "melbourne"], -25.2744, 133.7751, "澳大利亚", 1_500_000),
            (["新西兰", "new zealand"], -40.9006, 174.8860, "新西兰", 500_000),
            (["加拿大", "canada", "温哥华", "vancouver", "多伦多", "toronto"], 56.1304, -106.3468, "加拿大", 2_500_000),
            (["瑞士", "switzerland", "苏黎世", "zurich"], 46.8182, 8.2275, "瑞士", 200_000),
            (["土耳其", "turkey", "istanbul", "伊斯坦布尔"], 38.9637, 35.2433, "土耳其", 600_000),
            (["埃及", "egypt", "开罗", "cairo"], 26.8206, 30.8025, "埃及", 500_000),
            (["迪拜", "dubai"], 25.2048, 55.2708, "迪拜", 50_000),
            // China regions/provinces
            (["云南"], 25.0453, 101.7103, "云南", 200_000),
            (["海南"], 19.1959, 109.7453, "海南", 150_000),
            (["西藏", "拉萨", "tibet"], 29.6520, 91.1721, "西藏", 500_000),
            (["新疆", "乌鲁木齐"], 43.7930, 87.6271, "新疆", 800_000),
            (["内蒙古", "呼和浩特"], 40.8188, 111.6655, "内蒙古", 800_000),
            (["四川", "九寨沟"], 30.5728, 104.0668, "四川", 300_000),
            (["福建"], 26.1004, 119.2965, "福建", 200_000),
            (["浙江"], 29.1416, 119.7889, "浙江", 200_000),
            (["广西", "桂林"], 25.2354, 110.1799, "广西", 200_000),
            (["长沙"], 28.2282, 112.9388, "长沙", 40_000),
            (["哈尔滨", "冰城"], 45.8038, 126.5350, "哈尔滨", 40_000),
        ]

        for loc in knownLocations {
            if containsAny(lower, loc.keywords) {
                q.location = CLLocationCoordinate2D(latitude: loc.lat, longitude: loc.lon)
                q.locationRadius = loc.radius
                q.locationName = loc.name
                break
            }
        }

        // --- Generic outdoor/indoor ---
        if containsAny(lower, ["户外", "outdoor", "外面"]) {
            q.keywords.append("outdoor")
        }
        if containsAny(lower, ["室内", "indoor", "家里"]) {
            q.keywords.append("indoor")
        }

        // --- Flowers/plants ---
        if containsAny(lower, ["花", "flower", "植物", "plant"]) {
            q.keywords.append(contentsOf: ["flower", "plant", "garden"])
        }

        // --- Vehicle ---
        if containsAny(lower, ["车", "car", "汽车"]) {
            q.keywords.append(contentsOf: ["car", "vehicle"])
        }

        // --- Date/Time range ---
        // Parse temporal expressions so "昨天拍的照片" or "上周的照片"
        // correctly filters by date instead of returning all-time results.
        let (dateFrom, dateTo) = parseDateRange(lower)
        q.dateFrom = dateFrom
        q.dateTo = dateTo

        return q
    }

    // MARK: - Helpers

    /// Parses common temporal expressions (Chinese & English) into a date range.
    /// Returns (from, to) where nil means unbounded on that side.
    /// Uses Monday-based weeks consistent with GPTContextBuilder's weekBoundaryText.
    private func parseDateRange(_ text: String) -> (Date?, Date?) {
        let cal = Calendar.current
        let now = Date()
        let todayStart = cal.startOfDay(for: now)

        // "今天" / "today"
        if containsAny(text, ["今天", "today"]) {
            let todayEnd = cal.date(byAdding: .day, value: 1, to: todayStart)!
            return (todayStart, todayEnd)
        }

        // "昨天" / "yesterday"
        if containsAny(text, ["昨天", "yesterday"]) {
            let yesterdayStart = cal.date(byAdding: .day, value: -1, to: todayStart)!
            return (yesterdayStart, todayStart)
        }

        // "前天" / "day before yesterday"
        if containsAny(text, ["前天"]) {
            let start = cal.date(byAdding: .day, value: -2, to: todayStart)!
            let end = cal.date(byAdding: .day, value: -1, to: todayStart)!
            return (start, end)
        }

        // "这周" / "本周" / "this week" — Monday to now
        if containsAny(text, ["这周", "本周", "this week"]) {
            let todayWeekday = cal.component(.weekday, from: now) // 1=Sun..7=Sat
            let daysSinceMonday = (todayWeekday + 5) % 7
            let thisMonday = cal.date(byAdding: .day, value: -daysSinceMonday, to: todayStart)!
            let end = cal.date(byAdding: .day, value: 1, to: todayStart)!
            return (thisMonday, end)
        }

        // "上周" / "last week" — last Monday to last Sunday
        if containsAny(text, ["上周", "last week"]) {
            let todayWeekday = cal.component(.weekday, from: now)
            let daysSinceMonday = (todayWeekday + 5) % 7
            let thisMonday = cal.date(byAdding: .day, value: -daysSinceMonday, to: todayStart)!
            let lastMonday = cal.date(byAdding: .day, value: -7, to: thisMonday)!
            return (lastMonday, thisMonday)
        }

        // "这个月" / "本月" / "this month"
        if containsAny(text, ["这个月", "本月", "this month"]) {
            let comps = cal.dateComponents([.year, .month], from: now)
            let monthStart = cal.date(from: comps)!
            let end = cal.date(byAdding: .day, value: 1, to: todayStart)!
            return (monthStart, end)
        }

        // "上个月" / "last month"
        if containsAny(text, ["上个月", "上月", "last month"]) {
            let comps = cal.dateComponents([.year, .month], from: now)
            let thisMonthStart = cal.date(from: comps)!
            let lastMonthStart = cal.date(byAdding: .month, value: -1, to: thisMonthStart)!
            return (lastMonthStart, thisMonthStart)
        }

        // "最近三天" / "最近3天" / "近三天"
        if text.contains("最近") || text.contains("近") {
            // Try to extract a number of days
            let dayPatterns: [(String, Int)] = [
                ("三天", 3), ("3天", 3), ("两天", 2), ("2天", 2),
                ("五天", 5), ("5天", 5), ("七天", 7), ("7天", 7),
                ("十天", 10), ("10天", 10), ("半个月", 15), ("一个月", 30), ("30天", 30)
            ]
            for (pattern, days) in dayPatterns {
                if text.contains(pattern) {
                    let start = cal.date(byAdding: .day, value: -days, to: todayStart)!
                    let end = cal.date(byAdding: .day, value: 1, to: todayStart)!
                    return (start, end)
                }
            }
        }

        // "去年" / "last year"
        if containsAny(text, ["去年", "last year"]) {
            let year = cal.component(.year, from: now) - 1
            let start = cal.date(from: DateComponents(year: year, month: 1, day: 1))!
            let end = cal.date(from: DateComponents(year: year + 1, month: 1, day: 1))!
            return (start, end)
        }

        // "今年" / "this year"
        if containsAny(text, ["今年", "this year"]) {
            let year = cal.component(.year, from: now)
            let start = cal.date(from: DateComponents(year: year, month: 1, day: 1))!
            let end = cal.date(byAdding: .day, value: 1, to: todayStart)!
            return (start, end)
        }

        return (nil, nil)
    }

    private func containsAny(_ text: String, _ keywords: [String]) -> Bool {
        keywords.contains { text.contains($0) }
    }

    private func distance(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let loc1 = CLLocation(latitude: lat1, longitude: lon1)
        let loc2 = CLLocation(latitude: lat2, longitude: lon2)
        return loc1.distance(from: loc2)
    }
}

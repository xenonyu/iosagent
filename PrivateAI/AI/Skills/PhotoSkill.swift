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

        // --- Location clusters (cross-referenced with user's location history) ---
        let locationClusters = buildLocationClusters(photos: photos.filter { $0.hasLocation }, context: context)

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

        // Content analysis from Vision-indexed tags (CDPhotoIndex)
        let contentSection = buildContentAnalysis(
            photoIds: photos.map { $0.id },
            interval: interval,
            totalCount: photos.count,
            context: context
        )
        if !contentSection.isEmpty {
            lines.append("")
            lines.append(contentsOf: contentSection)
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Content Analysis (Vision Tags)

    /// Semantic categories used to classify Vision tags into human-readable themes.
    private static let tagCategories: [(label: String, emoji: String, tags: Set<String>)] = [
        ("自拍",   "🤳", ["selfie", "portrait", "face"]),
        ("合照",   "👥", ["group", "people", "crowd"]),
        ("美食",   "🍜", ["food", "meal", "restaurant", "dish", "dessert", "cake", "coffee", "drink", "fruit"]),
        ("风景",   "🏞️", ["landscape", "scenery", "nature", "mountain", "hill", "valley", "field"]),
        ("海边",   "🏖️", ["beach", "ocean", "sea", "coast", "wave"]),
        ("天空",   "🌤️", ["sky", "cloud", "sunset", "sunrise"]),
        ("水景",   "💧", ["lake", "river", "water", "waterfall"]),
        ("花草",   "🌸", ["flower", "plant", "garden", "tree", "forest"]),
        ("动物",   "🐾", ["animal", "cat", "dog", "bird", "pet", "kitten", "puppy", "fish"]),
        ("建筑",   "🏛️", ["building", "architecture", "house", "tower", "bridge", "church"]),
        ("城市",   "🏙️", ["city", "street", "urban", "road", "traffic"]),
        ("夜景",   "🌃", ["night", "light", "neon"]),
        ("车辆",   "🚗", ["car", "vehicle", "bus", "train", "transport"]),
        ("室内",   "🏠", ["indoor", "room", "interior"]),
        ("户外",   "⛰️", ["outdoor", "hiking", "camping", "park"]),
        ("雪景",   "❄️", ["snow", "winter", "skiing", "ice"]),
    ]

    /// Queries CDPhotoIndex for photos in the given date interval, classifies their
    /// Vision tags into semantic categories, and returns a content breakdown section.
    private func buildContentAnalysis(photoIds: [String], interval: DateInterval,
                                      totalCount: Int, context: SkillContext) -> [String] {
        let request = NSFetchRequest<CDPhotoIndex>(entityName: "CDPhotoIndex")
        request.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate <= %@",
            interval.start as NSDate, interval.end as NSDate
        )

        guard let indexed = try? context.coreDataContext.fetch(request),
              !indexed.isEmpty else {
            return []
        }

        // --- Categorize each indexed photo ---
        var categoryCounts: [String: Int] = [:]   // label → count
        var selfieCount = 0
        var groupCount = 0
        var soloFaceCount = 0

        for entry in indexed {
            let entryTags = (entry.tags ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            let tagSet = Set(entryTags)

            // Face-based classification
            let faces = Int(entry.faceCount)
            if faces == 1 {
                soloFaceCount += 1
                if entry.isFrontCamera {
                    selfieCount += 1
                }
            } else if faces >= 2 {
                groupCount += 1
            }

            // Tag-based classification — a photo can match multiple categories,
            // but we only count the first (most specific) match to avoid inflation.
            var matched = false
            for category in Self.tagCategories {
                if !tagSet.isDisjoint(with: category.tags) {
                    categoryCounts[category.label, default: 0] += 1
                    matched = true
                    break  // one category per photo
                }
            }

            // If no tag match but has faces, already counted above
            _ = matched
        }

        // Add face-based categories
        if selfieCount > 0 { categoryCounts["自拍", default: 0] += selfieCount }
        if groupCount > 0 { categoryCounts["合照", default: 0] += groupCount }

        // --- Build output ---
        let indexedRatio = Double(indexed.count) / Double(max(1, totalCount))

        // Need meaningful data to show content section
        guard !categoryCounts.isEmpty else { return [] }

        // Sort categories by count (descending), take top entries
        let sorted = categoryCounts.sorted { $0.value > $1.value }
        let topCategories = sorted.prefix(6)

        var lines: [String] = []
        lines.append("🏷️ **照片内容分析**:")

        // Bar chart visualization
        let maxCount = topCategories.first?.value ?? 1
        for (label, count) in topCategories {
            let emoji = Self.tagCategories.first { $0.label == label }?.emoji ?? "📷"
            let barLen = max(1, Int(Double(count) / Double(maxCount) * 8))
            let bar = String(repeating: "▓", count: barLen) + String(repeating: "░", count: max(0, 8 - barLen))
            let pct = indexed.count > 0 ? Int(Double(count) / Double(indexed.count) * 100) : 0
            lines.append("  \(emoji) \(label) [\(bar)] \(count)张（\(pct)%）")
        }

        // Top content insight
        if let top = topCategories.first, top.value >= 3 {
            let topEmoji = Self.tagCategories.first { $0.label == top.key }?.emoji ?? "📷"
            let personality = contentPersonality(topCategory: top.key, count: top.value, total: indexed.count)
            if !personality.isEmpty {
                lines.append("\n💡 \(personality)")
            }
        }

        // Coverage note if not all photos are indexed
        if indexedRatio < 0.8 && indexed.count < totalCount {
            let indexedPct = Int(indexedRatio * 100)
            lines.append("  ℹ️ 已索引 \(indexed.count)/\(totalCount) 张（\(indexedPct)%），在「设置」中可索引更多")
        }

        return lines
    }

    /// Generates a fun, personalized one-liner based on the dominant photo category.
    private func contentPersonality(topCategory: String, count: Int, total: Int) -> String {
        let pct = total > 0 ? Int(Double(count) / Double(total) * 100) : 0
        guard pct >= 25 else { return "" }

        switch topCategory {
        case "美食": return "这段时间你是个十足的美食记录者 🍽️"
        case "风景": return "风景照占比最高，你一直在用镜头捕捉美好"
        case "自拍": return "自拍最多，记录自己的每个精彩瞬间 ✨"
        case "合照": return "合照不少，看来这段时间社交很丰富"
        case "动物": return "萌宠出镜率最高，是个爱动物的人 🐱"
        case "海边": return "海边照片最多，是一段海风与阳光的记忆 🌊"
        case "天空": return "你总是抬头看天，捕捉天空的变化"
        case "花草": return "花花草草入镜最多，生活充满自然气息 🌿"
        case "建筑": return "建筑照片最多，对城市空间有独特的审美"
        case "城市": return "街头巷尾的城市记录者 📸"
        case "夜景": return "夜色中的光影猎手 🌃"
        case "雪景": return "冰天雪地里的探险家 ❄️"
        default: return ""
        }
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
            if let locationFromHistory = matchLocationFromHistory(query: lower, context: context) {
                resultPhotos = context.photoService.fetchNearby(
                    latitude: locationFromHistory.lat,
                    longitude: locationFromHistory.lon,
                    radiusMeters: 2000
                )
                searchDescription = "在「\(locationFromHistory.name)」附近"
            }
        }

        // --- Vision-based content search via CDPhotoIndex ---
        // Try Vision search when: (1) basic filters found nothing, or
        // (2) query contains content keywords (selfie, animals, food, scenes)
        //     that can't be answered by time/location alone.
        let hasContentKeywords = Self.contentKeywords.contains { lower.contains($0) }
        if resultPhotos.isEmpty || hasContentKeywords {
            let visionResult = searchViaVisionIndex(query: lower, context: context, timeRange: timeRange)
            if !visionResult.results.isEmpty {
                // Build description that includes time context when present
                let fullDescription: String
                if let range = timeRange, !visionResult.description.isEmpty {
                    fullDescription = "\(range.label)\(visionResult.description)"
                } else {
                    fullDescription = visionResult.description
                }
                return buildVisionSearchResults(
                    results: visionResult.results,
                    description: fullDescription,
                    query: query
                )
            }
        }

        // --- Build response ---
        if resultPhotos.isEmpty && searchDescription.isEmpty {
            if hasContentKeywords {
                // Content keyword present but no Vision index results — give a specific hint
                return "📷 没有找到匹配的照片。\n\n" +
                    "可能的原因：\n" +
                    "· 照片索引尚未建立 — 请在「设置」中触发照片索引\n" +
                    "· 该类型的照片确实不多\n\n" +
                    "💡 你也可以按时间或地点搜索，比如「上周拍的照片」或「在北京拍的照片」。"
            }
            return buildSearchHelpText(query: query)
        }

        if resultPhotos.isEmpty {
            var msg = "📷 没有找到\(searchDescription)的照片。\n\n"
            if hasContentKeywords {
                msg += "AI 内容搜索也没有找到匹配 — 可能需要先在「设置」中建立照片索引。\n"
            }
            msg += "试试调整时间范围或换个描述？"
            return msg
        }

        return buildSearchResults(photos: resultPhotos, description: searchDescription)
    }

    // MARK: - Vision Index Search

    /// Content keywords that should trigger Vision-based CDPhotoIndex search.
    private static let contentKeywords: [String] = [
        // People
        "自拍", "selfie", "合照", "合影", "group",
        "人", "人物", "face", "单人", "一个人",
        // Animals
        "猫", "cat", "狗", "dog", "动物", "animal", "宠物", "pet", "鸟", "bird",
        // Nature scenes
        "海边", "沙滩", "海滩", "beach", "大海", "海洋",
        "山", "mountain", "爬山", "登山",
        "雪", "snow", "滑雪",
        "日落", "sunset", "夕阳", "日出", "sunrise", "朝霞",
        "风景", "景色", "scenery", "landscape", "美景",
        "天空", "云", "sky", "cloud", "蓝天", "白云",
        "湖", "lake", "河", "river", "水",
        "树", "forest", "森林",
        // Urban scenes
        "夜景", "night", "夜色", "灯光",
        "建筑", "大楼", "building", "architecture",
        "城市", "city", "街", "street", "街拍",
        // Food & drink
        "食物", "美食", "吃", "food", "餐", "甜品", "蛋糕", "咖啡",
        // Flora & objects
        "花", "flower", "植物", "plant",
        "车", "car", "汽车",
        "户外", "outdoor", "室内", "indoor",
    ]

    private struct VisionSearchResult {
        let results: [PhotoSearchService.SearchResult]
        let description: String
    }

    /// Uses PhotoSearchService to query CDPhotoIndex (Vision-classified tags + face counts).
    /// When a timeRange is provided, the search is constrained to that date interval.
    private func searchViaVisionIndex(query: String, context: SkillContext, timeRange: QueryTimeRange? = nil) -> VisionSearchResult {
        let searchService = context.photoSearchService
        var photoQuery = searchService.parseQuery(query)

        // Apply time range constraint so "上周海边的照片" only searches last week
        if let range = timeRange {
            let interval = range.interval
            photoQuery.dateFrom = interval.start
            photoQuery.dateTo = interval.end
        }

        // Only proceed if the query parsed into something meaningful
        let hasMeaningfulQuery = !photoQuery.keywords.isEmpty
            || photoQuery.isSelfie == true
            || photoQuery.minFaces != nil
            || photoQuery.location != nil

        guard hasMeaningfulQuery else {
            return VisionSearchResult(results: [], description: "")
        }

        let results = searchService.search(query: photoQuery, limit: 30)

        // Build a human-readable description of what we searched for
        var descParts: [String] = []
        if photoQuery.isSelfie == true {
            descParts.append("自拍")
        } else if let min = photoQuery.minFaces, min >= 2 {
            descParts.append("合照")
        }
        if !photoQuery.keywords.isEmpty {
            let keywordLabel = buildKeywordLabel(photoQuery.keywords)
            if !keywordLabel.isEmpty { descParts.append(keywordLabel) }
        }
        if !photoQuery.locationName.isEmpty {
            descParts.append("在\(photoQuery.locationName)")
        }

        let description = descParts.isEmpty ? "相关" : descParts.joined(separator: "·")
        return VisionSearchResult(results: results, description: description)
    }

    /// Maps Vision tag keywords back to user-friendly Chinese labels.
    private func buildKeywordLabel(_ keywords: [String]) -> String {
        let mapping: [(tags: Set<String>, label: String)] = [
            (["cat", "animal", "kitten"], "猫咪"),
            (["dog", "animal", "puppy"], "狗狗"),
            (["bird", "animal"], "鸟"),
            (["animal"], "动物"),
            (["beach", "ocean", "sea", "coast"], "海边"),
            (["mountain", "hill", "hiking"], "山景"),
            (["snow", "winter", "skiing"], "雪景"),
            (["sunset", "sky"], "日落"),
            (["sunrise", "morning"], "日出"),
            (["landscape", "scenery", "nature"], "风景"),
            (["night", "light"], "夜景"),
            (["building", "architecture"], "建筑"),
            (["city", "street", "urban"], "城市"),
            (["sky", "cloud"], "天空"),
            (["lake", "river", "water"], "水景"),
            (["tree", "forest"], "树林"),
            (["food", "meal", "restaurant"], "美食"),
            (["flower", "plant", "garden"], "花草"),
            (["car", "vehicle"], "车辆"),
            (["outdoor"], "户外"),
            (["indoor"], "室内"),
        ]

        let kwSet = Set(keywords.map { $0.lowercased() })
        for entry in mapping {
            if !kwSet.isDisjoint(with: entry.tags) {
                return entry.label
            }
        }
        return ""
    }

    /// Formats Vision-based search results with tag info and relevance.
    private func buildVisionSearchResults(results: [PhotoSearchService.SearchResult],
                                          description: String,
                                          query: String) -> String {
        let df = DateFormatter()
        df.dateFormat = "M月d日 HH:mm"
        df.locale = Locale(identifier: "zh_CN")

        var lines = ["🔍 找到 **\(results.count) 张**\(description)的照片\n"]

        // Check if CDPhotoIndex has data at all — if very few, remind user to index
        let indexedCount = indexedPhotoCount(results: results)

        // Date range
        let dates = results.compactMap { $0.date }
        if let earliest = dates.min(), let latest = dates.max() {
            let dayDf = DateFormatter()
            dayDf.dateFormat = "M月d日"
            dayDf.locale = Locale(identifier: "zh_CN")
            let cal = Calendar.current
            if cal.isDate(earliest, inSameDayAs: latest) {
                lines.append("📅 拍摄于 \(dayDf.string(from: earliest))")
            } else {
                lines.append("📅 时间跨度: \(dayDf.string(from: earliest)) ~ \(dayDf.string(from: latest))")
            }
        }

        // Tag summary — show the most common tags across results
        let tagSummary = buildTagSummary(results: results)
        if !tagSummary.isEmpty {
            lines.append("🏷️ 识别标签: \(tagSummary)")
        }

        // Face info
        let withFaces = results.filter { $0.faceCount > 0 }
        if !withFaces.isEmpty {
            let maxFaces = withFaces.map { $0.faceCount }.max() ?? 0
            if maxFaces == 1 {
                lines.append("👤 单人照片为主")
            } else {
                lines.append("👥 最多 \(maxFaces) 人合照")
            }
        }

        // Location info
        let withLoc = results.filter { $0.latitude != 0 && $0.longitude != 0 }
        if !withLoc.isEmpty {
            lines.append("📍 \(withLoc.count) 张有位置信息")
        }

        // Show top results
        lines.append("\n**匹配度最高的照片**:")
        for result in results.prefix(8) {
            var parts: [String] = []
            if let date = result.date {
                parts.append(df.string(from: date))
            }
            if result.faceCount > 0 {
                parts.append("\(result.faceCount)人")
            }
            // Show top 2 readable tags
            let readableTags = result.tags.prefix(3)
                .filter { !$0.isEmpty }
                .joined(separator: "/")
            if !readableTags.isEmpty {
                parts.append("[\(readableTags)]")
            }
            let relevance = result.relevanceScore > 15 ? "⭐" : (result.relevanceScore > 5 ? "✓" : "")
            lines.append("  · \(parts.joined(separator: " "))\(relevance.isEmpty ? "" : " \(relevance)")")
        }

        if results.count > 8 {
            lines.append("  …还有 \(results.count - 8) 张匹配")
        }

        // Hint about indexing if results seem sparse
        lines.append("\n💡 搜索基于本地 AI 图像识别，在「设置」中可触发照片索引以覆盖更多照片。")

        return lines.joined(separator: "\n")
    }

    /// Summarizes the most common tags across search results.
    private func buildTagSummary(results: [PhotoSearchService.SearchResult]) -> String {
        var tagCounts: [String: Int] = [:]
        for result in results {
            for tag in result.tags where !tag.isEmpty {
                tagCounts[tag.lowercased(), default: 0] += 1
            }
        }
        let topTags = tagCounts.sorted { $0.value > $1.value }
            .prefix(5)
            .map { $0.key }
        return topTags.joined(separator: "、")
    }

    private func indexedPhotoCount(results: [PhotoSearchService.SearchResult]) -> Int {
        return results.count
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
        · 「找自拍照片」— 人脸识别搜索
        · 「海边的照片」— 场景搜索
        · 「风景照片」「夜景照片」— 场景类型
        · 「美食照片」「咖啡照片」— 内容分类
        · 「找猫的照片」「鸟的照片」— 物体识别
        · 「建筑照片」「街拍」— 城市场景

        💡 我可以根据时间、地点、内容和人脸帮你找到照片。
        需要先在「设置」中完成照片索引才能使用 AI 内容搜索。
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

    /// Groups photos by proximity into location clusters, using the user's
    /// own location history (CDLocationRecord) to resolve coordinates to real place names.
    private func buildLocationClusters(photos: [PhotoMetadataItem], context: SkillContext? = nil) -> [LocationCluster] {
        guard !photos.isEmpty else { return [] }

        // Load user's location history for cross-referencing
        let knownPlaces = loadKnownPlaces(from: context)

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

        // Convert to clusters, resolving names via location history → city lookup → coordinates
        var clusters = grid.values.map { entry in
            LocationCluster(
                name: resolveLocationName(lat: entry.lat, lon: entry.lon, knownPlaces: knownPlaces),
                count: entry.count,
                latitude: entry.lat,
                longitude: entry.lon
            )
        }
        clusters.sort { $0.count > $1.count }

        // Merge clusters that resolved to the same place name
        var merged: [String: LocationCluster] = [:]
        for cluster in clusters {
            if let existing = merged[cluster.name] {
                merged[cluster.name] = LocationCluster(
                    name: cluster.name,
                    count: existing.count + cluster.count,
                    latitude: existing.latitude,
                    longitude: existing.longitude
                )
            } else {
                merged[cluster.name] = cluster
            }
        }

        return merged.values.sorted { $0.count > $1.count }
    }

    // MARK: - Location Name Resolution

    /// A known place from the user's location history.
    private struct KnownPlace {
        let name: String
        let lat: Double
        let lon: Double
    }

    /// Loads the user's location history from CoreData for cross-referencing.
    private func loadKnownPlaces(from context: SkillContext?) -> [KnownPlace] {
        guard let ctx = context?.coreDataContext else { return [] }
        let request = CDLocationRecord.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        request.fetchLimit = 500

        guard let records = try? ctx.fetch(request) as? [CDLocationRecord] else { return [] }

        var seen = Set<String>()
        var places: [KnownPlace] = []
        for r in records {
            guard let name = r.placeName, !name.isEmpty,
                  r.latitude != 0, r.longitude != 0,
                  seen.insert(name).inserted else { continue }
            places.append(KnownPlace(name: name, lat: r.latitude, lon: r.longitude))
        }
        return places
    }

    /// Resolves a coordinate to a human-readable name using three strategies:
    /// 1. Match against user's own location records (best — personalized place names)
    /// 2. Match against known cities (good — recognizable city names)
    /// 3. Fall back to approximate coordinate description (last resort)
    private func resolveLocationName(lat: Double, lon: Double, knownPlaces: [KnownPlace]) -> String {
        // Strategy 1: Check user's own location history (within 2km)
        for place in knownPlaces {
            let distance = haversineDistance(lat1: lat, lon1: lon, lat2: place.lat, lon2: place.lon)
            if distance < 2000 {
                return place.name
            }
        }

        // Strategy 2: Check known cities (within city radius)
        if let city = matchCity(lat: lat, lon: lon) {
            return city
        }

        // Strategy 3: Approximate description
        return approximateRegion(lat: lat, lon: lon)
    }

    /// Haversine distance in meters between two coordinates.
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

    /// Matches coordinates against major cities.
    private func matchCity(lat: Double, lon: Double) -> String? {
        let cities: [(name: String, lat: Double, lon: Double, radius: Double)] = [
            ("北京", 39.90, 116.41, 60_000),
            ("上海", 31.23, 121.47, 50_000),
            ("广州", 23.13, 113.26, 40_000),
            ("深圳", 22.54, 114.06, 35_000),
            ("杭州", 30.27, 120.16, 35_000),
            ("成都", 30.57, 104.07, 35_000),
            ("南京", 32.06, 118.80, 35_000),
            ("武汉", 30.59, 114.31, 35_000),
            ("重庆", 29.56, 106.55, 35_000),
            ("西安", 34.34, 108.94, 35_000),
            ("苏州", 31.30, 120.59, 30_000),
            ("厦门", 24.48, 118.09, 25_000),
            ("青岛", 36.07, 120.38, 30_000),
            ("天津", 39.08, 117.20, 40_000),
            ("长沙", 28.23, 112.94, 30_000),
            ("郑州", 34.75, 113.65, 30_000),
            ("三亚", 18.25, 109.51, 25_000),
            ("昆明", 25.04, 102.71, 30_000),
            ("大连", 38.91, 121.60, 30_000),
            ("东京", 35.68, 139.65, 40_000),
            ("大阪", 34.69, 135.50, 35_000),
            ("首尔", 37.57, 126.98, 35_000),
            ("曼谷", 13.76, 100.50, 35_000),
            ("新加坡", 1.35, 103.82, 25_000),
            ("纽约", 40.71, -74.01, 40_000),
            ("旧金山", 37.77, -122.42, 35_000),
            ("洛杉矶", 34.05, -118.24, 50_000),
            ("巴黎", 48.86, 2.35, 30_000),
            ("伦敦", 51.51, -0.13, 35_000),
            ("悉尼", -33.87, 151.21, 35_000),
            ("香港", 22.32, 114.17, 20_000),
            ("台北", 25.03, 121.57, 25_000),
        ]

        for city in cities {
            let distance = haversineDistance(lat1: lat, lon1: lon, lat2: city.lat, lon2: city.lon)
            if distance < city.radius {
                return city.name
            }
        }
        return nil
    }

    /// Provides an approximate region description based on latitude/longitude.
    private func approximateRegion(lat: Double, lon: Double) -> String {
        // China mainland rough bounding box
        if lat >= 18 && lat <= 54 && lon >= 73 && lon <= 135 {
            // Approximate province-level region within China
            if lat > 39 && lon > 115 && lon < 118 { return "京津冀地区" }
            if lat > 30 && lat < 32 && lon > 120 && lon < 122 { return "长三角地区" }
            if lat > 22 && lat < 24 && lon > 112 && lon < 115 { return "珠三角地区" }
            if lat > 28 && lat < 32 && lon > 103 && lon < 108 { return "川渝地区" }
            return "中国"
        }
        // Japan
        if lat >= 30 && lat <= 46 && lon >= 129 && lon <= 146 { return "日本" }
        // Korea
        if lat >= 33 && lat <= 39 && lon >= 124 && lon <= 132 { return "韩国" }
        // Southeast Asia
        if lat >= -10 && lat <= 25 && lon >= 95 && lon <= 140 { return "东南亚" }
        // Europe
        if lat >= 35 && lat <= 71 && lon >= -10 && lon <= 40 { return "欧洲" }
        // North America
        if lat >= 25 && lat <= 50 && lon >= -130 && lon <= -65 { return "北美" }
        // Australia
        if lat >= -45 && lat <= -10 && lon >= 112 && lon <= 154 { return "澳大利亚" }

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

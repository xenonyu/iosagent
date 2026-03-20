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

        // Also fetch all media (including videos) for comprehensive stats
        let allMedia = context.photoService.fetchAllMedia(from: interval.start, to: interval.end)
        let videoItems = allMedia.filter { $0.isVideo }

        if photos.isEmpty && videoItems.isEmpty {
            return "📷 \(range.label)没有找到照片或视频。\n如果是有限访问权限，请在设置中选择更多照片，或者调整时间范围再试试。"
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

        // --- Media type breakdown ---
        // Count special types from the image set (screenshots, live photos, etc.)
        let mediaBreakdown = buildMediaBreakdown(photos: photos, videos: videoItems)
        if !mediaBreakdown.isEmpty {
            lines.append(mediaBreakdown)
        }

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

        // --- Photo events/moments timeline ---
        let events = detectPhotoEvents(photos: photos, context: context)
        if !events.isEmpty {
            let eventSection = buildEventTimeline(events: events, totalPhotos: photos.count)
            lines.append("")
            lines.append(contentsOf: eventSection)
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

    // MARK: - Media Type Breakdown

    /// Builds a compact media type summary line for photo stats view.
    /// Shows counts for screenshots, live photos, videos, panoramas, etc.
    private func buildMediaBreakdown(photos: [PhotoMetadataItem], videos: [PhotoMetadataItem]) -> String {
        var parts: [String] = []

        // Count special types from the image set
        var kindCounts: [PhotoMediaKind: Int] = [:]
        for photo in photos {
            if photo.mediaKind != .photo {
                kindCounts[photo.mediaKind, default: 0] += 1
            }
        }

        // Add video count
        if !videos.isEmpty {
            let totalDuration = videos.reduce(0.0) { $0 + $1.duration }
            let durationStr = totalDuration > 60
                ? "\(Int(totalDuration / 60))分钟"
                : "\(Int(totalDuration))秒"
            parts.append("🎬 \(videos.count)个视频（\(durationStr)）")
        }

        // Special image types (sorted by count, most frequent first)
        let orderedKinds: [PhotoMediaKind] = [.screenshot, .livePhoto, .depthEffect, .panorama, .hdr, .burst]
        for kind in orderedKinds {
            if let count = kindCounts[kind], count > 0 {
                parts.append("\(kind.emoji) \(count)\(kind.label == "截图" ? "张截图" : "张\(kind.label)")")
            }
        }

        guard !parts.isEmpty else { return "" }
        return parts.joined(separator: "  ")
    }

    // MARK: - Photo Event Detection

    /// A cluster of photos taken within a short time span, representing a life moment.
    private struct PhotoEvent {
        let photos: [PhotoMetadataItem]
        var startDate: Date { photos.first?.date ?? Date() }
        var endDate: Date { photos.last?.date ?? Date() }
        var count: Int { photos.count }
        var favorites: Int { photos.filter { $0.isFavorite }.count }
        var locationPhotos: [PhotoMetadataItem] { photos.filter { $0.hasLocation } }
        var locationName: String = ""

        /// Duration in minutes between first and last photo.
        var durationMinutes: Int {
            Int(endDate.timeIntervalSince(startDate) / 60)
        }
    }

    /// Clusters photos into events based on time proximity.
    /// Photos within `gapThreshold` (2 hours) of each other belong to the same event.
    /// Only events with 3+ photos are considered meaningful.
    private func detectPhotoEvents(photos: [PhotoMetadataItem], context: SkillContext? = nil) -> [PhotoEvent] {
        guard photos.count >= 3 else { return [] }

        let sorted = photos.sorted { $0.date < $1.date }
        let gapThreshold: TimeInterval = 2 * 3600 // 2 hours

        var events: [PhotoEvent] = []
        var currentCluster: [PhotoMetadataItem] = [sorted[0]]

        for i in 1..<sorted.count {
            let gap = sorted[i].date.timeIntervalSince(sorted[i - 1].date)
            if gap > gapThreshold {
                // End current cluster, start new one
                if currentCluster.count >= 3 {
                    events.append(PhotoEvent(photos: currentCluster))
                }
                currentCluster = [sorted[i]]
            } else {
                currentCluster.append(sorted[i])
            }
        }
        // Don't forget the last cluster
        if currentCluster.count >= 3 {
            events.append(PhotoEvent(photos: currentCluster))
        }

        // Resolve location names for events using the user's location history
        let knownPlaces = loadKnownPlaces(from: context)
        events = events.map { event in
            var e = event
            e.locationName = resolveEventLocation(event: event, knownPlaces: knownPlaces)
            return e
        }

        // Sort by photo count descending (most significant events first)
        events.sort { $0.count > $1.count }
        return events
    }

    /// Picks the best location name for a photo event by finding the most common
    /// location among its geotagged photos.
    private func resolveEventLocation(event: PhotoEvent, knownPlaces: [KnownPlace]) -> String {
        let locPhotos = event.locationPhotos
        guard !locPhotos.isEmpty else { return "" }

        // Use median photo's coordinates as representative location
        let midIdx = locPhotos.count / 2
        let representative = locPhotos.sorted { $0.date < $1.date }[midIdx]
        guard let lat = representative.latitude, let lon = representative.longitude else { return "" }

        return resolveLocationName(lat: lat, lon: lon, knownPlaces: knownPlaces)
    }

    /// Formats detected photo events into a narrative timeline section.
    private func buildEventTimeline(events: [PhotoEvent], totalPhotos: Int) -> [String] {
        // Don't show events section if photos are too evenly distributed (no clear moments)
        // or if there's only 1 event that covers all photos (no added value)
        if events.isEmpty { return [] }
        if events.count == 1 && events[0].count == totalPhotos { return [] }

        let cal = Calendar.current
        let dayDf = DateFormatter()
        dayDf.locale = Locale(identifier: "zh_CN")
        dayDf.dateFormat = "M月d日"

        let timeDf = DateFormatter()
        timeDf.locale = Locale(identifier: "zh_CN")
        timeDf.dateFormat = "HH:mm"

        var lines: [String] = ["📸 **生活瞬间**:"]

        let eventsInTimeOrder = events.prefix(6).sorted { $0.startDate < $1.startDate }

        for event in eventsInTimeOrder {
            var parts: [String] = []

            // Date + time of day
            let dayStr = dayDf.string(from: event.startDate)
            let period = timeOfDayLabel(hour: cal.component(.hour, from: event.startDate))
            parts.append("\(dayStr) \(period)")

            // Location if available
            if !event.locationName.isEmpty {
                parts.append("在\(event.locationName)")
            }

            // Photo count
            parts.append("拍了 \(event.count) 张")

            // Duration context — long events suggest trips/outings
            if event.durationMinutes >= 60 {
                let hours = event.durationMinutes / 60
                let mins = event.durationMinutes % 60
                if hours > 0 && mins > 0 {
                    parts.append("持续 \(hours)h\(mins)min")
                } else if hours > 0 {
                    parts.append("持续 \(hours) 小时")
                }
            }

            // Favorites hint
            if event.favorites > 0 {
                parts.append("❤️×\(event.favorites)")
            }

            // Guess the event type based on signals
            let eventHint = guessEventType(event: event)

            var line = "  · \(parts.joined(separator: "，"))"
            if !eventHint.isEmpty {
                line += "  \(eventHint)"
            }
            lines.append(line)
        }

        // Summary insight
        let eventPhotoTotal = events.prefix(6).reduce(0) { $0 + $1.count }
        let eventCoverage = Double(eventPhotoTotal) / Double(max(1, totalPhotos))
        if events.count >= 2 && eventCoverage > 0.6 {
            lines.append("\n💡 这段时间的照片集中在 \(events.count) 个时刻，你的记录很有节奏感")
        } else if events.count >= 3 {
            lines.append("\n💡 识别到 \(events.count) 个拍照时刻，生活挺丰富的")
        }

        return lines
    }

    /// Infers a likely event type from photo signals (count, duration, time, location).
    private func guessEventType(event: PhotoEvent) -> String {
        let cal = Calendar.current
        let hour = cal.component(.hour, from: event.startDate)
        let duration = event.durationMinutes
        let count = event.count
        let hasLocation = !event.locationName.isEmpty
        let isWeekend = {
            let wd = cal.component(.weekday, from: event.startDate)
            return wd == 1 || wd == 7
        }()

        // Long duration + many photos + location → trip/outing
        if duration > 180 && count >= 15 && hasLocation {
            return "🏖️ 可能是一次出游"
        }

        // Evening + moderate photos → dinner/gathering
        if hour >= 18 && hour <= 22 && count >= 5 && count <= 25 {
            return "🍽️ 可能是一次聚餐"
        }

        // Weekend + long duration + many photos → day trip
        if isWeekend && duration > 120 && count >= 10 {
            return "🚶 周末出行"
        }

        // Morning/afternoon + short burst → quick moment
        if duration < 30 && count >= 5 {
            return "📱 一段集中拍照"
        }

        // Many favorites → special moment
        if event.favorites >= 3 || (event.favorites > 0 && Double(event.favorites) / Double(count) > 0.3) {
            return "✨ 值得收藏的时刻"
        }

        return ""
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

        // --- Media type search (screenshots, videos, live photos, panoramas, etc.) ---
        if let mediaKind = detectMediaKind(in: lower) {
            let timeRange = extractTimeRange(from: lower)
            let interval = timeRange?.interval
            let items = context.photoService.fetchByMediaKind(
                mediaKind, from: interval?.start, to: interval?.end
            )
            return buildMediaTypeResults(
                items: items, kind: mediaKind,
                timeLabel: timeRange?.label, context: context
            )
        }

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

        return buildSearchResults(photos: resultPhotos, description: searchDescription, context: context)
    }

    // MARK: - Media Type Search

    /// Detects if the query is asking for a specific media type (screenshot, video, etc.).
    private func detectMediaKind(in text: String) -> PhotoMediaKind? {
        // Order: most specific first to avoid "照" in "截图" matching photo
        if containsAny(text, ["截图", "截屏", "screenshot", "屏幕截图", "屏幕快照"]) {
            return .screenshot
        }
        if containsAny(text, ["全景", "panorama", "全景照", "panoramic"]) {
            return .panorama
        }
        if containsAny(text, ["实况", "live photo", "livephoto", "动态照片"]) {
            return .livePhoto
        }
        if containsAny(text, ["人像", "portrait", "人像模式", "景深", "虚化", "depth"]) {
            return .depthEffect
        }
        if containsAny(text, ["连拍", "burst", "快拍"]) {
            return .burst
        }
        if containsAny(text, ["慢动作", "slo-mo", "slomo", "slow motion", "慢放"]) {
            return .sloMo
        }
        if containsAny(text, ["延时", "timelapse", "time-lapse", "延时摄影", "缩时"]) {
            return .timelapse
        }
        if containsAny(text, ["hdr"]) {
            return .hdr
        }
        // Video must be checked after sloMo/timelapse to avoid shadowing
        if containsAny(text, ["视频", "录像", "video", "影片", "录制", "拍的视频"]) {
            return .video
        }
        return nil
    }

    /// Builds a rich response for media-type-specific photo search results.
    private func buildMediaTypeResults(items: [PhotoMetadataItem], kind: PhotoMediaKind,
                                       timeLabel: String?, context: SkillContext) -> String {
        let kindLabel = kind.label
        let emoji = kind.emoji
        let timePart = timeLabel ?? ""

        if items.isEmpty {
            var msg = "\(emoji) \(timePart)没有找到\(kindLabel)。\n"
            switch kind {
            case .screenshot:
                msg += "试试扩大时间范围？比如「这个月的截图」。"
            case .video, .sloMo, .timelapse:
                msg += "试试「最近的视频」或「这个月拍的视频」。"
            case .livePhoto:
                msg += "实况照片需要在拍照时开启 Live Photo 功能。"
            case .panorama:
                msg += "全景照片需要使用相机的全景模式拍摄。"
            case .depthEffect:
                msg += "人像照片需要使用人像模式拍摄（支持的 iPhone 机型）。"
            default:
                msg += "试试调整时间范围再看看？"
            }
            return msg
        }

        let cal = Calendar.current
        let df = DateFormatter()
        df.dateFormat = "M月d日 HH:mm"
        df.locale = Locale(identifier: "zh_CN")
        let dayDf = DateFormatter()
        dayDf.dateFormat = "M月d日"
        dayDf.locale = Locale(identifier: "zh_CN")

        var lines = ["\(emoji) 找到 **\(items.count) \(items.count == 1 ? "个" : "个")**\(timePart)\(kindLabel)\n"]

        // --- Date range ---
        let sortedByDate = items.sorted { $0.date < $1.date }
        if let earliest = sortedByDate.first?.date, let latest = sortedByDate.last?.date {
            if cal.isDate(earliest, inSameDayAs: latest) {
                lines.append("📅 \(dayDf.string(from: earliest))")
            } else {
                lines.append("📅 \(dayDf.string(from: earliest)) ~ \(dayDf.string(from: latest))")
            }
        }

        // --- Video-specific stats ---
        if kind == .video || kind == .sloMo || kind == .timelapse {
            let totalSeconds = items.reduce(0.0) { $0 + $1.duration }
            let avgDuration = totalSeconds / Double(items.count)
            lines.append("⏱️ 总时长 \(formatDuration(totalSeconds))，平均 \(formatDuration(avgDuration))")

            let longest = items.max(by: { $0.duration < $1.duration })
            if let longest = longest, items.count > 1 {
                lines.append("🏆 最长: \(formatDuration(longest.duration))（\(df.string(from: longest.date))）")
            }
        }

        // --- Resolution stats for photos ---
        if !items.first!.isVideo && items.first!.pixelWidth > 0 {
            let maxRes = items.max(by: { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight })
            if let maxRes = maxRes, maxRes.pixelWidth > 0 {
                let mp = Double(maxRes.pixelWidth * maxRes.pixelHeight) / 1_000_000.0
                if kind == .panorama {
                    lines.append("📐 最大分辨率: \(maxRes.pixelWidth)×\(maxRes.pixelHeight)（\(String(format: "%.1f", mp))MP）")
                }
            }
        }

        // --- Favorites ---
        let favCount = items.filter { $0.isFavorite }.count
        if favCount > 0 {
            lines.append("❤️ 其中 \(favCount) 个已收藏")
        }

        // --- Location info ---
        let geoItems = items.filter { $0.hasLocation }
        if geoItems.count >= 2 {
            let clusters = buildLocationClusters(photos: geoItems, context: context)
            if !clusters.isEmpty {
                lines.append("\n📍 **拍摄地点**:")
                for cluster in clusters.prefix(5) {
                    lines.append("  · \(cluster.name)（\(cluster.count) 个）")
                }
            }
        } else if geoItems.count == 1 {
            let knownPlaces = loadKnownPlaces(from: context)
            if let lat = geoItems[0].latitude, let lon = geoItems[0].longitude {
                let name = resolveLocationName(lat: lat, lon: lon, knownPlaces: knownPlaces)
                lines.append("📍 拍摄于 \(name)")
            }
        }

        // --- Day distribution (when spanning multiple days) ---
        var dayCount: [Date: Int] = [:]
        items.forEach {
            let day = cal.startOfDay(for: $0.date)
            dayCount[day, default: 0] += 1
        }

        if dayCount.count >= 2 && dayCount.count <= 10 {
            let sortedDays = dayCount.sorted { $0.key < $1.key }
            let maxDayCount = sortedDays.map(\.value).max() ?? 1
            lines.append("\n📊 **逐日分布**:")
            for (day, count) in sortedDays {
                let barLen = max(1, Int(Double(count) / Double(maxDayCount) * 8))
                let bar = String(repeating: "▓", count: barLen) + String(repeating: "░", count: max(0, 8 - barLen))
                let weekday = cal.component(.weekday, from: day)
                let wdNames = ["", "日", "一", "二", "三", "四", "五", "六"]
                let wdStr = weekday < wdNames.count ? "周\(wdNames[weekday])" : ""
                lines.append("  \(dayDf.string(from: day))(\(wdStr)) [\(bar)] \(count)个")
            }
        }

        // --- Time-of-day pattern ---
        if items.count >= 5 {
            var periodCounts: [String: Int] = [:]
            for item in items {
                let hour = cal.component(.hour, from: item.date)
                let period = timeOfDayLabel(hour: hour)
                periodCounts[period, default: 0] += 1
            }
            if let peak = periodCounts.max(by: { $0.value < $1.value }) {
                let pct = Int(Double(peak.value) / Double(items.count) * 100)
                if pct >= 35 {
                    lines.append("⏰ 主要拍摄于\(peak.key)（\(pct)%）")
                }
            }
        }

        // --- Recent items list ---
        lines.append("\n**最近的\(kindLabel)**:")
        for item in items.prefix(6) {
            var parts: [String] = [df.string(from: item.date)]
            if item.isVideo {
                parts.append(formatDuration(item.duration))
            }
            if item.isFavorite { parts.append("❤️") }
            if item.hasLocation { parts.append("📍") }
            lines.append("  · \(parts.joined(separator: " "))")
        }
        if items.count > 6 {
            lines.append("  …还有 \(items.count - 6) 个")
        }

        // --- Kind-specific tips ---
        switch kind {
        case .screenshot:
            lines.append("\n💡 截图通常记录了重要信息。你也可以问「在北京拍的截图」按地点筛选。")
        case .video:
            lines.append("\n💡 你也可以问「慢动作视频」或「延时摄影」查看特定类型。")
        case .livePhoto:
            lines.append("\n💡 实况照片记录了拍摄前后 1.5 秒的动态瞬间。")
        case .depthEffect:
            lines.append("\n💡 人像模式照片支持后期调整背景虚化强度。")
        default:
            break
        }

        return lines.joined(separator: "\n")
    }

    /// Formats a time duration in seconds into a human-readable string.
    private func formatDuration(_ seconds: TimeInterval) -> String {
        let totalSec = Int(seconds)
        if totalSec < 60 {
            return "\(totalSec)秒"
        } else if totalSec < 3600 {
            let min = totalSec / 60
            let sec = totalSec % 60
            return sec > 0 ? "\(min)分\(sec)秒" : "\(min)分钟"
        } else {
            let hr = totalSec / 3600
            let min = (totalSec % 3600) / 60
            return min > 0 ? "\(hr)小时\(min)分" : "\(hr)小时"
        }
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
            // Show top readable tags, translated to Chinese
            let localizedTags = Self.localizeTags(Array(result.tags.prefix(3)))
            if !localizedTags.isEmpty {
                parts.append("[\(localizedTags.joined(separator: "/"))]")
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

    /// Summarizes the most common tags across search results, localized to Chinese.
    private func buildTagSummary(results: [PhotoSearchService.SearchResult]) -> String {
        // Count raw tags first, then localize for display
        var tagCounts: [String: Int] = [:]
        for result in results {
            for tag in result.tags where !tag.isEmpty {
                tagCounts[tag.lowercased(), default: 0] += 1
            }
        }
        // Localize and merge: "ocean"(5) + "sea"(3) both map to "大海" → 8
        var localizedCounts: [String: Int] = [:]
        for (tag, count) in tagCounts {
            let localized = Self.localizeTag(tag)
            localizedCounts[localized, default: 0] += count
        }
        let topTags = localizedCounts.sorted { $0.value > $1.value }
            .prefix(5)
            .map { $0.key }
        return topTags.joined(separator: "、")
    }

    private func indexedPhotoCount(results: [PhotoSearchService.SearchResult]) -> Int {
        return results.count
    }

    // MARK: - Search Results Formatting

    private func buildSearchResults(photos: [PhotoMetadataItem], description: String,
                                     context: SkillContext? = nil) -> String {
        let cal = Calendar.current
        let df = DateFormatter()
        df.dateFormat = "M月d日 HH:mm"
        df.locale = Locale(identifier: "zh_CN")
        let dayDf = DateFormatter()
        dayDf.dateFormat = "M月d日"
        dayDf.locale = Locale(identifier: "zh_CN")

        var lines = ["📷 找到 **\(photos.count) 张**\(description)的照片\n"]

        // Date range
        let sortedByDate = photos.sorted { $0.date < $1.date }
        if let earliest = sortedByDate.first?.date, let latest = sortedByDate.last?.date {
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

        // --- Time-of-day distribution (when results have enough data) ---
        if photos.count >= 5 {
            var periodCounts: [String: Int] = [:]
            for photo in photos {
                let hour = cal.component(.hour, from: photo.date)
                let period = timeOfDayLabel(hour: hour)
                periodCounts[period, default: 0] += 1
            }
            let sorted = periodCounts.sorted { $0.value > $1.value }
            if let peak = sorted.first, sorted.count >= 2 {
                let pct = Int(Double(peak.value) / Double(photos.count) * 100)
                if pct >= 35 {
                    lines.append("⏰ 主要拍摄于\(peak.key)（\(pct)%）")
                }
            }
        }

        // --- Day-by-day breakdown (when results span multiple days) ---
        var dayCount: [Date: Int] = [:]
        photos.forEach {
            let day = cal.startOfDay(for: $0.date)
            dayCount[day, default: 0] += 1
        }

        if dayCount.count >= 2 && dayCount.count <= 10 {
            let sortedDays = dayCount.sorted { $0.key < $1.key }
            let maxDayCount = sortedDays.map(\.value).max() ?? 1
            lines.append("\n📊 **逐日分布**:")
            for (day, count) in sortedDays {
                let barLen = max(1, Int(Double(count) / Double(maxDayCount) * 8))
                let bar = String(repeating: "▓", count: barLen) + String(repeating: "░", count: max(0, 8 - barLen))
                let weekday = cal.component(.weekday, from: day)
                let wdNames = ["", "日", "一", "二", "三", "四", "五", "六"]
                let wdStr = weekday < wdNames.count ? "周\(wdNames[weekday])" : ""
                lines.append("  \(dayDf.string(from: day))(\(wdStr)) [\(bar)] \(count)张")
            }
        } else if dayCount.count > 10 {
            // Too many days for full breakdown — show summary
            let activeDays = dayCount.count
            let avgPerDay = Double(photos.count) / Double(activeDays)
            if let mostActive = dayCount.max(by: { $0.value < $1.value }) {
                let dayFullDf = DateFormatter()
                dayFullDf.dateFormat = "M月d日（E）"
                dayFullDf.locale = Locale(identifier: "zh_CN")
                lines.append("\n📊 覆盖 \(activeDays) 天，平均每天 \(String(format: "%.1f", avgPerDay)) 张")
                lines.append("🏆 拍照最多: \(dayFullDf.string(from: mostActive.key))（\(mostActive.value) 张）")
            }
        }

        // --- Photo event/moment detection (reuse existing logic) ---
        if photos.count >= 6 {
            let events = detectPhotoEvents(photos: photos, context: context)
            if !events.isEmpty {
                let eventSection = buildEventTimeline(events: events, totalPhotos: photos.count)
                if !eventSection.isEmpty {
                    lines.append("")
                    lines.append(contentsOf: eventSection)
                }
            }
        }

        // --- Location clustering (when results have geotagged photos) ---
        let geoPhotos = photos.filter { $0.hasLocation }
        if geoPhotos.count >= 2 {
            let clusters = buildLocationClusters(photos: geoPhotos, context: context)
            if !clusters.isEmpty {
                lines.append("\n📍 **拍照地点**:")
                for cluster in clusters.prefix(5) {
                    lines.append("  · \(cluster.name)（\(cluster.count) 张）")
                }
                if geoPhotos.count < photos.count {
                    lines.append("  · 还有 \(photos.count - geoPhotos.count) 张没有位置信息")
                }
            }
        } else {
            let withLoc = geoPhotos.count
            if withLoc > 0 && withLoc < photos.count {
                lines.append("\n📍 \(withLoc) 张有位置信息")
            }
        }

        // --- Content analysis from Vision index (if context available) ---
        if let ctx = context, photos.count >= 3 {
            let dates = photos.map { $0.date }
            if let earliest = dates.min(), let latest = dates.max() {
                let interval = DateInterval(start: earliest, end: latest.addingTimeInterval(1))
                let contentSection = buildContentAnalysis(
                    photoIds: photos.map { $0.id },
                    interval: interval,
                    totalCount: photos.count,
                    context: ctx
                )
                if !contentSection.isEmpty {
                    lines.append("")
                    lines.append(contentsOf: contentSection)
                }
            }
        }

        // --- Recent photos list (compact, at the end) ---
        lines.append("\n**最近拍摄**:")
        for photo in photos.prefix(6) {
            let timeStr = df.string(from: photo.date)
            let fav = photo.isFavorite ? " ❤️" : ""
            let loc = photo.hasLocation ? " 📍" : ""
            lines.append("  · \(timeStr)\(fav)\(loc)")
        }

        if photos.count > 6 {
            lines.append("  …还有 \(photos.count - 6) 张")
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
        · 「找猫的照片」「鸟的照片」— 物体识别
        · 「最近的截图」— 按媒体类型搜索
        · 「这周的视频」— 视频搜索
        · 「全景照片」「实况照片」「人像照片」— 特殊拍摄模式

        💡 我可以根据时间、地点、内容、媒体类型和人脸帮你找到照片。
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
            // Countries (large radius covers the entire country for trip-level matching)
            (["日本", "japan"], 36.2048, 138.2529, "日本", 500_000),
            (["韩国", "korea"], 35.9078, 127.7669, "韩国", 300_000),
            (["泰国", "thailand"], 15.8700, 100.9925, "泰国", 500_000),
            (["越南", "vietnam"], 14.0583, 108.2772, "越南", 500_000),
            (["马来西亚", "malaysia"], 4.2105, 101.9758, "马来西亚", 500_000),
            (["印度尼西亚", "印尼", "indonesia", "巴厘岛", "bali"], -0.7893, 113.9213, "印尼", 1_000_000),
            (["美国", "america", "usa"], 37.0902, -95.7129, "美国", 2_000_000),
            (["法国", "france"], 46.2276, 2.2137, "法国", 500_000),
            (["英国", "uk", "britain"], 55.3781, -3.4360, "英国", 400_000),
            (["意大利", "italy", "罗马", "rome", "威尼斯", "venice", "米兰", "milan"], 41.8719, 12.5674, "意大利", 500_000),
            (["西班牙", "spain", "巴塞罗那", "barcelona", "马德里", "madrid"], 40.4637, -3.7492, "西班牙", 500_000),
            (["德国", "germany"], 51.1657, 10.4515, "德国", 400_000),
            (["澳大利亚", "australia", "墨尔本", "melbourne"], -25.2744, 133.7751, "澳大利亚", 1_500_000),
            (["新西兰", "new zealand"], -40.9006, 174.8860, "新西兰", 500_000),
            (["加拿大", "canada", "温哥华", "vancouver", "多伦多", "toronto"], 56.1304, -106.3468, "加拿大", 2_000_000),
            (["瑞士", "switzerland", "苏黎世", "zurich"], 46.8182, 8.2275, "瑞士", 200_000),
            (["土耳其", "turkey", "istanbul", "伊斯坦布尔"], 38.9637, 35.2433, "土耳其", 600_000),
            (["埃及", "egypt", "开罗", "cairo"], 26.8206, 30.8025, "埃及", 500_000),
            (["迪拜", "dubai"], 25.2048, 55.2708, "迪拜", 50_000),
            // China regions
            (["云南"], 25.0453, 101.7103, "云南", 200_000),
            (["海南"], 19.1959, 109.7453, "海南", 150_000),
            (["西藏", "拉萨", "tibet"], 29.6520, 91.1721, "西藏", 500_000),
            (["新疆", "乌鲁木齐"], 43.7930, 87.6271, "新疆", 800_000),
            (["四川", "九寨沟"], 30.5728, 104.0668, "四川", 300_000),
            (["广西", "桂林"], 25.2354, 110.1799, "广西", 200_000),
            (["长沙"], 28.2282, 112.9388, "长沙", 40_000),
            (["哈尔滨", "冰城"], 45.8038, 126.5350, "哈尔滨", 40_000),
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

    /// Delegates to SkillRouter's full time parser which handles:
    /// 前天/大前天/大后天, specific weekdays (周一/下周三), relative days (最近3天/5天前),
    /// 上上周, and all standard ranges — instead of the previous 6-keyword subset.
    private func extractTimeRange(from text: String) -> QueryTimeRange? {
        guard SkillRouter.hasExplicitTimeReference(text) else { return nil }
        return SkillRouter.extractTimeRange(from: text)
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

    // MARK: - Vision Tag Localization

    /// Maps raw English Vision Framework tags to user-friendly Chinese labels.
    /// Tags not in the dictionary are returned as-is (already Chinese or unknown).
    private static let tagLocalization: [String: String] = [
        // People
        "person": "人物", "people": "人物", "face": "人脸", "portrait": "人像",
        "selfie": "自拍", "group": "合影", "crowd": "人群", "baby": "婴儿", "child": "小孩",
        // Animals
        "cat": "猫", "kitten": "小猫", "dog": "狗", "puppy": "小狗",
        "bird": "鸟", "fish": "鱼", "animal": "动物", "pet": "宠物",
        "horse": "马", "rabbit": "兔子", "insect": "昆虫", "butterfly": "蝴蝶",
        // Nature & Scenery
        "landscape": "风景", "scenery": "风景", "nature": "自然",
        "mountain": "山", "hill": "山丘", "valley": "山谷",
        "beach": "海滩", "ocean": "大海", "sea": "大海", "coast": "海岸", "wave": "海浪",
        "lake": "湖", "river": "河流", "water": "水", "waterfall": "瀑布",
        "sky": "天空", "cloud": "云", "sunset": "日落", "sunrise": "日出",
        "tree": "树", "forest": "森林", "flower": "花", "plant": "植物", "garden": "花园",
        "field": "田野", "grass": "草地", "park": "公园",
        "snow": "雪", "winter": "冬景", "ice": "冰", "skiing": "滑雪",
        "rain": "雨", "fog": "雾",
        // Urban & Architecture
        "building": "建筑", "architecture": "建筑", "house": "房屋", "tower": "塔",
        "bridge": "桥", "church": "教堂", "temple": "寺庙", "castle": "城堡",
        "city": "城市", "street": "街道", "urban": "城市", "road": "道路", "traffic": "交通",
        "night": "夜景", "light": "灯光", "neon": "霓虹",
        // Food & Drink
        "food": "美食", "meal": "餐食", "restaurant": "餐厅", "dish": "菜品",
        "dessert": "甜品", "cake": "蛋糕", "coffee": "咖啡", "drink": "饮品", "fruit": "水果",
        "bread": "面包", "wine": "酒", "tea": "茶",
        // Transport
        "car": "汽车", "vehicle": "车辆", "bus": "公交", "train": "火车",
        "airplane": "飞机", "boat": "船", "bicycle": "自行车", "motorcycle": "摩托车",
        // Indoor / Outdoor
        "indoor": "室内", "room": "房间", "interior": "室内",
        "outdoor": "户外", "hiking": "徒步", "camping": "露营",
        // Activities & Objects
        "sport": "运动", "gym": "健身", "swimming": "游泳", "running": "跑步",
        "book": "书", "screen": "屏幕", "text": "文字", "sign": "标牌",
        "art": "艺术", "painting": "画作", "music": "音乐",
        "toy": "玩具", "gift": "礼物", "clothing": "服装", "hat": "帽子",
    ]

    /// Translates a single Vision tag to Chinese. Returns the original if no mapping exists
    /// and the tag is already non-ASCII (likely Chinese), otherwise returns the English tag
    /// with parenthetical hint.
    private static func localizeTag(_ tag: String) -> String {
        let key = tag.lowercased().trimmingCharacters(in: .whitespaces)
        if let localized = tagLocalization[key] {
            return localized
        }
        // If the tag already contains CJK characters, keep it as-is
        if key.unicodeScalars.contains(where: { $0.value >= 0x4E00 && $0.value <= 0x9FFF }) {
            return tag
        }
        return tag
    }

    /// Translates an array of Vision tags to Chinese, removing duplicates that map
    /// to the same Chinese label (e.g. "ocean" and "sea" both → "大海").
    private static func localizeTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in tags where !tag.isEmpty {
            let localized = localizeTag(tag)
            if !seen.contains(localized) {
                seen.insert(localized)
                result.append(localized)
            }
        }
        return result
    }
}

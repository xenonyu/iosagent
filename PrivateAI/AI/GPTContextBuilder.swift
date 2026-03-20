import Foundation
import CoreData

/// Assembles a rich context prompt from all local iOS data sources for RawGPTService.
/// Replaces ClawEngine — no local routing, just structured data context building.
final class GPTContextBuilder {

    private let coreDataContext: NSManagedObjectContext
    private let healthService: HealthService
    private let calendarService: CalendarService
    private let photoService: PhotoMetadataService
    private let locationService: LocationService
    private let photoSearchService: PhotoSearchService
    private var profile: UserProfileData

    init(context: NSManagedObjectContext,
         healthService: HealthService,
         calendarService: CalendarService,
         photoService: PhotoMetadataService,
         locationService: LocationService,
         profile: UserProfileData) {
        self.coreDataContext = context
        self.healthService = healthService
        self.calendarService = calendarService
        self.photoService = photoService
        self.locationService = locationService
        self.photoSearchService = PhotoSearchService(context: context)
        self.profile = profile
    }

    func updateProfile(_ newProfile: UserProfileData) {
        self.profile = newProfile
    }

    // MARK: - Build Prompt

    /// Gathers all local data in parallel then assembles a structured prompt.
    func buildPrompt(userQuery: String,
                     conversationHistory: [ChatMessage],
                     completion: @escaping (String) -> Void) {
        let group = DispatchGroup()
        var todayHealth = HealthSummary()
        var weeklyHealth: [HealthSummary] = []

        group.enter()
        healthService.fetchDailySummary(for: Date()) { summary in
            todayHealth = summary
            group.leave()
        }

        group.enter()
        healthService.fetchSummaries(days: 7) { summaries in
            weeklyHealth = summaries
            group.leave()
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }

            let now = Date()
            let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now
            let sevenDaysAhead = Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now

            let todayEvents = self.calendarService.todayEvents()
            let upcomingEvents = self.calendarService.fetchEvents(from: now, to: sevenDaysAhead)
            let recentPhotos = self.photoService.fetchAllMedia(from: sevenDaysAgo, to: now)
            let locationRecords = CDLocationRecord.fetchRecent(days: 7, in: self.coreDataContext)
            let lifeEvents = CDLifeEvent.fetchRecent(limit: 15, in: self.coreDataContext)

            // Run photo search when query looks photo-related so GPT can describe results
            let photoResults = self.searchPhotosIfNeeded(query: userQuery)

            let prompt = self.assemble(
                userQuery: userQuery,
                conversationHistory: conversationHistory,
                todayHealth: todayHealth,
                weeklyHealth: weeklyHealth,
                todayEvents: todayEvents,
                upcomingEvents: upcomingEvents,
                recentPhotos: recentPhotos,
                locationRecords: locationRecords,
                lifeEvents: lifeEvents,
                photoSearchResults: photoResults
            )
            completion(prompt)
        }
    }

    // MARK: - Assemble

    private func assemble(userQuery: String,
                          conversationHistory: [ChatMessage],
                          todayHealth: HealthSummary,
                          weeklyHealth: [HealthSummary],
                          todayEvents: [CalendarEventItem],
                          upcomingEvents: [CalendarEventItem],
                          recentPhotos: [PhotoMetadataItem],
                          locationRecords: [CDLocationRecord],
                          lifeEvents: [CDLifeEvent],
                          photoSearchResults: [PhotoSearchService.SearchResult] = []) -> String {
        var parts: [String] = []

        // SYSTEM
        let now = Date()
        let dateFmt = DateFormatter()
        dateFmt.locale = Locale(identifier: "zh_CN")
        dateFmt.dateFormat = "yyyy年M月d日 EEEE HH:mm"
        let weekday = dateFmt.string(from: now)

        // Build data availability summary so GPT knows what's available at a glance
        var availableData: [String] = []
        var unavailableData: [String] = []
        if todayHealth.steps > 0 || todayHealth.exerciseMinutes > 0 || todayHealth.sleepHours > 0 || todayHealth.heartRate > 0 {
            availableData.append("健康数据")
        } else {
            unavailableData.append("健康数据（未授权或未同步）")
        }
        if !todayEvents.isEmpty || !upcomingEvents.isEmpty {
            availableData.append("日历日程")
        } else {
            unavailableData.append("日历日程（无日程或未授权）")
        }
        if !locationRecords.isEmpty {
            availableData.append("位置记录")
        } else {
            unavailableData.append("位置记录（暂无记录或未授权）")
        }
        if !recentPhotos.isEmpty {
            availableData.append("照片统计")
        } else {
            unavailableData.append("照片统计（暂无照片或未授权）")
        }
        if !lifeEvents.isEmpty {
            availableData.append("生活记录")
        } else {
            unavailableData.append("生活记录（暂无记录）")
        }

        let availSummary = availableData.isEmpty ? "无" : availableData.joined(separator: "、")
        let unavailSummary = unavailableData.isEmpty ? "" : "\n不可用：\(unavailableData.joined(separator: "、"))"

        parts.append("""
        [SYSTEM]
        你是 iosclaw，运行在用户 iPhone 上的私人 AI 助理。你可以读取用户的健康、位置、日历、照片、生活记录等本地数据。
        当前时间：\(weekday)
        可用数据源：\(availSummary)\(unavailSummary)

        能力边界：
        - 你只能读取数据，不能创建、修改或保存任何记录。如果用户想记录事情，告诉他可以在 App 的生活记录页面手动添加。
        - 你不能发送消息、设置闹钟、打电话等操作类任务。

        回复要求：
        - 用自然、友好、简洁的中文回答。如果用户用英文提问，用英文回答。
        - 引用具体数据时，必须使用下方提供的真实数据，不要编造任何数字。
        - 如果某项数据为 0 或为空，坦诚说明「暂无该数据」或「尚未授权」，不要猜测。
        - 回答健康、运动相关问题时，优先引用准确数值，再给出简短解读或鼓励。
        - 涉及多天数据时，可引用「近7天趋势」进行对比分析，指出趋势变化。
        - 不要重复罗列所有数据，只回答用户问到的内容。
        - 回答要有温度感，像一个了解用户的私人助手，不是冰冷的数据报表。
        """)

        // USER PROFILE
        var profileParts: [String] = []
        if !profile.name.isEmpty { profileParts.append("名字：\(profile.name)") }
        if let bd = profile.birthday {
            let age = Calendar.current.dateComponents([.year], from: bd, to: Date()).year ?? 0
            if age > 0 { profileParts.append("\(age)岁") }
        }
        if !profile.occupation.isEmpty { profileParts.append("职业：\(profile.occupation)") }
        if !profile.interests.isEmpty { profileParts.append("兴趣：\(profile.interests.joined(separator: "、"))") }
        if !profileParts.isEmpty {
            parts.append("[用户信息]\n\(profileParts.joined(separator: "，"))")
        }

        // TODAY'S HEALTH
        parts.append(healthSection(todayHealth))

        // 7-DAY HEALTH TREND
        if weeklyHealth.count >= 3 {
            parts.append(trendSection(weeklyHealth))
        }

        // CALENDAR
        parts.append(calendarSection(todayEvents: todayEvents, upcoming: upcomingEvents))

        // LOCATION
        if !locationRecords.isEmpty {
            parts.append(locationSection(locationRecords))
        }

        // PHOTO STATS
        if !recentPhotos.isEmpty {
            parts.append(photoSection(recentPhotos))
        }

        // PHOTO SEARCH RESULTS (when user asks about specific photos)
        if !photoSearchResults.isEmpty {
            parts.append(photoSearchSection(photoSearchResults))
        }

        // LIFE EVENTS
        if !lifeEvents.isEmpty {
            parts.append(lifeEventsSection(lifeEvents))
        }

        // CONVERSATION HISTORY (truncated to save tokens)
        if !conversationHistory.isEmpty {
            let historyLines = conversationHistory.suffix(6).map { msg in
                let prefix = msg.isUser ? "用户：" : "助理："
                let content = msg.content
                // Truncate long assistant replies to save tokens
                let truncated = content.count > 150 ? String(content.prefix(150)) + "…" : content
                return prefix + truncated
            }
            parts.append("[对话历史]\n" + historyLines.joined(separator: "\n"))
        }

        // CURRENT QUESTION
        parts.append("[当前问题]\n用户说：\(userQuery)")

        return parts.joined(separator: "\n\n")
    }

    // MARK: - Section Builders

    private func healthSection(_ h: HealthSummary) -> String {
        var lines = ["[今日健康数据]"]

        if h.steps > 0 {
            var line = "步数：\(Int(h.steps))步"
            if h.distanceKm > 0 { line += "，距离：\(String(format: "%.1f", h.distanceKm))km" }
            lines.append(line)
        }
        if h.exerciseMinutes > 0 {
            var line = "运动时间：\(Int(h.exerciseMinutes))分钟"
            if h.activeCalories > 0 { line += "，活动卡路里：\(Int(h.activeCalories))kcal" }
            lines.append(line)
        }
        if h.heartRate > 0 {
            var line = "心率：均值\(Int(h.heartRate))bpm"
            if h.restingHeartRate > 0 { line += "，静息\(Int(h.restingHeartRate))bpm" }
            if h.hrv > 0 { line += "，HRV \(Int(h.hrv))ms" }
            lines.append(line)
        }
        if h.oxygenSaturation > 0 { lines.append("血氧：\(Int(h.oxygenSaturation))%") }
        if h.vo2Max > 0 { lines.append("VO2 Max：\(String(format: "%.1f", h.vo2Max)) ml/kg·min") }
        if h.bodyMassKg > 0 { lines.append("体重：\(String(format: "%.1f", h.bodyMassKg))kg") }
        if h.sleepHours > 0 {
            var line = "睡眠：\(String(format: "%.1f", h.sleepHours))小时"
            var phases: [String] = []
            if h.sleepDeepHours > 0 { phases.append("深睡\(String(format: "%.1f", h.sleepDeepHours))h") }
            if h.sleepREMHours > 0 { phases.append("REM \(String(format: "%.1f", h.sleepREMHours))h") }
            if h.sleepCoreHours > 0 { phases.append("浅睡\(String(format: "%.1f", h.sleepCoreHours))h") }
            if !phases.isEmpty { line += "（\(phases.joined(separator: "，"))）" }
            if let onset = h.sleepOnset, let wake = h.wakeTime {
                let fmt = DateFormatter(); fmt.dateFormat = "HH:mm"
                line += "，入睡\(fmt.string(from: onset))，起床\(fmt.string(from: wake))"
            }
            lines.append(line)
        }
        if !h.workouts.isEmpty {
            let wLines = h.workouts.prefix(5).map { w in
                let name = workoutName(w.activityType)
                let dur = Int(w.duration / 60)
                var s = "\(name) \(dur)分钟"
                if w.totalCalories > 0 { s += " \(Int(w.totalCalories))kcal" }
                if w.totalDistance > 10 { s += " \(String(format: "%.1f", w.totalDistance / 1000))km" }
                return s
            }
            lines.append("今日运动：" + wLines.joined(separator: "；"))
        }

        if lines.count == 1 { lines.append("（今日暂无健康数据，可能尚未授权 HealthKit 或数据未同步）") }
        return lines.joined(separator: "\n")
    }

    private func trendSection(_ summaries: [HealthSummary]) -> String {
        let fmt = DateFormatter(); fmt.dateFormat = "M/d"
        let cal = Calendar.current
        var lines = ["[近7天健康趋势]", "日期  | 步数  | 运动(分) | 睡眠(h) | 心率(bpm)"]
        for s in summaries.prefix(7) {
            let dateLabel = cal.isDateInToday(s.date) ? "\(fmt.string(from: s.date))(今天)" : fmt.string(from: s.date)
            let steps = s.steps > 0 ? "\(Int(s.steps))" : "-"
            let ex = s.exerciseMinutes > 0 ? "\(Int(s.exerciseMinutes))" : "-"
            let sl = s.sleepHours > 0 ? String(format: "%.1f", s.sleepHours) : "-"
            let hr = s.heartRate > 0 ? "\(Int(s.heartRate))" : "-"
            lines.append("\(dateLabel)  | \(steps)  | \(ex)  | \(sl)  | \(hr)")
        }
        // Add weekly averages for quick reference
        let validStepsDays = summaries.prefix(7).filter { $0.steps > 0 }
        let validSleepDays = summaries.prefix(7).filter { $0.sleepHours > 0 }
        let validExDays = summaries.prefix(7).filter { $0.exerciseMinutes > 0 }
        var avgParts: [String] = []
        if !validStepsDays.isEmpty {
            let avg = validStepsDays.map(\.steps).reduce(0, +) / Double(validStepsDays.count)
            avgParts.append("日均步数\(Int(avg))")
        }
        if !validExDays.isEmpty {
            let avg = validExDays.map(\.exerciseMinutes).reduce(0, +) / Double(validExDays.count)
            avgParts.append("日均运动\(Int(avg))分钟")
        }
        if !validSleepDays.isEmpty {
            let avg = validSleepDays.map(\.sleepHours).reduce(0, +) / Double(validSleepDays.count)
            avgParts.append("日均睡眠\(String(format: "%.1f", avg))h")
        }
        if !avgParts.isEmpty {
            lines.append("周均值：\(avgParts.joined(separator: "，"))")
        }
        return lines.joined(separator: "\n")
    }

    private func calendarSection(todayEvents: [CalendarEventItem], upcoming: [CalendarEventItem]) -> String {
        var lines = ["[日历日程]"]
        if todayEvents.isEmpty {
            lines.append("今天：无日程")
        } else {
            lines.append("今天：")
            for e in todayEvents.prefix(10) {
                var line = "  \(e.timeDisplay) \(e.title)"
                if !e.location.isEmpty { line += "（\(e.location)）" }
                if let label = e.attendeeLabel { line += " \(label)" }
                lines.append(line)
            }
        }
        let cal = Calendar.current
        let futureEvents = upcoming.filter { !cal.isDateInToday($0.startDate) }.prefix(10)
        if !futureEvents.isEmpty {
            lines.append("近期：")
            let df = DateFormatter(); df.dateFormat = "M月d日"
            let timeFmt = DateFormatter(); timeFmt.dateFormat = "HH:mm"
            for e in futureEvents {
                let dateStr = df.string(from: e.startDate)
                let timeStr = e.isAllDay ? "全天" : "\(timeFmt.string(from: e.startDate))–\(timeFmt.string(from: e.endDate))"
                var line = "  \(dateStr) \(timeStr) \(e.title)"
                if !e.location.isEmpty { line += "（\(e.location)）" }
                if let label = e.attendeeLabel { line += " \(label)" }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    private func locationSection(_ records: [CDLocationRecord]) -> String {
        var counts: [String: Int] = [:]
        var latest: [String: Date] = [:]
        for r in records {
            let name = (r.placeName?.isEmpty == false ? r.placeName : r.address) ?? "未知地点"
            counts[name, default: 0] += 1
            if let ts = r.timestamp, (latest[name] == nil || ts > latest[name]!) {
                latest[name] = ts
            }
        }
        let sorted = counts.sorted { $0.value > $1.value }.prefix(10)
        let fmt = DateFormatter(); fmt.dateFormat = "M月d日 HH:mm"
        var lines = ["[位置记录（近7天）]"]
        for (name, count) in sorted {
            var line = "\(name)（\(count)次）"
            if let ts = latest[name] { line += " 最近到访：\(fmt.string(from: ts))" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private func photoSection(_ photos: [PhotoMetadataItem]) -> String {
        let total = photos.count
        let videos = photos.filter { $0.isVideo }.count
        let geoTagged = photos.filter { $0.hasLocation }.count
        let favorites = photos.filter { $0.isFavorite }.count
        let screenshots = photos.filter { $0.isScreenshot }.count
        var lines = ["[照片统计（近7天）]"]
        lines.append("共 \(total - videos) 张照片，\(videos) 个视频")
        if geoTagged > 0 { lines.append("含地理位置：\(geoTagged) 张") }
        if favorites > 0 { lines.append("已收藏：\(favorites) 张") }
        if screenshots > 0 { lines.append("截图：\(screenshots) 张") }
        return lines.joined(separator: "\n")
    }

    private func lifeEventsSection(_ events: [CDLifeEvent]) -> String {
        let fmt = DateFormatter(); fmt.dateFormat = "M月d日"
        var lines = ["[生活记录（近期）]"]
        for e in events.prefix(15) {
            let mood = MoodType(rawValue: e.mood ?? "") ?? .neutral
            let date = e.timestamp.map { fmt.string(from: $0) } ?? ""
            var line = "\(mood.emoji) \(e.title ?? "记录")"
            if !date.isEmpty { line += "（\(date)）" }
            if let content = e.content, !content.isEmpty {
                line += "：\(content.prefix(60))"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Photo Search

    /// Detects photo-related queries and runs a local photo search.
    private func searchPhotosIfNeeded(query: String) -> [PhotoSearchService.SearchResult] {
        let lower = query.lowercased()
        let photoKeywords = [
            "找照片", "搜照片", "找图片", "搜图片", "找找照片", "照片搜索",
            "帮我找", "给我找", "搜一下", "找一下",
            "find photo", "search photo", "show me photo",
            "的照片", "的图片", "的相片",
            "photo of", "picture of",
            "拍的", "拍了", "拍过"
        ]
        guard photoKeywords.contains(where: { lower.contains($0) }) else { return [] }

        let parsed = photoSearchService.parseQuery(query)
        // Only search if we have meaningful criteria (keywords or location)
        guard !parsed.keywords.isEmpty || parsed.location != nil || parsed.isSelfie == true else { return [] }
        return photoSearchService.search(query: parsed, limit: 20)
    }

    private func photoSearchSection(_ results: [PhotoSearchService.SearchResult]) -> String {
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "M月d日"
        let total = results.count
        let withLocation = results.filter { $0.latitude != 0 }.count

        var lines = ["[照片搜索结果]"]
        lines.append("找到 \(total) 张匹配的照片" + (total >= 20 ? "（显示前20张）" : ""))

        // Date range of results
        let dates = results.compactMap { $0.date }
        if let earliest = dates.min(), let latest = dates.max() {
            if Calendar.current.isDate(earliest, inSameDayAs: latest) {
                lines.append("拍摄日期：\(dateFmt.string(from: earliest))")
            } else {
                lines.append("拍摄日期范围：\(dateFmt.string(from: earliest)) ~ \(dateFmt.string(from: latest))")
            }
        }

        if withLocation > 0 {
            lines.append("含地理位置：\(withLocation) 张")
        }

        // Top tags across all results for context
        var tagCounts: [String: Int] = [:]
        for r in results {
            for tag in r.tags where !tag.isEmpty {
                tagCounts[tag, default: 0] += 1
            }
        }
        let topTags = tagCounts.sorted { $0.value > $1.value }.prefix(8).map { $0.key }
        if !topTags.isEmpty {
            lines.append("主要标签：\(topTags.joined(separator: "、"))")
        }

        // Brief per-photo details (first 5)
        if results.count <= 5 {
            lines.append("详情：")
            for (i, r) in results.enumerated() {
                var detail = "  \(i + 1). "
                if let d = r.date { detail += "\(dateFmt.string(from: d)) " }
                if !r.tags.prefix(3).isEmpty { detail += "[\(r.tags.prefix(3).joined(separator: ","))]" }
                if r.faceCount > 0 { detail += " \(r.faceCount)人" }
                lines.append(detail)
            }
        }

        lines.append("提示：照片已在 App 界面以图片网格展示给用户，你只需用文字描述搜索结果概况。")
        return lines.joined(separator: "\n")
    }

    // MARK: - Workout Name

    private func workoutName(_ rawValue: UInt) -> String {
        switch rawValue {
        case 1:  return "🏃 跑步"
        case 2:  return "🚶 步行"
        case 13: return "🚴 骑行"
        case 20: return "⚽️ 足球"
        case 25: return "🏋️ HIIT"
        case 37: return "🏊 游泳"
        case 46: return "🧘 瑜伽"
        case 50: return "💪 力量训练"
        case 52: return "🚶 健走"
        case 60: return "🧘 冥想"
        case 74: return "🏃 椭圆机"
        case 75: return "🚴 动感单车"
        case 82: return "🤸 功能性训练"
        case 83: return "🏃 跑步机"
        default: return "🏅 运动"
        }
    }
}

// MARK: - CoreData Fetch Helpers

private extension CDLocationRecord {
    static func fetchRecent(days: Int, in context: NSManagedObjectContext) -> [CDLocationRecord] {
        let req = NSFetchRequest<CDLocationRecord>(entityName: "CDLocationRecord")
        let from = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        req.predicate = NSPredicate(format: "timestamp >= %@", from as NSDate)
        req.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        req.fetchLimit = 200
        return (try? context.fetch(req)) ?? []
    }
}

private extension CDLifeEvent {
    static func fetchRecent(limit: Int, in context: NSManagedObjectContext) -> [CDLifeEvent] {
        let req = NSFetchRequest<CDLifeEvent>(entityName: "CDLifeEvent")
        req.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        req.fetchLimit = limit
        return (try? context.fetch(req)) ?? []
    }
}

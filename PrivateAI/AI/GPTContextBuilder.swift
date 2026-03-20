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

            let prompt = self.assemble(
                userQuery: userQuery,
                conversationHistory: conversationHistory,
                todayHealth: todayHealth,
                weeklyHealth: weeklyHealth,
                todayEvents: todayEvents,
                upcomingEvents: upcomingEvents,
                recentPhotos: recentPhotos,
                locationRecords: locationRecords,
                lifeEvents: lifeEvents
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
                          lifeEvents: [CDLifeEvent]) -> String {
        var parts: [String] = []

        // SYSTEM
        let now = Date()
        let dateFmt = DateFormatter()
        dateFmt.locale = Locale(identifier: "zh_CN")
        dateFmt.dateFormat = "yyyy年M月d日 EEEE HH:mm"
        let weekday = dateFmt.string(from: now)

        parts.append("""
        [SYSTEM]
        你是 iosclaw，运行在用户 iPhone 上的私人 AI 助理。你可以访问用户的健康、位置、日历、照片、生活记录等本地数据。
        当前时间：\(weekday)

        回复要求：
        - 用自然、友好、简洁的中文回答。如果用户用英文提问，用英文回答。
        - 引用具体数据时，必须使用下方提供的真实数据，不要编造任何数字。
        - 如果某项数据为 0 或为空，坦诚说明「暂无该数据」或「尚未授权」，不要猜测。
        - 回答健康、运动相关问题时，优先引用准确数值，再给出简短解读。
        - 涉及多天数据时，可引用「近7天趋势」表格进行对比分析。
        - 不要重复罗列所有数据，只回答用户问到的内容。
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

        // LIFE EVENTS
        if !lifeEvents.isEmpty {
            parts.append(lifeEventsSection(lifeEvents))
        }

        // CONVERSATION HISTORY
        if !conversationHistory.isEmpty {
            let historyLines = conversationHistory.suffix(10).map { msg in
                (msg.isUser ? "用户：" : "助理：") + msg.content
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

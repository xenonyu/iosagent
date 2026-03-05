import Foundation
import CoreData

/// The local AI reasoning engine.
/// Queries CoreData + HealthKit to build a context-rich answer.
/// No network calls. No external AI API. All logic on-device.
final class LocalAIEngine {

    private let context: NSManagedObjectContext
    private let healthService: HealthService
    private let calendarService: CalendarService
    private let photoService: PhotoMetadataService
    private let profile: UserProfileData
    private let contextMemory: ContextMemory?

    init(context: NSManagedObjectContext,
         healthService: HealthService,
         calendarService: CalendarService,
         photoService: PhotoMetadataService,
         profile: UserProfileData,
         contextMemory: ContextMemory? = nil) {
        self.context = context
        self.healthService = healthService
        self.calendarService = calendarService
        self.photoService = photoService
        self.profile = profile
        self.contextMemory = contextMemory
    }

    // MARK: - Main Entry Point

    func respond(to query: String,
                 preResolvedIntent: QueryIntent? = nil,
                 completion: @escaping (String) -> Void) {
        let intent = preResolvedIntent ?? IntentParser.parse(query)

        switch intent {
        case .exercise(let range):
            respondExercise(range: range, completion: completion)

        case .location(let range):
            respondLocation(range: range, completion: completion)

        case .mood(let range):
            respondMood(range: range, completion: completion)

        case .recommendation(let topic):
            completion(respondRecommendation(topic: topic))

        case .summary(let range):
            respondSummary(range: range, completion: completion)

        case .events(let range):
            respondEvents(range: range, completion: completion)

        case .health(let metric, let range):
            respondHealth(metric: metric, range: range, completion: completion)

        case .calendar(let range):
            completion(respondCalendar(range: range))

        case .photos(let range):
            completion(respondPhotos(range: range))

        case .profile:
            completion(respondProfile())

        case .addEvent(let title, let content, let mood):
            saveAndConfirmEvent(title: title, content: content, mood: mood, completion: completion)

        case .unknown:
            completion(respondUnknown(query: query))
        }
    }

    // MARK: - Exercise

    private func respondExercise(range: QueryTimeRange, completion: @escaping (String) -> Void) {
        let interval = range.interval
        let events = CDLifeEvent.fetch(from: interval.start, to: interval.end, in: context)
            .filter { $0.category == .health }

        healthService.fetchWeeklySummaries { summaries in
            let filtered = summaries.filter {
                interval.contains($0.date)
            }

            var lines: [String] = []
            lines.append("🏃 \(range.label)的运动记录：\n")

            if filtered.isEmpty && events.isEmpty {
                lines.append("暂无运动记录。建议开启健康权限获取更详细数据。")
                completion(lines.joined(separator: "\n"))
                return
            }

            // Health data
            let totalSteps = filtered.reduce(0) { $0 + $1.steps }
            let totalExercise = filtered.reduce(0) { $0 + $1.exerciseMinutes }
            let totalCalories = filtered.reduce(0) { $0 + $1.activeCalories }

            if totalSteps > 0 {
                lines.append("👟 总步数：\(Int(totalSteps).formatted()) 步")
            }
            if totalExercise > 0 {
                lines.append("⏱ 运动时长：\(Int(totalExercise)) 分钟")
            }
            if totalCalories > 0 {
                lines.append("🔥 消耗热量：\(Int(totalCalories)) 千卡")
            }

            // Life events
            if !events.isEmpty {
                lines.append("\n📝 相关记录：")
                events.prefix(5).forEach {
                    lines.append("• \($0.timestamp.shortDisplay)：\($0.title)")
                }
            }

            completion(lines.joined(separator: "\n"))
        }
    }

    // MARK: - Location

    private func respondLocation(range: QueryTimeRange, completion: @escaping (String) -> Void) {
        let interval = range.interval
        let records = CDLocationRecord.fetch(from: interval.start, to: interval.end, in: context)

        if records.isEmpty {
            completion("📍 \(range.label)暂无位置记录。\n请确认已开启位置权限，并且在设置中允许后台定位。")
            return
        }

        // Group by place name
        var placeCount: [String: Int] = [:]
        for r in records {
            let key = r.displayName
            placeCount[key, default: 0] += 1
        }

        var lines: [String] = ["📍 \(range.label)去过的地方：\n"]
        let sorted = placeCount.sorted { $0.value > $1.value }
        sorted.prefix(8).forEach { name, count in
            let times = count > 1 ? "（\(count)次）" : ""
            lines.append("• \(name)\(times)")
        }

        if records.count > 8 {
            lines.append("\n共记录了 \(records.count) 个位置点")
        }

        completion(lines.joined(separator: "\n"))
    }

    // MARK: - Mood

    private func respondMood(range: QueryTimeRange, completion: @escaping (String) -> Void) {
        let interval = range.interval
        let events = CDLifeEvent.fetch(from: interval.start, to: interval.end, in: context)

        if events.isEmpty {
            completion("😊 \(range.label)暂无心情记录。\n通过对话告诉我你今天的心情，我会帮你记录下来！")
            return
        }

        // Count moods
        var moodCount: [MoodType: Int] = [:]
        events.forEach { moodCount[$0.mood, default: 0] += 1 }

        let dominant = moodCount.max(by: { $0.value < $1.value })?.key ?? .neutral

        var lines: [String] = ["💭 \(range.label)的心情状态：\n"]
        lines.append("\(dominant.emoji) 主要状态：\(dominant.label)\n")

        MoodType.allCases.forEach { mood in
            if let count = moodCount[mood], count > 0 {
                let bar = String(repeating: "▓", count: min(count, 10))
                lines.append("\(mood.emoji) \(mood.label) \(bar) \(count)次")
            }
        }

        // Show recent mood events
        let moodEvents = events.prefix(3)
        if !moodEvents.isEmpty {
            lines.append("\n最近记录：")
            moodEvents.forEach {
                lines.append("• \($0.timestamp.shortDisplay) \($0.mood.emoji) \($0.title)")
            }
        }

        completion(lines.joined(separator: "\n"))
    }

    // MARK: - Summary

    private func respondSummary(range: QueryTimeRange, completion: @escaping (String) -> Void) {
        let interval = range.interval
        let events = CDLifeEvent.fetch(from: interval.start, to: interval.end, in: context)
        let locations = CDLocationRecord.fetch(from: interval.start, to: interval.end, in: context)

        healthService.fetchWeeklySummaries { summaries in
            var lines: [String] = ["📋 \(range.label)的生活总结：\n"]

            // Events summary
            if !events.isEmpty {
                let byCategory = Dictionary(grouping: events, by: { $0.category })
                lines.append("📌 生活事件（共 \(events.count) 条）")
                byCategory.forEach { cat, evts in
                    lines.append("  \(cat.label)：\(evts.count) 条")
                }
            }

            // Location summary
            if !locations.isEmpty {
                let uniquePlaces = Set(locations.map { $0.displayName }).count
                lines.append("\n📍 去过 \(uniquePlaces) 个地点，共记录 \(locations.count) 次")
            }

            // Health summary
            let totalSteps = summaries.reduce(0) { $0 + $1.steps }
            let totalExercise = summaries.reduce(0) { $0 + $1.exerciseMinutes }
            if totalSteps > 0 || totalExercise > 0 {
                lines.append("\n🏃 健康数据：")
                if totalSteps > 0 { lines.append("  步数：\(Int(totalSteps).formatted()) 步") }
                if totalExercise > 0 { lines.append("  运动：\(Int(totalExercise)) 分钟") }
            }

            // Mood summary
            let moods = events.map { $0.mood }
            if !moods.isEmpty {
                let dominant = Dictionary(grouping: moods, by: { $0 })
                    .max(by: { $0.value.count < $1.value.count })?.key ?? .neutral
                lines.append("\n\(dominant.emoji) 整体心情：\(dominant.label)")
            }

            if events.isEmpty && locations.isEmpty {
                lines.append("暂无足够的数据生成总结。\n请多与我互动，我会帮你记录生活点滴！")
            }

            completion(lines.joined(separator: "\n"))
        }
    }

    // MARK: - Events

    private func respondEvents(range: QueryTimeRange, completion: @escaping (String) -> Void) {
        let interval = range.interval
        let events = CDLifeEvent.fetch(from: interval.start, to: interval.end, in: context)

        if events.isEmpty {
            completion("📝 \(range.label)暂无记录的事件。\n可以告诉我你做了什么，比如：「今天去健身了，感觉很好」")
            return
        }

        var lines: [String] = ["📝 \(range.label)的事件记录（共 \(events.count) 条）：\n"]
        events.prefix(10).forEach { event in
            lines.append("\(event.mood.emoji) \(event.timestamp.shortDisplay)")
            lines.append("  \(event.title)")
        }

        if events.count > 10 {
            lines.append("\n…还有 \(events.count - 10) 条记录")
        }

        completion(lines.joined(separator: "\n"))
    }

    // MARK: - Health

    private func respondHealth(metric: String, range: QueryTimeRange, completion: @escaping (String) -> Void) {
        healthService.fetchWeeklySummaries { summaries in
            let interval = range.interval
            let filtered = summaries.filter { interval.contains($0.date) }

            guard !filtered.isEmpty else {
                completion("📊 暂无健康数据。\n请在设置中开启健康权限以获取详细数据。")
                return
            }

            switch metric {
            case "sleep":
                let total = filtered.reduce(0) { $0 + $1.sleepHours }
                let avg = total / Double(filtered.count)
                completion("😴 \(range.label)平均睡眠：\(String(format: "%.1f", avg)) 小时\n建议保持 7-8 小时睡眠。")

            case "heartRate":
                let avg = filtered.compactMap { $0.heartRate > 0 ? $0.heartRate : nil }
                    .reduce(0, +) / Double(max(filtered.count, 1))
                let display = avg > 0 ? "\(Int(avg)) BPM" : "暂无数据"
                completion("❤️ \(range.label)平均心率：\(display)")

            case "steps":
                let total = filtered.reduce(0) { $0 + $1.steps }
                let avg = total / Double(max(filtered.count, 1))
                completion("👟 \(range.label)总步数：\(Int(total).formatted()) 步\n日均：\(Int(avg).formatted()) 步")

            default:
                let total = filtered.reduce(0) { $0 + $1.steps }
                let exercise = filtered.reduce(0) { $0 + $1.exerciseMinutes }
                let sleep = filtered.reduce(0) { $0 + $1.sleepHours } / Double(max(filtered.count, 1))
                completion("📊 \(range.label)健康概览：\n👟 \(Int(total).formatted()) 步\n⏱ \(Int(exercise)) 分钟运动\n😴 均睡 \(String(format: "%.1f", sleep)) 小时")
            }
        }
    }

    // MARK: - Recommendation

    private func respondRecommendation(topic: String) -> String {
        switch topic {
        case "gift_wife":
            return buildGiftResponse(for: "老婆", defaults: [
                "💐 鲜花或精品护肤套装（了解她常用品牌）",
                "💍 定制首饰，刻上特别日期或名字",
                "📖 她喜欢的书籍或课程订阅",
                "🍽 预约一家她一直想去的餐厅",
                "✈️ 一次她一直想去的小旅行",
                "🛁 高品质浴室套装，让她放松一下",
                "💆‍♀️ 专业 SPA 或按摩体验"
            ])

        case "gift_husband":
            return buildGiftResponse(for: "老公", defaults: [
                "⌚ 他一直想要的手表或电子产品",
                "🎮 游戏或他感兴趣的装备",
                "👔 质感好的衬衫或西装",
                "🍺 精酿啤酒或威士忌套装",
                "🎯 他的兴趣爱好相关装备",
                "📚 专业书籍或在线课程",
                "🍳 高端厨具（如果他爱做饭）"
            ])

        case "gift_mother":
            return buildGiftResponse(for: "妈妈", defaults: [
                "💐 高档鲜花礼盒",
                "🧴 适合中年女性的护肤品",
                "👗 舒适时尚的衣物",
                "🎶 健康理疗仪器（颈椎按摩仪等）",
                "🍵 好茶叶套装",
                "📱 教她用好手机的实用课程",
                "🍽 一起吃一顿好饭"
            ])

        default:
            return "🎁 送礼建议：\n\n最好的礼物是了解对方真正需要什么。\n\n可以告诉我更多信息：\n• 对方的兴趣爱好\n• 预算范围\n• 场合/原因\n\n我会给你更精准的建议！"
        }
    }

    private func buildGiftResponse(for person: String, defaults: [String]) -> String {
        var lines = ["🎁 送\(person)礼物建议：\n"]

        // Personalize based on saved family info
        let familyMember = profile.familyMembers.first {
            person.contains("老婆") || person.contains("妻") ? $0.relation.contains("妻") || $0.relation.contains("老婆") : false
        }
        if let member = familyMember, !member.notes.isEmpty {
            lines.append("💡 根据你的记录，她 \(member.notes)\n")
        }

        lines.append(contentsOf: defaults.map { "• \($0)" })
        lines.append("\n💬 告诉我更多她的喜好，我可以给出更个性化的建议！")
        return lines.joined(separator: "\n")
    }

    // MARK: - Profile

    private func respondProfile() -> String {
        guard !profile.name.isEmpty else {
            return "👤 您还没有填写个人信息。\n前往「我」页面完善您的资料，让我更了解您！"
        }

        var lines = ["👤 您的个人信息：\n"]
        lines.append("姓名：\(profile.name)")

        if let bd = profile.birthday {
            let age = Calendar.current.dateComponents([.year], from: bd, to: Date()).year ?? 0
            lines.append("年龄：\(age) 岁")
        }

        if !profile.occupation.isEmpty {
            lines.append("职业：\(profile.occupation)")
        }

        if !profile.interests.isEmpty {
            lines.append("兴趣：\(profile.interests.joined(separator: "、"))")
        }

        if !profile.familyMembers.isEmpty {
            lines.append("\n家人：")
            profile.familyMembers.forEach {
                lines.append("• \($0.relation)：\($0.name)")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Save Event

    private func saveAndConfirmEvent(title: String, content: String, mood: MoodType, completion: @escaping (String) -> Void) {
        let event = LifeEvent(
            title: title,
            content: content,
            mood: mood,
            category: .life
        )

        context.perform {
            CDLifeEvent.create(from: event, context: self.context)
            try? self.context.save()

            DispatchQueue.main.async {
                completion("✅ 已记录！\n\n\(mood.emoji) \(title)\n\n我会帮你记住这个时刻。你可以随时问我「最近记录了什么」来回顾。")
            }
        }
    }

    // MARK: - Calendar

    private func respondCalendar(range: QueryTimeRange) -> String {
        let interval = range.interval
        let events = calendarService.fetchEvents(from: interval.start, to: interval.end)

        if events.isEmpty {
            return "📅 \(range.label)的日历里没有事件。\n请确认已开启日历权限，或者前往日历 App 添加行程。"
        }

        var lines = ["📅 \(range.label)的日程（共 \(events.count) 个）：\n"]
        let fmt = DateFormatter()
        fmt.dateFormat = "M月d日"

        let grouped = Dictionary(grouping: events) { fmt.string(from: $0.startDate) }
        grouped.keys.sorted().prefix(7).forEach { dateStr in
            lines.append("📌 \(dateStr)")
            grouped[dateStr]?.forEach { event in
                lines.append("  • \(event.timeDisplay) \(event.title)")
                if !event.location.isEmpty { lines.append("    📍 \(event.location)") }
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Photos

    private func respondPhotos(range: QueryTimeRange) -> String {
        let interval = range.interval
        let photos = photoService.fetchMetadata(from: interval.start, to: interval.end)

        if photos.isEmpty {
            return "📷 \(range.label)没有照片记录。\n请确认已开启相册权限。"
        }

        let withLocation = photos.filter { $0.hasLocation }.count
        let favorites = photos.filter { $0.isFavorite }.count

        // Group by day
        let cal = Calendar.current
        var dayCount: [Date: Int] = [:]
        photos.forEach {
            let day = cal.startOfDay(for: $0.date)
            dayCount[day, default: 0] += 1
        }
        let mostActiveDay = dayCount.max(by: { $0.value < $1.value })

        var lines = ["📷 \(range.label)的照片活动：\n"]
        lines.append("总计拍了 \(photos.count) 张照片")
        if withLocation > 0 { lines.append("📍 其中 \(withLocation) 张有位置信息") }
        if favorites > 0 { lines.append("❤️ 标记了 \(favorites) 张收藏") }

        if let (day, count) = mostActiveDay {
            let df = DateFormatter()
            df.dateFormat = "M月d日"
            lines.append("\n🏆 最活跃的一天：\(df.string(from: day))（\(count) 张）")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Unknown

    private func respondUnknown(query: String) -> String {
        // Check context memory for hints
        var contextHint = ""
        if let hint = contextMemory?.buildContextHint() {
            contextHint = "\n\n（基于近期话题：\(hint)）"
        }

        let suggestions = [
            "• 「我上周做了什么运动？」",
            "• 「最近去过哪些地方？」",
            "• 「帮我总结这个月的生活」",
            "• 「给老婆推荐礼物」",
            "• 「我今天的日历行程」",
            "• 「最近拍了多少照片」",
            "• 「今天跑步了5公里，感觉很棒」（记录事件）"
        ]
        return "🤔 我理解你在问：「\(query)」\(contextHint)\n\n我目前最擅长回答：\n\n\(suggestions.joined(separator: "\n"))\n\n或者直接告诉我你做了什么，我会帮你记录下来！"
    }
}

// MARK: - Date Helpers

private extension Date {
    var shortDisplay: String {
        let fmt = DateFormatter()
        let cal = Calendar.current
        if cal.isDateInToday(self) {
            fmt.dateFormat = "今天 HH:mm"
        } else if cal.isDateInYesterday(self) {
            fmt.dateFormat = "昨天 HH:mm"
        } else {
            fmt.dateFormat = "M月d日"
        }
        return fmt.string(from: self)
    }
}

private extension DateInterval {
    func contains(_ date: Date) -> Bool {
        date >= start && date <= end
    }
}

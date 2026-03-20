import Foundation

/// Handles saving new life events to CoreData with smart auto-categorization.
/// Detects event category (work/health/social/travel/learning/life) and enriches
/// the confirmation with contextual feedback.
struct RecordSkill: ClawSkill {

    let id = "record"

    func canHandle(intent: QueryIntent) -> Bool {
        if case .addEvent = intent { return true }
        return false
    }

    func execute(intent: QueryIntent, context: SkillContext, completion: @escaping (String) -> Void) {
        guard case .addEvent(let title, let content, let mood) = intent else { return }

        let category = detectCategory(from: content)
        let tags = extractTags(from: content, category: category)
        let event = LifeEvent(title: title, content: content, mood: mood, category: category, tags: tags)
        let ctx = context.coreDataContext

        ctx.perform {
            CDLifeEvent.create(from: event, context: ctx)
            try? ctx.save()

            // Count recent events for context
            let cal = Calendar.current
            let weekStart = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())) ?? Date()
            let recentEvents = CDLifeEvent.fetch(from: weekStart, to: Date(), in: ctx)
            let weekCount = recentEvents.count

            DispatchQueue.main.async {
                let response = self.buildConfirmation(
                    title: title, mood: mood, category: category,
                    tags: tags, weekCount: weekCount
                )
                completion(response)
            }
        }
    }

    // MARK: - Category Detection

    /// Detects the most appropriate EventCategory from the event content.
    /// Uses keyword matching with priority ordering to handle overlapping contexts.
    private func detectCategory(from text: String) -> EventCategory {
        let lower = text.lowercased()

        // Work: meetings, projects, tasks, deadlines, presentations
        let workKeywords = ["工作", "上班", "开会", "会议", "项目", "汇报", "报告", "加班",
                            "deadline", "提交", "完成了", "发布", "上线", "代码", "review",
                            "同事", "领导", "客户", "甲方", "需求", "任务", "述职", "面试",
                            "办公", "出差", "PPT", "ppt", "方案", "策划", "排期",
                            "work", "meeting", "project", "office", "presentation",
                            "晋升", "升职", "调岗", "入职", "离职", "offer", "薪资"]

        // Health: exercise, medical, wellness
        let healthKeywords = ["跑步", "跑了", "运动", "健身", "锻炼", "游泳", "瑜伽", "骑车",
                              "打球", "爬山", "散步", "走路", "徒步", "跳绳", "举铁", "撸铁",
                              "看病", "医院", "体检", "吃药", "头疼", "感冒", "发烧",
                              "公里", "配速", "心率", "卡路里",
                              "篮球", "足球", "羽毛球", "网球", "乒乓球", "滑雪", "攀岩",
                              "gym", "run", "swim", "workout", "exercise", "yoga",
                              "减肥", "减重", "早睡", "早起", "戒糖"]

        // Social: friends, family, dining, gatherings
        let socialKeywords = ["朋友", "聚餐", "聚会", "吃饭", "约饭", "聚了", "见面",
                              "party", "社交", "约会", "相亲", "告白",
                              "家人", "父母", "爸妈", "爸爸", "妈妈", "老婆", "老公",
                              "女朋友", "男朋友", "对象", "女友", "男友",
                              "孩子", "宝宝", "儿子", "女儿", "哥哥", "姐姐", "弟弟", "妹妹",
                              "闺蜜", "兄弟", "同学", "老友",
                              "生日", "婚礼", "毕业", "团建",
                              "friend", "family", "dinner", "date", "reunion"]

        // Travel: trips, places, transport
        let travelKeywords = ["旅行", "旅游", "出发", "到达", "飞机", "火车", "高铁",
                              "机场", "车站", "酒店", "民宿", "景点", "打卡",
                              "去了", "到了", "回来了", "回了",
                              "上海", "北京", "广州", "深圳", "成都", "杭州", "重庆",
                              "日本", "韩国", "泰国", "美国", "欧洲",
                              "自驾", "露营", "爬山", "海边", "沙滩",
                              "travel", "trip", "flight", "hotel", "vacation", "road trip"]

        // Learning: study, courses, skills, reading
        let learningKeywords = ["学习", "学了", "学会", "上课", "课程", "培训", "考试",
                                "看书", "读书", "读了", "看了一本", "读完",
                                "编程", "写代码", "练习", "练了", "刷题",
                                "新技能", "技术", "教程", "视频教程",
                                "英语", "日语", "法语", "德语", "语言",
                                "认证", "证书", "备考", "复习", "笔记",
                                "study", "learn", "course", "book", "read",
                                "分享会", "讲座", "workshop", "线上课"]

        // Score each category — higher score wins
        // Priority matters for overlap: "和同事出差" has both work + travel keywords
        let scores: [(EventCategory, Int)] = [
            (.work, countMatches(lower, keywords: workKeywords)),
            (.health, countMatches(lower, keywords: healthKeywords)),
            (.social, countMatches(lower, keywords: socialKeywords)),
            (.travel, countMatches(lower, keywords: travelKeywords)),
            (.learning, countMatches(lower, keywords: learningKeywords))
        ]

        // Find the highest-scoring category
        if let best = scores.max(by: { $0.1 < $1.1 }), best.1 > 0 {
            return best.0
        }

        // Default: general life event
        return .life
    }

    /// Counts how many keywords from the list appear in the text.
    private func countMatches(_ text: String, keywords: [String]) -> Int {
        keywords.reduce(0) { $0 + (text.contains($1.lowercased()) ? 1 : 0) }
    }

    // MARK: - Tag Extraction

    /// Extracts relevant tags based on detected category and content keywords.
    private func extractTags(from text: String, category: EventCategory) -> [String] {
        let lower = text.lowercased()
        var tags: [String] = []

        switch category {
        case .health:
            let sports: [(String, [String])] = [
                ("跑步", ["跑步", "跑了", "run"]),
                ("游泳", ["游泳", "swim"]),
                ("瑜伽", ["瑜伽", "yoga"]),
                ("骑行", ["骑车", "骑行", "cycling"]),
                ("健身", ["健身", "举铁", "撸铁", "gym"]),
                ("球类", ["打球", "篮球", "足球", "羽毛球", "网球", "乒乓球"]),
                ("户外", ["爬山", "徒步", "hiking", "攀岩", "滑雪"])
            ]
            for (tag, keywords) in sports {
                if keywords.contains(where: { lower.contains($0) }) {
                    tags.append(tag)
                }
            }
        case .social:
            if containsAny(lower, ["家人", "父母", "爸", "妈", "老婆", "老公", "孩子", "宝宝",
                                    "儿子", "女儿", "哥", "姐", "弟", "妹"]) {
                tags.append("家人")
            }
            if containsAny(lower, ["朋友", "闺蜜", "兄弟", "同学", "老友"]) {
                tags.append("朋友")
            }
            if containsAny(lower, ["同事", "领导", "团建"]) {
                tags.append("同事")
            }
        case .work:
            if containsAny(lower, ["开会", "会议", "meeting"]) { tags.append("会议") }
            if containsAny(lower, ["加班", "overtime"]) { tags.append("加班") }
            if containsAny(lower, ["完成", "发布", "上线", "提交"]) { tags.append("成就") }
        case .travel:
            if containsAny(lower, ["飞机", "机场", "flight"]) { tags.append("飞行") }
            if containsAny(lower, ["自驾", "开车"]) { tags.append("自驾") }
        case .learning:
            if containsAny(lower, ["看书", "读书", "读了", "读完", "book"]) { tags.append("阅读") }
            if containsAny(lower, ["编程", "代码", "coding"]) { tags.append("编程") }
        case .life:
            break
        }

        return tags
    }

    private func containsAny(_ text: String, _ keywords: [String]) -> Bool {
        keywords.contains { text.contains($0) }
    }

    // MARK: - Confirmation Response

    /// Builds a rich confirmation message with category context and weekly stats.
    private func buildConfirmation(title: String, mood: MoodType, category: EventCategory,
                                   tags: [String], weekCount: Int) -> String {
        var lines: [String] = []

        // Category-aware header
        let catEmoji = categoryEmoji(category)
        lines.append("✅ 已记录！")
        lines.append("")
        lines.append("\(mood.emoji) \(title)")

        // Show detected category (skip for generic .life to avoid noise)
        if category != .life {
            var catLine = "\(catEmoji) 分类：\(category.label)"
            if !tags.isEmpty {
                catLine += "（\(tags.joined(separator: "·"))）"
            }
            lines.append(catLine)
        }

        // Weekly context
        lines.append("")
        if weekCount <= 1 {
            lines.append("📝 这是你本周的第一条记录，继续保持！")
        } else {
            lines.append("📝 本周已记录 \(weekCount) 条。")
        }

        // Category-specific encouragement
        switch category {
        case .health:
            lines.append("💪 坚持运动的你很棒！问我「运动打卡」可以查看连续记录。")
        case .work:
            lines.append("📋 工作辛苦了！问我「这周总结」可以看看这周的整体情况。")
        case .social:
            lines.append("🤝 社交让生活更有温度。问我「最近记录了什么」可以回顾。")
        case .travel:
            lines.append("✈️ 旅途愉快！问我「去过哪些地方」可以查看你的足迹。")
        case .learning:
            lines.append("📖 持续学习的你很棒！问我「最近记录了什么」可以回顾。")
        case .life:
            lines.append("我会帮你记住这个时刻。问我「最近记录了什么」可以随时回顾。")
        }

        return lines.joined(separator: "\n")
    }

    /// Returns a representative emoji for each event category.
    private func categoryEmoji(_ category: EventCategory) -> String {
        switch category {
        case .work:     return "💼"
        case .health:   return "🏃"
        case .social:   return "🤝"
        case .travel:   return "✈️"
        case .learning: return "📖"
        case .life:     return "📝"
        }
    }
}

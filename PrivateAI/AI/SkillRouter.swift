import Foundation

// MARK: - Query Intent

enum QueryIntent {
    case exercise(range: QueryTimeRange)
    case location(range: QueryTimeRange)
    case mood(range: QueryTimeRange)
    case recommendation(topic: String)
    case summary(range: QueryTimeRange)
    case events(range: QueryTimeRange)
    case health(metric: String, range: QueryTimeRange)
    case calendar(range: QueryTimeRange)
    case photos(range: QueryTimeRange)
    case profile
    case addEvent(title: String, content: String, mood: MoodType)
    case streak
    case weeklyInsight
    case comparison
    case photoSearch(query: String)
    case countdown(topic: String)
    case todo(action: TodoAction, content: String)
    case habit(action: HabitAction, content: String)
    case greeting(type: GreetingType)
    case unknown
}

// MARK: - Greeting Type

enum GreetingType {
    case hello          // 你好, hi, hello
    case thanks         // 谢谢, thank you
    case farewell       // 拜拜, bye, 再见
    case presence       // 在吗, are you there
    case selfIntro      // 你是谁, who are you
    case howAreYou      // 你好吗, how are you
}

// MARK: - Skill Router

/// Rule-based NLP router for Chinese and English user queries.
/// No external API — all logic runs locally on device.
/// Renamed from IntentParser to reflect its role in the Skill architecture.
struct SkillRouter {

    // MARK: - Parse

    static func parse(_ text: String) -> QueryIntent {
        let lower = text.lowercased()
        let trimmed = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = extractTimeRange(from: lower)

        // --- Greeting / Conversational ---
        // Only match short utterances to avoid false positives on longer queries
        if let greetingType = parseGreeting(trimmed) {
            return .greeting(type: greetingType)
        }

        // --- Event Recording ---
        if containsAny(lower, ["我今天", "今天我", "刚刚", "记录一下", "帮我记", "记一下", "i did", "i went", "i ate"]) {
            return parseAddEvent(from: text)
        }

        // --- Exercise / Fitness ---
        if containsAny(lower, ["运动", "锻炼", "健身", "跑步", "步数", "走路", "步行",
                                "exercise", "workout", "steps", "run", "walk", "fitness", "calories"]) {
            return .exercise(range: range)
        }

        // --- Location / Places ---
        if containsAny(lower, ["去过", "去哪", "哪里", "地点", "位置", "地方", "在哪",
                                "where", "place", "location", "visit", "went to", "been to"]) {
            return .location(range: range)
        }

        // --- Mood / Emotion ---
        if containsAny(lower, ["心情", "情绪", "感觉", "开心", "难过", "心态",
                                "mood", "feeling", "emotion", "happy", "sad", "stressed"]) {
            return .mood(range: range)
        }

        // --- Recommendation ---
        if containsAny(lower, ["推荐", "建议", "送什么", "买什么", "礼物", "帮我选",
                                "recommend", "suggest", "gift", "what to buy"]) {
            let topic = extractRecommendationTopic(from: lower)
            return .recommendation(topic: topic)
        }

        // --- Summary ---
        if containsAny(lower, ["总结", "回顾", "概括", "做了什么", "发生了什么",
                                "summary", "recap", "review", "what happened", "what did i"]) {
            return .summary(range: range)
        }

        // --- Health Metrics ---
        if containsAny(lower, ["睡眠", "睡了", "心率", "血压", "卡路里",
                                "sleep", "heart rate", "calories", "health"]) {
            let metric = extractHealthMetric(from: lower)
            return .health(metric: metric, range: range)
        }

        // --- Streak ---
        if containsAny(lower, ["连续", "打卡", "坚持", "streak", "连续几天", "streak days"]) {
            return .streak
        }

        // --- Weekly Insight ---
        if containsAny(lower, ["本周总结", "这周怎么样", "周报", "weekly", "本周情况", "这周总结"]) {
            return .weeklyInsight
        }

        // --- Comparison ---
        if containsAny(lower, ["比上周", "对比", "compared to", "趋势", "比较", "vs"]) {
            return .comparison
        }

        // --- Countdown / Days Until ---
        if containsAny(lower, ["倒计时", "还有多少天", "还有几天", "还有多久", "距离", "countdown",
                                "多少天后", "days until", "how many days", "什么时候到"]) {
            let topic = extractCountdownTopic(from: lower)
            return .countdown(topic: topic)
        }

        // Birthday countdown (when mentioning birthday without general event context)
        if containsAny(lower, ["生日"]) && containsAny(lower, ["还有", "多久", "几天", "什么时候", "哪天", "倒计时"]) {
            let topic = extractCountdownTopic(from: lower)
            return .countdown(topic: topic)
        }

        // --- Habit Tracking ---
        if containsAny(lower, ["习惯", "打卡", "habit", "check in", "checkin"]) {
            let (action, content) = extractHabitAction(from: lower, original: text)
            return .habit(action: action, content: content)
        }
        if containsAny(lower, ["创建习惯", "新习惯", "添加习惯", "追踪习惯", "new habit", "create habit", "track habit"]) {
            let content = extractHabitContent(from: text)
            return .habit(action: .create, content: content)
        }
        if containsAny(lower, ["删除习惯", "去掉习惯", "不追踪", "remove habit", "delete habit"]) {
            let content = extractHabitContent(from: text)
            return .habit(action: .delete, content: content)
        }

        // --- Todo / Memo ---
        if containsAny(lower, ["待办", "todo", "to-do", "任务清单", "备忘"]) {
            let (action, content) = extractTodoAction(from: lower, original: text)
            return .todo(action: action, content: content)
        }
        if containsAny(lower, ["提醒我", "帮我记个", "记个待办", "添加待办", "新增待办", "add task", "add todo", "remind me"]) {
            let content = extractTodoContent(from: text)
            return .todo(action: .add, content: content)
        }

        // --- Weather感受 ---
        if containsAny(lower, ["天气", "冷", "热", "下雨", "weather"]) {
            return .events(range: range)
        }

        // --- Calendar ---
        if containsAny(lower, ["日历", "行程", "日程", "计划", "会议", "约会", "活动",
                                "calendar", "schedule", "meeting", "event", "appointment"]) {
            return .calendar(range: range)
        }

        // --- Photo Search (AI visual search) ---
        if containsAny(lower, ["找照片", "找一下", "找一张", "找到", "搜照片", "帮我找",
                                "find photo", "search photo", "look for photo"]) &&
           containsAny(lower, ["照片", "自拍", "photo", "图", "pic", "拍"]) {
            return .photoSearch(query: text)
        }

        // --- Photo Search (description-based) ---
        if containsAny(lower, ["拍了一张", "拍过一张", "有一张照片", "有张照片",
                                "哪张", "哪些照片"]) {
            return .photoSearch(query: text)
        }

        // --- Photos (stats) ---
        if containsAny(lower, ["照片", "拍了", "拍过", "图片", "相册", "记录了几张",
                                "photo", "picture", "shot", "camera", "image"]) {
            return .photos(range: range)
        }

        // --- Profile ---
        if containsAny(lower, ["我是谁", "我叫什么", "我的信息", "个人资料",
                                "who am i", "my profile", "my info"]) {
            return .profile
        }

        // --- General Events ---
        if containsAny(lower, ["事件", "事情", "最近", "记录", "日志",
                                "events", "diary", "log", "recent"]) {
            return .events(range: range)
        }

        return .unknown
    }

    // MARK: - Time Range Extraction

    static func extractTimeRange(from text: String) -> QueryTimeRange {
        if containsAny(text, ["今天", "today"]) { return .today }
        if containsAny(text, ["昨天", "yesterday"]) { return .yesterday }
        if containsAny(text, ["前天", "day before yesterday"]) { return .yesterday }
        if containsAny(text, ["明天", "tomorrow"]) { return .today }
        if containsAny(text, ["今年", "this year"]) { return .all }
        if containsAny(text, ["上周", "上个星期", "last week", "past week"]) { return .lastWeek }
        if containsAny(text, ["这周", "本周", "this week"]) { return .thisWeek }
        if containsAny(text, ["上个月", "上月", "last month"]) { return .lastMonth }
        if containsAny(text, ["这个月", "本月", "this month"]) { return .thisMonth }
        if containsAny(text, ["最近", "recent", "lately", "recently"]) { return .lastWeek }
        return .lastWeek
    }

    // MARK: - Recommendation Topic

    private static func extractRecommendationTopic(from text: String) -> String {
        if containsAny(text, ["礼物", "gift"]) {
            if containsAny(text, ["老婆", "妻子", "wife"]) { return "gift_wife" }
            if containsAny(text, ["老公", "丈夫", "husband"]) { return "gift_husband" }
            if containsAny(text, ["妈妈", "mother", "mom"]) { return "gift_mother" }
            if containsAny(text, ["爸爸", "father", "dad"]) { return "gift_father" }
            return "gift_general"
        }
        return "general"
    }

    // MARK: - Health Metric

    private static func extractHealthMetric(from text: String) -> String {
        if containsAny(text, ["睡眠", "睡了", "sleep"]) { return "sleep" }
        if containsAny(text, ["心率", "heart rate"]) { return "heartRate" }
        if containsAny(text, ["步数", "走路", "步行", "steps", "walk"]) { return "steps" }
        if containsAny(text, ["卡路里", "热量", "calories"]) { return "calories" }
        return "general"
    }

    // MARK: - Add Event Parsing

    private static func parseAddEvent(from text: String) -> QueryIntent {
        var mood = MoodType.neutral
        if containsAny(text.lowercased(), ["开心", "高兴", "棒", "好", "great", "happy", "good"]) {
            mood = .good
        } else if containsAny(text.lowercased(), ["难过", "不开心", "糟", "sad", "bad", "upset"]) {
            mood = .sad
        } else if containsAny(text.lowercased(), ["累", "疲惫", "tired", "exhausted"]) {
            mood = .tired
        }
        let title = String(text.prefix(20))
        return .addEvent(title: title, content: text, mood: mood)
    }

    // MARK: - Countdown Topic

    private static func extractCountdownTopic(from text: String) -> String {
        // Family member birthdays
        if containsAny(text, ["老婆", "妻子", "wife"]) && containsAny(text, ["生日"]) { return "birthday_wife" }
        if containsAny(text, ["老公", "丈夫", "husband"]) && containsAny(text, ["生日"]) { return "birthday_husband" }
        if containsAny(text, ["妈妈", "母亲", "mom", "mother"]) && containsAny(text, ["生日"]) { return "birthday_mother" }
        if containsAny(text, ["爸爸", "父亲", "dad", "father"]) && containsAny(text, ["生日"]) { return "birthday_father" }
        if containsAny(text, ["生日", "birthday"]) { return "birthday_self" }

        // Holidays
        if containsAny(text, ["春节", "过年", "新年", "chinese new year", "lunar new year"]) { return "holiday_spring" }
        if containsAny(text, ["中秋", "mid-autumn"]) { return "holiday_midautumn" }
        if containsAny(text, ["国庆", "十一", "national day"]) { return "holiday_national" }
        if containsAny(text, ["元旦", "new year"]) { return "holiday_newyear" }
        if containsAny(text, ["圣诞", "christmas"]) { return "holiday_christmas" }
        if containsAny(text, ["情人节", "valentine"]) { return "holiday_valentine" }
        if containsAny(text, ["端午", "dragon boat"]) { return "holiday_dragonboat" }
        if containsAny(text, ["劳动节", "五一", "labor day"]) { return "holiday_labor" }

        // General — show all upcoming
        return "all"
    }

    // MARK: - Todo Action Extraction

    private static func extractTodoAction(from lower: String, original: String) -> (TodoAction, String) {
        // Complete / finish
        if containsAny(lower, ["完成", "做完了", "搞定", "done", "finish", "complete", "勾选"]) {
            let content = extractTodoContent(from: original)
            return (.complete, content)
        }
        // Clear done items
        if containsAny(lower, ["清理", "清除", "删除已完成", "clear done", "清空已完成"]) {
            return (.clear, "")
        }
        // Add
        if containsAny(lower, ["添加", "新增", "加一个", "记个", "add", "帮我记"]) {
            let content = extractTodoContent(from: original)
            return (.add, content)
        }
        // Default: list
        return (.list, "")
    }

    private static func extractTodoContent(from text: String) -> String {
        // Try to extract content after common delimiters
        let delimiters = ["：", ":", "——", "—", "- "]
        for delim in delimiters {
            if let range = text.range(of: delim) {
                let content = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !content.isEmpty { return content }
            }
        }
        // Try extracting after keyword phrases
        let prefixes = ["帮我记个待办", "记个待办", "添加待办", "新增待办", "提醒我",
                        "帮我记个", "add todo", "add task", "remind me to",
                        "完成待办", "完成"]
        let lower = text.lowercased()
        for prefix in prefixes {
            if let range = lower.range(of: prefix) {
                let content = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !content.isEmpty { return content }
            }
        }
        return ""
    }

    // MARK: - Habit Action Extraction

    private static func extractHabitAction(from lower: String, original: String) -> (HabitAction, String) {
        // Stats
        if containsAny(lower, ["统计", "数据", "报告", "分析", "stats", "report", "分析习惯"]) {
            let content = extractHabitContent(from: original)
            return (.stats, content)
        }
        // Create
        if containsAny(lower, ["创建", "新增", "添加", "追踪", "开始", "create", "new", "add", "track"]) {
            let content = extractHabitContent(from: original)
            return (.create, content)
        }
        // Delete
        if containsAny(lower, ["删除", "去掉", "移除", "不要", "remove", "delete"]) {
            let content = extractHabitContent(from: original)
            return (.delete, content)
        }
        // Check in all
        if containsAny(lower, ["全部打卡", "全部签到", "都打卡", "check in all", "checkin all"]) {
            return (.checkin, "_all")
        }
        // Check in specific
        if containsAny(lower, ["打卡", "签到", "check in", "checkin", "done"]) {
            let content = extractHabitContent(from: original)
            return (.checkin, content)
        }
        // List
        if containsAny(lower, ["我的习惯", "习惯列表", "哪些习惯", "list", "habits", "查看习惯"]) {
            return (.list, "")
        }
        // Default: list
        return (.list, "")
    }

    private static func extractHabitContent(from text: String) -> String {
        let delimiters = ["：", ":", "——", "—", "- "]
        for delim in delimiters {
            if let range = text.range(of: delim) {
                let content = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !content.isEmpty { return content }
            }
        }
        let prefixes = ["创建习惯", "新习惯", "添加习惯", "追踪习惯", "删除习惯", "去掉习惯",
                        "打卡", "签到", "习惯统计", "习惯数据",
                        "create habit", "new habit", "track habit",
                        "delete habit", "remove habit", "check in"]
        let lower = text.lowercased()
        for prefix in prefixes {
            if let range = lower.range(of: prefix) {
                let content = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !content.isEmpty { return content }
            }
        }
        return ""
    }

    // MARK: - Greeting Parsing

    /// Detects conversational greetings. Uses a length cap to avoid matching longer queries
    /// that happen to contain a greeting word (e.g., "你好，帮我总结这周运动").
    private static func parseGreeting(_ trimmed: String) -> GreetingType? {
        // Only match short messages (≤15 chars) to avoid false positives
        guard trimmed.count <= 15 else { return nil }

        // Self-intro: "你是谁", "who are you"
        if containsAny(trimmed, ["你是谁", "你叫什么", "who are you", "what are you", "介绍一下你自己"]) {
            return .selfIntro
        }
        // How are you: "你好吗", "你怎么样"
        if containsAny(trimmed, ["你好吗", "你怎么样", "how are you", "你还好吗"]) {
            return .howAreYou
        }
        // Thanks
        if containsAny(trimmed, ["谢谢", "感谢", "多谢", "thank", "thanks", "thx"]) {
            return .thanks
        }
        // Farewell
        if containsAny(trimmed, ["拜拜", "再见", "回头见", "下次见", "晚安", "bye", "goodbye",
                                   "good night", "see you", "gn"]) {
            return .farewell
        }
        // Presence
        if containsAny(trimmed, ["在吗", "在不在", "你在吗", "are you there", "hello?", "你在不在"]) {
            return .presence
        }
        // Hello (check last to avoid matching "你好吗" as hello)
        if containsAny(trimmed, ["你好", "嗨", "哈喽", "hello", "hey", "hi", "嘿",
                                   "早上好", "下午好", "晚上好", "早安", "午安",
                                   "good morning", "good afternoon", "good evening"]) {
            return .hello
        }
        return nil
    }

    // MARK: - Helpers

    static func containsAny(_ text: String, _ keywords: [String]) -> Bool {
        keywords.contains { text.contains($0) }
    }
}

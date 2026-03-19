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
    case randomDecision(action: RandomDecisionAction)
    case dateTime(query: DateTimeQuery)
    case math(expression: String)
    case unitConversion(value: Double, fromUnit: String, toUnit: String)
    case unknown
}

// MARK: - Date Time Query

enum DateTimeQuery {
    case currentTime    // 几点了, what time
    case currentDate    // 今天几号, what date
    case dayOfWeek      // 星期几, what day
    case weekNumber     // 第几周, week number
    case fullInfo       // 现在什么时间, general time/date
}

// MARK: - Random Decision Action

enum RandomDecisionAction {
    case coinFlip
    case diceRoll(sides: Int)
    case pickOne(options: [String])
    case randomNumber(min: Int, max: Int)
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

        // --- Date / Time ---
        if let dtQuery = parseDateTimeQuery(lower) {
            return .dateTime(query: dtQuery)
        }

        // --- Unit Conversion ---
        if let conversion = parseUnitConversion(lower) {
            return .unitConversion(value: conversion.0, fromUnit: conversion.1, toUnit: conversion.2)
        }

        // --- Math / Calculator ---
        if let expr = parseMathExpression(lower, original: text) {
            return .math(expression: expr)
        }

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

        // --- Random Decision ---
        if let decisionAction = parseRandomDecision(trimmed, original: text) {
            return .randomDecision(action: decisionAction)
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

    // MARK: - Random Decision Parsing

    private static func parseRandomDecision(_ trimmed: String, original: String) -> RandomDecisionAction? {
        let lower = trimmed

        // Coin flip
        if containsAny(lower, ["抛硬币", "丢硬币", "翻硬币", "flip coin", "coin flip", "flip a coin", "toss a coin", "toss coin"]) {
            return .coinFlip
        }

        // Dice roll
        if containsAny(lower, ["掷骰子", "丢骰子", "扔骰子", "roll dice", "roll a dice", "throw dice"]) {
            // Check for custom sides: "掷20面骰子", "roll a d20"
            let sides = extractDiceSides(from: lower)
            return .diceRoll(sides: sides)
        }

        // Pick one from options: "帮我选 A还是B还是C" or "帮我选 A或B或C"
        if containsAny(lower, ["帮我选", "帮我挑", "帮忙选", "帮忙挑", "随便选", "随机选",
                                "pick one", "choose one", "choose for me", "pick for me",
                                "选一个", "挑一个", "帮我决定"]) {
            let options = extractOptions(from: original)
            return .pickOne(options: options)
        }

        // Random number: "随机数字", "随机数 1到100"
        if containsAny(lower, ["随机数", "random number", "随机一个数", "给我一个数字"]) {
            let (min, max) = extractNumberRange(from: lower)
            return .randomNumber(min: min, max: max)
        }

        return nil
    }

    private static func extractDiceSides(from text: String) -> Int {
        // Match patterns like "20面", "d20", "12面骰"
        let patterns = [
            try? NSRegularExpression(pattern: "(\\d+)\\s*面", options: []),
            try? NSRegularExpression(pattern: "d(\\d+)", options: .caseInsensitive)
        ]
        let nsText = text as NSString
        for regex in patterns.compactMap({ $0 }) {
            if let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: nsText.length)) {
                if match.numberOfRanges > 1 {
                    let numStr = nsText.substring(with: match.range(at: 1))
                    if let sides = Int(numStr), sides >= 2 { return sides }
                }
            }
        }
        return 6 // default 6-sided die
    }

    private static func extractOptions(from text: String) -> [String] {
        // Remove common prefix phrases
        var cleaned = text
        let prefixes = ["帮我选", "帮我挑", "帮忙选", "帮忙挑", "随便选", "随机选",
                        "选一个", "挑一个", "帮我决定",
                        "pick one", "choose one", "choose for me", "pick for me"]
        for prefix in prefixes {
            if let range = cleaned.lowercased().range(of: prefix) {
                cleaned = String(cleaned[range.upperBound...])
                break
            }
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        // Remove leading punctuation
        cleaned = cleaned.replacingOccurrences(of: "^[：:，, ]+", with: "", options: .regularExpression)

        // Split by "还是", "或者", "或", ",", "、", " or "
        let separators = ["还是", "或者", " or ", "、", "，", ","]
        var options: [String] = [cleaned]
        for sep in separators {
            let split = options.flatMap { $0.components(separatedBy: sep) }
            if split.count > options.count {
                options = split
                break
            }
        }

        return options
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func extractNumberRange(from text: String) -> (Int, Int) {
        // Match "1到100", "1-100", "1~100", "between 1 and 100"
        let patterns = [
            try? NSRegularExpression(pattern: "(\\d+)\\s*[到至~\\-]+\\s*(\\d+)", options: []),
            try? NSRegularExpression(pattern: "between\\s+(\\d+)\\s+and\\s+(\\d+)", options: .caseInsensitive)
        ]
        let nsText = text as NSString
        for regex in patterns.compactMap({ $0 }) {
            if let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: nsText.length)) {
                if match.numberOfRanges > 2 {
                    let minStr = nsText.substring(with: match.range(at: 1))
                    let maxStr = nsText.substring(with: match.range(at: 2))
                    if let lo = Int(minStr), let hi = Int(maxStr) {
                        return (lo, hi)
                    }
                }
            }
        }
        return (1, 100) // default range
    }

    // MARK: - Date/Time Parsing

    private static func parseDateTimeQuery(_ text: String) -> DateTimeQuery? {
        // Week number
        if containsAny(text, ["第几周", "周数", "week number", "哪一周", "今年第几周"]) {
            return .weekNumber
        }
        // Day of week
        if containsAny(text, ["星期几", "周几", "礼拜几", "what day"]) {
            return .dayOfWeek
        }
        // Current time
        if containsAny(text, ["几点", "什么时间", "几时", "what time", "现在时间", "时间是"]) {
            return .currentTime
        }
        // Current date
        if containsAny(text, ["几号", "几月几号", "什么日期", "today's date", "今天日期", "哪一天"]) {
            return .currentDate
        }
        // General "now" queries
        if containsAny(text, ["现在", "此刻"]) &&
           containsAny(text, ["时间", "日期", "多少号", "time", "date"]) {
            return .fullInfo
        }
        return nil
    }

    // MARK: - Math Expression Parsing

    /// Detects math/calculator requests and extracts the arithmetic expression.
    private static func parseMathExpression(_ lower: String, original: String) -> String? {
        // Explicit "calculate" keywords
        if containsAny(lower, ["计算", "算一下", "算下", "等于多少", "等于几", "是多少",
                                "calculate", "compute", "多少钱", "总共多少",
                                "加上", "减去", "乘以", "除以"]) {
            let expr = extractMathExpr(from: original)
            if !expr.isEmpty { return expr }
        }

        // Pure math expression detection: starts with digit or paren, contains operators
        let stripped = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        if looksLikeMathExpression(stripped) {
            return stripped
        }

        // "X + Y = ?" or "X * Y" patterns embedded in text
        if let regex = try? NSRegularExpression(
            pattern: "\\d+[\\s]*([\\.\\d]*[\\s]*[+\\-×÷*/xX%^])+[\\s]*[\\.\\d]+",
            options: []
        ) {
            let ns = original as NSString
            if let match = regex.firstMatch(in: original, options: [],
                                             range: NSRange(location: 0, length: ns.length)) {
                return ns.substring(with: match.range)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return nil
    }

    /// Check if a string looks like a standalone math expression (e.g. "3+5", "(2+3)*4").
    private static func looksLikeMathExpression(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        // Must start with digit, paren, or minus sign
        guard let first = text.unicodeScalars.first,
              CharacterSet.decimalDigits.contains(first) || first == "(" || first == "-" else {
            return false
        }
        // Must contain at least one operator
        let operators: [Character] = ["+", "-", "*", "/", "×", "÷", "^", "%"]
        let hasOperator = text.contains { operators.contains($0) }
        guard hasOperator else { return false }
        // Should be relatively short and mostly math characters
        let mathChars = CharacterSet.decimalDigits
            .union(CharacterSet(charactersIn: "+-*/×÷^%().= ?xX"))
            .union(.whitespaces)
        let allMath = text.unicodeScalars.allSatisfy { mathChars.contains($0) }
        return allMath && text.count <= 80
    }

    /// Extract math expression from a natural language query.
    private static func extractMathExpr(from text: String) -> String {
        var cleaned = text
        let prefixes = ["计算", "算一下", "算下", "帮我算", "请计算", "calculate", "compute",
                        "帮我计算", "你帮我算", "请帮我算"]
        for prefix in prefixes {
            if let range = cleaned.lowercased().range(of: prefix) {
                cleaned = String(cleaned[range.upperBound...])
                break
            }
        }
        // Remove trailing question markers
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.replacingOccurrences(of: "[？?等于多少是几=]+$", with: "", options: .regularExpression)
        cleaned = cleaned.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "：:，,")))
        return cleaned
    }

    // MARK: - Helpers

    // MARK: - Unit Conversion Parsing

    /// Detects unit conversion queries like "25摄氏度转华氏", "10kg转磅", "5 miles to km"
    private static func parseUnitConversion(_ text: String) -> (Double, String, String)? {
        // Check if text contains conversion keywords
        guard containsAny(text, ["转换", "转", "换算", "等于多少", "是多少", "convert", "to ",
                                  "摄氏", "华氏", "℃", "℉", "celsius", "fahrenheit",
                                  "公里", "英里", "千米", "km", "mile",
                                  "公斤", "千克", "磅", "kg", "lb", "pound",
                                  "厘米", "英寸", "cm", "inch",
                                  "米转", "米是", "英尺", "feet", "foot", "ft",
                                  "升", "加仑", "liter", "gallon",
                                  "克转", "克是", "盎司", "gram", "ounce", "oz"]) else { return nil }

        // Extract number from text
        guard let regex = try? NSRegularExpression(pattern: "([\\d]+\\.?[\\d]*)", options: []),
              let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length)) else {
            return nil
        }
        let numStr = (text as NSString).substring(with: match.range(at: 1))
        guard let value = Double(numStr) else { return nil }

        // Temperature
        if containsAny(text, ["摄氏", "℃", "celsius", "°c"]) &&
           containsAny(text, ["华氏", "℉", "fahrenheit", "°f", "转", "to ", "换", "等于"]) {
            return (value, "celsius", "fahrenheit")
        }
        if containsAny(text, ["华氏", "℉", "fahrenheit", "°f"]) &&
           containsAny(text, ["摄氏", "℃", "celsius", "°c", "转", "to ", "换", "等于"]) {
            return (value, "fahrenheit", "celsius")
        }

        // Length: km ↔ miles
        if containsAny(text, ["公里", "千米", "km", "kilometer"]) &&
           containsAny(text, ["英里", "mile", "转", "to ", "换"]) {
            return (value, "km", "miles")
        }
        if containsAny(text, ["英里", "mile"]) &&
           containsAny(text, ["公里", "千米", "km", "kilometer", "转", "to ", "换"]) {
            return (value, "miles", "km")
        }

        // Length: cm ↔ inches
        if containsAny(text, ["厘米", "cm", "centimeter"]) &&
           containsAny(text, ["英寸", "inch", "转", "to ", "换"]) {
            return (value, "cm", "inches")
        }
        if containsAny(text, ["英寸", "inch"]) &&
           containsAny(text, ["厘米", "cm", "centimeter", "转", "to ", "换"]) {
            return (value, "inches", "cm")
        }

        // Length: m ↔ feet
        if containsAny(text, ["米", "m "]) && !containsAny(text, ["公里", "千米", "厘米", "km", "cm"]) &&
           containsAny(text, ["英尺", "feet", "foot", "ft", "转", "to "]) {
            return (value, "meters", "feet")
        }
        if containsAny(text, ["英尺", "feet", "foot", "ft"]) &&
           containsAny(text, ["米", "m", "转", "to ", "换"]) && !containsAny(text, ["公里", "千米", "km"]) {
            return (value, "feet", "meters")
        }

        // Weight: kg ↔ lbs
        if containsAny(text, ["公斤", "千克", "kg", "kilogram"]) &&
           containsAny(text, ["磅", "lb", "pound", "转", "to ", "换"]) {
            return (value, "kg", "lbs")
        }
        if containsAny(text, ["磅", "lb", "pound"]) &&
           containsAny(text, ["公斤", "千克", "kg", "kilogram", "转", "to ", "换"]) {
            return (value, "lbs", "kg")
        }

        // Weight: g ↔ oz
        if containsAny(text, ["克", "gram", "g "]) && !containsAny(text, ["公斤", "千克", "kg"]) &&
           containsAny(text, ["盎司", "oz", "ounce", "转", "to "]) {
            return (value, "grams", "oz")
        }
        if containsAny(text, ["盎司", "oz", "ounce"]) &&
           containsAny(text, ["克", "gram", "g", "转", "to ", "换"]) {
            return (value, "oz", "grams")
        }

        // Volume: L ↔ gallons
        if containsAny(text, ["升", "liter", "litre"]) &&
           containsAny(text, ["加仑", "gallon", "转", "to ", "换"]) {
            return (value, "liters", "gallons")
        }
        if containsAny(text, ["加仑", "gallon"]) &&
           containsAny(text, ["升", "liter", "litre", "转", "to ", "换"]) {
            return (value, "gallons", "liters")
        }

        return nil
    }

    static func containsAny(_ text: String, _ keywords: [String]) -> Bool {
        keywords.contains { text.contains($0) }
    }
}

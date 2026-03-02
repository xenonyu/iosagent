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
    case profile
    case addEvent(title: String, content: String, mood: MoodType)
    case unknown
}

// MARK: - Intent Parser

/// Rule-based NLP parser for Chinese and English user queries.
/// No external API — all logic runs locally on device.
struct IntentParser {

    // MARK: - Parse

    static func parse(_ text: String) -> QueryIntent {
        let lower = text.lowercased()
        let range = extractTimeRange(from: lower)

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
        if containsAny(text, ["上周", "上个星期", "last week", "past week"]) { return .lastWeek }
        if containsAny(text, ["这周", "本周", "this week"]) { return .thisWeek }
        if containsAny(text, ["上个月", "上月", "last month"]) { return .lastMonth }
        if containsAny(text, ["这个月", "本月", "this month"]) { return .thisMonth }
        if containsAny(text, ["最近", "recent", "lately", "recently"]) { return .lastWeek }
        return .lastWeek // Default
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
        // Extract mood from text
        var mood = MoodType.neutral
        if containsAny(text.lowercased(), ["开心", "高兴", "棒", "好", "great", "happy", "good"]) {
            mood = .good
        } else if containsAny(text.lowercased(), ["难过", "不开心", "糟", "sad", "bad", "upset"]) {
            mood = .sad
        } else if containsAny(text.lowercased(), ["累", "疲惫", "tired", "exhausted"]) {
            mood = .tired
        }

        // Use first 20 chars as title, rest as content
        let title = String(text.prefix(20))
        return .addEvent(title: title, content: text, mood: mood)
    }

    // MARK: - Helpers

    static func containsAny(_ text: String, _ keywords: [String]) -> Bool {
        keywords.contains { text.contains($0) }
    }
}

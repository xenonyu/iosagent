import Foundation

/// Maintains conversation context across multiple turns.
/// Tracks entities, time references, and recent topics so the AI
/// can answer follow-up questions coherently.
final class ContextMemory {

    private let maxMessages = 12

    // MARK: - State

    private(set) var recentMessages: [ChatMessage] = []
    private(set) var lastTimeRange: QueryTimeRange = .lastWeek
    private(set) var mentionedPeople: Set<String> = []
    private(set) var mentionedTopics: [String] = []
    private(set) var lastIntent: QueryIntent? = nil
    private(set) var lastStreakResult: Int? = nil

    // MARK: - Public API

    func add(message: ChatMessage) {
        recentMessages.append(message)
        if recentMessages.count > maxMessages {
            recentMessages.removeFirst()
        }
        extractContext(from: message.content)
    }

    func setLastIntent(_ intent: QueryIntent) {
        lastIntent = intent
    }

    func setLastStreak(_ streak: Int) {
        lastStreakResult = streak
    }

    func clear() {
        recentMessages = []
        lastTimeRange = .lastWeek
        mentionedPeople = []
        mentionedTopics = []
        lastIntent = nil
        lastStreakResult = nil
    }

    // MARK: - Context Enrichment

    /// Returns a resolved intent by inheriting context from previous turns.
    ///
    /// Handles three follow-up scenarios:
    /// 1. "那昨天呢?" → unknown intent + follow-up → inherits previous skill, changes time range
    /// 2. "昨天" (bare time) → unknown intent + time-only → inherits previous skill, changes time range
    /// 3. "睡眠呢?" → known intent + follow-up + no explicit time → inherits time range from previous turn
    ///    (e.g. after "今天走了多少步？", "睡眠呢" should mean today's sleep, not default lastWeek)
    func resolveIntent(from rawText: String) -> QueryIntent {
        let lower = rawText.lowercased()
        let trimmed = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        let newIntent = SkillRouter.parse(rawText)
        let newRange = SkillRouter.extractTimeRange(from: lower)

        // Detect follow-up patterns: "那...呢", time-only queries, continuation phrases
        let followUpPhrases = [
            "那", "那天", "那昨", "呢", "怎么样", "那上周", "那上个月",
            "and", "what about", "how about", "then"
        ]
        let isFollowUp = SkillRouter.containsAny(lower, followUpPhrases)

        // Also detect bare time references as follow-ups: "昨天", "上周", "这个月" alone
        let isTimeOnly = newIntent.isUnknown && isTimeReference(trimmed)

        // Scenario 1 & 2: Unknown intent → inherit previous skill entirely
        if (isFollowUp || isTimeOnly), let last = lastIntent, newIntent.isUnknown {
            return inheritIntent(last, withRange: newRange)
        }

        // Scenario 3: Known intent + follow-up signal + no explicit time in query
        // → keep the new skill but inherit time range from the previous turn.
        // Example: "今天走了多少步？" then "睡眠呢？"
        //   newIntent = .health(sleep, lastWeek)  ← wrong default range
        //   lastTimeRange = .today                ← correct from previous turn
        //   Result: .health(sleep, today)
        if isFollowUp, let last = lastIntent, !newIntent.isUnknown {
            let queryHasExplicitTime = hasExplicitTimeReference(lower)
            if !queryHasExplicitTime, let previousRange = extractRange(from: last) {
                return applyRange(previousRange, to: newIntent)
            }
        }

        return newIntent
    }

    /// Checks if the input is primarily a time reference with no other meaningful content.
    /// e.g. "昨天", "上周呢", "这个月的", "前天怎么样"
    private func isTimeReference(_ text: String) -> Bool {
        let timeWords = [
            "今天", "昨天", "前天", "大前天",
            "这周", "上周", "上上周", "本周",
            "这个月", "上个月", "本月",
            "最近", "近期",
            "today", "yesterday", "last week", "this week", "this month"
        ]
        // Strip filler words to check if the core is just a time reference
        var stripped = text
        for filler in ["呢", "的", "怎么样", "如何", "？", "?", "吗"] {
            stripped = stripped.replacingOccurrences(of: filler, with: "")
        }
        stripped = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        return timeWords.contains(where: { stripped == $0 || stripped.hasPrefix($0) && stripped.count <= $0.count + 2 })
    }

    /// Returns a context hint string to prepend to queries.
    func buildContextHint() -> String? {
        guard recentMessages.count > 2 else { return nil }
        let userMsgs = recentMessages.filter { $0.isUser }.suffix(2)
        guard !userMsgs.isEmpty else { return nil }
        let recent = userMsgs.map { String($0.content.prefix(30)) }.joined(separator: " / ")
        return "近期话题：\(recent)"
    }

    // MARK: - Extraction

    private func extractContext(from text: String) {
        let lower = text.lowercased()

        // Time range
        lastTimeRange = SkillRouter.extractTimeRange(from: lower)

        // People
        let peopleKw = ["老婆", "妻子", "老公", "丈夫", "妈妈", "爸爸", "孩子", "朋友", "同事", "boss", "女朋友", "男朋友"]
        peopleKw.forEach { if lower.contains($0) { mentionedPeople.insert($0) } }

        // Topics
        let topicKw = ["运动", "健康", "位置", "地点", "心情", "工作", "睡眠", "计划", "日历", "照片"]
        topicKw.forEach { if lower.contains($0) && !mentionedTopics.contains($0) {
            mentionedTopics.append($0)
        }}

        // Keep only last 5 topics
        if mentionedTopics.count > 5 { mentionedTopics.removeFirst() }
    }

    /// Checks whether the query text contains an explicit time reference (e.g. "今天", "上周", "this month").
    /// If not, the query is using the default range from SkillRouter (.lastWeek) and we should
    /// inherit the time range from the previous conversational turn instead.
    private func hasExplicitTimeReference(_ text: String) -> Bool {
        let timeKeywords = [
            "今天", "昨天", "前天", "大前天", "明天", "后天",
            "这周", "本周", "上周", "上上周", "下周",
            "这个月", "本月", "上个月", "下个月",
            "今年", "最近", "近期",
            "today", "yesterday", "tomorrow",
            "this week", "last week", "next week",
            "this month", "last month",
            "recently", "lately"
        ]
        return timeKeywords.contains(where: { text.contains($0) })
    }

    /// Extracts the QueryTimeRange from an existing intent, if it carries one.
    private func extractRange(from intent: QueryIntent) -> QueryTimeRange? {
        switch intent {
        case .exercise(let r):   return r
        case .location(let r):   return r
        case .mood(let r):       return r
        case .summary(let r):    return r
        case .events(let r):     return r
        case .health(_, let r):  return r
        case .calendar(let r):   return r
        case .photos(let r):     return r
        default:                 return nil
        }
    }

    /// Returns a new intent of the same type but with a different time range.
    /// For intents that don't carry a time range, returns them unchanged.
    private func applyRange(_ range: QueryTimeRange, to intent: QueryIntent) -> QueryIntent {
        switch intent {
        case .exercise:          return .exercise(range: range)
        case .location:          return .location(range: range)
        case .mood:              return .mood(range: range)
        case .summary:           return .summary(range: range)
        case .events:            return .events(range: range)
        case .health(let m, _):  return .health(metric: m, range: range)
        case .calendar:          return .calendar(range: range)
        case .photos:            return .photos(range: range)
        default:                 return intent
        }
    }

    private func inheritIntent(_ intent: QueryIntent, withRange range: QueryTimeRange) -> QueryIntent {
        switch intent {
        case .exercise:         return .exercise(range: range)
        case .location:         return .location(range: range)
        case .mood:             return .mood(range: range)
        case .summary:          return .summary(range: range)
        case .events:           return .events(range: range)
        case .health(let m, _): return .health(metric: m, range: range)
        case .calendar:         return .calendar(range: range)
        case .photos:           return .photos(range: range)
        case .streak:           return .streak
        case .weeklyInsight:    return .weeklyInsight
        case .comparison:       return .comparison
        default:                return intent
        }
    }
}

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
    /// Handles five follow-up scenarios:
    /// 1. "那昨天呢?" → unknown intent + follow-up → inherits previous skill, changes time range
    /// 2. "昨天" (bare time) → unknown intent + time-only → inherits previous skill, changes time range
    /// 2b. "够了吗?" / "详细说说" → unknown intent + elaboration/evaluation → re-triggers previous intent unchanged
    ///    (e.g. after "这周运动了多少", "够了吗" should re-show exercise data, not fall to unknown)
    /// 3. "睡眠呢?" → known intent + follow-up + no explicit time → inherits time range from previous turn
    ///    (e.g. after "今天走了多少步？", "睡眠呢" should mean today's sleep, not default lastWeek)
    /// 4. "心率" / "睡眠" / "步数" → short bare-keyword query with no explicit time
    ///    → implicitly a follow-up, inherits time range from context
    ///    (e.g. after "今天走了多少步", just "心率" should mean today's heart rate)
    func resolveIntent(from rawText: String) -> QueryIntent {
        let lower = rawText.lowercased()
        let trimmed = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        let newIntent = SkillRouter.parse(rawText)
        let newRange = SkillRouter.extractTimeRange(from: lower)

        // Detect follow-up patterns: "那...呢", time-only queries, continuation phrases
        // Include "怎么样", "怎样", and colloquial "咋样" — all interchangeable in Chinese
        let followUpPhrases = [
            "那", "那天", "那昨", "呢", "怎么样", "怎样", "咋样", "那上周", "那上个月",
            "and", "what about", "how about", "then"
        ]
        let isFollowUp = SkillRouter.containsAny(lower, followUpPhrases)

        // Also detect bare time references as follow-ups: "昨天", "上周", "这个月" alone
        let isTimeOnly = newIntent.isUnknown && isTimeReference(trimmed)

        // Scenario 2b (checked BEFORE Scenario 1):
        // Elaboration / evaluation follow-up → re-trigger previous intent unchanged.
        // "够了吗", "达标了吗", "正常吗", "详细说说", "还有呢", "为什么呢" contain no skill keywords,
        // so SkillRouter returns .unknown. These are conversational reactions to the previous
        // response — the user wants the SAME data context, not a new topic.
        //
        // Must run before Scenario 1 because phrases like "还有呢", "为什么呢" contain "呢"
        // which would match followUpPhrases and incorrectly apply a time range change.
        // Elaboration should preserve the original intent + time range entirely.
        if newIntent.isUnknown, let last = lastIntent {
            if isElaborationFollowUp(trimmed) {
                return last
            }
        }

        // Scenario 1 & 2: Unknown intent → inherit previous skill entirely
        if (isFollowUp || isTimeOnly), let last = lastIntent, newIntent.isUnknown {
            return inheritIntent(last, withRange: newRange)
        }

        // Scenario 3: Known intent + explicit follow-up signal + no explicit time in query
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

        // Scenario 4: Short bare-keyword query with no follow-up marker and no explicit time
        // → implicitly a follow-up in conversational context, inherit time range.
        // Users naturally type just "心率", "睡眠", "步数", "运动", "日程", "照片"
        // after a previous query — these should inherit the time context rather than
        // defaulting to .lastWeek which feels disconnected.
        // Guard: only trigger when there's a recent intent AND the query is short enough
        // to be a bare keyword (≤8 characters for CJK, ≤15 for English), AND the new
        // intent carries a time range (so we can meaningfully replace it).
        if !isFollowUp, let last = lastIntent, !newIntent.isUnknown {
            let queryHasExplicitTime = hasExplicitTimeReference(lower)
            let isShortQuery = trimmed.count <= shortQueryThreshold(trimmed)
            if !queryHasExplicitTime && isShortQuery,
               let previousRange = extractRange(from: last),
               extractRange(from: newIntent) != nil {
                return applyRange(previousRange, to: newIntent)
            }
        }

        return newIntent
    }

    /// Returns the max character count for a query to be considered "short" (bare keyword).
    /// CJK characters carry more meaning per character, so the threshold is lower.
    private func shortQueryThreshold(_ text: String) -> Int {
        // If primarily CJK (Chinese), use a tighter limit
        let cjkCount = text.unicodeScalars.filter { $0.value >= 0x4E00 && $0.value <= 0x9FFF }.count
        return cjkCount > text.count / 2 ? 8 : 15
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
        for filler in ["呢", "的", "怎么样", "怎样", "咋样", "如何", "好不好", "好吗", "？", "?", "吗"] {
            stripped = stripped.replacingOccurrences(of: filler, with: "")
        }
        stripped = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        if timeWords.contains(where: { stripped == $0 || stripped.hasPrefix($0) && stripped.count <= $0.count + 2 }) {
            return true
        }
        // Also recognize bare calendar dates as time references: "3月15号", "15号", "3/15"
        if stripped.range(of: #"^\d{1,2}月\d{1,2}[号日]$"#, options: .regularExpression) != nil { return true }
        if stripped.range(of: #"^\d{1,2}[号日]$"#, options: .regularExpression) != nil { return true }
        if stripped.range(of: #"^\d{1,2}[/\-]\d{1,2}$"#, options: .regularExpression) != nil { return true }
        return false
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

        // Topics — covers core iOS data categories for context-aware follow-ups
        let topicKw = ["运动", "健康", "位置", "地点", "心情", "工作", "睡眠", "计划", "日历", "照片",
                        "体重", "心率", "恢复", "步数", "距离", "卡路里"]
        topicKw.forEach { if lower.contains($0) && !mentionedTopics.contains($0) {
            mentionedTopics.append($0)
        }}

        // Keep only last 5 topics
        if mentionedTopics.count > 5 { mentionedTopics.removeFirst() }
    }

    /// Detects elaboration / evaluation follow-ups — conversational reactions where the user
    /// wants the SAME data context re-triggered, not a new topic.
    ///
    /// Three categories:
    /// 1. **Evaluation**: "够了吗", "达标了吗", "正常吗", "算多吗", "健康吗" — user judges previous data
    /// 2. **Elaboration**: "详细说说", "具体说说", "再说说", "展开说", "还有呢" — user wants more detail
    /// 3. **Confirmation**: "对不对", "是不是", "真的吗", "确定吗" — user double-checks previous answer
    private func isElaborationFollowUp(_ text: String) -> Bool {
        let evaluationPhrases = [
            // Goal evaluation
            "够了吗", "够不够", "够了没", "达标了吗", "达标没", "达到了吗",
            // Normalcy check
            "正常吗", "正不正常", "算正常吗", "健康吗", "算健康吗",
            // Quantity evaluation
            "算多吗", "算少吗", "多不多", "少不少", "多吗", "少吗",
            "高吗", "低吗", "高不高", "低不低",
            // Quality evaluation
            "好吗", "好不好", "怎么样", "算好吗", "还行吗",
            "及格吗", "合格吗", "过关吗",
            // Enough?
            "enough", "is that good", "is that normal", "is it ok"
        ]
        let elaborationPhrases = [
            // Request for more detail
            "详细说说", "具体说说", "再说说", "展开说", "说详细点",
            "具体点", "详细点", "再详细", "再具体",
            // Continuation
            "还有呢", "还有吗", "然后呢", "接下来呢", "继续",
            "还有什么", "别的呢",
            // Why / reason
            "为什么呢", "为什么", "为啥", "为啥呢", "什么原因",
            "怎么回事", "咋回事",
            // Advice
            "怎么办", "咋办", "怎么改善", "怎么提高", "怎么提升",
            "有什么建议", "有建议吗", "该怎么做",
            // English
            "tell me more", "more detail", "why", "any advice", "what should i do"
        ]
        let confirmationPhrases = [
            "对不对", "对吗", "是不是", "是吗", "真的吗", "确定吗",
            "没错吧", "对吧", "right", "really", "are you sure"
        ]

        let allPhrases = evaluationPhrases + elaborationPhrases + confirmationPhrases
        return allPhrases.contains(where: { text.contains($0) })
    }

    /// Checks whether the query text contains an explicit time reference (e.g. "今天", "上周", "this month").
    /// If not, the query is using the default range from SkillRouter (.lastWeek) and we should
    /// inherit the time range from the previous conversational turn instead.
    private func hasExplicitTimeReference(_ text: String) -> Bool {
        // Delegate to SkillRouter's comprehensive check which covers keywords,
        // weekday patterns, absolute calendar dates (3月15号), and English month names.
        return SkillRouter.hasExplicitTimeReference(text)
    }

    /// Extracts the QueryTimeRange from an existing intent, if it carries one.
    /// For intents that don't carry an explicit range but have a natural time context,
    /// returns a sensible default so follow-up queries can inherit it.
    private func extractRange(from intent: QueryIntent) -> QueryTimeRange? {
        switch intent {
        case .exercise(let r, _): return r
        case .location(let r):   return r
        case .locationPlace(_, let r): return r
        case .mood(let r):       return r
        case .summary(let r):    return r
        case .events(let r):     return r
        case .health(_, let r):  return r
        case .calendar(let r):   return r
        case .photos(let r):     return r
        case .comparison(let r): return r
        // Rangeless intents: return their implicit time context so follow-ups
        // can inherit a meaningful range instead of falling back to .lastWeek.
        case .calendarNext:                return .today
        case .calendarSearch(_, let r):    return r
        case .exerciseLastOccurrence:      return .lastWeek
        case .streak:                      return .thisWeek
        case .weeklyInsight:               return .thisWeek
        default:                           return nil
        }
    }

    /// Returns a new intent of the same type but with a different time range.
    /// For intents that don't carry a time range, returns them unchanged.
    private func applyRange(_ range: QueryTimeRange, to intent: QueryIntent) -> QueryIntent {
        switch intent {
        case .exercise(_, let f): return .exercise(range: range, workoutFilter: f)
        case .location:          return .location(range: range)
        case .locationPlace(let n, _): return .locationPlace(name: n, range: range)
        case .mood:              return .mood(range: range)
        case .summary:           return .summary(range: range)
        case .events:            return .events(range: range)
        case .health(let m, _):  return .health(metric: m, range: range)
        case .calendar:          return .calendar(range: range)
        case .calendarSearch(let k, _): return .calendarSearch(keyword: k, range: range)
        case .photos:            return .photos(range: range)
        case .comparison:        return .comparison(range: range)
        default:                 return intent
        }
    }

    private func inheritIntent(_ intent: QueryIntent, withRange range: QueryTimeRange) -> QueryIntent {
        switch intent {
        case .exercise(_, let f): return .exercise(range: range, workoutFilter: f)
        case .location:         return .location(range: range)
        case .locationPlace(let n, _): return .locationPlace(name: n, range: range)
        case .mood:             return .mood(range: range)
        case .summary:          return .summary(range: range)
        case .events:           return .events(range: range)
        case .health(let m, _): return .health(metric: m, range: range)
        case .calendar:         return .calendar(range: range)
        case .photos:           return .photos(range: range)
        case .comparison:       return .comparison(range: range)
        // Rangeless intents: upgrade to their parent intent type with the new range.
        // e.g. calendarNext → "那明天呢" should become .calendar(range: .tomorrow),
        //      not stay stuck on calendarNext which ignores the time change.
        case .calendarNext:                     return .calendar(range: range)
        case .calendarSearch(let k, _):         return .calendarSearch(keyword: k, range: range)
        case .exerciseLastOccurrence(let f):    return .exercise(range: range, workoutFilter: f)
        case .streak:                           return .exercise(range: range, workoutFilter: nil)
        case .weeklyInsight:                    return .summary(range: range)
        default:                return intent
        }
    }
}

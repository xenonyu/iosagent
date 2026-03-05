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

    func clear() {
        recentMessages = []
        lastTimeRange = .lastWeek
        mentionedPeople = []
        mentionedTopics = []
        lastIntent = nil
    }

    // MARK: - Context Enrichment

    /// Returns a resolved intent by inheriting context from previous turns.
    /// Example: "那昨天呢?" → inherits previous exercise intent but changes time range.
    func resolveIntent(from rawText: String) -> QueryIntent {
        let lower = rawText.lowercased()
        let newIntent = IntentParser.parse(rawText)
        let newRange = IntentParser.extractTimeRange(from: lower)

        // "那...呢" / "那..." follow-up patterns — inherit last intent with new range
        let isFollowUp = IntentParser.containsAny(lower, [
            "那", "那天", "那昨", "呢", "怎么样", "那上周", "那上个月",
            "and", "what about", "how about", "then"
        ])

        if isFollowUp, let last = lastIntent, case .unknown = newIntent {
            return inheritIntent(last, withRange: newRange)
        }

        // If same topic continuation, prefer last intent's category
        return newIntent
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
        lastTimeRange = IntentParser.extractTimeRange(from: lower)

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

    private func inheritIntent(_ intent: QueryIntent, withRange range: QueryTimeRange) -> QueryIntent {
        switch intent {
        case .exercise:      return .exercise(range: range)
        case .location:      return .location(range: range)
        case .mood:          return .mood(range: range)
        case .summary:       return .summary(range: range)
        case .events:        return .events(range: range)
        case .health(let m, _): return .health(metric: m, range: range)
        default:             return intent
        }
    }
}

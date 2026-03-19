import Foundation
import CoreData

/// The iosclaw AI engine — replaces LocalAIEngine.
///
/// Owns the SkillRegistry and routes all user queries to the correct ClawSkill.
/// No network calls ever made here. All processing runs on-device.
///
/// Data flow:
///   User query (String)
///     → SkillRouter.parse() → QueryIntent
///       → SkillRegistry.execute()
///         → matched ClawSkill.execute(intent, SkillContext)
///           → String response → completion()
final class ClawEngine {

    private let registry = SkillRegistry()

    private let coreDataContext: NSManagedObjectContext
    private let healthService: HealthService
    private let calendarService: CalendarService
    private let photoService: PhotoMetadataService
    private let locationService: LocationService
    private var profile: UserProfileData
    private let contextMemory: ContextMemory?

    init(context: NSManagedObjectContext,
         healthService: HealthService,
         calendarService: CalendarService,
         photoService: PhotoMetadataService,
         locationService: LocationService,
         profile: UserProfileData,
         contextMemory: ContextMemory? = nil) {
        self.coreDataContext = context
        self.healthService = healthService
        self.calendarService = calendarService
        self.photoService = photoService
        self.locationService = locationService
        self.profile = profile
        self.contextMemory = contextMemory
        registerSkills()
    }

    // MARK: - Skill Registration

    /// Register all Skills in priority order.
    /// RecordSkill is first so event-recording keywords aren't shadowed by other skills.
    private func registerSkills() {
        registry.register(RecordSkill())
        registry.register(HealthSkill())
        registry.register(LocationSkill())
        registry.register(MoodSkill())
        registry.register(CalendarSkill())
        registry.register(PhotoSkill())
        registry.register(ProfileSkill())
        registry.register(SummarySkill())
        registry.register(CountdownSkill())
        registry.register(TodoSkill())
        registry.register(HabitSkill())
        registry.register(RecommendationSkill())
        registry.register(WaterTrackSkill())
        registry.register(ExpenseSkill())
        registry.register(PomodoroSkill())
        registry.register(RandomDecisionSkill())
        registry.register(UnitConversionSkill())
        registry.register(MathSkill())
        registry.register(DateTimeSkill())
        registry.register(BMISkill())
        registry.register(SleepCalculatorSkill())
        registry.register(BreathingSkill())
        registry.register(PasswordGeneratorSkill())
        registry.register(NoteSkill())
        registry.register(ReminderSkill())
        registry.register(TextToolSkill())
        registry.register(DailyQuoteSkill())
        registry.register(PersonalStatsSkill())
        registry.register(LunarCalendarSkill())
        registry.register(SearchSkill())
        registry.register(GreetingSkill())
        registry.register(UnknownSkill())
    }

    // MARK: - Profile Update

    /// Refreshes the user profile before processing a new query.
    /// Call this before `respond(to:)` when the engine is long-lived so
    /// that profile changes (name, birthday, etc.) are picked up immediately.
    func updateProfile(_ newProfile: UserProfileData) {
        profile = newProfile
    }

    // MARK: - Main Entry Point

    /// Routes the user's query to the correct Skill.
    ///
    /// - Parameters:
    ///   - query: Raw user input string.
    ///   - preResolvedIntent: If ContextMemory already resolved a follow-up intent,
    ///     pass it here to skip re-parsing.
    ///   - completion: Called on the main thread with the final response string.
    func respond(to query: String,
                 preResolvedIntent: QueryIntent? = nil,
                 completion: @escaping (String) -> Void) {
        let intent = preResolvedIntent ?? SkillRouter.parse(query)
        let ctx = SkillContext(
            coreDataContext: coreDataContext,
            healthService: healthService,
            calendarService: calendarService,
            photoService: photoService,
            locationService: locationService,
            profile: profile,
            contextMemory: contextMemory,
            originalQuery: query
        )
        registry.execute(intent: intent, context: ctx, completion: completion)
    }

    // MARK: - GPT Context Prompt Builder

    /// Builds a natural-language prompt for the external LLM,
    /// embedding all local context (profile, health, events, locations, calendar)
    /// and recent conversation history for multi-turn coherence.
    ///
    /// - Parameters:
    ///   - userQuery: The current user input.
    ///   - conversationHistory: Recent chat messages for multi-turn context.
    ///   - completion: Called with the assembled prompt string.
    func buildGPTPrompt(userQuery: String,
                        conversationHistory: [ChatMessage] = [],
                        completion: @escaping (String) -> Void) {
        let interval = QueryTimeRange.lastWeek.interval
        let events = CDLifeEvent.fetch(from: interval.start, to: interval.end, in: coreDataContext)
        let locations = CDLocationRecord.fetch(from: interval.start, to: interval.end, in: coreDataContext)
        let calendarEvents = calendarService.fetchEvents(
            from: Date(),
            to: Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
        )

        healthService.fetchDailySummary(for: Date()) { [weak self] health in
            guard let self else { return }
            var parts: [String] = []

            // --- System Role ---
            parts.append("你是 iosclaw，一个运行在用户 iPhone 上的私人 AI 助理。你可以访问用户的健康、位置、日历、照片、生活记录等本地数据。请用自然、友好、简洁的中文回答用户问题。如果用户用英文提问，请用英文回答。")

            // --- User Profile ---
            var intro = "用户信息："
            if !self.profile.name.isEmpty { intro += "名字\(self.profile.name)" }
            if let bd = self.profile.birthday {
                let age = Calendar.current.dateComponents([.year], from: bd, to: Date()).year ?? 0
                intro += "，\(age)岁"
            }
            if !self.profile.occupation.isEmpty { intro += "，职业\(self.profile.occupation)" }
            if !self.profile.interests.isEmpty { intro += "，兴趣\(self.profile.interests.joined(separator: "、"))" }
            parts.append(intro)

            // --- Health Data ---
            var healthParts: [String] = []
            if health.steps > 0 { healthParts.append("今天走了\(Int(health.steps))步") }
            if health.exerciseMinutes > 0 { healthParts.append("运动\(Int(health.exerciseMinutes))分钟") }
            if health.sleepHours > 0 { healthParts.append("昨晚睡了\(String(format: "%.1f", health.sleepHours))小时") }
            if !healthParts.isEmpty { parts.append("健康数据：\(healthParts.joined(separator: "，"))") }

            // --- Life Events ---
            if !events.isEmpty {
                let evtSummary = events.prefix(8).map { "\($0.mood.emoji)\($0.title)(\($0.content.prefix(30)))" }.joined(separator: "；")
                parts.append("最近的生活记录：\(evtSummary)")
            }

            // --- Locations ---
            if !locations.isEmpty {
                var placeCount: [String: Int] = [:]
                locations.forEach { placeCount[$0.displayName, default: 0] += 1 }
                let topPlaces = placeCount.sorted { $0.value > $1.value }.prefix(5).map { "\($0.key)(\($0.value)次)" }.joined(separator: "、")
                parts.append("最近去过的地方：\(topPlaces)")
            }

            // --- Calendar ---
            if !calendarEvents.isEmpty {
                let upcoming = calendarEvents.prefix(5).map { $0.title }.joined(separator: "、")
                parts.append("近期日程：\(upcoming)")
            }

            // --- Conversation History ---
            if !conversationHistory.isEmpty {
                let historyLines = conversationHistory.suffix(10).map { msg in
                    let role = msg.isUser ? "用户" : "助理"
                    return "\(role)：\(String(msg.content.prefix(200)))"
                }
                parts.append("最近对话记录：\n\(historyLines.joined(separator: "\n"))")
            }

            let contextSentence = parts.joined(separator: "\n\n")
            completion("\(contextSentence)\n\n用户现在说：\(userQuery)")
        }
    }
}

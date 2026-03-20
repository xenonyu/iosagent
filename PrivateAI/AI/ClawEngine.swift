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
            originalQuery: query,
            followUpMode: contextMemory?.lastFollowUpMode ?? .none
        )
        registry.execute(intent: intent, context: ctx, completion: completion)
    }

}

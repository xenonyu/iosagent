import Foundation
import CoreData

// MARK: - Skill Context

/// Unified data-access context passed to every ClawSkill on execution.
/// Skills never reach outside this struct — all services and state flow through here.
struct SkillContext {
    let coreDataContext: NSManagedObjectContext
    let healthService: HealthService
    let calendarService: CalendarService
    let photoService: PhotoMetadataService
    let profile: UserProfileData
    let contextMemory: ContextMemory?
    let originalQuery: String
}

// MARK: - ClawSkill Protocol

/// Every registered Skill must implement this protocol.
/// Skills are self-contained: each owns its intent matching logic and response generation.
protocol ClawSkill {
    /// Unique identifier for debugging and logging.
    var id: String { get }
    /// Returns true if this skill can handle the given intent.
    func canHandle(intent: QueryIntent) -> Bool
    /// Generate a response for the intent using the provided context.
    func execute(intent: QueryIntent, context: SkillContext, completion: @escaping (String) -> Void)
}

// MARK: - Shared Date Helpers (available to all Skills)

extension Date {
    /// Returns a human-friendly short string: "今天 14:30", "昨天 09:00", or "3月5日"
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

extension DateInterval {
    /// Returns true if `date` falls within [start, end] (inclusive on both ends).
    func contains(_ date: Date) -> Bool {
        date >= start && date <= end
    }
}

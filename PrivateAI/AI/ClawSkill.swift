import Foundation
import CoreData

// MARK: - Follow-Up Mode

/// Indicates how the user's follow-up relates to the previous response.
/// When a skill re-triggers via ContextMemory elaboration detection,
/// this tells the skill HOW to respond differently instead of repeating data.
enum FollowUpMode {
    /// Normal first-time query — show full data response.
    case none
    /// User is evaluating the previous data: "够了吗", "正常吗", "达标了吗"
    /// → Skill should give a concise yes/no judgment with context.
    case evaluation
    /// User wants more detail: "详细说说", "还有呢", "具体点"
    /// → Skill should expand on the previous response.
    case elaboration
    /// User is asking for advice: "怎么办", "怎么改善", "有什么建议"
    /// → Skill should give actionable recommendations.
    case advice
    /// User is asking why: "为什么", "什么原因", "怎么回事"
    /// → Skill should explain possible causes.
    case reason
    /// User is confirming: "对不对", "真的吗", "确定吗"
    /// → Skill should briefly validate its previous answer.
    case confirmation
}

// MARK: - Skill Context

/// Unified data-access context passed to every ClawSkill on execution.
/// Skills never reach outside this struct — all services and state flow through here.
struct SkillContext {
    let coreDataContext: NSManagedObjectContext
    let healthService: HealthService
    let calendarService: CalendarService
    let photoService: PhotoMetadataService
    let locationService: LocationService
    let profile: UserProfileData
    let contextMemory: ContextMemory?
    let originalQuery: String
    /// When non-`.none`, the user is following up on a previous response.
    /// Skills should check this to give targeted responses instead of repeating full data.
    let followUpMode: FollowUpMode

    /// Lazy accessor for PhotoSearchService (searches CDPhotoIndex built by Vision).
    /// Only created when actually needed to avoid unnecessary overhead.
    var photoSearchService: PhotoSearchService {
        PhotoSearchService(context: coreDataContext)
    }
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

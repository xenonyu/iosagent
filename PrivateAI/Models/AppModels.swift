import Foundation

// MARK: - Chat Message

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    var content: String
    var isUser: Bool
    var timestamp: Date

    init(id: UUID = UUID(), content: String, isUser: Bool, timestamp: Date = Date()) {
        self.id = id
        self.content = content
        self.isUser = isUser
        self.timestamp = timestamp
    }
}

// MARK: - Life Event

struct LifeEvent: Identifiable, Equatable {
    let id: UUID
    var title: String
    var content: String
    var mood: MoodType
    var category: EventCategory
    var tags: [String]
    var timestamp: Date

    init(
        id: UUID = UUID(),
        title: String,
        content: String,
        mood: MoodType = .neutral,
        category: EventCategory = .life,
        tags: [String] = [],
        timestamp: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.mood = mood
        self.category = category
        self.tags = tags
        self.timestamp = timestamp
    }
}

enum MoodType: String, CaseIterable, Codable {
    case great = "great"
    case good = "good"
    case neutral = "neutral"
    case tired = "tired"
    case stressed = "stressed"
    case sad = "sad"

    var emoji: String {
        switch self {
        case .great:    return "😄"
        case .good:     return "😊"
        case .neutral:  return "😐"
        case .tired:    return "😴"
        case .stressed: return "😰"
        case .sad:      return "😢"
        }
    }

    var label: String {
        switch self {
        case .great:    return "很棒"
        case .good:     return "不错"
        case .neutral:  return "一般"
        case .tired:    return "疲惫"
        case .stressed: return "压力大"
        case .sad:      return "难过"
        }
    }
}

enum EventCategory: String, CaseIterable, Codable {
    case work = "work"
    case life = "life"
    case health = "health"
    case social = "social"
    case travel = "travel"
    case learning = "learning"

    var label: String {
        switch self {
        case .work:     return "工作"
        case .life:     return "生活"
        case .health:   return "健康"
        case .social:   return "社交"
        case .travel:   return "出行"
        case .learning: return "学习"
        }
    }

    var icon: String {
        switch self {
        case .work:     return "briefcase.fill"
        case .life:     return "house.fill"
        case .health:   return "heart.fill"
        case .social:   return "person.2.fill"
        case .travel:   return "airplane"
        case .learning: return "book.fill"
        }
    }
}

// MARK: - Location Record

struct LocationRecord: Identifiable, Equatable {
    let id: UUID
    var latitude: Double
    var longitude: Double
    var altitude: Double
    var address: String
    var placeName: String
    var duration: Double // minutes
    var timestamp: Date

    init(
        id: UUID = UUID(),
        latitude: Double,
        longitude: Double,
        altitude: Double = 0,
        address: String = "",
        placeName: String = "",
        duration: Double = 0,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.address = address
        self.placeName = placeName
        self.duration = duration
        self.timestamp = timestamp
    }

    var displayName: String {
        if !placeName.isEmpty { return placeName }
        if !address.isEmpty { return address }
        return String(format: "%.4f, %.4f", latitude, longitude)
    }
}

// MARK: - User Profile

struct UserProfileData: Codable {
    var name: String = ""
    var birthday: Date? = nil
    var occupation: String = ""
    var interests: [String] = []
    var familyMembers: [FamilyMember] = []
    var notes: String = ""
    var aiStyle: AIStyle = .friendly

    enum AIStyle: String, CaseIterable, Codable {
        case friendly = "friendly"
        case professional = "professional"
        case casual = "casual"

        var label: String {
            switch self {
            case .friendly:     return "友好温暖"
            case .professional: return "专业严谨"
            case .casual:       return "轻松随意"
            }
        }
    }
}

struct FamilyMember: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var relation: String
    var birthday: Date?
    var notes: String = ""
}

// MARK: - Health Summary

struct HealthSummary {
    var steps: Double = 0
    var activeCalories: Double = 0
    var exerciseMinutes: Double = 0
    var sleepHours: Double = 0
    /// Deep sleep (N3 stage) — most restorative phase
    var sleepDeepHours: Double = 0
    /// REM sleep — important for memory and learning
    var sleepREMHours: Double = 0
    /// Core/light sleep (N1+N2 stages)
    var sleepCoreHours: Double = 0
    var heartRate: Double = 0
    /// Resting heart rate — key cardiovascular fitness indicator (lower = fitter)
    var restingHeartRate: Double = 0
    /// Heart rate variability (SDNN in ms) — stress/recovery indicator (higher = better recovery)
    var hrv: Double = 0
    var distanceKm: Double = 0
    var flightsClimbed: Double = 0
    var date: Date = Date()

    /// True if sleep phase data is available (requires Apple Watch)
    var hasSleepPhases: Bool {
        sleepDeepHours > 0 || sleepREMHours > 0 || sleepCoreHours > 0
    }

    /// True if this day has any recorded data at all.
    var hasData: Bool {
        steps > 0 || exerciseMinutes > 0 || sleepHours > 0 || heartRate > 0 || distanceKm > 0.01 || flightsClimbed > 0
    }
}

// MARK: - Time Range

enum QueryTimeRange: Equatable {
    case today
    case yesterday
    case dayBeforeYesterday
    case tomorrow
    case dayAfterTomorrow
    case lastWeek
    case thisWeek
    case nextWeek
    case lastMonth
    case thisMonth
    case all
    /// A specific calendar date (e.g. "下周一", "本周三", "周五")
    case specificDate(Date)

    var interval: DateInterval {
        let cal = Calendar.current
        let now = Date()
        let todayStart = cal.startOfDay(for: now)
        switch self {
        case .today:
            return DateInterval(start: todayStart, end: now)
        case .yesterday:
            let start = cal.date(byAdding: .day, value: -1, to: todayStart)!
            return DateInterval(start: start, end: todayStart)
        case .dayBeforeYesterday:
            let start = cal.date(byAdding: .day, value: -2, to: todayStart)!
            let end = cal.date(byAdding: .day, value: -1, to: todayStart)!
            return DateInterval(start: start, end: end)
        case .tomorrow:
            let start = cal.date(byAdding: .day, value: 1, to: todayStart)!
            let end = cal.date(byAdding: .day, value: 2, to: todayStart)!
            return DateInterval(start: start, end: end)
        case .dayAfterTomorrow:
            let start = cal.date(byAdding: .day, value: 2, to: todayStart)!
            let end = cal.date(byAdding: .day, value: 3, to: todayStart)!
            return DateInterval(start: start, end: end)
        case .lastWeek:
            let start = cal.date(byAdding: .day, value: -7, to: now)!
            return DateInterval(start: start, end: now)
        case .thisWeek:
            let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
            let start = cal.date(from: comps)!
            return DateInterval(start: start, end: now)
        case .nextWeek:
            // Monday of next week through Sunday end
            let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
            let thisWeekStart = cal.date(from: comps)!
            let start = cal.date(byAdding: .weekOfYear, value: 1, to: thisWeekStart)!
            let end = cal.date(byAdding: .day, value: 7, to: start)!
            return DateInterval(start: start, end: end)
        case .lastMonth:
            let start = cal.date(byAdding: .month, value: -1, to: now)!
            return DateInterval(start: start, end: now)
        case .thisMonth:
            let comps = cal.dateComponents([.year, .month], from: now)
            let start = cal.date(from: comps)!
            return DateInterval(start: start, end: now)
        case .all:
            return DateInterval(start: Date.distantPast, end: now)
        case .specificDate(let date):
            let start = cal.startOfDay(for: date)
            let end = cal.date(byAdding: .day, value: 1, to: start)!
            return DateInterval(start: start, end: end)
        }
    }

    /// Whether this range represents a future time period.
    var isFuture: Bool {
        switch self {
        case .tomorrow, .dayAfterTomorrow, .nextWeek: return true
        case .specificDate(let date):
            return date > Calendar.current.startOfDay(for: Date())
        default: return false
        }
    }

    var label: String {
        switch self {
        case .today:              return "今天"
        case .yesterday:          return "昨天"
        case .dayBeforeYesterday: return "前天"
        case .tomorrow:           return "明天"
        case .dayAfterTomorrow:   return "后天"
        case .lastWeek:           return "过去7天"
        case .thisWeek:           return "本周"
        case .nextWeek:           return "下周"
        case .lastMonth:          return "过去30天"
        case .thisMonth:          return "本月"
        case .all:                return "全部"
        case .specificDate(let date):
            let fmt = DateFormatter()
            fmt.dateFormat = "M月d日（EEEE）"
            fmt.locale = Locale(identifier: "zh_CN")
            return fmt.string(from: date)
        }
    }
}

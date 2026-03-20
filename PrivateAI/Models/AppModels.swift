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

// MARK: - Workout Record

/// A single workout session from HealthKit (HKWorkout).
struct WorkoutRecord {
    var activityType: UInt       // HKWorkoutActivityType rawValue
    var duration: TimeInterval   // seconds
    var totalCalories: Double    // kcal
    var totalDistance: Double     // meters
    var startDate: Date
    var endDate: Date

    /// Human-readable workout type name (Chinese).
    var typeName: String {
        switch activityType {
        case 37:  return "跑步"          // running
        case 52:  return "步行"          // walking
        case 13:  return "骑行"          // cycling
        case 46:  return "游泳"          // swimming
        case 50:  return "瑜伽"          // yoga
        case 20:  return "功能性训练"     // functionalStrengthTraining
        case 35:  return "拳击"          // boxing/martialArts (kickboxing=47)
        case 47:  return "搏击操"        // kickboxing
        case 25:  return "高强度间歇"     // HIIT
        case 24:  return "力量训练"       // traditionalStrengthTraining (was 50? no, 50=yoga)
        case 58:  return "力量训练"       // traditionalStrengthTraining
        case 15:  return "椭圆机"        // elliptical
        case 43:  return "划船机"        // rowing
        case 16:  return "击剑"          // fencing
        case 62:  return "核心训练"       // coreTraining
        case 63:  return "舞蹈"          // dance (socialDance=77, cardioDance=78 on newer)
        case 10:  return "攀岩"          // climbing
        case 32:  return "滑雪"          // downhillSkiing
        case 60:  return "冥想"          // mindAndBody
        case 73:  return "太极"          // taiChi
        case 74:  return "普拉提"        // pilates
        case 17:  return "足球"          // soccer
        case 2:   return "羽毛球"        // badminton
        case 45:  return "网球"          // tennis
        case 3:   return "篮球"          // basketball
        case 56:  return "乒乓球"        // tableTennis
        case 26:  return "徒步"          // hiking
        case 76:  return "跳绳"          // jumpRope
        default:  return "其他运动"
        }
    }

    /// Emoji icon for the workout type.
    var typeEmoji: String {
        switch activityType {
        case 37:  return "🏃"   // running
        case 52:  return "🚶"   // walking
        case 13:  return "🚴"   // cycling
        case 46:  return "🏊"   // swimming
        case 50:  return "🧘"   // yoga
        case 20, 58: return "🏋️" // strength
        case 25:  return "💥"   // HIIT
        case 15:  return "🏃"   // elliptical
        case 43:  return "🚣"   // rowing
        case 10:  return "🧗"   // climbing
        case 26:  return "🥾"   // hiking
        case 60, 73: return "🧘" // mindAndBody/taiChi
        case 74:  return "🤸"   // pilates
        case 17:  return "⚽"   // soccer
        case 3:   return "🏀"   // basketball
        case 45:  return "🎾"   // tennis
        case 76:  return "🤾"   // jumpRope
        case 32:  return "⛷"   // skiing
        default:  return "🏅"
        }
    }

    /// Duration formatted as "Xh Ym" or "Ym".
    var durationFormatted: String {
        let mins = Int(duration / 60)
        if mins >= 60 {
            return "\(mins / 60)h\(mins % 60)m"
        }
        return "\(mins)分钟"
    }
}

// MARK: - Health Summary

struct HealthSummary {
    var steps: Double = 0
    var activeCalories: Double = 0
    /// Basal (resting) energy burned — metabolism at rest, typically 1200-2000 kcal/day
    var basalCalories: Double = 0
    var exerciseMinutes: Double = 0
    var sleepHours: Double = 0
    /// Deep sleep (N3 stage) — most restorative phase
    var sleepDeepHours: Double = 0
    /// REM sleep — important for memory and learning
    var sleepREMHours: Double = 0
    /// Core/light sleep (N1+N2 stages)
    var sleepCoreHours: Double = 0
    /// Time spent in bed (includes awake time) — used to compute sleep efficiency
    var inBedHours: Double = 0
    /// When the user fell asleep (earliest asleep sample start) — for circadian analysis
    var sleepOnset: Date?
    /// When the user woke up (latest asleep sample end) — for circadian analysis
    var wakeTime: Date?
    var heartRate: Double = 0
    /// Minimum heart rate recorded during the day — useful for detecting bradycardia or confirming low resting rate
    var heartRateMin: Double = 0
    /// Maximum heart rate recorded during the day — useful for detecting tachycardia or peak exercise intensity
    var heartRateMax: Double = 0
    /// Resting heart rate — key cardiovascular fitness indicator (lower = fitter)
    var restingHeartRate: Double = 0
    /// Heart rate variability (SDNN in ms) — stress/recovery indicator (higher = better recovery)
    var hrv: Double = 0
    var distanceKm: Double = 0
    var flightsClimbed: Double = 0
    /// Body mass in kg — from HealthKit (smart scales, manual entries)
    var bodyMassKg: Double = 0
    /// Blood oxygen saturation (SpO2) as percentage 0-100 — Apple Watch background measurements
    var oxygenSaturation: Double = 0
    /// VO2 Max in mL/(kg·min) — cardiorespiratory fitness from Apple Watch workouts
    var vo2Max: Double = 0
    /// Individual workout sessions from HKWorkout
    var workouts: [WorkoutRecord] = []
    var date: Date = Date()

    /// True if sleep phase data is available (requires Apple Watch)
    var hasSleepPhases: Bool {
        sleepDeepHours > 0 || sleepREMHours > 0 || sleepCoreHours > 0
    }

    /// True if this day has any recorded data at all.
    var hasData: Bool {
        steps > 0 || exerciseMinutes > 0 || sleepHours > 0 || heartRate > 0 || distanceKm > 0.01 || flightsClimbed > 0 || bodyMassKg > 0
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
    case nextMonth
    case all
    /// A specific calendar date (e.g. "下周一", "本周三", "周五")
    case specificDate(Date)
    /// A relative range of N days ending at now (e.g. "最近3天", "过去5天")
    case recentDays(Int)
    /// This weekend (Saturday + Sunday of the current week)
    case thisWeekend
    /// Next weekend (Saturday + Sunday of next week)
    case nextWeekend
    /// Last weekend (Saturday + Sunday of last week)
    case lastWeekend
    /// This year (Jan 1 of current year to now)
    case thisYear
    /// Last year (Jan 1 to Dec 31 of previous year)
    case lastYear
    /// Year before last (Jan 1 to Dec 31 of two years ago)
    case yearBeforeLast
    /// A season within a specific year.
    /// quarter: 1=spring(Mar-May), 2=summer(Jun-Aug), 3=autumn(Sep-Nov), 4=winter(Dec-Feb+1)
    case season(year: Int, quarter: Int)

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
        case .nextMonth:
            // 1st of next month through end of next month
            let thisMonthComps = cal.dateComponents([.year, .month], from: now)
            let thisMonthStart = cal.date(from: thisMonthComps)!
            let start = cal.date(byAdding: .month, value: 1, to: thisMonthStart)!
            let end = cal.date(byAdding: .month, value: 1, to: start)!
            return DateInterval(start: start, end: end)
        case .all:
            return DateInterval(start: Date.distantPast, end: now)
        case .specificDate(let date):
            let start = cal.startOfDay(for: date)
            let end = cal.date(byAdding: .day, value: 1, to: start)!
            return DateInterval(start: start, end: end)
        case .recentDays(let n):
            let start = cal.date(byAdding: .day, value: -n, to: todayStart)!
            return DateInterval(start: start, end: now)
        case .thisWeekend:
            let sat = Self.weekendSaturday(for: now, offset: 0)
            let mon = cal.date(byAdding: .day, value: 2, to: sat)!
            return DateInterval(start: sat, end: mon)
        case .nextWeekend:
            let sat = Self.weekendSaturday(for: now, offset: 1)
            let mon = cal.date(byAdding: .day, value: 2, to: sat)!
            return DateInterval(start: sat, end: mon)
        case .lastWeekend:
            let sat = Self.weekendSaturday(for: now, offset: -1)
            let mon = cal.date(byAdding: .day, value: 2, to: sat)!
            return DateInterval(start: sat, end: mon)
        case .thisYear:
            let yearComps = cal.dateComponents([.year], from: now)
            let yearStart = cal.date(from: yearComps)!
            return DateInterval(start: yearStart, end: now)
        case .lastYear:
            var startComps = cal.dateComponents([.year], from: now)
            startComps.year = (startComps.year ?? 2025) - 1
            let yearStart = cal.date(from: startComps)!
            let yearEnd = cal.date(from: cal.dateComponents([.year], from: now))!
            return DateInterval(start: yearStart, end: yearEnd)
        case .yearBeforeLast:
            var startComps = cal.dateComponents([.year], from: now)
            startComps.year = (startComps.year ?? 2025) - 2
            let yearStart = cal.date(from: startComps)!
            var endComps = cal.dateComponents([.year], from: now)
            endComps.year = (endComps.year ?? 2025) - 1
            let yearEnd = cal.date(from: endComps)!
            return DateInterval(start: yearStart, end: yearEnd)
        case .season(let year, let quarter):
            // Spring: Mar 1 – May 31, Summer: Jun 1 – Aug 31
            // Autumn: Sep 1 – Nov 30, Winter: Dec 1 – Feb 28/29 (of next year)
            var startComps = DateComponents()
            var endComps = DateComponents()
            switch quarter {
            case 1: // Spring
                startComps = DateComponents(year: year, month: 3, day: 1)
                endComps = DateComponents(year: year, month: 6, day: 1)
            case 2: // Summer
                startComps = DateComponents(year: year, month: 6, day: 1)
                endComps = DateComponents(year: year, month: 9, day: 1)
            case 3: // Autumn
                startComps = DateComponents(year: year, month: 9, day: 1)
                endComps = DateComponents(year: year, month: 12, day: 1)
            case 4: // Winter (crosses year boundary)
                startComps = DateComponents(year: year, month: 12, day: 1)
                endComps = DateComponents(year: year + 1, month: 3, day: 1)
            default:
                return DateInterval(start: todayStart, end: now)
            }
            let start = cal.date(from: startComps) ?? todayStart
            let end = cal.date(from: endComps) ?? now
            // If season hasn't fully arrived yet, cap to now
            let effectiveEnd = min(end, now)
            return DateInterval(start: start, end: max(start, effectiveEnd))
        }
    }

    /// Returns the start-of-day Saturday for the weekend in the given week offset.
    /// offset: 0 = this week, 1 = next week, -1 = last week.
    private static func weekendSaturday(for date: Date, offset: Int) -> Date {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: date)
        let weekday = cal.component(.weekday, from: todayStart) // 1=Sun, 7=Sat
        // Days until Saturday: Saturday is weekday 7
        let daysUntilSat = (7 - weekday + 7) % 7
        // If today is Sunday (weekday==1), "this weekend" means yesterday (Sat) + today (Sun)
        // So we go back to the most recent Saturday
        let thisSat: Date
        if weekday == 7 {
            // Today IS Saturday
            thisSat = todayStart
        } else if weekday == 1 {
            // Today is Sunday — "this weekend" = yesterday (Sat) + today
            thisSat = cal.date(byAdding: .day, value: -1, to: todayStart)!
        } else {
            // Weekday Mon-Fri — "this weekend" = upcoming Saturday
            thisSat = cal.date(byAdding: .day, value: daysUntilSat, to: todayStart)!
        }
        return cal.date(byAdding: .day, value: offset * 7, to: thisSat)!
    }

    /// Whether this range represents a future time period.
    var isFuture: Bool {
        switch self {
        case .tomorrow, .dayAfterTomorrow, .nextWeek, .nextMonth, .nextWeekend: return true
        case .thisWeekend:
            // Future if the weekend hasn't ended yet
            return interval.end > Date()
        case .specificDate(let date):
            return date > Calendar.current.startOfDay(for: Date())
        case .season(_, _):
            return interval.start > Date()
        case .recentDays: return false
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
        case .nextMonth:          return "下个月"
        case .all:                return "全部"
        case .specificDate(let date):
            let fmt = DateFormatter()
            fmt.dateFormat = "M月d日（EEEE）"
            fmt.locale = Locale(identifier: "zh_CN")
            return fmt.string(from: date)
        case .recentDays(let n):
            return "最近\(n)天"
        case .thisWeekend:
            return "这个周末"
        case .nextWeekend:
            return "下个周末"
        case .lastWeekend:
            return "上个周末"
        case .thisYear:
            let year = Calendar.current.component(.year, from: Date())
            return "今年（\(year)年）"
        case .lastYear:
            let year = Calendar.current.component(.year, from: Date()) - 1
            return "去年（\(year)年）"
        case .yearBeforeLast:
            let year = Calendar.current.component(.year, from: Date()) - 2
            return "前年（\(year)年）"
        case .season(let year, let quarter):
            let seasonNames = ["", "春天", "夏天", "秋天", "冬天"]
            let seasonName = (quarter >= 1 && quarter <= 4) ? seasonNames[quarter] : "季节"
            let currentYear = Calendar.current.component(.year, from: Date())
            if year == currentYear {
                return "今年\(seasonName)"
            } else if year == currentYear - 1 {
                return "去年\(seasonName)"
            } else if year == currentYear - 2 {
                return "前年\(seasonName)"
            } else {
                return "\(year)年\(seasonName)"
            }
        }
    }
}

// MARK: - Date Helpers

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

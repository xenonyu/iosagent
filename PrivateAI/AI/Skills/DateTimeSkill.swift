import Foundation

/// Handles date and time queries — current time, today's date, day of week, week number.
/// A fundamental personal-assistant capability that requires no external data.
struct DateTimeSkill: ClawSkill {

    let id = "dateTime"

    func canHandle(intent: QueryIntent) -> Bool {
        if case .dateTime = intent { return true }
        return false
    }

    func execute(intent: QueryIntent, context: SkillContext, completion: @escaping (String) -> Void) {
        guard case .dateTime(let query) = intent else { return }

        switch query {
        case .currentTime:
            respondCurrentTime(completion: completion)
        case .currentDate:
            respondCurrentDate(completion: completion)
        case .dayOfWeek:
            respondDayOfWeek(completion: completion)
        case .weekNumber:
            respondWeekNumber(completion: completion)
        case .fullInfo:
            respondFullInfo(completion: completion)
        }
    }

    // MARK: - Responses

    private func respondCurrentTime(completion: @escaping (String) -> Void) {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "HH:mm"
        let time = fmt.string(from: Date())

        let hour = Calendar.current.component(.hour, from: Date())
        let period = timePeriod(hour: hour)
        let emoji = timeEmoji(hour: hour)

        completion("\(emoji) 现在是\(period) **\(time)**\n\n\(timeGreeting(hour: hour))")
    }

    private func respondCurrentDate(completion: @escaping (String) -> Void) {
        let cal = Calendar.current
        let now = Date()
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "yyyy年M月d日"
        let dateStr = fmt.string(from: now)

        let weekday = chineseWeekday(cal.component(.weekday, from: now))

        // Days info for the month
        let day = cal.component(.day, from: now)
        let daysInMonth = cal.range(of: .day, in: .month, for: now)?.count ?? 30
        let remaining = daysInMonth - day

        completion("📅 今天是 **\(dateStr)**（\(weekday)）\n\n本月还剩 \(remaining) 天。")
    }

    private func respondDayOfWeek(completion: @escaping (String) -> Void) {
        let cal = Calendar.current
        let now = Date()
        let weekday = chineseWeekday(cal.component(.weekday, from: now))

        // How many days until weekend
        let dayIndex = cal.component(.weekday, from: now) // 1=Sun, 7=Sat
        let weekendMessage: String
        if dayIndex == 1 || dayIndex == 7 {
            weekendMessage = "🎉 今天是周末，好好享受休息日吧！"
        } else if dayIndex == 6 {
            weekendMessage = "🌟 明天就是周末啦，再坚持一下！"
        } else {
            let daysToWeekend = 7 - dayIndex // days until Saturday
            weekendMessage = "💪 距离周末还有 \(daysToWeekend) 天，加油！"
        }

        completion("📆 今天是**\(weekday)**\n\n\(weekendMessage)")
    }

    private func respondWeekNumber(completion: @escaping (String) -> Void) {
        let cal = Calendar.current
        let now = Date()
        let weekOfYear = cal.component(.weekOfYear, from: now)
        let dayOfYear = cal.ordinality(of: .day, in: .year, for: now) ?? 1
        let year = cal.component(.year, from: now)

        // Check if leap year
        let isLeap = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)
        let totalDays = isLeap ? 366 : 365
        let remaining = totalDays - dayOfYear
        let progress = Int(Double(dayOfYear) / Double(totalDays) * 100)

        completion("📊 \(year)年第 **\(weekOfYear)** 周\n\n今天是今年的第 \(dayOfYear) 天，还剩 \(remaining) 天（已过 \(progress)%）。")
    }

    private func respondFullInfo(completion: @escaping (String) -> Void) {
        let cal = Calendar.current
        let now = Date()
        let hour = cal.component(.hour, from: now)

        let timeFmt = DateFormatter()
        timeFmt.locale = Locale(identifier: "zh_CN")
        timeFmt.dateFormat = "HH:mm"
        let timeStr = timeFmt.string(from: now)

        let dateFmt = DateFormatter()
        dateFmt.locale = Locale(identifier: "zh_CN")
        dateFmt.dateFormat = "yyyy年M月d日"
        let dateStr = dateFmt.string(from: now)

        let weekday = chineseWeekday(cal.component(.weekday, from: now))
        let weekOfYear = cal.component(.weekOfYear, from: now)
        let emoji = timeEmoji(hour: hour)
        let period = timePeriod(hour: hour)

        completion("""
        \(emoji) \(period)好！现在是 **\(timeStr)**

        📅 \(dateStr)（\(weekday)）
        📊 今年第 \(weekOfYear) 周

        \(timeGreeting(hour: hour))
        """)
    }

    // MARK: - Helpers

    private func chineseWeekday(_ weekday: Int) -> String {
        switch weekday {
        case 1: return "星期日"
        case 2: return "星期一"
        case 3: return "星期二"
        case 4: return "星期三"
        case 5: return "星期四"
        case 6: return "星期五"
        case 7: return "星期六"
        default: return "星期？"
        }
    }

    private func timePeriod(hour: Int) -> String {
        switch hour {
        case 0..<6:   return "凌晨"
        case 6..<9:   return "早上"
        case 9..<12:  return "上午"
        case 12:      return "中午"
        case 13..<14: return "下午"
        case 14..<18: return "下午"
        case 18..<19: return "傍晚"
        case 19..<24: return "晚上"
        default:      return ""
        }
    }

    private func timeEmoji(hour: Int) -> String {
        switch hour {
        case 0..<6:   return "🌙"
        case 6..<9:   return "🌅"
        case 9..<12:  return "☀️"
        case 12..<14: return "🌞"
        case 14..<18: return "🌤"
        case 18..<20: return "🌇"
        case 20..<24: return "🌙"
        default:      return "🕐"
        }
    }

    private func timeGreeting(hour: Int) -> String {
        switch hour {
        case 0..<6:   return "夜深了，注意休息哦 💤"
        case 6..<9:   return "早安！新的一天，充满能量 ☕️"
        case 9..<12:  return "上午好！保持专注，效率满满 💪"
        case 12..<14: return "午饭时间到了，记得按时吃饭 🍜"
        case 14..<18: return "下午好！继续加油 ✨"
        case 18..<20: return "辛苦了一天，好好放松一下 🧘"
        case 20..<24: return "晚上好，享受美好的夜晚时光 🌃"
        default:      return "有什么需要帮忙的吗？"
        }
    }
}

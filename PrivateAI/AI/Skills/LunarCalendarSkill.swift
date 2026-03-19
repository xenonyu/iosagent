import Foundation

/// Provides Chinese lunar calendar information — lunar date, zodiac animal, solar terms.
/// Uses iOS built-in `Calendar(identifier: .chinese)` for accurate conversion.
struct LunarCalendarSkill: ClawSkill {

    let id = "lunarCalendar"

    func canHandle(intent: QueryIntent) -> Bool {
        if case .lunarCalendar = intent { return true }
        return false
    }

    func execute(intent: QueryIntent, context: SkillContext, completion: @escaping (String) -> Void) {
        guard case .lunarCalendar(let query) = intent else { return }

        switch query {
        case .today:
            completion(buildTodayLunar())
        case .zodiac:
            completion(buildZodiacInfo())
        case .solarTerm:
            completion(buildSolarTermInfo())
        case .fullInfo:
            completion(buildFullInfo())
        }
    }

    // MARK: - Today's Lunar Date

    private func buildTodayLunar() -> String {
        let now = Date()
        let lunar = lunarComponents(for: now)
        let gregorianStr = gregorianDateString(for: now)
        let lunarStr = lunarDateString(month: lunar.month, day: lunar.day, isLeapMonth: lunar.isLeapMonth)
        let zodiac = zodiacAnimal(for: lunar.year)
        let heavenlyStem = heavenlyStemBranch(for: lunar.year)

        return """
        🌙 今天的农历日期

        📅 公历：**\(gregorianStr)**
        🏮 农历：**\(heavenlyStem)（\(zodiac)年）\(lunarStr)**

        \(lunarDayWisdom(day: lunar.day))
        """
    }

    // MARK: - Zodiac Info

    private func buildZodiacInfo() -> String {
        let now = Date()
        let lunar = lunarComponents(for: now)
        let zodiac = zodiacAnimal(for: lunar.year)
        let heavenlyStem = heavenlyStemBranch(for: lunar.year)
        let personality = zodiacPersonality(zodiac)

        return """
        🐉 今年生肖：**\(zodiac)**

        干支纪年：**\(heavenlyStem)**

        \(zodiac)年性格特征：
        \(personality)

        🎊 祝你\(zodiac)年大吉！
        """
    }

    // MARK: - Solar Term Info

    private func buildSolarTermInfo() -> String {
        let now = Date()
        let (currentTerm, currentDate) = findCurrentOrPreviousSolarTerm(from: now)
        let (nextTerm, nextDate) = findNextSolarTerm(from: now)

        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "M月d日"

        var result = "🌿 节气信息\n\n"

        if let term = currentTerm, let date = currentDate {
            let desc = solarTermDescription(term)
            result += "当前节气：**\(term)**（\(fmt.string(from: date))）\n\(desc)\n\n"
        }

        if let term = nextTerm, let date = nextDate {
            let daysUntil = Calendar.current.dateComponents([.day], from: now, to: date).day ?? 0
            let desc = solarTermDescription(term)
            result += "下一个节气：**\(term)**（\(fmt.string(from: date))，还有 \(daysUntil) 天）\n\(desc)"
        }

        return result
    }

    // MARK: - Full Info

    private func buildFullInfo() -> String {
        let now = Date()
        let lunar = lunarComponents(for: now)
        let gregorianStr = gregorianDateString(for: now)
        let lunarStr = lunarDateString(month: lunar.month, day: lunar.day, isLeapMonth: lunar.isLeapMonth)
        let zodiac = zodiacAnimal(for: lunar.year)
        let heavenlyStem = heavenlyStemBranch(for: lunar.year)
        let (currentTerm, _) = findCurrentOrPreviousSolarTerm(from: now)
        let (nextTerm, nextDate) = findNextSolarTerm(from: now)

        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "M月d日"

        var result = """
        🌙 农历万年历

        📅 公历：**\(gregorianStr)**
        🏮 农历：**\(heavenlyStem)（\(zodiac)年）\(lunarStr)**
        """

        if let term = currentTerm {
            result += "\n🌿 当前节气：**\(term)**"
        }
        if let term = nextTerm, let date = nextDate {
            let daysUntil = Calendar.current.dateComponents([.day], from: now, to: date).day ?? 0
            result += "\n⏳ 下一节气：**\(term)**（\(fmt.string(from: date))，\(daysUntil)天后）"
        }

        // Upcoming traditional holidays
        let holidays = upcomingLunarHolidays(from: now, lunarYear: lunar.year)
        if !holidays.isEmpty {
            result += "\n\n🎉 近期传统节日：\n"
            result += holidays.joined(separator: "\n")
        }

        result += "\n\n\(lunarDayWisdom(day: lunar.day))"

        return result
    }

    // MARK: - Lunar Calendar Helpers

    private struct LunarDate {
        let year: Int
        let month: Int
        let day: Int
        let isLeapMonth: Bool
    }

    private func lunarComponents(for date: Date) -> LunarDate {
        let chineseCal = Calendar(identifier: .chinese)
        let comps = chineseCal.dateComponents([.year, .month, .day], from: date)
        let isLeap = chineseCal.dateComponents([.month], from: date).isLeapMonth ?? false
        return LunarDate(
            year: comps.year ?? 1,
            month: comps.month ?? 1,
            day: comps.day ?? 1,
            isLeapMonth: isLeap
        )
    }

    private func gregorianDateString(for date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "yyyy年M月d日 EEEE"
        return fmt.string(from: date)
    }

    private func lunarDateString(month: Int, day: Int, isLeapMonth: Bool) -> String {
        let monthNames = ["", "正月", "二月", "三月", "四月", "五月", "六月",
                          "七月", "八月", "九月", "十月", "冬月", "腊月"]
        let dayNames = [
            "", "初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
            "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
            "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十"
        ]

        let monthStr = (isLeapMonth ? "闰" : "") + (month >= 1 && month <= 12 ? monthNames[month] : "未知")
        let dayStr = day >= 1 && day <= 30 ? dayNames[day] : "未知"
        return "\(monthStr)\(dayStr)"
    }

    // MARK: - Zodiac

    private func zodiacAnimal(for lunarYear: Int) -> String {
        // Chinese calendar year cycles through 12 animals
        let animals = ["鼠", "牛", "虎", "兔", "龙", "蛇", "马", "羊", "猴", "鸡", "狗", "猪"]
        // The Chinese calendar's year component in iOS starts from 1 for 甲子
        // year % 12: 1=鼠, 2=牛, ... but we need to offset correctly
        let index = (lunarYear - 1) % 12
        return animals[index >= 0 ? index : index + 12]
    }

    private func heavenlyStemBranch(for lunarYear: Int) -> String {
        let stems = ["甲", "乙", "丙", "丁", "戊", "己", "庚", "辛", "壬", "癸"]
        let branches = ["子", "丑", "寅", "卯", "辰", "巳", "午", "未", "申", "酉", "戌", "亥"]

        let stemIndex = (lunarYear - 1) % 10
        let branchIndex = (lunarYear - 1) % 12

        let si = stemIndex >= 0 ? stemIndex : stemIndex + 10
        let bi = branchIndex >= 0 ? branchIndex : branchIndex + 12

        return "\(stems[si])\(branches[bi])年"
    }

    private func zodiacPersonality(_ zodiac: String) -> String {
        switch zodiac {
        case "鼠": return "🐭 聪明机智，反应灵敏，善于社交，有很强的适应能力"
        case "牛": return "🐂 勤劳踏实，意志坚定，诚实可靠，有耐心和毅力"
        case "虎": return "🐅 勇敢自信，有领导力，热情大方，敢于冒险挑战"
        case "兔": return "🐇 温柔善良，心思细腻，优雅有品味，人缘很好"
        case "龙": return "🐲 气度不凡，充满活力，有雄心壮志，天生领袖气质"
        case "蛇": return "🐍 深思熟虑，直觉敏锐，优雅神秘，善于分析问题"
        case "马": return "🐴 热情奔放，积极乐观，独立自主，追求自由"
        case "羊": return "🐑 温和善良，有艺术天赋，乐于助人，注重和谐"
        case "猴": return "🐵 聪明伶俐，幽默风趣，多才多艺，创造力强"
        case "鸡": return "🐔 勤勉认真，注重细节，坦率直爽，守时守信"
        case "狗": return "🐶 忠诚正直，有正义感，待人真诚，值得信赖"
        case "猪": return "🐷 真诚善良，慷慨大方，乐观开朗，福气满满"
        default: return "独特且有魅力"
        }
    }

    // MARK: - Solar Terms (节气)

    /// The 24 solar terms with approximate dates for 2026.
    /// Solar terms are based on the sun's position, so dates are Gregorian-based.
    private func solarTerms(for year: Int) -> [(name: String, month: Int, day: Int)] {
        // Approximate dates — accurate within ±1 day for most years
        return [
            ("小寒", 1, 5), ("大寒", 1, 20),
            ("立春", 2, 4), ("雨水", 2, 19),
            ("惊蛰", 3, 6), ("春分", 3, 21),
            ("清明", 4, 5), ("谷雨", 4, 20),
            ("立夏", 5, 6), ("小满", 5, 21),
            ("芒种", 6, 6), ("夏至", 6, 21),
            ("小暑", 7, 7), ("大暑", 7, 23),
            ("立秋", 8, 7), ("处暑", 8, 23),
            ("白露", 9, 8), ("秋分", 9, 23),
            ("寒露", 10, 8), ("霜降", 10, 23),
            ("立冬", 11, 7), ("小雪", 11, 22),
            ("大雪", 12, 7), ("冬至", 12, 22)
        ]
    }

    private func findCurrentOrPreviousSolarTerm(from date: Date) -> (String?, Date?) {
        let cal = Calendar.current
        let year = cal.component(.year, from: date)

        // Check current year and previous year's terms
        let allTerms = solarTerms(for: year - 1).compactMap { term -> (String, Date)? in
            guard let d = cal.date(from: DateComponents(year: year - 1, month: term.month, day: term.day)) else { return nil }
            return (term.name, d)
        } + solarTerms(for: year).compactMap { term -> (String, Date)? in
            guard let d = cal.date(from: DateComponents(year: year, month: term.month, day: term.day)) else { return nil }
            return (term.name, d)
        }

        // Find the most recent term that's on or before today
        let past = allTerms.filter { $0.1 <= date }
        return past.last.map { ($0.0, $0.1) } ?? (nil, nil)
    }

    private func findNextSolarTerm(from date: Date) -> (String?, Date?) {
        let cal = Calendar.current
        let year = cal.component(.year, from: date)

        let allTerms = solarTerms(for: year).compactMap { term -> (String, Date)? in
            guard let d = cal.date(from: DateComponents(year: year, month: term.month, day: term.day)) else { return nil }
            return (term.name, d)
        } + solarTerms(for: year + 1).compactMap { term -> (String, Date)? in
            guard let d = cal.date(from: DateComponents(year: year + 1, month: term.month, day: term.day)) else { return nil }
            return (term.name, d)
        }

        let future = allTerms.filter { $0.1 > date }
        return future.first.map { ($0.0, $0.1) } ?? (nil, nil)
    }

    private func solarTermDescription(_ term: String) -> String {
        switch term {
        case "小寒": return "❄️ 天渐寒冷，注意保暖防寒"
        case "大寒": return "🥶 一年最冷时节，宜温补养生"
        case "立春": return "🌱 春回大地，万物复苏"
        case "雨水": return "🌧 冰雪消融，春雨润物"
        case "惊蛰": return "⛈ 春雷惊百虫，万物生长"
        case "春分": return "🌸 昼夜平分，春暖花开"
        case "清明": return "🍃 天清气明，适合踏青扫墓"
        case "谷雨": return "🌾 雨生百谷，播种好时节"
        case "立夏": return "☀️ 夏天来临，万物繁茂"
        case "小满": return "🌿 麦穗渐满，注意防暑"
        case "芒种": return "🌾 忙于播种，勤劳收获"
        case "夏至": return "🌞 日照最长，盛夏开始"
        case "小暑": return "🌡 暑气渐盛，注意防暑降温"
        case "大暑": return "🔥 一年最热，多喝水多休息"
        case "立秋": return "🍂 秋天到来，暑去凉来"
        case "处暑": return "🌬 暑气渐消，秋意渐浓"
        case "白露": return "💧 露凝为白，昼夜温差大"
        case "秋分": return "🍁 昼夜平分，硕果累累"
        case "寒露": return "🍃 露冷风凉，注意添衣"
        case "霜降": return "🧊 初霜降临，秋末冬初"
        case "立冬": return "🌨 冬天来了，万物收藏"
        case "小雪": return "❄️ 初雪将至，天气渐冷"
        case "大雪": return "🌨 雪量增大，银装素裹"
        case "冬至": return "⛄️ 白昼最短，宜吃饺子汤圆"
        default: return ""
        }
    }

    // MARK: - Lunar Holidays

    private func upcomingLunarHolidays(from date: Date, lunarYear: Int) -> [String] {
        let cal = Calendar.current
        let chineseCal = Calendar(identifier: .chinese)
        let gregorianYear = cal.component(.year, from: date)

        // Major lunar holidays: (lunarMonth, lunarDay, name, emoji)
        let holidays: [(Int, Int, String, String)] = [
            (1, 1, "春节", "🧨"),
            (1, 15, "元宵节", "🏮"),
            (5, 5, "端午节", "🐲"),
            (7, 7, "七夕", "💕"),
            (7, 15, "中元节", "🕯"),
            (8, 15, "中秋节", "🥮"),
            (9, 9, "重阳节", "🌺"),
            (12, 30, "除夕", "🎆")
        ]

        var results: [String] = []
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "M月d日"

        // Try to find upcoming holidays within the next 120 days
        for holiday in holidays {
            // Convert lunar date to gregorian
            var lunarComps = DateComponents()
            lunarComps.calendar = chineseCal
            // Try current lunar year cycle
            for yearOffset in 0...1 {
                lunarComps.era = 78  // Current era in Chinese calendar
                lunarComps.year = lunarYear + yearOffset
                lunarComps.month = holiday.0
                lunarComps.day = holiday.1

                if let holidayDate = chineseCal.date(from: lunarComps) {
                    let daysUntil = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: holidayDate)).day ?? 0
                    if daysUntil >= 0 && daysUntil <= 120 {
                        if daysUntil == 0 {
                            results.append("\(holiday.3) **\(holiday.2)**：就是今天！")
                        } else {
                            results.append("\(holiday.3) **\(holiday.2)**：\(fmt.string(from: holidayDate))（\(daysUntil)天后）")
                        }
                        break
                    }
                }
            }
        }

        return results
    }

    // MARK: - Day Wisdom

    private func lunarDayWisdom(day: Int) -> String {
        switch day {
        case 1: return "🌑 初一，新月新气象，适合许愿和制定计划"
        case 15: return "🌕 十五月圆之夜，团圆美满"
        case 2...7: return "🌒 月初时光，万事开头，宜积极行动"
        case 8...14: return "🌓 上弦月渐盈，适合推进事务"
        case 16...22: return "🌖 月渐亏，适合总结反思"
        case 23...30: return "🌘 月末将尽，宜整理收尾"
        default: return "✨ 每一天都值得被认真对待"
        }
    }
}

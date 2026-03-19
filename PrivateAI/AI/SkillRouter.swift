import Foundation

// MARK: - Query Intent

enum QueryIntent {
    case exercise(range: QueryTimeRange)
    case location(range: QueryTimeRange)
    case mood(range: QueryTimeRange)
    case recommendation(topic: String)
    case summary(range: QueryTimeRange)
    case events(range: QueryTimeRange)
    case health(metric: String, range: QueryTimeRange)
    case calendar(range: QueryTimeRange)
    case photos(range: QueryTimeRange)
    case profile
    case addEvent(title: String, content: String, mood: MoodType)
    case streak
    case weeklyInsight
    case comparison
    case photoSearch(query: String)
    case countdown(topic: String)
    case todo(action: TodoAction, content: String)
    case habit(action: HabitAction, content: String)
    case greeting(type: GreetingType)
    case randomDecision(action: RandomDecisionAction)
    case dateTime(query: DateTimeQuery)
    case math(expression: String)
    case unitConversion(value: Double, fromUnit: String, toUnit: String)
    case waterTrack(action: WaterAction, amount: Int)
    case breathing(type: BreathingType)
    case bmi(heightCM: Double, weightKG: Double)
    case sleepCalc(query: SleepCalcQuery)
    case passwordGen(type: PasswordGenType)
    case pomodoro(action: PomodoroAction)
    case expense(action: ExpenseAction, amount: Double, category: String, note: String)
    case reminder(action: ReminderAction)
    case search(keyword: String)
    case note(action: NoteAction, content: String)
    case textTool(action: TextToolAction, content: String)
    case dailyQuote(category: QuoteCategory)
    case personalStats
    case lunarCalendar(query: LunarCalendarQuery)
    case unknown

    /// Whether this intent could not be matched to any known skill.
    var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }
}

// MARK: - Lunar Calendar Query

enum LunarCalendarQuery {
    case today       // 今天农历
    case zodiac      // 今年生肖
    case solarTerm   // 节气
    case fullInfo    // 农历万年历 (综合)
}

// MARK: - Quote Category

enum QuoteCategory {
    case motivational   // 励志
    case wisdom         // 智慧
    case life           // 生活
    case perseverance   // 坚持
    case dailyPick      // 今日一句 (deterministic per day)
    case random         // 随机
}

// MARK: - Text Tool Action

enum TextToolAction {
    case wordCount        // 字数统计
    case toUppercase      // 转大写
    case toLowercase      // 转小写
    case reverse          // 反转文本
    case removeSpaces     // 去除多余空格
    case charFrequency    // 字符频率统计
    case help             // 显示文本工具列表
}

// MARK: - Note Action

enum NoteAction {
    case add          // 记个笔记, 备忘
    case list         // 查看笔记, 我的笔记
    case delete       // 删除笔记
    case search       // 搜索笔记
}

// MARK: - Expense Action

enum ExpenseAction {
    case add          // 记一笔, 花了
    case today        // 今天花了多少
    case week         // 本周消费
    case month        // 本月消费
    case list         // 消费记录
    case delete       // 删除最近一笔
}

// MARK: - Pomodoro Action

enum PomodoroAction {
    case start(minutes: Int)  // record a completed focus session
    case today                // today's focus summary
    case history              // weekly focus history
    case goal(sessions: Int)  // set daily pomodoro goal
}

// MARK: - Breathing Type

enum BreathingType {
    case calm478      // 4-7-8 technique (inhale 4, hold 7, exhale 8)
    case boxBreathing // box breathing (4-4-4-4)
    case deepBreath   // simple deep breathing
    case energize     // energizing breath (quick inhale/exhale)
    case sleepAid     // pre-sleep relaxation breathing
    case overview     // show all available techniques
}

// MARK: - Date Time Query

enum DateTimeQuery {
    case currentTime    // 几点了, what time
    case currentDate    // 今天几号, what date
    case dayOfWeek      // 星期几, what day
    case weekNumber     // 第几周, week number
    case fullInfo       // 现在什么时间, general time/date
}

// MARK: - Random Decision Action

enum RandomDecisionAction {
    case coinFlip
    case diceRoll(sides: Int)
    case pickOne(options: [String])
    case randomNumber(min: Int, max: Int)
}

// MARK: - Greeting Type

enum GreetingType {
    case hello          // 你好, hi, hello
    case thanks         // 谢谢, thank you
    case farewell       // 拜拜, bye, 再见
    case presence       // 在吗, are you there
    case selfIntro      // 你是谁, who are you
    case howAreYou      // 你好吗, how are you
}

// MARK: - Sleep Calculator Query

enum SleepCalcQuery {
    case bedtimeFor(wakeHour: Int, wakeMin: Int)   // 几点睡 → 给定起床时间
    case wakeTimeFor(sleepHour: Int, sleepMin: Int) // 几点起 → 给定入睡时间
    case overview                                    // 通用睡眠计算
}

// MARK: - Password Generation Type

enum PasswordGenType {
    case standard(length: Int)   // letters + digits
    case strong(length: Int)     // letters + digits + symbols
    case pin(digits: Int)        // numeric PIN
    case memorable               // word-based easy-to-remember
    case overview                // show all options
}

// MARK: - Reminder Action

enum ReminderAction {
    case set(minutes: Int, message: String) // 提醒我X分钟后...
    case list                                // 查看提醒
    case clear                               // 清除提醒
}

// MARK: - Water Track Action

enum WaterAction {
    case drink       // 喝了水, drank water
    case today       // 今天喝了多少, today's intake
    case goal        // 设置目标, set goal
    case history     // 本周喝水, weekly history
}

// MARK: - Skill Router

/// Rule-based NLP router for Chinese and English user queries.
/// No external API — all logic runs locally on device.
/// Renamed from IntentParser to reflect its role in the Skill architecture.
struct SkillRouter {

    // MARK: - Parse

    static func parse(_ text: String) -> QueryIntent {
        let lower = text.lowercased()
        let trimmed = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = extractTimeRange(from: lower)

        // --- Lunar Calendar / Chinese Calendar ---
        if let lunarQuery = parseLunarCalendar(lower) {
            return .lunarCalendar(query: lunarQuery)
        }

        // --- Date / Time ---
        if let dtQuery = parseDateTimeQuery(lower) {
            return .dateTime(query: dtQuery)
        }

        // --- Unit Conversion ---
        if let conversion = parseUnitConversion(lower) {
            return .unitConversion(value: conversion.0, fromUnit: conversion.1, toUnit: conversion.2)
        }

        // --- Math / Calculator ---
        if let expr = parseMathExpression(lower, original: text) {
            return .math(expression: expr)
        }

        // --- Sleep Calculator ---
        if let sleepQuery = parseSleepCalc(lower) {
            return .sleepCalc(query: sleepQuery)
        }

        // --- BMI Calculator ---
        if let bmiResult = parseBMI(lower, original: text) {
            return .bmi(heightCM: bmiResult.0, weightKG: bmiResult.1)
        }

        // --- Breathing / Relaxation ---
        if let breathingType = parseBreathing(lower) {
            return .breathing(type: breathingType)
        }

        // --- Password Generator ---
        if let pwdType = parsePasswordGen(lower) {
            return .passwordGen(type: pwdType)
        }

        // --- Text Tools ---
        if let textToolIntent = parseTextTool(lower, original: text) {
            return textToolIntent
        }

        // --- Daily Quote / Motivation ---
        if let quoteCategory = parseQuote(lower) {
            return .dailyQuote(category: quoteCategory)
        }

        // --- Personal Stats / Usage Report ---
        if containsAny(lower, ["使用统计", "数据统计", "数据报告", "使用报告", "我的数据",
                                "用了多久", "使用情况", "用了多长时间", "用了几天",
                                "my stats", "usage stats", "my data", "data report"]) {
            return .personalStats
        }

        // --- Greeting / Conversational ---
        // Only match short utterances to avoid false positives on longer queries
        if let greetingType = parseGreeting(trimmed) {
            return .greeting(type: greetingType)
        }

        // --- Expense Tracking ---
        if let expenseIntent = parseExpense(lower, original: text) {
            return expenseIntent
        }

        // --- Event Recording ---
        if containsAny(lower, ["我今天", "今天我", "刚刚", "记录一下", "帮我记", "记一下", "i did", "i went", "i ate"]) {
            return parseAddEvent(from: text)
        }

        // --- Exercise / Fitness ---
        if containsAny(lower, ["运动", "锻炼", "健身", "跑步", "步数", "走路", "步行",
                                "运动量", "活动量", "消耗", "有氧", "骑车", "骑行",
                                "游泳", "爬山", "瑜伽", "打球", "散步", "徒步", "登山",
                                "跳绳", "举铁", "撸铁", "拉伸", "仰卧起坐", "俯卧撑",
                                "走了多", "跑了多", "走了几", "跑了几", "多少步", "几步",
                                "训练", "运动类型", "做了什么运动", "什么运动", "哪些运动",
                                "配速", "跑量", "骑了多", "游了多", "练了什么",
                                "hiit", "力量训练", "核心训练", "普拉提", "搏击",
                                "exercise", "workout", "steps", "run", "walk", "fitness",
                                "calories", "hiking", "swim", "cycling", "yoga"]) {
            return .exercise(range: range)
        }

        // --- Location / Places ---
        if containsAny(lower, ["去过", "去哪", "哪里", "地点", "位置", "地方", "在哪",
                                "足迹", "轨迹", "常去", "经常去", "出没", "到过", "待过",
                                "出门", "外出", "逛了", "逛街", "路过", "出去了",
                                "去了哪", "跑哪", "溜达", "遛弯", "到了哪",
                                "哪儿", "哪些地方", "什么地方",
                                "where", "place", "location", "visit", "went to", "been to",
                                "footprint", "places", "traveled", "visited"]) {
            return .location(range: range)
        }

        // --- Mood / Emotion ---
        if containsAny(lower, ["心情", "情绪", "感觉", "开心", "难过", "心态",
                                "mood", "feeling", "emotion", "happy", "sad", "stressed"]) {
            return .mood(range: range)
        }

        // --- Recommendation ---
        if containsAny(lower, ["推荐", "建议", "送什么", "买什么", "礼物", "帮我选",
                                "recommend", "suggest", "gift", "what to buy"]) {
            let topic = extractRecommendationTopic(from: lower)
            return .recommendation(topic: topic)
        }

        // --- Summary ---
        if containsAny(lower, ["总结", "回顾", "概括", "做了什么", "发生了什么",
                                "过得怎么样", "过得如何", "怎么过的", "生活怎么样",
                                "一天过得", "这段时间", "近况",
                                "summary", "recap", "review", "what happened", "what did i",
                                "how was my", "how have i been"]) {
            return .summary(range: range)
        }

        // --- Health Metrics ---
        if containsAny(lower, ["睡眠", "睡了", "睡得", "睡觉", "入睡", "失眠", "熬夜", "早睡", "晚睡",
                                "心率", "血压", "卡路里", "热量", "千卡", "大卡", "健康", "血氧", "脉搏",
                                "身体", "体质", "体能", "精力", "活力", "身体状况",
                                "HRV", "hrv", "心率变异", "静息心率",
                                "爬楼", "楼层", "爬了多少", "几层楼", "爬了几", "几层",
                                "flights", "climbed",
                                "走了多远", "跑了多远", "距离多少", "多少公里", "多少距离",
                                "多远", "几公里",
                                "体重", "体重变化", "多少斤", "多重", "几斤", "几公斤",
                                "瘦了", "胖了", "增重", "减重", "称重",
                                "weight", "body mass", "weigh",
                                "sleep", "heart rate", "calories", "health", "slept",
                                "energy", "burned", "body"]) {
            let metric = extractHealthMetric(from: lower)
            return .health(metric: metric, range: range)
        }

        // --- Streak ---
        if containsAny(lower, ["连续", "打卡", "坚持", "streak", "连续几天", "streak days"]) {
            return .streak
        }

        // --- Weekly Insight ---
        if containsAny(lower, ["本周总结", "这周怎么样", "周报", "weekly", "本周情况", "这周总结",
                                "这周过得", "本周回顾", "这礼拜", "weekly review"]) {
            return .weeklyInsight
        }

        // --- Comparison ---
        if containsAny(lower, ["比上周", "对比", "compared to", "趋势", "比较", "vs"]) {
            return .comparison
        }

        // --- Random Decision ---
        if let decisionAction = parseRandomDecision(trimmed, original: text) {
            return .randomDecision(action: decisionAction)
        }

        // --- Countdown / Days Until ---
        if containsAny(lower, ["倒计时", "还有多少天", "还有几天", "还有多久", "距离", "countdown",
                                "多少天后", "days until", "how many days", "什么时候到"]) {
            let topic = extractCountdownTopic(from: lower)
            return .countdown(topic: topic)
        }

        // Birthday countdown (when mentioning birthday without general event context)
        if containsAny(lower, ["生日"]) && containsAny(lower, ["还有", "多久", "几天", "什么时候", "哪天", "倒计时"]) {
            let topic = extractCountdownTopic(from: lower)
            return .countdown(topic: topic)
        }

        // --- Habit Tracking ---
        if containsAny(lower, ["习惯", "打卡", "habit", "check in", "checkin"]) {
            let (action, content) = extractHabitAction(from: lower, original: text)
            return .habit(action: action, content: content)
        }
        if containsAny(lower, ["创建习惯", "新习惯", "添加习惯", "追踪习惯", "new habit", "create habit", "track habit"]) {
            let content = extractHabitContent(from: text)
            return .habit(action: .create, content: content)
        }
        if containsAny(lower, ["删除习惯", "去掉习惯", "不追踪", "remove habit", "delete habit"]) {
            let content = extractHabitContent(from: text)
            return .habit(action: .delete, content: content)
        }

        // --- Timed Reminder (must be checked before Todo) ---
        if let reminderIntent = parseReminder(lower, original: text) {
            return reminderIntent
        }

        // --- Note / Quick Memo ---
        if let noteIntent = parseNote(lower, original: text) {
            return noteIntent
        }

        // --- Todo / Memo ---
        if containsAny(lower, ["待办", "todo", "to-do", "任务清单"]) {
            let (action, content) = extractTodoAction(from: lower, original: text)
            return .todo(action: action, content: content)
        }
        if containsAny(lower, ["提醒我", "帮我记个", "记个待办", "添加待办", "新增待办", "add task", "add todo", "remind me"]) {
            let content = extractTodoContent(from: text)
            return .todo(action: .add, content: content)
        }

        // --- Pomodoro / Focus Timer ---
        if let pomodoroIntent = parsePomodoro(lower, original: text) {
            return pomodoroIntent
        }

        // --- Water Tracking ---
        if let waterIntent = parseWaterTrack(lower, original: text) {
            return waterIntent
        }

        // --- Weather感受 ---
        if containsAny(lower, ["天气", "冷", "热", "下雨", "weather"]) {
            return .events(range: range)
        }

        // --- Calendar ---
        if containsAny(lower, ["日历", "行程", "日程", "计划", "会议", "约会", "活动",
                                "忙不忙", "忙吗", "有空", "空闲", "空不空", "安排", "待办",
                                "有啥事", "啥安排", "什么安排", "有没有会", "开会",
                                "专注", "深度工作", "碎片化", "集中精力", "能专心", "有时间",
                                "calendar", "schedule", "meeting", "event", "appointment",
                                "busy", "free time", "available", "agenda",
                                "focus time", "deep work", "fragmented"]) {
            return .calendar(range: range)
        }

        // --- Calendar: today/future + generic question → calendar intent ---
        // e.g. "今天有什么事", "明天干嘛", "后天有什么"
        if (range == .today || range.isFuture) && containsAny(lower, ["有什么", "干嘛", "干什么", "做什么",
                                                   "什么事", "有事", "有没有", "啥事",
                                                   "有啥", "怎么安排",
                                                   "what's on", "what do i have"]) {
            return .calendar(range: range)
        }

        // --- Photo Search (AI visual search) ---
        if containsAny(lower, ["找照片", "找一下", "找一张", "找到", "搜照片", "帮我找",
                                "find photo", "search photo", "look for photo"]) &&
           containsAny(lower, ["照片", "自拍", "photo", "图", "pic", "拍"]) {
            return .photoSearch(query: text)
        }

        // --- Photo Search (description-based) ---
        if containsAny(lower, ["拍了一张", "拍过一张", "有一张照片", "有张照片",
                                "哪张", "哪些照片"]) {
            return .photoSearch(query: text)
        }

        // --- Photo Search (location + photo context) ---
        if containsAny(lower, ["照片", "拍的", "photo"]) &&
           containsAny(lower, ["在北京", "在上海", "在广州", "在深圳", "在杭州", "在成都",
                                "在南京", "在西安", "在重庆", "在武汉", "在厦门", "在三亚",
                                "在东京", "在巴黎", "在纽约", "在伦敦", "海边", "山上",
                                "收藏", "喜欢", "最爱"]) {
            return .photoSearch(query: text)
        }

        // --- Photo Search (content keyword + photo context) ---
        // Queries like "猫的照片", "美食的图片", "海边的自拍", "日落照片"
        // These contain a Vision-searchable content keyword + photo noun — route to search, not stats.
        let photoContentKeywords = ["猫", "狗", "cat", "dog", "宠物", "动物",
                                     "海边", "沙滩", "海滩", "beach", "山", "mountain",
                                     "雪", "snow", "日落", "sunset", "夕阳",
                                     "美食", "食物", "food",
                                     "花", "flower", "植物",
                                     "户外", "outdoor", "室内", "indoor",
                                     "合照", "合影", "自拍", "selfie", "单人"]
        if containsAny(lower, ["照片", "图片", "photo", "pic", "拍的"]) &&
           containsAny(lower, photoContentKeywords) {
            return .photoSearch(query: text)
        }

        // --- Photos (stats) ---
        if containsAny(lower, ["照片", "拍了", "拍过", "图片", "相册", "记录了几张",
                                "拍照", "自拍", "截图", "相机",
                                "photo", "picture", "shot", "camera", "image", "selfie"]) {
            return .photos(range: range)
        }

        // --- Profile ---
        if containsAny(lower, ["我是谁", "我叫什么", "我的信息", "个人资料",
                                "who am i", "my profile", "my info"]) {
            return .profile
        }

        // --- Search Life Events ---
        if containsAny(lower, ["搜索", "查找", "搜一下", "查一下", "找一下记录", "找记录",
                                "search for", "search", "look up", "find record"]) {
            let keyword = extractSearchKeyword(from: text, lower: lower)
            if !keyword.isEmpty {
                return .search(keyword: keyword)
            }
        }

        // --- General Events ---
        if containsAny(lower, ["事件", "事情", "最近", "记录", "日志",
                                "events", "diary", "log", "recent"]) {
            return .events(range: range)
        }

        return .unknown
    }

    // MARK: - Time Range Extraction

    static func extractTimeRange(from text: String) -> QueryTimeRange {
        // --- Specific weekday parsing (must check before generic week ranges) ---
        // Matches: "下周一", "本周三", "这周五", "上周二", "周日", "星期四", "下星期一", "下个星期三"
        // Also English: "next monday", "this friday", "last wednesday"
        if let specificDate = extractSpecificWeekday(from: text) {
            return .specificDate(specificDate)
        }
        // Future ranges (check before past to avoid "明天" matching "天" in "今天")
        if containsAny(text, ["后天", "day after tomorrow"]) { return .dayAfterTomorrow }
        if containsAny(text, ["明天", "tomorrow"]) { return .tomorrow }
        if containsAny(text, ["下周", "下个星期", "下星期", "next week"]) { return .nextWeek }
        // Present
        if containsAny(text, ["今天", "today"]) { return .today }
        // Past ranges
        if containsAny(text, ["前天", "day before yesterday"]) { return .dayBeforeYesterday }
        if containsAny(text, ["昨天", "yesterday"]) { return .yesterday }
        if containsAny(text, ["今年", "this year"]) { return .all }
        if containsAny(text, ["上周", "上个星期", "last week", "past week"]) { return .lastWeek }
        if containsAny(text, ["这周", "本周", "this week"]) { return .thisWeek }
        if containsAny(text, ["上个月", "上月", "last month"]) { return .lastMonth }
        if containsAny(text, ["这个月", "本月", "this month"]) { return .thisMonth }
        if containsAny(text, ["最近", "recent", "lately", "recently"]) { return .lastWeek }
        return .lastWeek
    }

    // MARK: - Specific Weekday Extraction

    /// Parses specific weekday references like "下周一", "本周三", "周五", "星期四",
    /// "next monday", "this friday", "last wednesday" into a concrete Date.
    private static func extractSpecificWeekday(from text: String) -> Date? {
        let cal = Calendar.current

        // Chinese weekday names: 一=Monday(2), 二=Tue(3), ..., 日/天=Sunday(1)
        let chineseWeekdays: [(String, Int)] = [
            ("一", 2), ("二", 3), ("三", 4), ("四", 5),
            ("五", 6), ("六", 7), ("日", 1), ("天", 1)
        ]
        // English weekday names
        let englishWeekdays: [(String, Int)] = [
            ("monday", 2), ("tuesday", 3), ("wednesday", 4), ("thursday", 5),
            ("friday", 6), ("saturday", 7), ("sunday", 1),
            ("mon", 2), ("tue", 3), ("wed", 4), ("thu", 5),
            ("fri", 6), ("sat", 7), ("sun", 1)
        ]

        // Determine offset: next week (+1), this week (0), last week (-1), bare "周X" (0)
        // Chinese patterns: "下周X", "下星期X", "下个星期X", "本周X", "这周X", "上周X", "周X", "星期X"
        var weekOffset: Int? = nil
        var targetWeekday: Int? = nil

        for (name, wd) in chineseWeekdays {
            // Must check longer prefixes first to avoid partial matches
            if text.contains("下个星期\(name)") || text.contains("下星期\(name)") || text.contains("下周\(name)") {
                weekOffset = 1; targetWeekday = wd; break
            }
            if text.contains("上个星期\(name)") || text.contains("上星期\(name)") || text.contains("上周\(name)") {
                weekOffset = -1; targetWeekday = wd; break
            }
            if text.contains("本周\(name)") || text.contains("这周\(name)") || text.contains("这个星期\(name)") {
                weekOffset = 0; targetWeekday = wd; break
            }
            // Bare "周X" or "星期X" — treat as this week (current or upcoming)
            if text.contains("周\(name)") || text.contains("星期\(name)") {
                weekOffset = 0; targetWeekday = wd; break
            }
        }

        // English patterns
        if targetWeekday == nil {
            let lower = text.lowercased()
            for (name, wd) in englishWeekdays {
                if lower.contains("next \(name)") {
                    weekOffset = 1; targetWeekday = wd; break
                }
                if lower.contains("last \(name)") {
                    weekOffset = -1; targetWeekday = wd; break
                }
                if lower.contains("this \(name)") {
                    weekOffset = 0; targetWeekday = wd; break
                }
            }
        }

        guard let offset = weekOffset, let wd = targetWeekday else { return nil }

        // Calculate target date
        let now = Date()
        // Get start of current week (respects locale's first weekday setting)
        let weekComps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        guard let thisWeekStart = cal.date(from: weekComps) else { return nil }

        // Move to the target week
        guard let targetWeekStart = cal.date(byAdding: .weekOfYear, value: offset, to: thisWeekStart) else { return nil }

        // Find the target weekday within that week
        // thisWeekStart is the locale's first day of the week; we need to offset to the target weekday
        let firstWeekday = cal.component(.weekday, from: targetWeekStart)
        var dayDiff = wd - firstWeekday
        if dayDiff < 0 { dayDiff += 7 }

        return cal.date(byAdding: .day, value: dayDiff, to: targetWeekStart)
    }

    // MARK: - Recommendation Topic

    private static func extractRecommendationTopic(from text: String) -> String {
        if containsAny(text, ["礼物", "gift"]) {
            if containsAny(text, ["老婆", "妻子", "wife"]) { return "gift_wife" }
            if containsAny(text, ["老公", "丈夫", "husband"]) { return "gift_husband" }
            if containsAny(text, ["妈妈", "mother", "mom"]) { return "gift_mother" }
            if containsAny(text, ["爸爸", "father", "dad"]) { return "gift_father" }
            return "gift_general"
        }
        return "general"
    }

    // MARK: - Health Metric

    private static func extractHealthMetric(from text: String) -> String {
        if containsAny(text, ["睡眠", "睡了", "睡得", "睡觉", "入睡", "失眠", "熬夜", "早睡", "晚睡", "sleep", "slept"]) { return "sleep" }
        if containsAny(text, ["心率", "脉搏", "heart rate", "HRV", "hrv", "心率变异", "变异性", "静息心率", "resting heart"]) { return "heartRate" }
        if containsAny(text, ["步数", "走路", "步行", "多少步", "几步", "steps", "walk"]) { return "steps" }
        if containsAny(text, ["卡路里", "热量", "千卡", "大卡", "calories", "burned", "energy"]) { return "calories" }
        if containsAny(text, ["爬楼", "楼层", "几层", "爬了", "flights", "climbed", "floor"]) { return "flights" }
        if containsAny(text, ["多远", "距离", "公里", "几公里", "distance", "km", "far"]) { return "distance" }
        if containsAny(text, ["体重", "多重", "几斤", "几公斤", "多少斤", "瘦了", "胖了",
                               "增重", "减重", "称重", "weight", "body mass", "weigh"]) { return "weight" }
        return "general"
    }

    // MARK: - Add Event Parsing

    private static func parseAddEvent(from text: String) -> QueryIntent {
        var mood = MoodType.neutral
        if containsAny(text.lowercased(), ["开心", "高兴", "棒", "好", "great", "happy", "good"]) {
            mood = .good
        } else if containsAny(text.lowercased(), ["难过", "不开心", "糟", "sad", "bad", "upset"]) {
            mood = .sad
        } else if containsAny(text.lowercased(), ["累", "疲惫", "tired", "exhausted"]) {
            mood = .tired
        }
        let title = String(text.prefix(20))
        return .addEvent(title: title, content: text, mood: mood)
    }

    // MARK: - Search Keyword Extraction

    private static func extractSearchKeyword(from original: String, lower: String) -> String {
        // Remove trigger words and extract the actual search keyword
        let triggers = ["搜索", "查找", "搜一下", "查一下", "找一下记录", "找记录",
                        "search for", "search", "look up", "find record",
                        "的记录", "记录", "相关", "有关", "关于"]
        var keyword = original
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for trigger in triggers {
            keyword = keyword.replacingOccurrences(of: trigger, with: "")
        }
        keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        // Remove surrounding quotes if present
        if (keyword.hasPrefix("\"") && keyword.hasSuffix("\"")) ||
           (keyword.hasPrefix("「") && keyword.hasSuffix("」")) {
            keyword = String(keyword.dropFirst().dropLast())
        }
        return keyword
    }

    // MARK: - Countdown Topic

    private static func extractCountdownTopic(from text: String) -> String {
        // Family member birthdays
        if containsAny(text, ["老婆", "妻子", "wife"]) && containsAny(text, ["生日"]) { return "birthday_wife" }
        if containsAny(text, ["老公", "丈夫", "husband"]) && containsAny(text, ["生日"]) { return "birthday_husband" }
        if containsAny(text, ["妈妈", "母亲", "mom", "mother"]) && containsAny(text, ["生日"]) { return "birthday_mother" }
        if containsAny(text, ["爸爸", "父亲", "dad", "father"]) && containsAny(text, ["生日"]) { return "birthday_father" }
        if containsAny(text, ["生日", "birthday"]) { return "birthday_self" }

        // Holidays
        if containsAny(text, ["春节", "过年", "新年", "chinese new year", "lunar new year"]) { return "holiday_spring" }
        if containsAny(text, ["中秋", "mid-autumn"]) { return "holiday_midautumn" }
        if containsAny(text, ["国庆", "十一", "national day"]) { return "holiday_national" }
        if containsAny(text, ["元旦", "new year"]) { return "holiday_newyear" }
        if containsAny(text, ["圣诞", "christmas"]) { return "holiday_christmas" }
        if containsAny(text, ["情人节", "valentine"]) { return "holiday_valentine" }
        if containsAny(text, ["端午", "dragon boat"]) { return "holiday_dragonboat" }
        if containsAny(text, ["劳动节", "五一", "labor day"]) { return "holiday_labor" }

        // General — show all upcoming
        return "all"
    }

    // MARK: - Todo Action Extraction

    private static func extractTodoAction(from lower: String, original: String) -> (TodoAction, String) {
        // Complete / finish
        if containsAny(lower, ["完成", "做完了", "搞定", "done", "finish", "complete", "勾选"]) {
            let content = extractTodoContent(from: original)
            return (.complete, content)
        }
        // Clear done items
        if containsAny(lower, ["清理", "清除", "删除已完成", "clear done", "清空已完成"]) {
            return (.clear, "")
        }
        // Add
        if containsAny(lower, ["添加", "新增", "加一个", "记个", "add", "帮我记"]) {
            let content = extractTodoContent(from: original)
            return (.add, content)
        }
        // Default: list
        return (.list, "")
    }

    private static func extractTodoContent(from text: String) -> String {
        // Try to extract content after common delimiters
        let delimiters = ["：", ":", "——", "—", "- "]
        for delim in delimiters {
            if let range = text.range(of: delim) {
                let content = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !content.isEmpty { return content }
            }
        }
        // Try extracting after keyword phrases
        let prefixes = ["帮我记个待办", "记个待办", "添加待办", "新增待办", "提醒我",
                        "帮我记个", "add todo", "add task", "remind me to",
                        "完成待办", "完成"]
        let lower = text.lowercased()
        for prefix in prefixes {
            if let range = lower.range(of: prefix) {
                let content = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !content.isEmpty { return content }
            }
        }
        return ""
    }

    // MARK: - Note Parsing

    private static func parseNote(_ lower: String, original: String) -> QueryIntent? {
        let noteKeywords = ["笔记", "备忘", "备忘录", "note", "notes", "memo",
                            "记住", "记下", "记个笔记", "写个笔记", "快速记录"]
        guard containsAny(lower, noteKeywords) else { return nil }

        // Delete
        if containsAny(lower, ["删除笔记", "删掉笔记", "移除笔记", "delete note", "remove note"]) {
            let content = extractNoteContent(from: original, lower: lower)
            return .note(action: .delete, content: content)
        }

        // Search
        if containsAny(lower, ["搜索笔记", "查找笔记", "搜笔记", "search note", "find note"]) {
            let content = extractNoteContent(from: original, lower: lower)
            return .note(action: .search, content: content)
        }

        // List
        if containsAny(lower, ["查看笔记", "我的笔记", "所有笔记", "笔记列表", "查看备忘",
                                "备忘录", "我的备忘", "list notes", "show notes", "my notes"]) {
            return .note(action: .list, content: "")
        }

        // Add (default when mentioning note with content)
        if containsAny(lower, ["记个笔记", "写个笔记", "记住", "记下", "备忘",
                                "add note", "new note", "save note", "write note", "快速记录"]) {
            let content = extractNoteContent(from: original, lower: lower)
            return .note(action: .add, content: content)
        }

        // Bare "笔记" / "note" → list
        return .note(action: .list, content: "")
    }

    private static func extractNoteContent(from original: String, lower: String) -> String {
        // Try delimiters first
        let delimiters = ["：", ":", "——", "—", "- "]
        for delim in delimiters {
            if let range = original.range(of: delim) {
                let content = String(original[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !content.isEmpty { return content }
            }
        }
        // Try extracting after keyword phrases
        let prefixes = ["记个笔记", "写个笔记", "记住", "记下", "备忘",
                        "删除笔记", "搜索笔记", "查找笔记",
                        "add note", "new note", "save note", "delete note",
                        "search note", "find note", "快速记录"]
        for prefix in prefixes {
            if let range = lower.range(of: prefix) {
                let content = String(original[original.index(original.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: range.upperBound))...])
                    .trimmingCharacters(in: .whitespaces)
                if !content.isEmpty { return content }
            }
        }
        return ""
    }

    // MARK: - Habit Action Extraction

    private static func extractHabitAction(from lower: String, original: String) -> (HabitAction, String) {
        // Stats
        if containsAny(lower, ["统计", "数据", "报告", "分析", "stats", "report", "分析习惯"]) {
            let content = extractHabitContent(from: original)
            return (.stats, content)
        }
        // Create
        if containsAny(lower, ["创建", "新增", "添加", "追踪", "开始", "create", "new", "add", "track"]) {
            let content = extractHabitContent(from: original)
            return (.create, content)
        }
        // Delete
        if containsAny(lower, ["删除", "去掉", "移除", "不要", "remove", "delete"]) {
            let content = extractHabitContent(from: original)
            return (.delete, content)
        }
        // Check in all
        if containsAny(lower, ["全部打卡", "全部签到", "都打卡", "check in all", "checkin all"]) {
            return (.checkin, "_all")
        }
        // Check in specific
        if containsAny(lower, ["打卡", "签到", "check in", "checkin", "done"]) {
            let content = extractHabitContent(from: original)
            return (.checkin, content)
        }
        // List
        if containsAny(lower, ["我的习惯", "习惯列表", "哪些习惯", "list", "habits", "查看习惯"]) {
            return (.list, "")
        }
        // Default: list
        return (.list, "")
    }

    private static func extractHabitContent(from text: String) -> String {
        let delimiters = ["：", ":", "——", "—", "- "]
        for delim in delimiters {
            if let range = text.range(of: delim) {
                let content = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !content.isEmpty { return content }
            }
        }
        let prefixes = ["创建习惯", "新习惯", "添加习惯", "追踪习惯", "删除习惯", "去掉习惯",
                        "打卡", "签到", "习惯统计", "习惯数据",
                        "create habit", "new habit", "track habit",
                        "delete habit", "remove habit", "check in"]
        let lower = text.lowercased()
        for prefix in prefixes {
            if let range = lower.range(of: prefix) {
                let content = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !content.isEmpty { return content }
            }
        }
        return ""
    }

    // MARK: - Greeting Parsing

    /// Detects conversational greetings. Uses a length cap to avoid matching longer queries
    /// that happen to contain a greeting word (e.g., "你好，帮我总结这周运动").
    private static func parseLunarCalendar(_ text: String) -> LunarCalendarQuery? {
        let hasLunar = containsAny(text, ["农历", "阴历", "黄历", "老历", "旧历", "lunar"])
        let hasSolarTerm = containsAny(text, ["节气", "solar term", "二十四节气"])
        let hasZodiac = containsAny(text, ["生肖", "属什么", "属啥", "zodiac", "什么年"])

        // Solar term query
        if hasSolarTerm {
            return .solarTerm
        }

        // Zodiac query
        if hasZodiac {
            return .zodiac
        }

        // Lunar calendar with detail keywords → full info
        if hasLunar && containsAny(text, ["万年历", "详细", "全部", "所有", "complete"]) {
            return .fullInfo
        }

        // General lunar calendar query
        if hasLunar {
            return .today
        }

        // "今天什么日子" could trigger lunar calendar
        if containsAny(text, ["什么日子"]) && containsAny(text, ["今天", "today"]) {
            return .fullInfo
        }

        return nil
    }

    private static func parseGreeting(_ trimmed: String) -> GreetingType? {
        // Only match short messages (≤15 chars) to avoid false positives
        guard trimmed.count <= 15 else { return nil }

        // Self-intro: "你是谁", "who are you"
        if containsAny(trimmed, ["你是谁", "你叫什么", "who are you", "what are you", "介绍一下你自己"]) {
            return .selfIntro
        }
        // How are you: "你好吗", "你怎么样"
        if containsAny(trimmed, ["你好吗", "你怎么样", "how are you", "你还好吗"]) {
            return .howAreYou
        }
        // Thanks
        if containsAny(trimmed, ["谢谢", "感谢", "多谢", "thank", "thanks", "thx"]) {
            return .thanks
        }
        // Farewell
        if containsAny(trimmed, ["拜拜", "再见", "回头见", "下次见", "晚安", "bye", "goodbye",
                                   "good night", "see you", "gn"]) {
            return .farewell
        }
        // Presence
        if containsAny(trimmed, ["在吗", "在不在", "你在吗", "are you there", "hello?", "你在不在"]) {
            return .presence
        }
        // Hello (check last to avoid matching "你好吗" as hello)
        if containsAny(trimmed, ["你好", "嗨", "哈喽", "hello", "hey", "hi", "嘿",
                                   "早上好", "下午好", "晚上好", "早安", "午安",
                                   "good morning", "good afternoon", "good evening"]) {
            return .hello
        }
        return nil
    }

    // MARK: - Random Decision Parsing

    private static func parseRandomDecision(_ trimmed: String, original: String) -> RandomDecisionAction? {
        let lower = trimmed

        // Coin flip
        if containsAny(lower, ["抛硬币", "丢硬币", "翻硬币", "flip coin", "coin flip", "flip a coin", "toss a coin", "toss coin"]) {
            return .coinFlip
        }

        // Dice roll
        if containsAny(lower, ["掷骰子", "丢骰子", "扔骰子", "roll dice", "roll a dice", "throw dice"]) {
            // Check for custom sides: "掷20面骰子", "roll a d20"
            let sides = extractDiceSides(from: lower)
            return .diceRoll(sides: sides)
        }

        // Pick one from options: "帮我选 A还是B还是C" or "帮我选 A或B或C"
        if containsAny(lower, ["帮我选", "帮我挑", "帮忙选", "帮忙挑", "随便选", "随机选",
                                "pick one", "choose one", "choose for me", "pick for me",
                                "选一个", "挑一个", "帮我决定"]) {
            let options = extractOptions(from: original)
            return .pickOne(options: options)
        }

        // Random number: "随机数字", "随机数 1到100"
        if containsAny(lower, ["随机数", "random number", "随机一个数", "给我一个数字"]) {
            let (min, max) = extractNumberRange(from: lower)
            return .randomNumber(min: min, max: max)
        }

        return nil
    }

    private static func extractDiceSides(from text: String) -> Int {
        // Match patterns like "20面", "d20", "12面骰"
        let patterns = [
            try? NSRegularExpression(pattern: "(\\d+)\\s*面", options: []),
            try? NSRegularExpression(pattern: "d(\\d+)", options: .caseInsensitive)
        ]
        let nsText = text as NSString
        for regex in patterns.compactMap({ $0 }) {
            if let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: nsText.length)) {
                if match.numberOfRanges > 1 {
                    let numStr = nsText.substring(with: match.range(at: 1))
                    if let sides = Int(numStr), sides >= 2 { return sides }
                }
            }
        }
        return 6 // default 6-sided die
    }

    private static func extractOptions(from text: String) -> [String] {
        // Remove common prefix phrases
        var cleaned = text
        let prefixes = ["帮我选", "帮我挑", "帮忙选", "帮忙挑", "随便选", "随机选",
                        "选一个", "挑一个", "帮我决定",
                        "pick one", "choose one", "choose for me", "pick for me"]
        for prefix in prefixes {
            if let range = cleaned.lowercased().range(of: prefix) {
                cleaned = String(cleaned[range.upperBound...])
                break
            }
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        // Remove leading punctuation
        cleaned = cleaned.replacingOccurrences(of: "^[：:，, ]+", with: "", options: .regularExpression)

        // Split by "还是", "或者", "或", ",", "、", " or "
        let separators = ["还是", "或者", " or ", "、", "，", ","]
        var options: [String] = [cleaned]
        for sep in separators {
            let split = options.flatMap { $0.components(separatedBy: sep) }
            if split.count > options.count {
                options = split
                break
            }
        }

        return options
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func extractNumberRange(from text: String) -> (Int, Int) {
        // Match "1到100", "1-100", "1~100", "between 1 and 100"
        let patterns = [
            try? NSRegularExpression(pattern: "(\\d+)\\s*[到至~\\-]+\\s*(\\d+)", options: []),
            try? NSRegularExpression(pattern: "between\\s+(\\d+)\\s+and\\s+(\\d+)", options: .caseInsensitive)
        ]
        let nsText = text as NSString
        for regex in patterns.compactMap({ $0 }) {
            if let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: nsText.length)) {
                if match.numberOfRanges > 2 {
                    let minStr = nsText.substring(with: match.range(at: 1))
                    let maxStr = nsText.substring(with: match.range(at: 2))
                    if let lo = Int(minStr), let hi = Int(maxStr) {
                        return (lo, hi)
                    }
                }
            }
        }
        return (1, 100) // default range
    }

    // MARK: - Date/Time Parsing

    private static func parseDateTimeQuery(_ text: String) -> DateTimeQuery? {
        // Week number
        if containsAny(text, ["第几周", "周数", "week number", "哪一周", "今年第几周"]) {
            return .weekNumber
        }
        // Day of week
        if containsAny(text, ["星期几", "周几", "礼拜几", "what day"]) {
            return .dayOfWeek
        }
        // Current time
        if containsAny(text, ["几点", "什么时间", "几时", "what time", "现在时间", "时间是"]) {
            return .currentTime
        }
        // Current date
        if containsAny(text, ["几号", "几月几号", "什么日期", "today's date", "今天日期", "哪一天"]) {
            return .currentDate
        }
        // General "now" queries
        if containsAny(text, ["现在", "此刻"]) &&
           containsAny(text, ["时间", "日期", "多少号", "time", "date"]) {
            return .fullInfo
        }
        return nil
    }

    // MARK: - Math Expression Parsing

    /// Detects math/calculator requests and extracts the arithmetic expression.
    private static func parseMathExpression(_ lower: String, original: String) -> String? {
        // Explicit "calculate" keywords
        if containsAny(lower, ["计算", "算一下", "算下", "等于多少", "等于几", "是多少",
                                "calculate", "compute", "多少钱", "总共多少",
                                "加上", "减去", "乘以", "除以"]) {
            let expr = extractMathExpr(from: original)
            if !expr.isEmpty { return expr }
        }

        // Pure math expression detection: starts with digit or paren, contains operators
        let stripped = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        if looksLikeMathExpression(stripped) {
            return stripped
        }

        // "X + Y = ?" or "X * Y" patterns embedded in text
        if let regex = try? NSRegularExpression(
            pattern: "\\d+[\\s]*([\\.\\d]*[\\s]*[+\\-×÷*/xX%^])+[\\s]*[\\.\\d]+",
            options: []
        ) {
            let ns = original as NSString
            if let match = regex.firstMatch(in: original, options: [],
                                             range: NSRange(location: 0, length: ns.length)) {
                return ns.substring(with: match.range)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return nil
    }

    /// Check if a string looks like a standalone math expression (e.g. "3+5", "(2+3)*4").
    private static func looksLikeMathExpression(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        // Must start with digit, paren, or minus sign
        guard let first = text.unicodeScalars.first,
              CharacterSet.decimalDigits.contains(first) || first == "(" || first == "-" else {
            return false
        }
        // Must contain at least one operator
        let operators: [Character] = ["+", "-", "*", "/", "×", "÷", "^", "%"]
        let hasOperator = text.contains { operators.contains($0) }
        guard hasOperator else { return false }
        // Should be relatively short and mostly math characters
        let mathChars = CharacterSet.decimalDigits
            .union(CharacterSet(charactersIn: "+-*/×÷^%().= ?xX"))
            .union(.whitespaces)
        let allMath = text.unicodeScalars.allSatisfy { mathChars.contains($0) }
        return allMath && text.count <= 80
    }

    /// Extract math expression from a natural language query.
    private static func extractMathExpr(from text: String) -> String {
        var cleaned = text
        let prefixes = ["计算", "算一下", "算下", "帮我算", "请计算", "calculate", "compute",
                        "帮我计算", "你帮我算", "请帮我算"]
        for prefix in prefixes {
            if let range = cleaned.lowercased().range(of: prefix) {
                cleaned = String(cleaned[range.upperBound...])
                break
            }
        }
        // Remove trailing question markers
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.replacingOccurrences(of: "[？?等于多少是几=]+$", with: "", options: .regularExpression)
        cleaned = cleaned.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "：:，,")))
        return cleaned
    }

    // MARK: - Water Tracking Parsing

    private static func parseWaterTrack(_ lower: String, original: String) -> QueryIntent? {
        // Must contain water-related keywords
        guard containsAny(lower, ["喝水", "喝了水", "杯水", "水量", "饮水", "补水",
                                    "drink water", "water intake", "drank water",
                                    "hydrat", "glasses of water"]) else {
            return nil
        }

        // Set goal
        if containsAny(lower, ["目标", "设置", "设定", "goal", "set"]) {
            let amount = extractWaterAmount(from: lower)
            return .waterTrack(action: .goal, amount: amount)
        }

        // History / weekly
        if containsAny(lower, ["本周", "这周", "一周", "历史", "记录", "统计",
                                "week", "history", "stats", "report"]) {
            return .waterTrack(action: .history, amount: 0)
        }

        // Today's summary
        if containsAny(lower, ["今天", "today", "多少", "几杯", "how much", "how many"]) {
            return .waterTrack(action: .today, amount: 0)
        }

        // Record drinking — default action
        if containsAny(lower, ["喝了", "喝水", "drank", "drink", "补水", "一杯", "两杯", "三杯"]) {
            let amount = extractWaterAmount(from: lower)
            return .waterTrack(action: .drink, amount: max(1, amount))
        }

        // Fallback: show today's summary
        return .waterTrack(action: .today, amount: 0)
    }

    private static func extractWaterAmount(from text: String) -> Int {
        // Chinese number words
        let chineseNumbers: [(String, Int)] = [
            ("十", 10), ("九", 9), ("八", 8), ("七", 7), ("六", 6),
            ("五", 5), ("四", 4), ("三", 3), ("两", 2), ("二", 2), ("一", 1), ("半", 0)
        ]
        for (word, num) in chineseNumbers {
            if text.contains(word) && containsAny(text, ["杯", "cup", "glass"]) {
                return num
            }
        }

        // Digit extraction: "3杯", "500ml"
        if let regex = try? NSRegularExpression(pattern: "(\\d+)\\s*(杯|cup|glass|ml|毫升)", options: []),
           let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length)) {
            let numStr = (text as NSString).substring(with: match.range(at: 1))
            let unit = (text as NSString).substring(with: match.range(at: 2))
            if let num = Int(numStr) {
                // Convert ml to cups (1 cup ≈ 250ml)
                if unit == "ml" || unit == "毫升" {
                    return max(1, num / 250)
                }
                return num
            }
        }

        // Plain number in text
        if let regex = try? NSRegularExpression(pattern: "(\\d+)", options: []),
           let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length)) {
            let numStr = (text as NSString).substring(with: match.range(at: 1))
            if let num = Int(numStr), num >= 1, num <= 20 { return num }
        }

        return 1
    }

    // MARK: - Helpers

    // MARK: - Unit Conversion Parsing

    /// Detects unit conversion queries like "25摄氏度转华氏", "10kg转磅", "5 miles to km"
    private static func parseUnitConversion(_ text: String) -> (Double, String, String)? {
        // Check if text contains conversion keywords
        guard containsAny(text, ["转换", "转", "换算", "等于多少", "是多少", "convert", "to ",
                                  "摄氏", "华氏", "℃", "℉", "celsius", "fahrenheit",
                                  "公里", "英里", "千米", "km", "mile",
                                  "公斤", "千克", "磅", "kg", "lb", "pound",
                                  "厘米", "英寸", "cm", "inch",
                                  "米转", "米是", "英尺", "feet", "foot", "ft",
                                  "升", "加仑", "liter", "gallon",
                                  "克转", "克是", "盎司", "gram", "ounce", "oz"]) else { return nil }

        // Extract number from text
        guard let regex = try? NSRegularExpression(pattern: "([\\d]+\\.?[\\d]*)", options: []),
              let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length)) else {
            return nil
        }
        let numStr = (text as NSString).substring(with: match.range(at: 1))
        guard let value = Double(numStr) else { return nil }

        // Temperature
        if containsAny(text, ["摄氏", "℃", "celsius", "°c"]) &&
           containsAny(text, ["华氏", "℉", "fahrenheit", "°f", "转", "to ", "换", "等于"]) {
            return (value, "celsius", "fahrenheit")
        }
        if containsAny(text, ["华氏", "℉", "fahrenheit", "°f"]) &&
           containsAny(text, ["摄氏", "℃", "celsius", "°c", "转", "to ", "换", "等于"]) {
            return (value, "fahrenheit", "celsius")
        }

        // Length: km ↔ miles
        if containsAny(text, ["公里", "千米", "km", "kilometer"]) &&
           containsAny(text, ["英里", "mile", "转", "to ", "换"]) {
            return (value, "km", "miles")
        }
        if containsAny(text, ["英里", "mile"]) &&
           containsAny(text, ["公里", "千米", "km", "kilometer", "转", "to ", "换"]) {
            return (value, "miles", "km")
        }

        // Length: cm ↔ inches
        if containsAny(text, ["厘米", "cm", "centimeter"]) &&
           containsAny(text, ["英寸", "inch", "转", "to ", "换"]) {
            return (value, "cm", "inches")
        }
        if containsAny(text, ["英寸", "inch"]) &&
           containsAny(text, ["厘米", "cm", "centimeter", "转", "to ", "换"]) {
            return (value, "inches", "cm")
        }

        // Length: m ↔ feet
        if containsAny(text, ["米", "m "]) && !containsAny(text, ["公里", "千米", "厘米", "km", "cm"]) &&
           containsAny(text, ["英尺", "feet", "foot", "ft", "转", "to "]) {
            return (value, "meters", "feet")
        }
        if containsAny(text, ["英尺", "feet", "foot", "ft"]) &&
           containsAny(text, ["米", "m", "转", "to ", "换"]) && !containsAny(text, ["公里", "千米", "km"]) {
            return (value, "feet", "meters")
        }

        // Weight: kg ↔ lbs
        if containsAny(text, ["公斤", "千克", "kg", "kilogram"]) &&
           containsAny(text, ["磅", "lb", "pound", "转", "to ", "换"]) {
            return (value, "kg", "lbs")
        }
        if containsAny(text, ["磅", "lb", "pound"]) &&
           containsAny(text, ["公斤", "千克", "kg", "kilogram", "转", "to ", "换"]) {
            return (value, "lbs", "kg")
        }

        // Weight: g ↔ oz
        if containsAny(text, ["克", "gram", "g "]) && !containsAny(text, ["公斤", "千克", "kg"]) &&
           containsAny(text, ["盎司", "oz", "ounce", "转", "to "]) {
            return (value, "grams", "oz")
        }
        if containsAny(text, ["盎司", "oz", "ounce"]) &&
           containsAny(text, ["克", "gram", "g", "转", "to ", "换"]) {
            return (value, "oz", "grams")
        }

        // Volume: L ↔ gallons
        if containsAny(text, ["升", "liter", "litre"]) &&
           containsAny(text, ["加仑", "gallon", "转", "to ", "换"]) {
            return (value, "liters", "gallons")
        }
        if containsAny(text, ["加仑", "gallon"]) &&
           containsAny(text, ["升", "liter", "litre", "转", "to ", "换"]) {
            return (value, "gallons", "liters")
        }

        return nil
    }

    // MARK: - Breathing Parsing

    /// Detects breathing exercise / relaxation queries.
    private static func parseBreathing(_ text: String) -> BreathingType? {
        guard containsAny(text, ["呼吸", "深呼吸", "冥想", "放松", "静心", "减压", "缓解压力",
                                   "breathing", "breathe", "meditat", "relax", "calm down",
                                   "焦虑", "紧张", "anxiety", "stress relief"]) else {
            return nil
        }

        // 4-7-8 technique
        if containsAny(text, ["478", "4-7-8", "四七八"]) {
            return .calm478
        }
        // Box breathing
        if containsAny(text, ["box", "方块", "箱式", "4444", "4-4-4-4"]) {
            return .boxBreathing
        }
        // Sleep aid
        if containsAny(text, ["睡前", "助眠", "睡不着", "失眠", "sleep", "insomnia", "入睡"]) {
            return .sleepAid
        }
        // Energize
        if containsAny(text, ["提神", "清醒", "精神", "energi", "wake up", "活力"]) {
            return .energize
        }
        // Deep breath (specific request)
        if containsAny(text, ["深呼吸", "deep breath"]) {
            return .deepBreath
        }
        // If they mention relaxation/calm keywords
        if containsAny(text, ["放松", "静心", "减压", "calm", "relax", "缓解", "焦虑", "紧张", "anxiety", "stress"]) {
            return .calm478
        }
        // General breathing / meditation → show overview
        if containsAny(text, ["呼吸", "冥想", "breathing", "meditat"]) {
            return .overview
        }

        return .overview
    }

    // MARK: - BMI Parsing

    /// Detects BMI calculation queries and extracts height (cm) and weight (kg).
    /// Supports patterns like:
    /// - "我身高175体重70", "身高165cm 体重55kg"
    /// - "BMI 180 75", "calculate bmi height 170 weight 65"
    /// - "175cm 70kg bmi"
    private static func parseBMI(_ lower: String, original: String) -> (Double, Double)? {
        // Must contain BMI-related keywords
        guard containsAny(lower, ["bmi", "体质指数", "体重指数", "身体质量",
                                    "身高.*体重", "体重.*身高"]) ||
              (containsAny(lower, ["身高"]) && containsAny(lower, ["体重"])) else {
            return nil
        }

        var height: Double = 0
        var weight: Double = 0
        let nsText = original as NSString

        // Pattern 1: "身高175体重70" or "身高175cm体重70kg"
        if let regex = try? NSRegularExpression(
            pattern: "身高\\s*([\\d.]+)\\s*(cm|厘米|公分)?\\s*[，,]?\\s*体重\\s*([\\d.]+)\\s*(kg|公斤|千克|斤)?",
            options: .caseInsensitive
        ), let match = regex.firstMatch(in: original, options: [], range: NSRange(location: 0, length: nsText.length)),
           match.numberOfRanges >= 4 {
            let hStr = nsText.substring(with: match.range(at: 1))
            let wStr = nsText.substring(with: match.range(at: 3))
            if let h = Double(hStr), let w = Double(wStr) {
                height = h
                weight = w
                // Check if weight unit is 斤 (jin, half-kg)
                if match.numberOfRanges >= 5 {
                    let wUnit = nsText.substring(with: match.range(at: 4))
                    if wUnit == "斤" { weight = w / 2.0 }
                }
            }
        }

        // Pattern 2: "体重70身高175" (reversed order)
        if height == 0 || weight == 0 {
            if let regex = try? NSRegularExpression(
                pattern: "体重\\s*([\\d.]+)\\s*(kg|公斤|千克|斤)?\\s*[，,]?\\s*身高\\s*([\\d.]+)\\s*(cm|厘米|公分)?",
                options: .caseInsensitive
            ), let match = regex.firstMatch(in: original, options: [], range: NSRange(location: 0, length: nsText.length)),
               match.numberOfRanges >= 4 {
                let wStr = nsText.substring(with: match.range(at: 1))
                let hStr = nsText.substring(with: match.range(at: 3))
                if let h = Double(hStr), let w = Double(wStr) {
                    height = h
                    weight = w
                    if match.numberOfRanges >= 3 {
                        let wUnit = nsText.substring(with: match.range(at: 2))
                        if wUnit == "斤" { weight = w / 2.0 }
                    }
                }
            }
        }

        // Pattern 3: "bmi 175 70" or "BMI 180 75" (two numbers after BMI keyword)
        if height == 0 || weight == 0 {
            if let regex = try? NSRegularExpression(
                pattern: "bmi\\s+([\\d.]+)\\s+([\\d.]+)",
                options: .caseInsensitive
            ), let match = regex.firstMatch(in: original, options: [], range: NSRange(location: 0, length: nsText.length)),
               match.numberOfRanges >= 3 {
                let num1Str = nsText.substring(with: match.range(at: 1))
                let num2Str = nsText.substring(with: match.range(at: 2))
                if let n1 = Double(num1Str), let n2 = Double(num2Str) {
                    // Heuristic: larger number is height (cm), smaller is weight (kg)
                    if n1 > n2 {
                        height = n1; weight = n2
                    } else {
                        height = n2; weight = n1
                    }
                }
            }
        }

        // Pattern 4: "height 170 weight 65" or "170cm 65kg"
        if height == 0 || weight == 0 {
            if let regex = try? NSRegularExpression(
                pattern: "([\\d.]+)\\s*cm\\s+([\\d.]+)\\s*kg",
                options: .caseInsensitive
            ), let match = regex.firstMatch(in: original, options: [], range: NSRange(location: 0, length: nsText.length)),
               match.numberOfRanges >= 3 {
                let hStr = nsText.substring(with: match.range(at: 1))
                let wStr = nsText.substring(with: match.range(at: 2))
                if let h = Double(hStr), let w = Double(wStr) {
                    height = h; weight = w
                }
            }
        }

        // Pattern 5: English "height X weight Y"
        if height == 0 || weight == 0 {
            if let regex = try? NSRegularExpression(
                pattern: "height\\s*([\\d.]+)\\s*(?:cm)?\\s*weight\\s*([\\d.]+)\\s*(?:kg)?",
                options: .caseInsensitive
            ), let match = regex.firstMatch(in: original, options: [], range: NSRange(location: 0, length: nsText.length)),
               match.numberOfRanges >= 3 {
                let hStr = nsText.substring(with: match.range(at: 1))
                let wStr = nsText.substring(with: match.range(at: 2))
                if let h = Double(hStr), let w = Double(wStr) {
                    height = h; weight = w
                }
            }
        }

        // If height looks like meters (e.g. 1.75), convert to cm
        if height > 0 && height < 3.0 {
            height = height * 100
        }

        // Return 0,0 if we couldn't parse (skill will show usage hint)
        if height == 0 && weight == 0 {
            // Keyword matched but no numbers — show usage hint
            return (0, 0)
        }

        return (height, weight)
    }

    // MARK: - Sleep Calculator Parser

    private static func parseSleepCalc(_ text: String) -> SleepCalcQuery? {
        let sleepKeywords = ["睡眠计算", "睡眠周期", "几点睡", "几点起", "什么时候睡",
                             "什么时候起", "几点入睡", "几点醒", "几点起床",
                             "sleep calc", "sleep cycle", "when to sleep", "when to wake",
                             "现在睡", "打算睡", "想睡", "要睡"]

        guard containsAny(text, sleepKeywords) else { return nil }

        // Try to extract a time from the text
        let (hour, minute) = extractTimeFromText(text)

        // Determine direction: bedtime (given wake time) or wake time (given sleep time)
        let wantBedtime = containsAny(text, ["几点睡", "什么时候睡", "几点入睡", "when to sleep",
                                              "要几点睡", "应该几点睡"])
        let wantWakeTime = containsAny(text, ["几点起", "几点醒", "几点起床", "什么时候起",
                                               "when to wake", "现在睡", "打算睡", "想睡", "要睡"])

        if let h = hour {
            let m = minute ?? 0
            if wantBedtime {
                // "我想7点起床，几点睡" → bedtime for wake=7:00
                return .bedtimeFor(wakeHour: h, wakeMin: m)
            } else if wantWakeTime {
                // "我打算11点睡，几点起" → wake time for sleep=23:00
                return .wakeTimeFor(sleepHour: h, sleepMin: m)
            }
            // Ambiguous with time: guess from the hour value
            // If hour >= 18 or hour <= 2, likely a bedtime → compute wake times
            // If hour >= 5 and hour <= 12, likely a wake time → compute bedtimes
            if h >= 18 || h <= 2 {
                return .wakeTimeFor(sleepHour: h, sleepMin: m)
            } else if h >= 5 && h <= 12 {
                return .bedtimeFor(wakeHour: h, wakeMin: m)
            }
            // Default: treat as wake time target
            return .bedtimeFor(wakeHour: h, wakeMin: m)
        }

        // "现在睡几点起" — no specific time, use current time as bedtime
        if wantWakeTime {
            let cal = Calendar.current
            let now = Date()
            return .wakeTimeFor(sleepHour: cal.component(.hour, from: now),
                                sleepMin: cal.component(.minute, from: now))
        }

        return .overview
    }

    /// Extract hour (and optional minute) from natural language time expressions.
    private static func extractTimeFromText(_ text: String) -> (Int?, Int?) {
        let nsText = text as NSString

        // Pattern: "7点半" "7点30" "7:30" "23点" "11点"
        // Chinese: X点Y分, X点半, X点
        if let regex = try? NSRegularExpression(
            pattern: "(\\d{1,2})[点时:：](\\d{1,2}|半)?\\s*(?:分)?",
            options: []
        ), let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: nsText.length)),
           match.numberOfRanges >= 2 {
            let hourStr = nsText.substring(with: match.range(at: 1))
            if let h = Int(hourStr), h >= 0, h <= 23 {
                var minute: Int? = nil
                if match.numberOfRanges >= 3, match.range(at: 2).location != NSNotFound {
                    let minStr = nsText.substring(with: match.range(at: 2))
                    if minStr == "半" {
                        minute = 30
                    } else if let m = Int(minStr), m >= 0, m <= 59 {
                        minute = m
                    }
                }
                return (h, minute)
            }
        }

        // Pattern: bare number in sleep context, e.g., "6点起床" already matched above
        // Try "早上7点", "晚上11点" — the digit part
        if let regex = try? NSRegularExpression(
            pattern: "(?:早上|上午|中午|下午|晚上|深夜|凌晨)\\s*(\\d{1,2})",
            options: []
        ), let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: nsText.length)),
           match.numberOfRanges >= 2 {
            let hourStr = nsText.substring(with: match.range(at: 1))
            if let h = Int(hourStr) {
                // Adjust for period
                var adjusted = h
                if text.contains("下午") || text.contains("晚上") {
                    if h >= 1 && h <= 12 { adjusted = (h == 12) ? 12 : h + 12 }
                } else if text.contains("凌晨") || text.contains("深夜") {
                    if h == 12 { adjusted = 0 }
                }
                if adjusted >= 0 && adjusted <= 23 {
                    return (adjusted, nil)
                }
            }
        }

        return (nil, nil)
    }

    // MARK: - Password Generator Parser

    private static func parsePasswordGen(_ text: String) -> PasswordGenType? {
        let pwdKeywords = ["密码", "password", "passwd", "口令", "pin码", "pin code",
                           "验证码", "生成密码", "随机密码", "安全密码"]
        guard containsAny(text, pwdKeywords) else { return nil }

        // PIN code
        if containsAny(text, ["pin码", "pin code", "pin", "数字密码", "数字码", "纯数字"]) {
            let digits = extractNumber(from: text) ?? 6
            return .pin(digits: digits)
        }

        // Memorable / easy to remember
        if containsAny(text, ["好记", "易记", "容易记", "memorable", "easy to remember", "记得住"]) {
            return .memorable
        }

        // Strong password
        if containsAny(text, ["强密码", "安全密码", "复杂密码", "strong", "secure", "特殊字符"]) {
            let length = extractNumber(from: text) ?? 16
            return .strong(length: length)
        }

        // Standard with optional custom length
        if containsAny(text, ["生成", "创建", "给我", "来个", "来一个", "generate", "create", "make"]) {
            let length = extractNumber(from: text) ?? 12
            return .standard(length: length)
        }

        // Generic "密码" mention — show overview
        return .overview
    }

    /// Extract the first integer from text (for password length, PIN digits, etc.)
    private static func extractNumber(from text: String) -> Int? {
        let nsText = text as NSString
        guard let regex = try? NSRegularExpression(pattern: "(\\d+)", options: []),
              let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: nsText.length)),
              match.numberOfRanges >= 2 else {
            return nil
        }
        return Int(nsText.substring(with: match.range(at: 1)))
    }

    // MARK: - Pomodoro Parsing

    private static func parsePomodoro(_ lower: String, original: String) -> QueryIntent? {
        guard containsAny(lower, ["番茄", "pomodoro", "专注", "focus", "番茄钟",
                                    "专注时间", "focus session", "集中精力",
                                    "专注了", "专注完"]) else { return nil }

        // Set goal
        if containsAny(lower, ["目标", "设置", "设定", "goal", "set"]) {
            let sessions = extractNumber(from: lower) ?? 0
            return .pomodoro(action: .goal(sessions: sessions))
        }

        // History / weekly
        if containsAny(lower, ["本周", "这周", "一周", "历史", "统计", "报告",
                                "week", "history", "stats", "report"]) {
            return .pomodoro(action: .history)
        }

        // Today's summary
        if containsAny(lower, ["今天", "today", "多少", "几个", "how many", "进度"]) {
            return .pomodoro(action: .today)
        }

        // Record completed session — default action
        if containsAny(lower, ["完成", "做完", "结束", "done", "finish", "complete",
                                "开始", "start", "记录", "记一个", "打卡",
                                "专注了", "专注完"]) {
            let minutes = extractPomodoroMinutes(from: lower)
            return .pomodoro(action: .start(minutes: minutes))
        }

        // Fallback: show today's summary
        return .pomodoro(action: .today)
    }

    private static func extractPomodoroMinutes(from text: String) -> Int {
        // Match "25分钟", "50min", "30分", "45 minutes"
        let nsText = text as NSString
        if let regex = try? NSRegularExpression(
            pattern: "(\\d+)\\s*(?:分钟|分|min|minutes|minute)",
            options: .caseInsensitive
        ), let match = regex.firstMatch(in: text, options: [],
                                         range: NSRange(location: 0, length: nsText.length)),
           match.numberOfRanges >= 2 {
            let numStr = nsText.substring(with: match.range(at: 1))
            if let n = Int(numStr), n >= 1, n <= 240 { return n }
        }
        return 25 // default pomodoro length
    }

    // MARK: - Expense Parsing

    private static func parseExpense(_ lower: String, original: String) -> QueryIntent? {
        let expenseKeywords = ["记账", "记一笔", "花了", "消费", "支出", "开销", "花费",
                               "账单", "花销", "记笔账", "收支", "expense", "spent",
                               "spending", "cost", "pay", "paid"]

        guard containsAny(lower, expenseKeywords) else { return nil }

        // Delete last entry
        if containsAny(lower, ["删除", "撤销", "取消", "撤回", "delete", "undo", "remove"]) {
            return .expense(action: .delete, amount: 0, category: "", note: "")
        }

        // Monthly summary
        if containsAny(lower, ["本月", "这个月", "月消费", "月支出", "月账单", "this month", "monthly"]) {
            return .expense(action: .month, amount: 0, category: "", note: "")
        }

        // Weekly summary
        if containsAny(lower, ["本周", "这周", "周消费", "周支出", "this week", "weekly"]) {
            return .expense(action: .week, amount: 0, category: "", note: "")
        }

        // Today's summary
        if containsAny(lower, ["今天花了多少", "今天消费", "今天支出", "今天开销", "today"]) &&
           !containsAny(lower, ["记一笔", "记账", "花了.*元", "花了.*块"]) {
            return .expense(action: .today, amount: 0, category: "", note: "")
        }

        // List records
        if containsAny(lower, ["消费记录", "账单记录", "消费列表", "开销列表", "查看消费",
                                "查看账单", "查看开销", "list expense", "expense list"]) {
            return .expense(action: .list, amount: 0, category: "", note: "")
        }

        // Add expense — extract amount, category, note
        let amount = extractExpenseAmount(from: lower)
        let category = extractExpenseCategory(from: lower)
        let note = extractExpenseNote(from: original, lower: lower)

        if amount > 0 {
            return .expense(action: .add, amount: amount, category: category, note: note)
        }

        // If keywords match but no amount: show today summary
        if containsAny(lower, ["花了多少", "消费多少", "多少钱", "how much"]) {
            return .expense(action: .today, amount: 0, category: "", note: "")
        }

        // Default: show today's summary
        return .expense(action: .today, amount: 0, category: "", note: "")
    }

    private static func extractExpenseAmount(from text: String) -> Double {
        let nsText = text as NSString
        // Match patterns: "35元", "35块", "35.5元", "$35", "¥100", "100元钱"
        let patterns = [
            "([\\d]+\\.?[\\d]*)\\s*(?:元|块|块钱|元钱|rmb|¥|yuan)",
            "(?:¥|\\$|￥)\\s*([\\d]+\\.?[\\d]*)",
            "(?:花了|花费|消费|支出|spent|paid|cost)\\s*([\\d]+\\.?[\\d]*)",
            "([\\d]+\\.?[\\d]*)\\s*(?:dollar|dollars|usd)"
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: nsText.length)),
               match.numberOfRanges >= 2 {
                let numStr = nsText.substring(with: match.range(at: 1))
                if let num = Double(numStr), num > 0 { return num }
            }
        }
        return 0
    }

    private static func extractExpenseCategory(from text: String) -> String {
        // Food / dining
        if containsAny(text, ["早餐", "午餐", "晚餐", "吃饭", "外卖", "饭", "餐", "食",
                               "零食", "奶茶", "咖啡", "水果", "买菜", "超市",
                               "breakfast", "lunch", "dinner", "food", "meal", "coffee", "tea"]) {
            return "餐饮"
        }
        // Transport
        if containsAny(text, ["打车", "出租", "地铁", "公交", "加油", "油费", "停车", "交通",
                               "uber", "taxi", "transport", "gas", "parking", "bus", "subway"]) {
            return "交通"
        }
        // Shopping
        if containsAny(text, ["买了", "购物", "网购", "衣服", "鞋", "包", "化妆品",
                               "shopping", "bought", "purchase", "clothes"]) {
            return "购物"
        }
        // Entertainment
        if containsAny(text, ["电影", "游戏", "ktv", "娱乐", "门票", "旅游", "酒店",
                               "movie", "game", "entertainment", "hotel", "travel"]) {
            return "娱乐"
        }
        // Medical
        if containsAny(text, ["医院", "药", "看病", "挂号", "体检", "医疗",
                               "hospital", "medicine", "medical", "doctor"]) {
            return "医疗"
        }
        // Education
        if containsAny(text, ["书", "课", "学费", "培训", "教育",
                               "book", "course", "education", "tuition"]) {
            return "教育"
        }
        // Housing
        if containsAny(text, ["房租", "水电", "物业", "维修", "家具",
                               "rent", "utility", "maintenance"]) {
            return "居住"
        }
        return "其他"
    }

    private static func extractExpenseNote(from original: String, lower: String) -> String {
        // Try to extract a meaningful note after common keywords
        let prefixes = ["记一笔", "记账", "花了", "消费", "支出", "花费"]
        for prefix in prefixes {
            if let range = lower.range(of: prefix) {
                let after = String(original[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                // Remove amount patterns and return the rest as note
                let cleaned = after.replacingOccurrences(
                    of: "[\\d]+\\.?[\\d]*\\s*(?:元|块|块钱|元钱|rmb|¥)",
                    with: "",
                    options: .regularExpression
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "，,。.、"))
                if !cleaned.isEmpty { return cleaned }
            }
        }
        return ""
    }

    // MARK: - Reminder Parsing

    /// Detects timed reminder requests like "提醒我5分钟后喝水", "30分钟后提醒我开会",
    /// "1小时后提醒我", "半小时后提醒我吃药", "remind me in 10 minutes to drink water"
    private static func parseReminder(_ lower: String, original: String) -> QueryIntent? {
        // Must contain reminder keyword AND a time expression
        let hasReminderKeyword = containsAny(lower, ["提醒我", "提醒一下", "定个提醒", "设个提醒",
                                                       "闹钟", "定时", "remind me", "set a reminder",
                                                       "set reminder", "alarm"])

        // List reminders
        if hasReminderKeyword && containsAny(lower, ["查看提醒", "提醒列表", "有什么提醒",
                                                       "哪些提醒", "list reminder", "my reminder",
                                                       "查看闹钟", "闹钟列表"]) {
            return .reminder(action: .list)
        }

        // Clear reminders
        if hasReminderKeyword && containsAny(lower, ["清除提醒", "取消提醒", "删除提醒",
                                                       "清除闹钟", "取消闹钟", "删除闹钟",
                                                       "cancel reminder", "clear reminder",
                                                       "delete reminder"]) {
            return .reminder(action: .clear)
        }

        guard hasReminderKeyword else { return nil }

        // Try to extract time delay (in minutes)
        let nsText = lower as NSString
        var minutes: Int?

        // Pattern: "X分钟后" / "X分钟以后" / "X分钟之后"
        if let regex = try? NSRegularExpression(
            pattern: "(\\d+)\\s*分钟\\s*(?:后|以后|之后)?",
            options: []
        ), let match = regex.firstMatch(in: lower, options: [],
                                         range: NSRange(location: 0, length: nsText.length)),
           match.numberOfRanges >= 2 {
            let numStr = nsText.substring(with: match.range(at: 1))
            if let n = Int(numStr), n >= 1, n <= 1440 { minutes = n }
        }

        // Pattern: "X小时后" / "X个小时后"
        if minutes == nil,
           let regex = try? NSRegularExpression(
            pattern: "(\\d+)\\s*(?:个)?小时\\s*(?:后|以后|之后)?",
            options: []
           ), let match = regex.firstMatch(in: lower, options: [],
                                            range: NSRange(location: 0, length: nsText.length)),
           match.numberOfRanges >= 2 {
            let numStr = nsText.substring(with: match.range(at: 1))
            if let n = Int(numStr), n >= 1, n <= 24 { minutes = n * 60 }
        }

        // Pattern: "半小时后" / "半个小时后"
        if minutes == nil && containsAny(lower, ["半小时", "半个小时"]) {
            minutes = 30
        }

        // Pattern: "X min", "X minutes", "in X minutes"
        if minutes == nil,
           let regex = try? NSRegularExpression(
            pattern: "(\\d+)\\s*(?:min|minutes?)",
            options: .caseInsensitive
           ), let match = regex.firstMatch(in: lower, options: [],
                                            range: NSRange(location: 0, length: nsText.length)),
           match.numberOfRanges >= 2 {
            let numStr = nsText.substring(with: match.range(at: 1))
            if let n = Int(numStr), n >= 1, n <= 1440 { minutes = n }
        }

        // Pattern: "X hour(s)"
        if minutes == nil,
           let regex = try? NSRegularExpression(
            pattern: "(\\d+)\\s*(?:hours?|hr)",
            options: .caseInsensitive
           ), let match = regex.firstMatch(in: lower, options: [],
                                            range: NSRange(location: 0, length: nsText.length)),
           match.numberOfRanges >= 2 {
            let numStr = nsText.substring(with: match.range(at: 1))
            if let n = Int(numStr), n >= 1, n <= 24 { minutes = n * 60 }
        }

        // Pattern: "X秒后" / "X seconds"
        if minutes == nil,
           let regex = try? NSRegularExpression(
            pattern: "(\\d+)\\s*(?:秒|seconds?|sec)",
            options: .caseInsensitive
           ), let match = regex.firstMatch(in: lower, options: [],
                                            range: NSRange(location: 0, length: nsText.length)),
           match.numberOfRanges >= 2 {
            let numStr = nsText.substring(with: match.range(at: 1))
            if let n = Int(numStr), n >= 10, n <= 3600 {
                minutes = max(1, n / 60) // convert to minutes, min 1
            }
        }

        // No time expression found → not a timed reminder, let it fall through to todo
        guard let mins = minutes else { return nil }

        // Extract the reminder message (what to remind about)
        let message = extractReminderMessage(from: original, lower: lower)

        return .reminder(action: .set(minutes: mins, message: message))
    }

    /// Extract the actual reminder content from the query.
    private static func extractReminderMessage(from original: String, lower: String) -> String {
        var cleaned = original

        // Remove time expressions
        let timePatterns = [
            "\\d+\\s*分钟\\s*(?:后|以后|之后)?",
            "\\d+\\s*(?:个)?小时\\s*(?:后|以后|之后)?",
            "半(?:个)?小时\\s*(?:后|以后|之后)?",
            "\\d+\\s*(?:min(?:utes?)?|hours?|hr|seconds?|sec)\\s*(?:later)?",
            "in\\s+\\d+\\s+(?:min(?:utes?)?|hours?)",
            "\\d+\\s*秒\\s*(?:后|以后|之后)?"
        ]
        for pattern in timePatterns {
            cleaned = cleaned.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }

        // Remove reminder keywords
        let keywords = ["提醒我", "提醒一下", "定个提醒", "设个提醒", "闹钟", "定时",
                        "remind me", "set a reminder", "set reminder"]
        for kw in keywords {
            cleaned = cleaned.replacingOccurrences(of: kw, with: "", options: .caseInsensitive)
        }

        // Clean up
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "，,。.、：:！!？?to "))
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned.isEmpty ? "提醒时间到了" : cleaned
    }

    // MARK: - Text Tool Parsing

    private static func parseTextTool(_ lower: String, original: String) -> QueryIntent? {
        let textToolKeywords = ["字数", "字符数", "统计字数", "几个字", "多少字", "多少个字",
                                "word count", "char count", "character count",
                                "转大写", "大写", "uppercase", "to upper",
                                "转小写", "小写", "lowercase", "to lower",
                                "反转", "倒过来", "倒着写", "reverse",
                                "去空格", "去除空格", "去掉空格", "remove spaces", "trim",
                                "字符频率", "字频", "字符统计", "char frequency",
                                "文本工具", "文字工具", "text tool"]

        guard containsAny(lower, textToolKeywords) else { return nil }

        // Determine the action
        let action: TextToolAction
        if containsAny(lower, ["字数", "字符数", "统计字数", "几个字", "多少字", "多少个字",
                                "word count", "char count", "character count"]) {
            action = .wordCount
        } else if containsAny(lower, ["转大写", "大写", "uppercase", "to upper"]) {
            action = .toUppercase
        } else if containsAny(lower, ["转小写", "小写", "lowercase", "to lower"]) {
            action = .toLowercase
        } else if containsAny(lower, ["反转", "倒过来", "倒着写", "reverse"]) {
            action = .reverse
        } else if containsAny(lower, ["去空格", "去除空格", "去掉空格", "remove spaces", "trim"]) {
            action = .removeSpaces
        } else if containsAny(lower, ["字符频率", "字频", "字符统计", "char frequency"]) {
            action = .charFrequency
        } else {
            action = .help
        }

        // Extract the content after the keyword trigger
        let content = extractTextToolContent(from: original, lower: lower)
        return .textTool(action: action, content: content)
    }

    /// Extract the text content the user wants to process.
    /// Looks for quoted text first, then text after common delimiters.
    private static func extractTextToolContent(from original: String, lower: String) -> String {
        // Try quoted content first: "...", '...', 「...」, 『...』
        let quotePatterns: [(String, String)] = [
            ("\"", "\""), ("'", "'"), ("\u{201C}", "\u{201D}"), ("\u{2018}", "\u{2019}"),
            ("「", "」"), ("『", "』"), ("《", "》")
        ]
        for (open, close) in quotePatterns {
            if let startRange = original.range(of: open),
               let endRange = original.range(of: close, range: startRange.upperBound..<original.endIndex) {
                let extracted = String(original[startRange.upperBound..<endRange.lowerBound])
                if !extracted.isEmpty { return extracted }
            }
        }

        // Try text after colon/comma
        let delimiters = ["：", ":", "，", ","]
        for d in delimiters {
            if let range = original.range(of: d) {
                let after = original[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !after.isEmpty { return after }
            }
        }

        return ""
    }

    static func containsAny(_ text: String, _ keywords: [String]) -> Bool {
        keywords.contains { text.contains($0) }
    }

    // MARK: - Daily Quote Parsing

    private static func parseQuote(_ lower: String) -> QuoteCategory? {
        let quoteKeywords = ["名言", "名句", "语录", "格言", "一句话", "每日一句", "今日一句",
                             "鸡汤", "金句", "quote", "daily quote", "motivat", "inspire",
                             "激励我", "鼓励我", "励志", "来句", "来一句", "说句"]
        guard containsAny(lower, quoteKeywords) else { return nil }

        // Daily pick
        if containsAny(lower, ["每日", "今日", "今天的", "daily"]) {
            return .dailyPick
        }

        // Category-specific
        if containsAny(lower, ["励志", "激励", "鼓励", "加油", "motivat", "inspire"]) {
            return .motivational
        }
        if containsAny(lower, ["智慧", "哲理", "哲学", "wisdom"]) {
            return .wisdom
        }
        if containsAny(lower, ["生活", "人生", "life"]) {
            return .life
        }
        if containsAny(lower, ["坚持", "毅力", "不放弃", "persever"]) {
            return .perseverance
        }

        return .random
    }
}

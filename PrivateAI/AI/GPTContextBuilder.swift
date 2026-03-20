import Foundation
import CoreData

/// Assembles a rich context prompt from all local iOS data sources for RawGPTService.
/// Replaces ClawEngine — no local routing, just structured data context building.
final class GPTContextBuilder {

    private let coreDataContext: NSManagedObjectContext
    private let healthService: HealthService
    private let calendarService: CalendarService
    private let photoService: PhotoMetadataService
    private let locationService: LocationService
    private let photoSearchService: PhotoSearchService
    private var profile: UserProfileData

    init(context: NSManagedObjectContext,
         healthService: HealthService,
         calendarService: CalendarService,
         photoService: PhotoMetadataService,
         locationService: LocationService,
         profile: UserProfileData) {
        self.coreDataContext = context
        self.healthService = healthService
        self.calendarService = calendarService
        self.photoService = photoService
        self.locationService = locationService
        self.photoSearchService = PhotoSearchService(context: context)
        self.profile = profile
    }

    func updateProfile(_ newProfile: UserProfileData) {
        self.profile = newProfile
    }

    // MARK: - Build Prompt

    /// Gathers all local data in parallel then assembles a structured prompt.
    /// Includes a safety timeout (10s) for HealthKit queries — if they hang
    /// (system daemon unresponsive, corrupted DB, etc.), the prompt is built
    /// without health data rather than blocking the UI indefinitely.
    func buildPrompt(userQuery: String,
                     conversationHistory: [ChatMessage],
                     completion: @escaping (String) -> Void) {
        let group = DispatchGroup()
        var todayHealth = HealthSummary()
        var weeklyHealth: [HealthSummary] = []

        group.enter()
        healthService.fetchDailySummary(for: Date()) { summary in
            todayHealth = summary
            group.leave()
        }

        group.enter()
        healthService.fetchSummaries(days: 7) { summaries in
            weeklyHealth = summaries
            group.leave()
        }

        // Wait on a background queue with a timeout, then dispatch back to main.
        // HealthKit queries go through a system daemon — if it's unresponsive,
        // the DispatchGroup would never notify, leaving the user stuck in
        // "thinking" state indefinitely. The 10s timeout ensures we always
        // respond, even if health data is unavailable.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let waitResult = group.wait(timeout: .now() + 10)

            DispatchQueue.main.async {
                guard let self else { return }

                var healthTimedOut = false
                if waitResult == .timedOut {
                    // HealthKit queries didn't complete in time — proceed with empty data.
                    // The callbacks may still fire later on main, but the local vars won't
                    // be read again, so there's no race condition.
                    todayHealth = HealthSummary()
                    weeklyHealth = []
                    healthTimedOut = true
                }

                let now = Date()
                let cal = Calendar.current
                // Use startOfDay to ensure we capture full calendar days, matching
                // how health data is fetched (per-day summaries for days 0..6).
                // Without startOfDay, a query at 3pm would miss data before 3pm on
                // the earliest day — e.g., photos taken Wednesday morning would vanish
                // if it's now Wednesday 3pm, 7 days later.
                let dataRangeStart = cal.startOfDay(for: cal.date(byAdding: .day, value: -6, to: now) ?? now)
                let sevenDaysAhead = cal.date(byAdding: .day, value: 7, to: now) ?? now

                let todayEvents = self.calendarService.todayEvents()
                let upcomingEvents = self.calendarService.fetchEvents(from: now, to: sevenDaysAhead)
                // Also fetch past 7 days of calendar events so GPT can answer
                // "what meetings did I have yesterday?" or "last week's schedule"
                let pastStartOfToday = cal.startOfDay(for: now)
                let pastEvents = self.calendarService.fetchEvents(from: dataRangeStart, to: pastStartOfToday)
                let recentPhotos = self.photoService.fetchAllMedia(from: dataRangeStart, to: now)
                let locationRecords = CDLocationRecord.fetchRecent(in: self.coreDataContext, since: dataRangeStart)
                let lifeEvents = CDLifeEvent.fetchRecent(limit: 15, in: self.coreDataContext)

                // Run photo search when query looks photo-related so GPT can describe results
                let (photoResults, photoQuery) = self.searchPhotosIfNeeded(query: userQuery)

                let prompt = self.assemble(
                    userQuery: userQuery,
                    conversationHistory: conversationHistory,
                    todayHealth: todayHealth,
                    weeklyHealth: weeklyHealth,
                    todayEvents: todayEvents,
                    upcomingEvents: upcomingEvents,
                    pastEvents: pastEvents,
                    recentPhotos: recentPhotos,
                    locationRecords: locationRecords,
                    lifeEvents: lifeEvents,
                    photoSearchResults: photoResults,
                    photoSearchQuery: photoQuery,
                    healthTimedOut: healthTimedOut
                )
                completion(prompt)
            }
        }
    }

    // MARK: - Assemble

    private func assemble(userQuery: String,
                          conversationHistory: [ChatMessage],
                          todayHealth: HealthSummary,
                          weeklyHealth: [HealthSummary],
                          todayEvents: [CalendarEventItem],
                          upcomingEvents: [CalendarEventItem],
                          pastEvents: [CalendarEventItem] = [],
                          recentPhotos: [PhotoMetadataItem],
                          locationRecords: [CDLocationRecord],
                          lifeEvents: [CDLifeEvent],
                          photoSearchResults: [PhotoSearchService.SearchResult] = [],
                          photoSearchQuery: PhotoSearchService.PhotoQuery? = nil,
                          healthTimedOut: Bool = false) -> String {
        var parts: [String] = []

        // SYSTEM
        let now = Date()
        let dateFmt = DateFormatter()
        dateFmt.locale = Locale(identifier: "zh_CN")
        dateFmt.dateFormat = "yyyy年M月d日 EEEE HH:mm"
        let weekday = dateFmt.string(from: now)

        // Build data availability summary so GPT knows what's available at a glance
        var availableData: [String] = []
        var unavailableData: [String] = []

        // Determine health data availability with time-of-day awareness.
        // Early morning (before 8am) today's steps/exercise are naturally 0 —
        // that's NOT an authorization issue. Check weekly data to distinguish.
        let todayHasHealth = todayHealth.steps > 0 || todayHealth.exerciseMinutes > 0
            || todayHealth.sleepHours > 0 || todayHealth.heartRate > 0
        let weekHasHealth = weeklyHealth.contains { $0.steps > 0 || $0.exerciseMinutes > 0
            || $0.sleepHours > 0 || $0.heartRate > 0 }
        let hourOfDay = Calendar.current.component(.hour, from: now)

        // Health — Apple doesn't expose read-only auth status, so we infer from data
        if healthTimedOut {
            unavailableData.append("健康数据（读取超时，HealthKit 暂时无响应，请稍后再试）")
        } else if todayHasHealth || weekHasHealth {
            availableData.append("健康数据")
        } else if self.healthService.isHealthDataAvailable {
            unavailableData.append("健康数据（HealthKit 可用但近7天无数据，可能未授权或设备未佩戴）")
        } else {
            unavailableData.append("健康数据（此设备不支持 HealthKit，如 iPad）")
        }

        // Calendar — use explicit auth check to distinguish "no events" from "not authorized"
        if !todayEvents.isEmpty || !upcomingEvents.isEmpty || !pastEvents.isEmpty {
            availableData.append("日历日程")
        } else if self.calendarService.isAuthorized {
            unavailableData.append("日历日程（已授权，近期确实无日程安排）")
        } else {
            unavailableData.append("日历日程（未授权，用户需在 iPhone 设置 → iosclaw → 日历 中开启权限）")
        }

        // Location — use CLAuthorizationStatus for precise feedback
        if !locationRecords.isEmpty {
            availableData.append("位置记录")
        } else {
            let locAuth = self.locationService.authorizationStatus
            switch locAuth {
            case .authorizedAlways, .authorizedWhenInUse:
                unavailableData.append("位置记录（已授权，但近7天暂无记录，可能尚未产生显著位置变化）")
            case .denied, .restricted:
                unavailableData.append("位置记录（未授权，用户需在 iPhone 设置 → iosclaw → 位置 中开启权限）")
            default:
                unavailableData.append("位置记录（尚未请求位置权限）")
            }
        }

        // Photos — use PHPhotoLibrary auth status
        if !recentPhotos.isEmpty {
            availableData.append("照片统计")
        } else if self.photoService.isAuthorized {
            unavailableData.append("照片统计（已授权，近7天无新照片）")
        } else {
            unavailableData.append("照片统计（未授权，用户需在 iPhone 设置 → iosclaw → 照片 中开启权限）")
        }

        if !lifeEvents.isEmpty {
            availableData.append("生活记录")
        } else {
            unavailableData.append("生活记录（暂无记录）")
        }

        let availSummary = availableData.isEmpty ? "无" : availableData.joined(separator: "、")
        let unavailSummary = unavailableData.isEmpty ? "" : "\n不可用：\(unavailableData.joined(separator: "、"))"

        // Build explicit data time boundaries so GPT knows exact coverage
        let boundaryFmt = DateFormatter(); boundaryFmt.dateFormat = "M月d日"
        let dataStartDate = Calendar.current.date(byAdding: .day, value: -6, to: now) ?? now
        let healthBoundary = "健康/运动/睡眠数据：\(boundaryFmt.string(from: dataStartDate))~\(boundaryFmt.string(from: now))（共7天）"
        let locationBoundary = locationRecords.isEmpty ? "" : {
            let timestamps = locationRecords.compactMap { $0.timestamp }
            if let earliest = timestamps.min(), let latest = timestamps.max() {
                return "位置记录：\(boundaryFmt.string(from: earliest))~\(boundaryFmt.string(from: latest))"
            }
            return "位置记录：近7天"
        }()
        let calendarEndDate = Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now
        let calendarBoundary = "日历日程：\(boundaryFmt.string(from: dataStartDate))~\(boundaryFmt.string(from: calendarEndDate))（过去7天+未来7天）"
        let lifeEventBoundary: String = {
            let timestamps = lifeEvents.compactMap { $0.timestamp }
            if let earliest = timestamps.min(), let latest = timestamps.max() {
                return "生活记录：\(boundaryFmt.string(from: earliest))~\(boundaryFmt.string(from: latest))（最近\(lifeEvents.count)条）"
            }
            return ""
        }()

        var boundaries = [healthBoundary, calendarBoundary]
        if !locationBoundary.isEmpty { boundaries.append(locationBoundary) }
        if !lifeEventBoundary.isEmpty { boundaries.append(lifeEventBoundary) }
        let dataBoundaryText = boundaries.joined(separator: "\n")

        // Determine tone based on user's AI style preference
        let toneInstruction: String
        switch self.profile.aiStyle {
        case .friendly:
            toneInstruction = "用自然、友好、温暖的语气回答，像一个关心用户的老朋友。适当使用鼓励和关怀的语句。"
        case .professional:
            toneInstruction = "用简洁、专业、严谨的语气回答。重点突出数据和结论，减少寒暄。"
        case .casual:
            toneInstruction = "用轻松、随意的语气回答，可以适当幽默。像朋友间闲聊一样自然。"
        }

        parts.append("""
        [SYSTEM]
        你是 iosclaw，运行在用户 iPhone 上的私人 AI 助理。你可以读取用户的健康、位置、日历、照片、生活记录等本地数据。
        当前时间：\(weekday)
        可用数据源：\(availSummary)\(unavailSummary)

        数据时间范围（重要）：
        \(dataBoundaryText)
        ⚠️ 你只拥有上述时间范围内的数据。如果用户询问的时间段超出数据覆盖范围（如「上个月」「今年」「过去30天」），你必须：
        1. 先说明你只有近7天的数据
        2. 基于已有数据给出部分回答（如「近7天内…」）
        3. 不要将7天数据外推为更长时间段的结论

        能力边界：
        - 你只能读取数据，不能创建、修改或保存任何记录。如果用户想记录事情，告诉他可以在 App 的生活记录页面手动添加。
        - 你不能发送消息、设置闹钟、打电话等操作类任务。
        - 如果用户询问的数据标注为「未授权」，请明确告诉用户需要在 iPhone 的「设置 → iosclaw」中开启对应权限，而不是模糊地说「可能未授权」。
        - 如果数据标注为「已授权但无数据」，则说明权限正常，只是该时间段内确实没有相关数据，不需要建议用户去开权限。

        回复要求：
        - \(toneInstruction)
        - 如果用户用英文提问，用英文回答。
        - 引用具体数据时，必须使用下方提供的真实数据，不要编造任何数字。
        - 如果某项数据为 0 或为空，坦诚说明「暂无该数据」或「尚未授权」，不要猜测。
        - 回答健康、运动相关问题时，优先引用准确数值，再给出简短解读或鼓励。
        - 涉及多天数据时，可引用「近7天趋势」进行对比分析，指出趋势变化。
        - 周统计中会标注「X天中Y天有运动」，回答时要如实反映活跃天数，不要把少数几天的数据当作每天都达到了。例如7天中2天运动共60分钟，应该说「这周运动了2天，共60分钟」，而不是「日均运动30分钟」。
        - 不要重复罗列所有数据，只回答用户问到的内容。
        - 如果用户提到家人（如"我妈"、"我爸"等），参考下方[用户信息]中的家庭成员数据来回答。
        - 日历日程中 [日历名] 标签表示事件来源（如 [Work]、[个人]、[家庭]），用户问「工作会议」时参考此标签区分。日程的「备注」字段包含议程或描述，用户问「那个会议聊什么」时可引用。日历数据已标注星期几和相对日期（昨天/前天/明天/后天），用户问「周三有什么安排」时直接匹配对应日期即可。
        - 今天的日程带有时间状态标注（已结束/进行中），回答日程问题时优先告诉用户接下来的安排，而不是罗列全天。例如下午3点问「今天有什么安排」，重点说还有哪些未完成的，已结束的可简要带过。
        - 对话历史中的内容是之前的对话，注意用户可能会用「那…呢」「昨天的呢」「详细说说」等方式追问。如果用户的问题很短且含指代词（如「那个」「它」「上面说的」），结合对话历史推断用户指的是什么。

        回复格式：
        - 简单问题（如「今天几步」「心率多少」）：直接回答数值+一句话点评，不超过2-3行。
        - 中等问题（如「睡眠怎么样」「今天运动情况」）：数据+简要分析，3-5行即可。
        - 复杂问题（如「总结这周」「对比分析」）：可以用结构化格式，但控制在10行以内。
        - 闲聊/问候（如「你好」「谢谢」）：自然回复即可，1-2句话。
        - 不要使用 Markdown 标题（# ## ###），不要使用粗体（**）。可以适当使用 emoji 和换行来组织内容。
        - 这是手机 App 聊天界面，保持回复紧凑、适合手机阅读。
        """)

        // USER PROFILE
        var profileParts: [String] = []
        if !profile.name.isEmpty { profileParts.append("名字：\(profile.name)") }
        if let bd = profile.birthday {
            let age = Calendar.current.dateComponents([.year], from: bd, to: Date()).year ?? 0
            if age > 0 { profileParts.append("\(age)岁") }
        }
        if !profile.occupation.isEmpty { profileParts.append("职业：\(profile.occupation)") }
        if !profile.interests.isEmpty { profileParts.append("兴趣：\(profile.interests.joined(separator: "、"))") }
        if !profile.notes.isEmpty { profileParts.append("备注：\(profile.notes)") }

        // Family members — enables GPT to answer "when is my mom's birthday?" etc.
        if !profile.familyMembers.isEmpty {
            let dateFmt2 = DateFormatter(); dateFmt2.dateFormat = "M月d日"
            let familyLines = profile.familyMembers.map { member -> String in
                var desc = "\(member.relation)：\(member.name)"
                if let bd = member.birthday {
                    desc += "（生日：\(dateFmt2.string(from: bd))）"
                }
                if !member.notes.isEmpty {
                    desc += "（\(member.notes)）"
                }
                return desc
            }
            profileParts.append("家庭成员：\(familyLines.joined(separator: "；"))")
        }

        if !profileParts.isEmpty {
            parts.append("[用户信息]\n\(profileParts.joined(separator: "\n"))")
        }

        // TODAY'S HEALTH
        parts.append(healthSection(todayHealth, weeklyHealth: weeklyHealth, hourOfDay: hourOfDay))

        // When today's data is empty (e.g. early morning), surface yesterday's key
        // metrics so GPT can still answer "how did I do yesterday?" or "how was my sleep?"
        if !todayHasHealth && hourOfDay < 10 {
            if let yesterday = weeklyHealth.first(where: {
                Calendar.current.isDateInYesterday($0.date) &&
                ($0.steps > 0 || $0.sleepHours > 0 || $0.exerciseMinutes > 0)
            }) {
                parts.append(yesterdayHighlight(yesterday))
            }
        }

        // 7-DAY HEALTH TREND
        if weeklyHealth.count >= 3 {
            parts.append(trendSection(weeklyHealth))
        }

        // 7-DAY SLEEP QUALITY (per-day phase breakdown for sleep analysis)
        let sleepAnalysis = weeklySleepSection(weeklyHealth)
        if !sleepAnalysis.isEmpty {
            parts.append(sleepAnalysis)
        }

        // 7-DAY WORKOUT HISTORY (individual sessions GPT can reference)
        let workoutHistory = weeklyWorkoutSection(weeklyHealth)
        if !workoutHistory.isEmpty {
            parts.append(workoutHistory)
        }

        // CALENDAR
        parts.append(calendarSection(todayEvents: todayEvents, upcoming: upcomingEvents, past: pastEvents))

        // LOCATION
        if !locationRecords.isEmpty {
            parts.append(locationSection(locationRecords))
        }

        // PHOTO STATS
        if !recentPhotos.isEmpty {
            parts.append(photoSection(recentPhotos))
        }

        // PHOTO SEARCH RESULTS (when user asks about specific photos)
        if !photoSearchResults.isEmpty {
            parts.append(photoSearchSection(photoSearchResults, query: photoSearchQuery))
        } else if let pq = photoSearchQuery, (!pq.keywords.isEmpty || pq.location != nil) {
            // Search was attempted but found no results — tell GPT so it can inform the user
            var criteria: [String] = []
            if !pq.keywords.isEmpty { criteria.append("关键词：\(pq.keywords.joined(separator: "、"))") }
            if !pq.locationName.isEmpty { criteria.append("地点：\(pq.locationName)") }
            parts.append("[照片搜索结果]\n搜索条件：\(criteria.joined(separator: "，"))\n未找到匹配的照片。可能是照片索引尚未建立，或相册中没有符合条件的照片。")
        }

        // LIFE EVENTS
        if !lifeEvents.isEmpty {
            parts.append(lifeEventsSection(lifeEvents))
        }

        // CONVERSATION HISTORY (truncated to save tokens)
        // Note: ChatViewModel adds the current user message to conversationHistory
        // before calling buildPrompt, so we must strip it to avoid duplicating the
        // query that already appears in [当前问题].
        if !conversationHistory.isEmpty {
            var recentHistory = Array(conversationHistory.suffix(7)) // grab one extra in case we drop one
            if let last = recentHistory.last, last.isUser, last.content == userQuery {
                recentHistory.removeLast()
            }
            // Filter out error/system messages that were persisted to CoreData.
            // On app restart these get loaded into conversationHistory and would
            // confuse GPT if sent as previous "assistant" responses (e.g. "⚠️ 请求超时了").
            // Also remove orphaned user messages (user messages not followed by an
            // assistant response) — these arise when error messages are stripped,
            // leaving a dangling question that would confuse GPT.
            let errorFiltered = recentHistory.filter { msg in
                guard !msg.isUser else { return true }
                return !msg.content.hasPrefix("⚠️")
            }
            var cleaned: [ChatMessage] = []
            for (i, msg) in errorFiltered.enumerated() {
                if msg.isUser {
                    let nextIndex = i + 1
                    if nextIndex < errorFiltered.count && !errorFiltered[nextIndex].isUser {
                        cleaned.append(msg)
                    }
                } else {
                    cleaned.append(msg)
                }
            }
            // Drop messages older than 48 hours — they're almost never relevant
            // and waste tokens while potentially confusing GPT with stale context.
            let cutoff = now.addingTimeInterval(-48 * 3600)
            let timeBounded = cleaned.filter { $0.timestamp > cutoff }
            let historyToShow = timeBounded.suffix(6)
            if !historyToShow.isEmpty {
                let histTimeFmt = DateFormatter(); histTimeFmt.dateFormat = "HH:mm"
                let histDateFmt = DateFormatter(); histDateFmt.dateFormat = "M月d日 HH:mm"
                let histCal = Calendar.current

                // Build history lines with session gap markers.
                // When there's a >2 hour gap between consecutive messages, insert
                // a "--- 新对话 ---" separator so GPT understands the context shifted
                // and doesn't try to maintain continuity from the old session.
                let sessionGapThreshold: TimeInterval = 2 * 3600 // 2 hours
                var historyLines: [String] = []
                let histArray = Array(historyToShow)

                for (idx, msg) in histArray.enumerated() {
                    // Check for session gap before this message
                    if idx > 0 {
                        let prevTime = histArray[idx - 1].timestamp
                        let gap = msg.timestamp.timeIntervalSince(prevTime)
                        if gap > sessionGapThreshold {
                            historyLines.append("--- 新对话 ---")
                        }
                    }

                    let prefix = msg.isUser ? "用户" : "助理"
                    let content = msg.content
                    // Truncate long assistant replies to save tokens, but keep enough
                    // context for meaningful follow-up conversations (300 chars).
                    // User messages are kept in full (usually short).
                    let limit = msg.isUser ? 200 : 300
                    let truncated = content.count > limit ? String(content.prefix(limit)) + "…" : content
                    // Include timestamp so GPT can reason about temporal references
                    // like "刚才说的" or "今天早上聊的". Same-day messages show HH:mm,
                    // older messages show full date to distinguish cross-day context.
                    let timeLabel: String
                    if histCal.isDateInToday(msg.timestamp) {
                        timeLabel = histTimeFmt.string(from: msg.timestamp)
                    } else if histCal.isDateInYesterday(msg.timestamp) {
                        timeLabel = "昨天\(histTimeFmt.string(from: msg.timestamp))"
                    } else {
                        timeLabel = histDateFmt.string(from: msg.timestamp)
                    }
                    historyLines.append("[\(timeLabel)] \(prefix)：\(truncated)")
                }

                // Check if the most recent history message is far from "now" —
                // if so, tell GPT this is likely a fresh conversation
                let lastHistoryTime = histArray.last?.timestamp ?? now
                let timeSinceLast = now.timeIntervalSince(lastHistoryTime)
                let headerNote: String
                if timeSinceLast > sessionGapThreshold {
                    headerNote = "（上次对话已是较久之前，当前可能是新话题）"
                } else {
                    headerNote = "（用于理解上下文，回答时参考最近的话题）"
                }
                parts.append("[对话历史\(headerNote)]\n" + historyLines.joined(separator: "\n"))
            }
        }

        // CURRENT QUESTION
        parts.append("[当前问题]\n用户说：\(userQuery)")

        return parts.joined(separator: "\n\n")
    }

    // MARK: - Section Builders

    private func healthSection(_ h: HealthSummary,
                               weeklyHealth: [HealthSummary] = [],
                               hourOfDay: Int = Calendar.current.component(.hour, from: Date())) -> String {
        var lines = ["[今日健康数据]"]

        // Determine if HealthKit is authorized by checking for any data today or
        // in the weekly trend. When authorized, we explicitly show zero-value key
        // metrics (steps, exercise, sleep) so GPT can correctly say "you haven't
        // exercised today" instead of being silent about it (which GPT interprets
        // as "data unavailable").
        let todayHasAny = h.steps > 0 || h.exerciseMinutes > 0
            || h.sleepHours > 0 || h.heartRate > 0
        let weekHasAnyData = weeklyHealth.contains { $0.steps > 0 || $0.exerciseMinutes > 0
            || $0.sleepHours > 0 || $0.heartRate > 0 }
        let healthAuthorized = todayHasAny || weekHasAnyData

        // Steps — show explicit 0 when authorized so GPT can say "还没走路"
        if h.steps > 0 {
            var line = "步数：\(Int(h.steps))步"
            if h.distanceKm > 0 { line += "，距离：\(String(format: "%.1f", h.distanceKm))km" }
            lines.append(line)
        } else if healthAuthorized && hourOfDay >= 8 {
            lines.append("步数：0步（今天还没有步行记录）")
        }

        // Exercise — critical to show 0 so GPT answers "今天运动了吗？" accurately
        if h.exerciseMinutes > 0 {
            var line = "运动时间：\(Int(h.exerciseMinutes))分钟"
            if h.activeCalories > 0 { line += "，活动卡路里：\(Int(h.activeCalories))kcal" }
            lines.append(line)
        } else if healthAuthorized && hourOfDay >= 8 {
            lines.append("运动时间：0分钟（今天还没有运动记录）")
        }

        if h.heartRate > 0 {
            var line = "心率：均值\(Int(h.heartRate))bpm"
            if h.restingHeartRate > 0 { line += "，静息\(Int(h.restingHeartRate))bpm" }
            if h.hrv > 0 { line += "，HRV \(Int(h.hrv))ms" }
            lines.append(line)
        }
        if h.flightsClimbed > 0 { lines.append("爬楼：\(Int(h.flightsClimbed))层") }
        if h.oxygenSaturation > 0 { lines.append("血氧：\(Int(h.oxygenSaturation))%") }
        if h.vo2Max > 0 { lines.append("VO2 Max：\(String(format: "%.1f", h.vo2Max)) ml/kg·min") }
        if h.bodyMassKg > 0 { lines.append("体重：\(String(format: "%.1f", h.bodyMassKg))kg") }

        // Sleep — show explicit 0 so GPT can answer "昨晚睡了吗？" accurately
        if h.sleepHours > 0 {
            var line = "睡眠：\(String(format: "%.1f", h.sleepHours))小时"
            var phases: [String] = []
            if h.sleepDeepHours > 0 { phases.append("深睡\(String(format: "%.1f", h.sleepDeepHours))h") }
            if h.sleepREMHours > 0 { phases.append("REM \(String(format: "%.1f", h.sleepREMHours))h") }
            if h.sleepCoreHours > 0 { phases.append("浅睡\(String(format: "%.1f", h.sleepCoreHours))h") }
            if !phases.isEmpty { line += "（\(phases.joined(separator: "，"))）" }
            // Sleep efficiency = actual sleep / time in bed — key quality metric
            if h.inBedHours > 0 && h.inBedHours >= h.sleepHours {
                let efficiency = Int((h.sleepHours / h.inBedHours) * 100)
                line += "，在床\(String(format: "%.1f", h.inBedHours))h，睡眠效率\(efficiency)%"
            }
            if let onset = h.sleepOnset, let wake = h.wakeTime {
                let fmt = DateFormatter(); fmt.dateFormat = "HH:mm"
                line += "，入睡\(fmt.string(from: onset))，起床\(fmt.string(from: wake))"
            }
            lines.append(line)
        } else if healthAuthorized {
            lines.append("睡眠：无记录（未检测到睡眠数据，可能未佩戴手表睡觉）")
        }

        if !h.workouts.isEmpty {
            let wLines = h.workouts.prefix(5).map { w in
                let name = "\(w.typeEmoji) \(w.typeName)"
                let dur = Int(w.duration / 60)
                var s = "\(name) \(dur)分钟"
                if w.totalCalories > 0 { s += " \(Int(w.totalCalories))kcal" }
                if w.totalDistance > 10 { s += " \(String(format: "%.1f", w.totalDistance / 1000))km" }
                return s
            }
            lines.append("今日运动：" + wLines.joined(separator: "；"))
        } else if h.exerciseMinutes > 0 {
            // Has exercise minutes (from Move ring) but no workout sessions —
            // user was active but didn't start a formal workout
            lines.append("今日运动：无正式运动记录（但有\(Int(h.exerciseMinutes))分钟活动，可能是日常活动计入）")
        }

        if lines.count == 1 {
            // No data at all and no zero-value lines were added
            if healthAuthorized && hourOfDay < 8 {
                lines.append("（现在是清晨，今日数据还在积累中，HealthKit 已授权正常）")
            } else if healthAuthorized {
                lines.append("（今日暂无健康数据，但近日有记录——可能数据尚未同步，HealthKit 已授权正常）")
            } else {
                lines.append("（今日暂无健康数据，可能尚未授权 HealthKit 或设备未佩戴）")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Quick yesterday summary for early-morning context when today is empty.
    private func yesterdayHighlight(_ y: HealthSummary) -> String {
        var lines = ["[昨日健康概要]（今日数据尚在积累，以下为昨天参考）"]
        if y.steps > 0 { lines.append("步数：\(Int(y.steps))步") }
        if y.exerciseMinutes > 0 { lines.append("运动：\(Int(y.exerciseMinutes))分钟") }
        if y.activeCalories > 0 { lines.append("活动消耗：\(Int(y.activeCalories))kcal") }
        if y.sleepHours > 0 {
            var line = "睡眠：\(String(format: "%.1f", y.sleepHours))小时"
            if let onset = y.sleepOnset, let wake = y.wakeTime {
                let fmt = DateFormatter(); fmt.dateFormat = "HH:mm"
                line += "（\(fmt.string(from: onset))~\(fmt.string(from: wake))）"
            }
            lines.append(line)
        }
        if y.heartRate > 0 { lines.append("心率均值：\(Int(y.heartRate))bpm") }
        return lines.joined(separator: "\n")
    }

    private func trendSection(_ summaries: [HealthSummary]) -> String {
        let fmt = DateFormatter(); fmt.dateFormat = "M/d"
        let weekdayFmt = DateFormatter(); weekdayFmt.locale = Locale(identifier: "zh_CN"); weekdayFmt.dateFormat = "EEE"
        let cal = Calendar.current
        var lines = ["[近7天健康趋势]", "日期  | 步数  | 运动(分) | 卡路里(kcal) | 睡眠(h) | 心率(bpm)"]
        // Show oldest→newest so GPT can naturally read the trend direction
        let chronological = Array(summaries.prefix(7).reversed())
        for s in chronological {
            // Include weekday name (周一~周日) so GPT can answer "周三运动了吗？" without date math
            let dayName: String
            if cal.isDateInToday(s.date) {
                dayName = "今天"
            } else if cal.isDateInYesterday(s.date) {
                dayName = "昨天"
            } else {
                dayName = weekdayFmt.string(from: s.date)
            }
            let dateLabel = "\(fmt.string(from: s.date))(\(dayName))"
            let steps = s.steps > 0 ? "\(Int(s.steps))" : "-"
            let ex = s.exerciseMinutes > 0 ? "\(Int(s.exerciseMinutes))" : "-"
            let cal_ = s.activeCalories > 0 ? "\(Int(s.activeCalories))" : "-"
            let sl = s.sleepHours > 0 ? String(format: "%.1f", s.sleepHours) : "-"
            let hr = s.heartRate > 0 ? "\(Int(s.heartRate))" : "-"
            lines.append("\(dateLabel)  | \(steps)  | \(ex)  | \(cal_)  | \(sl)  | \(hr)")
        }
        // Add weekly totals and averages with active-day counts so GPT can give
        // honest answers. E.g. "7天中有3天运动，共90分钟" is more useful than "日均30分钟"
        // which hides that the user only exercised 3 out of 7 days.
        let totalDays = min(summaries.count, 7)
        let week = summaries.prefix(7)
        let validStepsDays = week.filter { $0.steps > 0 }
        let validSleepDays = week.filter { $0.sleepHours > 0 }
        let validExDays = week.filter { $0.exerciseMinutes > 0 }
        var avgParts: [String] = []
        if !validStepsDays.isEmpty {
            let total = validStepsDays.map(\.steps).reduce(0, +)
            let avg = total / Double(totalDays)
            avgParts.append("\(totalDays)天日均步数\(Int(avg))")
        }
        if !validExDays.isEmpty {
            let totalMin = Int(validExDays.map(\.exerciseMinutes).reduce(0, +))
            avgParts.append("\(totalDays)天中\(validExDays.count)天有运动，共\(totalMin)分钟")
        }
        let validCalDays = week.filter { $0.activeCalories > 0 }
        if !validCalDays.isEmpty {
            let totalCal = Int(validCalDays.map(\.activeCalories).reduce(0, +))
            avgParts.append("周活动消耗\(totalCal)kcal")
        }
        if !validSleepDays.isEmpty {
            let total = validSleepDays.map(\.sleepHours).reduce(0, +)
            let avg = total / Double(validSleepDays.count)
            if validSleepDays.count < totalDays {
                avgParts.append("\(validSleepDays.count)/\(totalDays)天有睡眠数据，均\(String(format: "%.1f", avg))h")
            } else {
                avgParts.append("日均睡眠\(String(format: "%.1f", avg))h")
            }
        }
        if !avgParts.isEmpty {
            lines.append("周统计：\(avgParts.joined(separator: "，"))")
        }
        return lines.joined(separator: "\n")
    }

    private func calendarSection(todayEvents: [CalendarEventItem], upcoming: [CalendarEventItem], past: [CalendarEventItem] = []) -> String {
        let cal = Calendar.current
        let df = DateFormatter(); df.dateFormat = "M月d日"
        df.locale = Locale(identifier: "zh_CN")
        let timeFmt = DateFormatter(); timeFmt.dateFormat = "HH:mm"

        let now = Date()
        var lines = ["[日历日程]"]

        // Summarize calendar sources so GPT can distinguish work/personal/family events
        let allEvents = todayEvents + upcoming + past
        let calendarNames = Set(allEvents.map { $0.calendar }.filter { !$0.isEmpty })
        if calendarNames.count > 1 {
            lines.append("日历来源：\(calendarNames.sorted().joined(separator: "、"))")
        }

        // Past events grouped by day — enables "what did I do yesterday?" queries
        if !past.isEmpty {
            // Group by day
            var dayGroups: [Date: [CalendarEventItem]] = [:]
            for e in past {
                let dayStart = cal.startOfDay(for: e.startDate)
                dayGroups[dayStart, default: []].append(e)
            }
            let sortedDays = dayGroups.keys.sorted(by: >)  // newest first

            let dayNameFmt = DateFormatter()
            dayNameFmt.locale = Locale(identifier: "zh_CN")
            dayNameFmt.dateFormat = "M月d日（EEEE）"

            lines.append("过去7天日程：")
            for day in sortedDays.prefix(7) {
                guard let dayEvents = dayGroups[day] else { continue }
                let dayLabel: String
                if cal.isDateInYesterday(day) {
                    dayLabel = "昨天"
                } else if let twoDaysAgo = cal.date(byAdding: .day, value: -2, to: cal.startOfDay(for: now)),
                          cal.isDate(day, inSameDayAs: twoDaysAgo) {
                    dayLabel = "前天"
                } else {
                    dayLabel = dayNameFmt.string(from: day)
                }
                let eventDescs = dayEvents.prefix(5).map { e -> String in
                    let timeStr = e.isAllDay ? "全天" : "\(timeFmt.string(from: e.startDate))–\(timeFmt.string(from: e.endDate))"
                    var desc = "\(timeStr) \(e.title)"
                    if !e.calendar.isEmpty { desc += " [\(e.calendar)]" }
                    if !e.location.isEmpty { desc += "（\(e.location)）" }
                    if let label = e.attendeeLabel { desc += " \(label)" }
                    // Include notes for past events so GPT can answer "昨天那个会议聊什么？"
                    let trimmedNotes = e.notes.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedNotes.isEmpty {
                        let preview = trimmedNotes.count > 80 ? String(trimmedNotes.prefix(80)) + "…" : trimmedNotes
                        desc += " 备注：\(preview)"
                    }
                    return desc
                }
                lines.append("  \(dayLabel)：\(eventDescs.joined(separator: "；"))")
                if dayEvents.count > 5 {
                    lines.append("    …还有\(dayEvents.count - 5)项")
                }
            }
        }

        // Today's events — annotate with temporal status so GPT knows what's
        // past, ongoing, and upcoming relative to "now"
        if todayEvents.isEmpty {
            lines.append("今天：无日程")
        } else {
            // Find the next upcoming event for a highlight line
            let nextEvent = todayEvents.first { !$0.isAllDay && $0.startDate > now }
            if let next = nextEvent {
                let minutesUntil = Int(next.startDate.timeIntervalSince(now) / 60)
                if minutesUntil <= 60 {
                    lines.append("⏰ 下一个日程：\(next.title)（\(minutesUntil)分钟后）")
                }
            }

            lines.append("今天：")
            for e in todayEvents.prefix(10) {
                // Determine temporal status for non-all-day events
                let status: String
                if e.isAllDay {
                    status = ""
                } else if e.endDate <= now {
                    status = "（已结束）"
                } else if e.startDate <= now && e.endDate > now {
                    status = "（进行中）"
                } else {
                    status = ""
                }

                var line = "  \(e.timeDisplay) \(e.title)\(status)"
                if !e.calendar.isEmpty { line += " [\(e.calendar)]" }
                if !e.location.isEmpty { line += "（\(e.location)）" }
                if let label = e.attendeeLabel { line += " \(label)" }
                // Include truncated notes for meeting context (agenda, description)
                let trimmedNotes = e.notes.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedNotes.isEmpty {
                    let preview = trimmedNotes.count > 80 ? String(trimmedNotes.prefix(80)) + "…" : trimmedNotes
                    line += " 备注：\(preview)"
                }
                lines.append(line)
            }

            // Summary: how many done vs remaining
            let nonAllDay = todayEvents.filter { !$0.isAllDay }
            let doneCount = nonAllDay.filter { $0.endDate <= now }.count
            let remainCount = nonAllDay.filter { $0.startDate > now }.count
            if nonAllDay.count >= 3 {
                lines.append("  （已完成\(doneCount)项，还剩\(remainCount)项待进行）")
            }
        }

        // Upcoming events (future, excluding today) — include weekday names
        // so GPT can answer "下周三有什么会？" without needing date math
        let futureEvents = upcoming.filter { !cal.isDateInToday($0.startDate) }.prefix(10)
        if !futureEvents.isEmpty {
            let weekdayFmt = DateFormatter()
            weekdayFmt.locale = Locale(identifier: "zh_CN")
            weekdayFmt.dateFormat = "EEEE"
            lines.append("近期：")
            for e in futureEvents {
                // Add relative labels (明天/后天) and weekday for all future dates
                let eventDay = cal.startOfDay(for: e.startDate)
                let relativeLabel: String
                if let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)),
                   cal.isDate(eventDay, inSameDayAs: tomorrow) {
                    relativeLabel = "明天"
                } else if let dayAfter = cal.date(byAdding: .day, value: 2, to: cal.startOfDay(for: now)),
                          cal.isDate(eventDay, inSameDayAs: dayAfter) {
                    relativeLabel = "后天"
                } else {
                    relativeLabel = weekdayFmt.string(from: e.startDate)
                }
                let dateStr = "\(df.string(from: e.startDate))(\(relativeLabel))"
                let timeStr = e.isAllDay ? "全天" : "\(timeFmt.string(from: e.startDate))–\(timeFmt.string(from: e.endDate))"
                var line = "  \(dateStr) \(timeStr) \(e.title)"
                if !e.calendar.isEmpty { line += " [\(e.calendar)]" }
                if !e.location.isEmpty { line += "（\(e.location)）" }
                if let label = e.attendeeLabel { line += " \(label)" }
                // Include notes for upcoming events too — helps GPT answer "what's that meeting about?"
                let trimmedNotes = e.notes.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedNotes.isEmpty {
                    let preview = trimmedNotes.count > 80 ? String(trimmedNotes.prefix(80)) + "…" : trimmedNotes
                    line += " 备注：\(preview)"
                }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Extracts a display name for a location record with coordinate fallback.
    /// When both placeName and address are empty, provides lat/lon so GPT can
    /// approximate the location (GPT knows world geography well).
    private func locationDisplayName(for r: CDLocationRecord) -> String {
        if let name = r.placeName, !name.isEmpty { return name }
        if let addr = r.address, !addr.isEmpty { return addr }
        // Coordinate fallback — GPT can identify approximate area from lat/lon
        if r.latitude != 0 || r.longitude != 0 {
            return String(format: "%.3f°N, %.3f°E", r.latitude, r.longitude)
        }
        return "未知地点"
    }

    /// Extracts the city component from the address field.
    /// Address format from CLGeocoder is typically "街道, 城市, 省份" (Chinese locale).
    private func cityFromAddress(_ address: String?) -> String? {
        guard let addr = address, !addr.isEmpty else { return nil }
        let parts = addr.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        // The second component is typically the city (e.g. "南京西路, 上海市, 上海" → "上海市")
        if parts.count >= 2 { return parts[1] }
        return parts.first
    }

    private func locationSection(_ records: [CDLocationRecord]) -> String {
        let cal = Calendar.current
        let dateFmt = DateFormatter(); dateFmt.dateFormat = "M月d日（EEEE）"
        dateFmt.locale = Locale(identifier: "zh_CN")
        let timeFmt = DateFormatter(); timeFmt.dateFormat = "HH:mm"

        var lines = ["[位置记录（近7天）]"]

        // City/district aggregation so GPT can answer "去了几个城市？" or "在哪个区？"
        var cityCounts: [String: Int] = [:]
        for r in records {
            if let city = cityFromAddress(r.address), !city.isEmpty {
                cityCounts[city, default: 0] += 1
            }
        }
        if cityCounts.count >= 2 {
            let cityList = cityCounts.sorted { $0.value > $1.value }
                .map { "\($0.key)(\($0.value)次)" }
            lines.append("活动城市/区域：\(cityList.joined(separator: "、"))")
        } else if let singleCity = cityCounts.keys.first {
            lines.append("活动区域：\(singleCity)")
        }

        // Group records by day for temporal clarity — GPT can answer "where did I go yesterday?"
        var dayGroups: [Date: [CDLocationRecord]] = [:]
        for r in records {
            guard let ts = r.timestamp else { continue }
            let dayStart = cal.startOfDay(for: ts)
            dayGroups[dayStart, default: []].append(r)
        }
        let sortedDays = dayGroups.keys.sorted(by: >)  // newest first

        for day in sortedDays.prefix(7) {
            guard let dayRecords = dayGroups[day] else { continue }
            let dayLabel = cal.isDateInToday(day) ? "今天" :
                           cal.isDateInYesterday(day) ? "昨天" :
                           dateFmt.string(from: day)
            // Deduplicate by place name, keep chronological order and visit times
            var seenPlaces: [String: (count: Int, times: [String], address: String?)] = [:]
            var placeOrder: [String] = []
            for r in dayRecords.sorted(by: { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }) {
                let name = locationDisplayName(for: r)
                if seenPlaces[name] == nil {
                    placeOrder.append(name)
                    // Store address alongside for extra context when place name is short
                    seenPlaces[name] = (count: 0, times: [], address: r.address)
                }
                let timeStr = r.timestamp.map { timeFmt.string(from: $0) } ?? ""
                seenPlaces[name]!.count += 1
                if !timeStr.isEmpty && seenPlaces[name]!.times.count < 3 {
                    seenPlaces[name]!.times.append(timeStr)
                }
            }
            var dayLine = "\(dayLabel)："
            let placeParts = placeOrder.prefix(6).map { name -> String in
                let info = seenPlaces[name]!
                var part = name
                // Append city/district context if place name differs from address
                // (e.g., "星巴克" → "星巴克@上海市" helps GPT know which city)
                if let addr = info.address, !addr.isEmpty,
                   let city = self.cityFromAddress(addr),
                   !name.contains(city) {
                    part += "@\(city)"
                }
                if !info.times.isEmpty { part += "（\(info.times.joined(separator: "、"))）" }
                if info.count > 1 { part += "×\(info.count)" }
                return part
            }
            dayLine += placeParts.joined(separator: " → ")
            lines.append(dayLine)
        }

        // Summary: frequently visited places across the week
        var totalCounts: [String: Int] = [:]
        for r in records {
            let name = locationDisplayName(for: r)
            totalCounts[name, default: 0] += 1
        }
        let topPlaces = totalCounts.sorted { $0.value > $1.value }.prefix(5)
        if topPlaces.count > 1 {
            let summaryParts = topPlaces.map { "\($0.key)(\($0.value)次)" }
            lines.append("常去地点：\(summaryParts.joined(separator: "、"))")
        }

        return lines.joined(separator: "\n")
    }

    private func photoSection(_ photos: [PhotoMetadataItem]) -> String {
        let cal = Calendar.current
        let total = photos.count
        let videos = photos.filter { $0.isVideo }.count
        let geoTagged = photos.filter { $0.hasLocation }.count
        let favorites = photos.filter { $0.isFavorite }.count
        let screenshots = photos.filter { $0.isScreenshot }.count
        var lines = ["[照片统计（近7天）]"]
        lines.append("共 \(total - videos) 张照片，\(videos) 个视频")
        if geoTagged > 0 { lines.append("含地理位置：\(geoTagged) 张") }
        if favorites > 0 { lines.append("已收藏：\(favorites) 张") }
        if screenshots > 0 { lines.append("截图：\(screenshots) 张") }

        // Per-day breakdown so GPT can answer "昨天拍了几张照片？" accurately
        var dayGroups: [Date: [PhotoMetadataItem]] = [:]
        for p in photos {
            let dayStart = cal.startOfDay(for: p.date)
            dayGroups[dayStart, default: []].append(p)
        }
        let sortedDays = dayGroups.keys.sorted(by: >)  // newest first

        if sortedDays.count > 1 || (sortedDays.count == 1 && photos.count > 3) {
            let dateFmt = DateFormatter(); dateFmt.dateFormat = "M月d日"
            dateFmt.locale = Locale(identifier: "zh_CN")
            let weekdayFmt = DateFormatter(); weekdayFmt.locale = Locale(identifier: "zh_CN"); weekdayFmt.dateFormat = "EEE"

            lines.append("每日拍摄：")
            for day in sortedDays.prefix(7) {
                guard let dayPhotos = dayGroups[day] else { continue }
                let dayLabel: String
                if cal.isDateInToday(day) {
                    dayLabel = "今天"
                } else if cal.isDateInYesterday(day) {
                    dayLabel = "昨天"
                } else {
                    dayLabel = "\(dateFmt.string(from: day))(\(weekdayFmt.string(from: day)))"
                }

                let dayPhotosOnly = dayPhotos.filter { !$0.isVideo }
                let dayVideos = dayPhotos.filter { $0.isVideo }
                var countParts: [String] = []
                if !dayPhotosOnly.isEmpty { countParts.append("\(dayPhotosOnly.count)张照片") }
                if !dayVideos.isEmpty { countParts.append("\(dayVideos.count)个视频") }

                // Show media kind breakdown for variety (portrait, live, panorama, etc.)
                var kindCounts: [String: Int] = [:]
                for p in dayPhotos {
                    // Only annotate special types (skip plain .photo and .video)
                    switch p.mediaKind {
                    case .livePhoto, .panorama, .depthEffect, .burst, .sloMo, .timelapse:
                        kindCounts[p.mediaKind.label, default: 0] += 1
                    default:
                        break
                    }
                }
                let kindNote = kindCounts.isEmpty ? "" :
                    "（含\(kindCounts.map { "\($0.value)张\($0.key)" }.joined(separator: "、"))）"

                let dayFavs = dayPhotos.filter { $0.isFavorite }.count
                let favNote = dayFavs > 0 ? " ⭐\(dayFavs)" : ""

                lines.append("  \(dayLabel)：\(countParts.joined(separator: "、"))\(kindNote)\(favNote)")
            }
        }

        return lines.joined(separator: "\n")
    }

    private func lifeEventsSection(_ events: [CDLifeEvent]) -> String {
        let cal = Calendar.current
        let dateFmt = DateFormatter(); dateFmt.dateFormat = "M月d日"
        let timeFmt = DateFormatter(); timeFmt.dateFormat = "HH:mm"
        let weekdayFmt = DateFormatter()
        weekdayFmt.locale = Locale(identifier: "zh_CN")
        weekdayFmt.dateFormat = "EEE"
        let now = Date()

        var lines = ["[生活记录（近期）]"]

        // Category distribution summary so GPT can answer "最近都在忙什么？"
        var categoryCounts: [String: Int] = [:]
        for e in events {
            let cat = EventCategory(rawValue: e.category ?? "life") ?? .life
            categoryCounts[cat.label, default: 0] += 1
        }
        if categoryCounts.count > 1 {
            let summary = categoryCounts.sorted { $0.value > $1.value }
                .map { "\($0.key)\($0.value)条" }
            lines.append("分类：\(summary.joined(separator: "、"))")
        }

        for e in events.prefix(15) {
            let mood = MoodType(rawValue: e.mood ?? "") ?? .neutral
            let category = EventCategory(rawValue: e.category ?? "life") ?? .life

            // Build date label with relative names and weekday, matching calendar/location sections
            let dateLabel: String
            if let ts = e.timestamp {
                let relativeDay: String
                if cal.isDateInToday(ts) {
                    relativeDay = "今天"
                } else if cal.isDateInYesterday(ts) {
                    relativeDay = "昨天"
                } else if let twoDaysAgo = cal.date(byAdding: .day, value: -2, to: cal.startOfDay(for: now)),
                          cal.isDate(ts, inSameDayAs: twoDaysAgo) {
                    relativeDay = "前天"
                } else {
                    relativeDay = weekdayFmt.string(from: ts)
                }
                dateLabel = "\(dateFmt.string(from: ts))(\(relativeDay)) \(timeFmt.string(from: ts))"
            } else {
                dateLabel = ""
            }

            var line = "\(mood.emoji) [\(category.label)] \(e.title ?? "记录")"
            if !dateLabel.isEmpty { line += "（\(dateLabel)）" }
            if let content = e.content, !content.isEmpty {
                let preview = content.count > 100 ? String(content.prefix(100)) + "…" : content
                line += "：\(preview)"
            }
            // Include tags for searchability (e.g. "关于旅行的记录")
            let tagsStr = e.tags ?? ""
            let tags = tagsStr.split(separator: ",").map(String.init).filter { !$0.isEmpty }
            if !tags.isEmpty {
                line += " #\(tags.prefix(4).joined(separator: " #"))"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Weekly Workout History

    /// Extracts individual workout sessions from weekly summaries so GPT can answer
    /// questions like "when was my last run?" or "how many times did I exercise this week?"
    private func weeklyWorkoutSection(_ summaries: [HealthSummary]) -> String {
        let cal = Calendar.current
        let dateFmt = DateFormatter(); dateFmt.dateFormat = "M/d"
        let weekdayFmt = DateFormatter(); weekdayFmt.locale = Locale(identifier: "zh_CN"); weekdayFmt.dateFormat = "EEE"
        let timeFmt = DateFormatter(); timeFmt.dateFormat = "HH:mm"

        // Collect all workouts from all days, tagged with their date
        var allWorkouts: [(date: Date, workout: WorkoutRecord)] = []
        for s in summaries.prefix(7) {
            for w in s.workouts {
                allWorkouts.append((date: s.date, workout: w))
            }
        }

        guard !allWorkouts.isEmpty else { return "" }

        // Sort chronologically (newest first) for easy reading
        allWorkouts.sort { $0.workout.startDate > $1.workout.startDate }

        var lines = ["[近7天运动记录]"]
        // Summary line
        let totalSessions = allWorkouts.count
        let activeDays = Set(allWorkouts.map { cal.startOfDay(for: $0.date) }).count
        lines.append("共 \(totalSessions) 次运动，覆盖 \(activeDays) 天")

        // List each workout (cap at 15 to avoid token bloat)
        for item in allWorkouts.prefix(15) {
            let w = item.workout
            let name = "\(w.typeEmoji) \(w.typeName)"
            let dayLabel: String
            if cal.isDateInToday(item.date) {
                dayLabel = "今天"
            } else if cal.isDateInYesterday(item.date) {
                dayLabel = "昨天"
            } else {
                dayLabel = "\(dateFmt.string(from: item.date))(\(weekdayFmt.string(from: item.date)))"
            }
            let timeStr = timeFmt.string(from: w.startDate)
            let dur = Int(w.duration / 60)
            var line = "\(dayLabel) \(timeStr) \(name) \(dur)分钟"
            if w.totalCalories > 0 { line += " \(Int(w.totalCalories))kcal" }
            if w.totalDistance > 100 { line += " \(String(format: "%.1f", w.totalDistance / 1000))km" }
            lines.append(line)
        }

        // Workout type breakdown for quick stats
        var typeCounts: [String: Int] = [:]
        for item in allWorkouts {
            let name = "\(item.workout.typeEmoji) \(item.workout.typeName)"
            typeCounts[name, default: 0] += 1
        }
        if typeCounts.count > 1 {
            let breakdown = typeCounts.sorted { $0.value > $1.value }
                .map { "\($0.key)\($0.value)次" }
            lines.append("运动类型：\(breakdown.joined(separator: "、"))")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Weekly Sleep Analysis

    /// Builds a per-day sleep quality breakdown for the past 7 days.
    /// Enables GPT to answer "最近睡眠质量怎么样？", "哪天睡得最好？",
    /// "我入睡时间规律吗？" with precise phase-level data.
    /// Returns empty string if fewer than 2 days have sleep data.
    private func weeklySleepSection(_ summaries: [HealthSummary]) -> String {
        let cal = Calendar.current
        let dateFmt = DateFormatter(); dateFmt.dateFormat = "M/d"
        let weekdayFmt = DateFormatter()
        weekdayFmt.locale = Locale(identifier: "zh_CN")
        weekdayFmt.dateFormat = "EEE"
        let timeFmt = DateFormatter(); timeFmt.dateFormat = "HH:mm"

        // Only include days that have sleep data
        let daysWithSleep = summaries.prefix(7).filter { $0.sleepHours > 0 }
        guard daysWithSleep.count >= 2 else { return "" }

        var lines = ["[近7天睡眠质量分析]"]

        // Show oldest → newest for natural trend reading
        let chronological = Array(daysWithSleep.reversed())

        for s in chronological {
            let dayName: String
            if cal.isDateInToday(s.date) {
                dayName = "今天"
            } else if cal.isDateInYesterday(s.date) {
                dayName = "昨天"
            } else {
                dayName = weekdayFmt.string(from: s.date)
            }
            let dateLabel = "\(dateFmt.string(from: s.date))(\(dayName))"

            var parts: [String] = []
            parts.append("总\(String(format: "%.1f", s.sleepHours))h")

            // Phase breakdown
            if s.hasSleepPhases {
                var phases: [String] = []
                if s.sleepDeepHours > 0 { phases.append("深睡\(String(format: "%.1f", s.sleepDeepHours))h") }
                if s.sleepREMHours > 0 { phases.append("REM\(String(format: "%.1f", s.sleepREMHours))h") }
                if s.sleepCoreHours > 0 { phases.append("浅睡\(String(format: "%.1f", s.sleepCoreHours))h") }
                parts.append(phases.joined(separator: "/"))
            }

            // Sleep efficiency
            if s.inBedHours > 0 && s.inBedHours >= s.sleepHours {
                let efficiency = Int((s.sleepHours / s.inBedHours) * 100)
                parts.append("效率\(efficiency)%")
            }

            // Onset and wake times for circadian regularity analysis
            if let onset = s.sleepOnset {
                parts.append("入睡\(timeFmt.string(from: onset))")
            }
            if let wake = s.wakeTime {
                parts.append("起床\(timeFmt.string(from: wake))")
            }

            lines.append("\(dateLabel)：\(parts.joined(separator: "，"))")
        }

        // Weekly sleep quality summary
        let totalDays = daysWithSleep.count
        let avgSleep = daysWithSleep.map(\.sleepHours).reduce(0, +) / Double(totalDays)
        var summaryParts: [String] = []
        summaryParts.append("\(totalDays)天有睡眠数据，均\(String(format: "%.1f", avgSleep))h")

        // Average deep sleep ratio — key quality metric
        let daysWithPhases = daysWithSleep.filter { $0.hasSleepPhases }
        if !daysWithPhases.isEmpty {
            let avgDeep = daysWithPhases.map(\.sleepDeepHours).reduce(0, +) / Double(daysWithPhases.count)
            let avgREM = daysWithPhases.map(\.sleepREMHours).reduce(0, +) / Double(daysWithPhases.count)
            summaryParts.append("均深睡\(String(format: "%.1f", avgDeep))h/REM\(String(format: "%.1f", avgREM))h")

            // Deep sleep ratio — healthy is 15-25% of total sleep
            let avgTotal = daysWithPhases.map(\.sleepHours).reduce(0, +) / Double(daysWithPhases.count)
            if avgTotal > 0 {
                let deepRatio = Int((avgDeep / avgTotal) * 100)
                summaryParts.append("深睡占比\(deepRatio)%")
            }
        }

        // Sleep regularity — std dev of onset times
        let onsets = daysWithSleep.compactMap { $0.sleepOnset }
        if onsets.count >= 3 {
            // Convert onset to minutes-since-18:00 for comparison (handles cross-midnight)
            let onsetMinutes = onsets.map { onset -> Double in
                let comps = cal.dateComponents([.hour, .minute], from: onset)
                var mins = Double((comps.hour ?? 0) * 60 + (comps.minute ?? 0))
                // Normalize: times before 18:00 are next-day (e.g. 01:00 = 25*60)
                if mins < 18 * 60 { mins += 24 * 60 }
                return mins
            }
            let mean = onsetMinutes.reduce(0, +) / Double(onsetMinutes.count)
            let variance = onsetMinutes.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(onsetMinutes.count)
            let stdDevMins = Int(variance.squareRoot())
            if stdDevMins <= 30 {
                summaryParts.append("入睡时间较规律（波动≈\(stdDevMins)分钟）")
            } else if stdDevMins <= 60 {
                summaryParts.append("入睡时间有些波动（波动≈\(stdDevMins)分钟）")
            } else {
                summaryParts.append("入睡时间不太规律（波动≈\(stdDevMins)分钟）")
            }
        }

        lines.append("周睡眠概要：\(summaryParts.joined(separator: "，"))")

        return lines.joined(separator: "\n")
    }

    // MARK: - Photo Search

    /// Detects photo-related queries and runs a local photo search.
    /// Returns both the search results and the parsed query so GPT knows what was searched for.
    private func searchPhotosIfNeeded(query: String) -> (results: [PhotoSearchService.SearchResult], query: PhotoSearchService.PhotoQuery?) {
        let lower = query.lowercased()
        // Specific photo keywords — always trigger search
        let specificKeywords = [
            "找照片", "搜照片", "找图片", "搜图片", "找找照片", "照片搜索",
            "find photo", "search photo", "show me photo",
            "的照片", "的图片", "的相片",
            "photo of", "picture of",
            "拍的", "拍了", "拍过"
        ]
        // Generic action keywords — only trigger when combined with photo context
        let genericKeywords = ["帮我找", "给我找", "搜一下", "找一下"]
        let photoContext = ["照片", "图片", "相片", "photo", "picture", "拍", "自拍", "截图", "视频"]

        let hasSpecific = specificKeywords.contains(where: { lower.contains($0) })
        let hasGenericWithContext = genericKeywords.contains(where: { lower.contains($0) })
            && photoContext.contains(where: { lower.contains($0) })
        guard hasSpecific || hasGenericWithContext else { return ([], nil) }

        let parsed = photoSearchService.parseQuery(query)
        // Only search if we have meaningful criteria (keywords or location)
        guard !parsed.keywords.isEmpty || parsed.location != nil || parsed.isSelfie == true else { return ([], parsed) }
        let results = photoSearchService.search(query: parsed, limit: 20)
        return (results, parsed)
    }

    private func photoSearchSection(_ results: [PhotoSearchService.SearchResult],
                                     query: PhotoSearchService.PhotoQuery? = nil) -> String {
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "M月d日"
        let total = results.count
        let withLocation = results.filter { $0.latitude != 0 }.count

        var lines = ["[照片搜索结果]"]

        // Include search criteria so GPT can describe what was searched and give
        // contextual responses (e.g. "找到15张在日本拍的风景照" vs "找到15张照片")
        if let pq = query {
            var criteria: [String] = []
            if !pq.locationName.isEmpty { criteria.append("地点：\(pq.locationName)") }
            if !pq.keywords.isEmpty { criteria.append("类型：\(pq.keywords.joined(separator: "、"))") }
            if pq.isSelfie == true { criteria.append("自拍") }
            if let min = pq.minFaces, min > 1 { criteria.append("多人合照") }
            if !criteria.isEmpty {
                lines.append("搜索条件：\(criteria.joined(separator: "，"))")
            }
        }

        lines.append("找到 \(total) 张匹配的照片" + (total >= 20 ? "（显示前20张）" : ""))

        // Date range of results
        let dates = results.compactMap { $0.date }
        if let earliest = dates.min(), let latest = dates.max() {
            if Calendar.current.isDate(earliest, inSameDayAs: latest) {
                lines.append("拍摄日期：\(dateFmt.string(from: earliest))")
            } else {
                lines.append("拍摄日期范围：\(dateFmt.string(from: earliest)) ~ \(dateFmt.string(from: latest))")
            }
        }

        if withLocation > 0 {
            lines.append("含地理位置：\(withLocation) 张")
        }

        // Top tags across all results for context
        var tagCounts: [String: Int] = [:]
        for r in results {
            for tag in r.tags where !tag.isEmpty {
                tagCounts[tag, default: 0] += 1
            }
        }
        let topTags = tagCounts.sorted { $0.value > $1.value }.prefix(8).map { $0.key }
        if !topTags.isEmpty {
            lines.append("主要标签：\(topTags.joined(separator: "、"))")
        }

        // Brief per-photo details (first 5)
        if results.count <= 5 {
            lines.append("详情：")
            for (i, r) in results.enumerated() {
                var detail = "  \(i + 1). "
                if let d = r.date { detail += "\(dateFmt.string(from: d)) " }
                if !r.tags.prefix(3).isEmpty { detail += "[\(r.tags.prefix(3).joined(separator: ","))]" }
                if r.faceCount > 0 { detail += " \(r.faceCount)人" }
                lines.append(detail)
            }
        }

        lines.append("提示：照片已在 App 界面以图片网格展示给用户，你只需用文字描述搜索结果概况。")
        return lines.joined(separator: "\n")
    }

}

// MARK: - CoreData Fetch Helpers

private extension CDLocationRecord {
    /// Fetches location records since a given date.
    /// The caller provides the exact start date (with startOfDay applied) to ensure
    /// consistency with other data sources (health, photos, calendar).
    static func fetchRecent(in context: NSManagedObjectContext, since fromDate: Date) -> [CDLocationRecord] {
        let req = NSFetchRequest<CDLocationRecord>(entityName: "CDLocationRecord")
        req.predicate = NSPredicate(format: "timestamp >= %@", fromDate as NSDate)
        req.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        req.fetchLimit = 200
        return (try? context.fetch(req)) ?? []
    }
}

private extension CDLifeEvent {
    static func fetchRecent(limit: Int, in context: NSManagedObjectContext) -> [CDLifeEvent] {
        let req = NSFetchRequest<CDLifeEvent>(entityName: "CDLifeEvent")
        req.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        req.fetchLimit = limit
        return (try? context.fetch(req)) ?? []
    }
}

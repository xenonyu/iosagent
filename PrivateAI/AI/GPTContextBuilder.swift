import Foundation
import CoreData
import CoreLocation

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
        var weeklyHealth: [HealthSummary] = []

        // Fetch 14 days so "上周" always has complete Mon-Sun data.
        // Without this, on a Wednesday the 7-day window only covers Thu→Wed,
        // leaving last Mon/Tue/Wed missing — GPT would caveat "仅有4/7天数据"
        // and give incomplete weekly comparisons.
        //
        // Today's data is extracted from this same array (the i=0 entry) rather
        // than fetched separately via fetchDailySummary. This eliminates ~13
        // redundant HealthKit queries per prompt build AND prevents data
        // inconsistency: if steps/calories arrive between two separate fetches,
        // [今日健康数据] and the trend table's "今天" row would show different
        // numbers, causing GPT to cite conflicting values.
        group.enter()
        healthService.fetchSummaries(days: 14) { summaries in
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
                    weeklyHealth = []
                    healthTimedOut = true
                }

                // Extract today's health from the 14-day array — guaranteed to be
                // the exact same HealthSummary object used in the trend table, so
                // GPT never sees conflicting numbers between sections.
                let todayHealth: HealthSummary = weeklyHealth.first(where: {
                    Calendar.current.isDateInToday($0.date)
                }) ?? HealthSummary()

                let now = Date()
                let cal = Calendar.current
                // Use startOfDay to ensure we capture full calendar days.
                // Extend to 14 days (same as health data) so "上周" queries always
                // have complete Mon-Sun data for calendar/location/photos too.
                // Without this, on a Wednesday "上周一到上周三" is 8-10 days ago
                // and would be missing from the prompt entirely.
                let dataRangeStart = cal.startOfDay(for: cal.date(byAdding: .day, value: -13, to: now) ?? now)
                let sevenDaysAhead = cal.date(byAdding: .day, value: 7, to: now) ?? now

                let todayEvents = self.calendarService.todayEvents()
                let upcomingEvents = self.calendarService.fetchEvents(from: now, to: sevenDaysAhead)
                // Fetch past 14 days of calendar events so GPT can answer
                // "what meetings did I have yesterday?" and "上周有什么会议?"
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

        // Include timezone so GPT can correctly interpret all timestamps in the prompt.
        // Without this, GPT might assume UTC or a wrong timezone, causing errors when
        // users ask about events spanning time zones or when the Azure backend is in a
        // different region (Japan East).
        let tzAbbrev = TimeZone.current.abbreviation() ?? "UTC"
        let tzOffsetSeconds = TimeZone.current.secondsFromGMT()
        let tzOffsetHours = tzOffsetSeconds / 3600
        let tzOffsetMins = abs(tzOffsetSeconds % 3600) / 60
        let tzOffset = tzOffsetMins == 0
            ? "UTC\(tzOffsetHours >= 0 ? "+" : "")\(tzOffsetHours)"
            : "UTC\(tzOffsetHours >= 0 ? "+" : "")\(tzOffsetHours):\(String(format: "%02d", tzOffsetMins))"
        let tzName = TimeZone.current.localizedName(for: .shortGeneric, locale: Locale(identifier: "zh_CN")) ?? tzAbbrev

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
        let dataStartDate = Calendar.current.date(byAdding: .day, value: -13, to: now) ?? now
        let healthRangeStart = dataStartDate
        let healthBoundary = "健康/运动/睡眠数据：\(boundaryFmt.string(from: healthRangeStart))~\(boundaryFmt.string(from: now))（共14天，每天有详细趋势数据，完整覆盖本周+上周）"
        let locationBoundary = locationRecords.isEmpty ? "" : {
            let timestamps = locationRecords.compactMap { $0.timestamp }
            if let earliest = timestamps.min(), let latest = timestamps.max() {
                return "位置记录：\(boundaryFmt.string(from: earliest))~\(boundaryFmt.string(from: latest))"
            }
            return "位置记录：近14天"
        }()
        let calendarEndDate = Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now
        let calendarBoundary = "日历日程：\(boundaryFmt.string(from: dataStartDate))~\(boundaryFmt.string(from: calendarEndDate))（过去14天+未来7天）"
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

        // Build explicit "this week" / "last week" boundaries so GPT can correctly
        // scope temporal queries like "这周运动了几次" vs "上周睡得怎么样".
        // Without this, GPT often conflates "近7天" with "这周", e.g. on Wednesday
        // it might count last Thu/Fri/Sat/Sun data as "this week" because all 7 days
        // are present in the trend table.
        let weekBoundaryText: String = {
            let wkCal = Calendar.current
            // Monday-based week (ISO 8601, standard in Chinese locale)
            let todayWeekday = wkCal.component(.weekday, from: now) // 1=Sun..7=Sat
            let daysSinceMonday = (todayWeekday + 5) % 7 // Mon=0, Tue=1, ..., Sun=6
            let thisMonday = wkCal.date(byAdding: .day, value: -daysSinceMonday, to: wkCal.startOfDay(for: now))!
            let lastMonday = wkCal.date(byAdding: .day, value: -7, to: thisMonday)!
            let lastSunday = wkCal.date(byAdding: .day, value: -1, to: thisMonday)!

            let wkFmt = DateFormatter(); wkFmt.dateFormat = "M月d日"
            let thisWeekLabel = "\(wkFmt.string(from: thisMonday))~\(wkFmt.string(from: now))（周一至今天，共\(daysSinceMonday + 1)天）"
            let lastWeekLabel = "\(wkFmt.string(from: lastMonday))~\(wkFmt.string(from: lastSunday))（周一至周日，健康数据完整）"
            return "「这周」= \(thisWeekLabel)\n「上周」= \(lastWeekLabel)"
        }()

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
        当前时间：\(weekday)（\(tzName)，\(tzOffset)）
        可用数据源：\(availSummary)\(unavailSummary)

        数据时间范围（重要）：
        \(dataBoundaryText)
        \(weekBoundaryText)
        ⚠️ 你只拥有上述时间范围内的数据。所有数据（健康/日历/位置/照片）覆盖近14天（本周+上周完整），日历额外包含未来7天。如果用户询问的时间段超出数据覆盖范围（如「上个月」「今年」「过去30天」），你必须：
        1. 先说明你拥有的数据范围（近14天）
        2. 基于已有数据给出部分回答（如「近两周内…」）
        3. 不要将有限数据外推为更长时间段的结论
        ⚠️ 「这周」和「近7天」是不同概念。用户说「这周」指本周一至今天，说「上周」指上周一至上周日。回答时务必按上方日期范围筛选对应的数据行，不要把上周的数据算入这周，也不要把这周的数据算入上周。
        \(hourOfDay < 5 ? """
        ⚠️ 深夜/凌晨时间语境（重要）：现在是凌晨\(hourOfDay)点多，用户很可能还没有睡觉。在这个时段：
        - 用户说「今天」很大概率指的是刚刚过去的那一天（即日历上的「昨天」），因为在用户的感知中一天还没有结束。
        - 回答时优先引用「昨天」的完整数据（见[昨日健康概要]或趋势表中「昨天」行），然后补充说明「新一天（日历上的今天）刚开始，数据还在积累」。
        - 例如：用户凌晨2点问「今天走了多少步」→ 应该回答「你刚过去的这一天走了X步」并引用昨天的数据，而不是说「今天0步」。
        - 如果用户明确说「新的一天」或「日历上的今天」，再回答当前日历日的数据。
        """ : "")
        ⚠️ 睡眠日期归属规则（重要）：睡眠数据按「醒来当天」归属。例如\(boundaryFmt.string(from: Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now))晚23:00入睡→\(boundaryFmt.string(from: now))早7:00起床，这笔睡眠记录在\(boundaryFmt.string(from: now))（今天）的行中，而不是\(boundaryFmt.string(from: Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now))。因此：
        - 用户问「昨晚睡了多久」「昨天晚上睡得怎么样」→ 查看「今天」行的睡眠数据（因为昨晚的睡眠醒来时已是今天）
        - 用户问「前天晚上」→ 查看「昨天」行的睡眠数据
        - 趋势表和睡眠分析中已标注每行对应的实际睡眠夜晚（如「\(boundaryFmt.string(from: Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now))晚→\(boundaryFmt.string(from: now))」），请据此匹配用户提到的时间。

        能力边界：
        - 你只能读取数据，不能创建、修改或保存任何记录。如果用户想记录事情，告诉他可以在 App 的生活记录页面手动添加。
        - 你不能发送消息、设置闹钟、打电话等操作类任务。
        - 如果用户询问的数据标注为「未授权」，请明确告诉用户需要在 iPhone 的「设置 → iosclaw」中开启对应权限，而不是模糊地说「可能未授权」。
        - 如果数据标注为「已授权但无数据」，则说明权限正常，只是该时间段内确实没有相关数据，不需要建议用户去开权限。

        ⚠️ 以下数据本 App 不追踪，你没有这些信息，绝对不要编造：
        - 饮食/食物/营养/卡路里摄入（注意：我们只有卡路里「消耗」数据，没有「摄入」数据。用户问「吃了什么」「吃了多少卡路里」时，明确说明没有饮食记录功能，可建议用户使用专门的饮食记录 App）
        - 饮水量
        - 血压、血糖
        - 经期/月经周期
        - 屏幕使用时间 / App 使用情况
        - 社交媒体 / 通讯记录 / 通话记录
        - 财务/消费记录
        - 用药/服药提醒
        如果用户询问以上内容，坦诚说明「这类数据我暂时无法获取」，并简要建议可以用什么方式记录（如 iOS 健康 App 手动录入血压、使用屏幕使用时间功能等），但不要编造数据。

        回复要求：
        - \(toneInstruction)
        - 如果用户用英文提问，用英文回答。
        - 引用具体数据时，必须使用下方提供的真实数据，不要编造任何数字。
        - 如果某项数据为 0 或为空，坦诚说明「暂无该数据」或「尚未授权」，不要猜测。
        - 回答健康、运动相关问题时，优先引用准确数值，再结合[健康参考标准]给出个性化解读（如「离建议的7000步还差1500步」），不要只说数字。
        - ⚠️ 今日健康数据标注了「截至X点」。如果现在还在上午或下午，今天的步数/运动/卡路里等数据还会继续增长，不要过早下结论说「今天步数偏少」「运动不够」。应该说「截至目前…」或「到目前为止…」，必要时可鼓励用户继续保持。只有晚上10点之后的数据才接近当天最终值。
        - ⚠️ 卡路里说明：「活动kcal」是运动/活动消耗，「总消耗kcal」= 活动 + 基础代谢（身体维持生命所需能量）。用户问「今天消耗了多少卡路里」时，应回答总消耗值。基础代谢约占总消耗60-75%，这是正常的。
        - ⚠️ 活动圆环（Apple Watch 三圆环）说明：用户问「圆环合了吗」「三个圆环怎么样」时，结合活动卡路里（🔴Move）、运动分钟数（🟢Exercise）和站立时间（🔵Stand）来评估。如果某个圆环数据为0或缺失，说明可能未佩戴 Apple Watch。站立时间衡量的是「一天中有几个小时站起来活动了」。
        - 涉及多天数据时，可引用「近14天趋势」进行对比分析，指出趋势变化。
        - 周统计中会标注「X天中Y天有运动」，回答时要如实反映活跃天数，不要把少数几天的数据当作每天都达到了。例如7天中2天运动共60分钟，应该说「这周运动了2天，共60分钟」，而不是「日均运动30分钟」。
        - ⚠️ 跨周对比时，务必使用「日均」数据进行公平比较，因为本周天数可能不足7天。例如本周4天日均消耗2100kcal vs 上周7天日均2000kcal → 说明本周消耗更高，而不是比较总量（8400 vs 14000）得出本周更少的错误结论。
        - ⚠️ 体重数据说明：趋势表和周统计中会包含体重数据（如有记录）。体重数据来自智能体重秤或手动录入，不一定每天都有。回答体重趋势时，关注变化方向和幅度，短期波动（0.5kg以内）通常是正常的水分变化，不要过度解读。如果只有1-2天的记录，说明数据有限，不宜下趋势结论。
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

        // HEALTH REFERENCE BENCHMARKS — age-adjusted so GPT can give personalized insights
        // e.g. "离推荐的8000步还差1500步" instead of just "你走了6500步"
        let benchmarks = healthBenchmarks()
        if !benchmarks.isEmpty {
            parts.append(benchmarks)
        }

        // TODAY'S HEALTH
        parts.append(healthSection(todayHealth, weeklyHealth: weeklyHealth, hourOfDay: hourOfDay, healthTimedOut: healthTimedOut))

        // When today's data is empty (e.g. early morning), surface yesterday's key
        // metrics so GPT can still answer "how did I do yesterday?" or "how was my sleep?"
        // Also always surface yesterday's data during late-night hours (0-5 AM) even if
        // today has some data (e.g. sleep tracking), because at 2 AM the user's "today"
        // almost certainly refers to the previous calendar day.
        let shouldShowYesterday = (!todayHasHealth && hourOfDay < 10) || hourOfDay < 5
        if shouldShowYesterday {
            if let yesterday = weeklyHealth.first(where: {
                Calendar.current.isDateInYesterday($0.date) &&
                ($0.steps > 0 || $0.sleepHours > 0 || $0.exerciseMinutes > 0)
            }) {
                parts.append(yesterdayHighlight(yesterday))
            }
        }

        // 14-DAY HEALTH TREND (full per-day table for all available data)
        if weeklyHealth.count >= 3 {
            parts.append(trendSection(weeklyHealth))
        }

        // 14-DAY SLEEP QUALITY (per-day phase breakdown for sleep analysis)
        // Uses all 14 days so GPT can answer "上周睡得怎么样" with per-night details,
        // not just the aggregate from buildPerWeekStats.
        let sleepAnalysis = weeklySleepSection(weeklyHealth)
        if !sleepAnalysis.isEmpty {
            parts.append(sleepAnalysis)
        }

        // 14-DAY WORKOUT HISTORY (individual sessions GPT can reference)
        // Uses all 14 days so GPT can answer "上周做了什么运动" with session details.
        let workoutHistory = weeklyWorkoutSection(weeklyHealth)
        if !workoutHistory.isEmpty {
            parts.append(workoutHistory)
        }

        // CALENDAR — only include when authorized or has data.
        // When not authorized, all event arrays are empty and calendarSection would output
        // "今天：无日程", which contradicts the SYSTEM prompt's "日历日程（未授权…）" message.
        // This misleads GPT into saying "you have no events" instead of guiding the user
        // to grant calendar permission. Location/photos/lifeEvents are already gated.
        let hasCalendarData = !todayEvents.isEmpty || !upcomingEvents.isEmpty || !pastEvents.isEmpty
        if hasCalendarData || self.calendarService.isAuthorized {
            parts.append(calendarSection(todayEvents: todayEvents, upcoming: upcomingEvents, past: pastEvents))
        }

        // LOCATION — include current live position when available.
        // CDLocationRecord only saves on 200m+ moves, so the user's latest
        // position may not be persisted yet. Adding CLLocation gives GPT
        // the ability to answer "我现在在哪？" accurately.
        if !locationRecords.isEmpty || self.locationService.currentLocation != nil {
            parts.append(locationSection(locationRecords,
                                         currentLocation: self.locationService.currentLocation,
                                         currentPlaceName: self.locationService.currentPlaceName,
                                         currentAddress: self.locationService.currentAddress))
        }

        // PHOTO STATS
        if !recentPhotos.isEmpty {
            parts.append(photoSection(recentPhotos, locationRecords: locationRecords))
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
                    // Recency-biased truncation: keep the most recent exchange at a
                    // higher char limit so GPT has rich context for follow-up questions
                    // (e.g. "详细说说运动" after a weekly summary). Older messages are
                    // truncated more aggressively to save tokens.
                    // "Most recent" = last 2 messages in the array (typically 1 user + 1 assistant).
                    let isRecent = idx >= histArray.count - 2
                    let charLimit: Int
                    if msg.isUser {
                        charLimit = isRecent ? 300 : 150
                    } else {
                        charLimit = isRecent ? 600 : 200
                    }
                    let truncated = content.count > charLimit ? String(content.prefix(charLimit)) + "…" : content
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

        // QUERY RELEVANCE HINT — guides GPT's attention to the most relevant
        // data sections without removing any data (safe fallback). This reduces
        // "over-referencing" where GPT cites irrelevant data in its response
        // (e.g. mentioning calendar events when user asked about step count).
        let relevanceHint = buildRelevanceHint(query: userQuery, conversationHistory: conversationHistory)
        if !relevanceHint.isEmpty {
            parts.append(relevanceHint)
        }

        // TEMPORAL FOCUS HINT — resolves relative time expressions ("昨天", "上周",
        // "前天") to exact calendar dates so GPT can directly match them to the
        // correct rows in the trend table, sleep analysis, and calendar sections.
        // Without this, GPT often mismatches temporal references:
        //   - "昨晚睡得怎么样" → GPT looks at yesterday's sleep row instead of today's
        //     (sleep is attributed to the wake-up day)
        //   - "前天去了哪里" → GPT isn't sure which date "前天" is
        //   - "上周运动了几次" → GPT may include this week's data by mistake
        let temporalHint = buildTemporalHint(query: userQuery)
        if !temporalHint.isEmpty {
            parts.append(temporalHint)
        }

        // CURRENT QUESTION
        parts.append("[当前问题]\n用户说：\(userQuery)")

        return parts.joined(separator: "\n\n")
    }

    // MARK: - Query Relevance

    /// Data topic categories for guiding GPT's attention.
    private enum QueryTopic: String, CaseIterable {
        case health     // 步数、运动、睡眠、心率、卡路里、体重
        case calendar   // 日程、会议、日历、安排
        case location   // 位置、去过、地方、足迹
        case photos     // 照片、图片、拍
        case lifeEvents // 记录、备忘、心情
        case general    // 总结、回顾、你好 → include all
    }

    /// Detects which data topics the user's query is about.
    /// Returns a set of relevant topics. If no specific topic matches or the
    /// query is a general/summary question, returns all topics (safe fallback).
    /// When `previousUserQuery` is provided and the current query looks like a
    /// follow-up (short, uses context words like "那…呢"), inherits topics from
    /// the previous query so the relevance hint stays focused.
    private func detectQueryTopics(_ query: String, previousUserQuery: String? = nil) -> Set<QueryTopic> {
        let lower = query.lowercased()
        var topics: Set<QueryTopic> = []

        let healthWords = [
            "步数", "步", "走路", "走了", "跑步", "跑了", "运动", "锻炼", "健身",
            "睡眠", "睡觉", "睡了", "睡得", "入睡", "起床", "失眠", "早起", "熬夜", "晚睡",
            "心率", "心跳", "卡路里", "热量", "消耗", "能量",
            "体重", "胖", "瘦", "血氧", "VO2", "减肥", "增重",
            // Specific workout types — users often ask about specific activities
            "游泳", "骑车", "骑行", "瑜伽", "散步", "爬山", "徒步", "举铁", "力量训练",
            "拉伸", "冥想", "太极", "跳绳", "划船", "椭圆机", "高强度",
            // Physical condition — often relates to health/sleep data
            "累", "疲劳", "精力", "恢复", "酸痛", "状态",
            // Activity Rings (Apple Watch) — users commonly ask "圆环合了吗？"
            "圆环", "活动圆环", "站立", "站了",
            "exercise", "sleep", "step", "heart", "workout", "calorie", "weight",
            "hrv", "vo2", "bpm", "swimming", "cycling", "yoga", "hiking", "running",
            "stand", "ring", "activity ring"
        ]
        if healthWords.contains(where: { lower.contains($0) }) {
            topics.insert(.health)
        }

        let calendarWords = [
            "日程", "日历", "会议", "安排", "行程", "活动", "计划", "开会",
            // Appointment & work-related terms
            "约", "预约", "面试", "上班", "下班", "提醒", "截止", "deadline",
            "见面", "聚餐", "聚会", "约会",
            "schedule", "calendar", "meeting", "event", "appointment", "interview"
        ]
        if calendarWords.contains(where: { lower.contains($0) }) {
            topics.insert(.calendar)
        }

        let locationWords = [
            "去了", "去过", "地方", "位置", "在哪", "哪里", "足迹", "出门",
            "城市", "回家", "公司", "地点",
            // Movement & commute terms
            "附近", "通勤", "出差", "旅行", "路线", "距离", "远", "逛",
            "location", "where", "place", "travel", "commute", "nearby"
        ]
        if locationWords.contains(where: { lower.contains($0) }) {
            topics.insert(.location)
        }

        let photoWords = [
            "照片", "图片", "相片", "拍照", "拍了", "拍的", "拍过",
            "相册", "美照", "风景照", "合影", "合照",
            "photo", "picture", "pic", "视频", "video", "自拍", "截图", "selfie"
        ]
        if photoWords.contains(where: { lower.contains($0) }) {
            topics.insert(.photos)
        }

        let lifeWords = [
            "记录", "备忘", "日记", "心情", "情绪", "感受", "记了", "记过",
            "mood", "note", "journal", "diary"
        ]
        if lifeWords.contains(where: { lower.contains($0) }) {
            topics.insert(.lifeEvents)
        }

        // General/summary queries → include all.
        // IMPORTANT: Do NOT include temporal words like "今天", "这周", "上周" here!
        // Those are time modifiers, not topic indicators. "今天走了多少步" should
        // match health only, not general. Putting "今天" in generalWords defeats
        // the entire relevance hint mechanism for the majority of real queries.
        // Similarly, "怎么样" is too ambiguous — "睡得怎么样" is health-specific,
        // not general. Only truly topic-agnostic words belong here.
        // "一天" and "一周" were previously here but REMOVED — they are temporal
        // modifiers, not topic indicators. "一周运动了几次" should match health only;
        // "一天走多少步合适" should match health only. Having them here caused the
        // relevance hint to be disabled for the majority of queries with temporal
        // qualifiers, defeating the entire focus mechanism.
        // Instead, add truly topic-agnostic "what did I do" patterns that signal
        // the user wants a cross-domain summary (not just one data type).
        let generalWords = [
            "总结", "回顾", "概括", "过得怎么样", "过得如何",
            "summary", "review", "overview",
            "你好", "谢谢", "嗨", "hello", "hi", "hey", "你是谁",
            "什么都", "所有",
            // "What did I do" patterns — truly general, asking about all activities
            "干了什么", "做了什么", "干什么了", "做什么了",
            "怎么过的", "发生了什么", "忙什么", "忙些什么",
            "都有什么", "都干了", "都做了",
            "what did i do", "what happened"
        ]
        if generalWords.contains(where: { lower.contains($0) }) {
            topics.insert(.general)
        }

        // If no specific topic detected or includes general, return all —
        // BUT first check if this looks like a follow-up query that should
        // inherit topics from the previous exchange.
        if topics.isEmpty || topics.contains(.general) {
            // Follow-up detection: short queries with context-dependent words
            // like "那…呢", "详细说说", "也看看", "继续" strongly suggest the user
            // is continuing the same topic from the previous exchange. Without
            // topic inheritance, the relevance hint becomes empty and GPT loses
            // its focus guidance for these very common interaction patterns.
            if topics.isEmpty, let prevQuery = previousUserQuery, !prevQuery.isEmpty {
                let followUpPatterns = [
                    "呢", "那", "也", "再", "还", "详细", "具体", "多说", "展开",
                    "继续", "接着", "然后", "对比", "比较", "怎么样", "如何",
                    "更多", "补充", "分析", "解释", "为什么",
                    "what about", "more", "detail", "compare", "continue", "why",
                    "how about", "and", "also", "tell me more"
                ]
                let isLikelyFollowUp = lower.count <= 20
                    || followUpPatterns.contains(where: { lower.contains($0) })

                if isLikelyFollowUp {
                    let inherited = detectQueryTopics(prevQuery) // no previousUserQuery → won't recurse
                    // Only inherit if the previous query had specific topics (not general)
                    if inherited != Set(QueryTopic.allCases) && !inherited.isEmpty {
                        return inherited
                    }
                }
            }
            return Set(QueryTopic.allCases)
        }

        return topics
    }

    /// Builds a hint section that tells GPT which data sections are most relevant
    /// to the user's question. This helps GPT produce more focused answers by
    /// prioritizing the right data instead of over-referencing everything.
    /// Uses conversation history to detect follow-up queries and inherit topics.
    private func buildRelevanceHint(query: String, conversationHistory: [ChatMessage] = []) -> String {
        // Extract the previous user query for follow-up topic inheritance.
        // The most recent user message in history (excluding the current query)
        // is the one the user might be following up on.
        let previousUserQuery = conversationHistory
            .filter { $0.isUser && $0.content != query }
            .last?.content

        let topics = detectQueryTopics(query, previousUserQuery: previousUserQuery)

        // If all topics are relevant (general query), no need for a hint
        if topics == Set(QueryTopic.allCases) { return "" }

        var sectionNames: [String] = []
        if topics.contains(.health) {
            sectionNames.append("[今日健康数据]、[近14天健康趋势]、[睡眠质量分析]、[运动记录]")
        }
        if topics.contains(.calendar) {
            sectionNames.append("[日历日程]")
        }
        if topics.contains(.location) {
            sectionNames.append("[位置记录]")
        }
        if topics.contains(.photos) {
            sectionNames.append("[照片统计]、[照片搜索结果]")
        }
        if topics.contains(.lifeEvents) {
            sectionNames.append("[生活记录]")
        }

        guard !sectionNames.isEmpty else { return "" }

        return "[查询重点提示]\n用户问题主要涉及：\(sectionNames.joined(separator: "、"))。请重点参考这些部分的数据回答，其他部分的数据除非明显相关否则无需引用。"
    }

    // MARK: - Temporal Focus

    /// Detects relative time expressions in the user's query and resolves them
    /// to exact calendar dates. This eliminates a major source of GPT errors:
    /// when the user says "昨天" or "前天", GPT has to mentally calculate dates
    /// from the "当前时间" line and match them to data rows — often incorrectly.
    ///
    /// Pre-resolving dates also helps with tricky sleep attribution: "昨晚睡得
    /// 怎么样" needs today's row (sleep is attributed to wake-up day), and without
    /// an explicit date mapping, GPT consistently looks at yesterday's row.
    private func buildTemporalHint(query: String) -> String {
        let lower = query.lowercased()
        let cal = Calendar.current
        let now = Date()
        let dateFmt = DateFormatter(); dateFmt.dateFormat = "M月d日"
        let weekdayFmt = DateFormatter()
        weekdayFmt.locale = Locale(identifier: "zh_CN")
        weekdayFmt.dateFormat = "EEEE"

        var hints: [String] = []

        // --- Single-day references ---

        let yesterdayDate = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now))!
        let twoDaysAgo = cal.date(byAdding: .day, value: -2, to: cal.startOfDay(for: now))!
        let threeDaysAgo = cal.date(byAdding: .day, value: -3, to: cal.startOfDay(for: now))!
        let tomorrowDate = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
        let dayAfterTomorrow = cal.date(byAdding: .day, value: 2, to: cal.startOfDay(for: now))!

        // "昨天" / "yesterday"
        let yesterdayWords = ["昨天", "昨日", "yesterday"]
        if yesterdayWords.contains(where: { lower.contains($0) }) {
            hints.append("「昨天」= \(dateFmt.string(from: yesterdayDate))（\(weekdayFmt.string(from: yesterdayDate))）→ 趋势表/日历/位置中标记为「昨天」的行")
        }

        // "昨晚" / "last night" — special: sleep attributed to today's row
        let lastNightWords = ["昨晚", "昨天晚上", "昨夜", "last night"]
        if lastNightWords.contains(where: { lower.contains($0) }) {
            hints.append("「昨晚」的睡眠 → 查看趋势表中「今天」行的睡眠数据（因为昨晚入睡→今天醒来，归属今天）")
        }

        // "前天" / "the day before yesterday"
        let twoDaysAgoWords = ["前天", "前日", "day before yesterday"]
        if twoDaysAgoWords.contains(where: { lower.contains($0) }) {
            hints.append("「前天」= \(dateFmt.string(from: twoDaysAgo))（\(weekdayFmt.string(from: twoDaysAgo))）→ 趋势表中标记为「前天」的行")
        }

        // "前天晚上" — sleep attributed to yesterday's row
        let twoDaysAgoNightWords = ["前天晚上", "前天夜里", "前晚"]
        if twoDaysAgoNightWords.contains(where: { lower.contains($0) }) {
            hints.append("「前天晚上」的睡眠 → 查看趋势表中「昨天」行的睡眠数据（前天晚上入睡→昨天醒来，归属昨天）")
        }

        // "大前天"
        if lower.contains("大前天") {
            hints.append("「大前天」= \(dateFmt.string(from: threeDaysAgo))（\(weekdayFmt.string(from: threeDaysAgo))）")
        }

        // "明天" / "tomorrow"
        let tomorrowWords = ["明天", "明日", "tomorrow"]
        if tomorrowWords.contains(where: { lower.contains($0) }) {
            hints.append("「明天」= \(dateFmt.string(from: tomorrowDate))（\(weekdayFmt.string(from: tomorrowDate))）→ 查看日历日程中「明天」对应的日程")
        }

        // "后天"
        let dayAfterWords = ["后天", "day after tomorrow"]
        if dayAfterWords.contains(where: { lower.contains($0) }) {
            hints.append("「后天」= \(dateFmt.string(from: dayAfterTomorrow))（\(weekdayFmt.string(from: dayAfterTomorrow))）")
        }

        // --- Week references ---

        let todayWeekday = cal.component(.weekday, from: now) // 1=Sun..7=Sat
        let daysSinceMonday = (todayWeekday + 5) % 7
        let thisMonday = cal.date(byAdding: .day, value: -daysSinceMonday, to: cal.startOfDay(for: now))!
        let thisSunday = cal.date(byAdding: .day, value: 6, to: thisMonday)!
        let lastMonday = cal.date(byAdding: .day, value: -7, to: thisMonday)!
        let lastSunday = cal.date(byAdding: .day, value: -1, to: thisMonday)!

        // "这周" / "本周" / "this week"
        let thisWeekWords = ["这周", "本周", "这礼拜", "这星期", "this week"]
        if thisWeekWords.contains(where: { lower.contains($0) }) {
            hints.append("「这周/本周」= \(dateFmt.string(from: thisMonday))（周一）~\(dateFmt.string(from: now))（今天），已过\(daysSinceMonday + 1)天 → 参考「本周」周统计")
        }

        // "上周" / "last week"
        let lastWeekWords = ["上周", "上礼拜", "上星期", "last week"]
        if lastWeekWords.contains(where: { lower.contains($0) }) {
            hints.append("「上周」= \(dateFmt.string(from: lastMonday))（周一）~\(dateFmt.string(from: lastSunday))（周日），完整7天 → 参考「上周」周统计")
        }

        // "下周" / "next week"
        let nextWeekWords = ["下周", "下礼拜", "下星期", "next week"]
        if nextWeekWords.contains(where: { lower.contains($0) }) {
            let nextMonday = cal.date(byAdding: .day, value: 7, to: thisMonday)!
            let nextSunday = cal.date(byAdding: .day, value: 6, to: nextMonday)!
            hints.append("「下周」= \(dateFmt.string(from: nextMonday))（周一）~\(dateFmt.string(from: nextSunday))（周日）→ 查看日历日程中对应日期")
        }

        // --- Weekend / Weekday references ---
        // "周末" is one of the most common Chinese temporal expressions.
        // Without explicit date resolution, GPT frequently misidentifies which
        // Saturday/Sunday the user means, especially near week boundaries
        // (e.g. on Monday, "周末" likely means last Sat-Sun, not next).

        // Compute weekend dates for this week and last week
        let thisSaturday = cal.date(byAdding: .day, value: 5, to: thisMonday)! // Mon+5 = Sat
        let thisSundayDate = cal.date(byAdding: .day, value: 6, to: thisMonday)! // Mon+6 = Sun
        let lastSaturday = cal.date(byAdding: .day, value: -7, to: thisSaturday)!
        let lastSundayDate = cal.date(byAdding: .day, value: -7, to: thisSundayDate)!
        let nextSaturday = cal.date(byAdding: .day, value: 7, to: thisSaturday)!
        let nextSundayDate = cal.date(byAdding: .day, value: 7, to: thisSundayDate)!

        // "上个周末" / "上周末" — always last week's Sat-Sun
        let lastWeekendWords = ["上个周末", "上周末", "上个礼拜末", "上星期末", "last weekend"]
        if lastWeekendWords.contains(where: { lower.contains($0) }) {
            hints.append("「上个周末」= \(dateFmt.string(from: lastSaturday))（周六）~\(dateFmt.string(from: lastSundayDate))（周日）")
        }
        // "下个周末" / "下周末" — next week's Sat-Sun
        else if ["下个周末", "下周末", "下个礼拜末", "下星期末", "next weekend"].contains(where: { lower.contains($0) }) {
            hints.append("「下个周末」= \(dateFmt.string(from: nextSaturday))（周六）~\(dateFmt.string(from: nextSundayDate))（周日）→ 查看日历日程中对应日期")
        }
        // "这个周末" / "周末" — context-dependent:
        //   Before Saturday → this week's upcoming Sat-Sun
        //   On Sat/Sun → today (this weekend)
        //   After Sunday (Mon) → likely refers to last weekend (just passed)
        else if ["这个周末", "这周末", "周末", "礼拜末", "星期末", "weekend"].contains(where: { lower.contains($0) }) {
            let todayStart = cal.startOfDay(for: now)
            if todayStart >= thisSaturday {
                // It's Sat or Sun — user is in the weekend
                hints.append("「周末」= \(dateFmt.string(from: thisSaturday))（周六）~\(dateFmt.string(from: thisSundayDate))（周日）← 本周末（当前正处于周末）")
            } else if daysSinceMonday <= 1 {
                // Mon or Tue — "周末" most likely refers to the one that just passed
                hints.append("「周末」→ 刚过去的周末 = \(dateFmt.string(from: lastSaturday))（周六）~\(dateFmt.string(from: lastSundayDate))（周日），即将到来的周末 = \(dateFmt.string(from: thisSaturday))（周六）~\(dateFmt.string(from: thisSundayDate))（周日）。结合用户问题的时态判断：回顾性问题（去了哪、做了什么）→ 上个周末；计划性问题（有什么安排）→ 这个周末。")
            } else {
                // Wed-Fri — "周末" most likely refers to the upcoming Sat-Sun
                hints.append("「周末」= 即将到来的 \(dateFmt.string(from: thisSaturday))（周六）~\(dateFmt.string(from: thisSundayDate))（周日）")
            }
        }

        // "工作日" / "weekday" — Monday to Friday
        let weekdayTerms = ["工作日", "上班日", "weekday", "weekdays"]
        if weekdayTerms.contains(where: { lower.contains($0) }) {
            let thisFriday = cal.date(byAdding: .day, value: 4, to: thisMonday)! // Mon+4 = Fri
            let lastFriday = cal.date(byAdding: .day, value: -7, to: thisFriday)!
            if lastWeekWords.contains(where: { lower.contains($0) }) {
                // "上周工作日"
                hints.append("「上周工作日」= \(dateFmt.string(from: lastMonday))（周一）~\(dateFmt.string(from: lastFriday))（周五）")
            } else {
                // "这周工作日" or just "工作日"
                let endDay = min(thisFriday, cal.startOfDay(for: now))
                hints.append("「工作日」= 本周 \(dateFmt.string(from: thisMonday))（周一）~\(dateFmt.string(from: endDay))（\(daysSinceMonday < 5 ? "至今天" : "周五")），上周 \(dateFmt.string(from: lastMonday))（周一）~\(dateFmt.string(from: lastFriday))（周五）")
            }
        }

        // --- Ambiguous expressions ---

        // "最近" / "前几天" / "这几天" — common ambiguous terms
        let recentWords = ["最近", "近来", "近期", "recently", "lately"]
        if recentWords.contains(where: { lower.contains($0) }) {
            hints.append("「最近」→ 优先参考近3~7天数据，结合上下文判断具体范围")
        }
        let fewDaysWords = ["前几天", "前些天", "这几天", "这两天"]
        if fewDaysWords.contains(where: { lower.contains($0) }) {
            let threeDaysAgoDate = cal.date(byAdding: .day, value: -3, to: cal.startOfDay(for: now))!
            hints.append("「\(fewDaysWords.first { lower.contains($0) } ?? "前几天")」→ 大约\(dateFmt.string(from: threeDaysAgoDate))~\(dateFmt.string(from: now))（近3~4天）")
        }

        // --- Month references ---
        // Users commonly ask "这个月运动了几次" or "上个月睡得怎么样".
        // Without explicit month boundaries, GPT has to calculate month start/end
        // from the date string and often gets it wrong, especially near month
        // transitions (e.g. on March 2, "上个月" = Feb 1-28, not "近30天").
        // Also clarify data coverage: we only have 14 days, so most month queries
        // will be partial — GPT must communicate this honestly.

        let thisMonthStart = cal.date(from: cal.dateComponents([.year, .month], from: now))!
        let dayOfMonth = cal.component(.day, from: now)

        let lastMonthWords = ["上个月", "上月", "last month"]
        if lastMonthWords.contains(where: { lower.contains($0) }) {
            let lastMonthDate = cal.date(byAdding: .month, value: -1, to: thisMonthStart)!
            let lastMonthEnd = cal.date(byAdding: .day, value: -1, to: thisMonthStart)!
            let lastMonthDays = cal.component(.day, from: lastMonthEnd)
            let lastMonthFmt = DateFormatter(); lastMonthFmt.dateFormat = "M月"
            let monthName = lastMonthFmt.string(from: lastMonthDate)
            // How many days of last month fall within our 14-day window?
            let dataStart = cal.date(byAdding: .day, value: -13, to: cal.startOfDay(for: now))!
            let coveredStart = max(lastMonthDate, dataStart)
            let coveredEnd = min(lastMonthEnd, cal.startOfDay(for: now))
            if coveredStart <= coveredEnd {
                let coveredDays = cal.dateComponents([.day], from: coveredStart, to: coveredEnd).day.map { $0 + 1 } ?? 0
                if coveredDays >= lastMonthDays {
                    hints.append("「上个月」= \(monthName)（\(dateFmt.string(from: lastMonthDate))~\(dateFmt.string(from: lastMonthEnd))，共\(lastMonthDays)天，数据完整覆盖）")
                } else {
                    hints.append("「上个月」= \(monthName)（\(dateFmt.string(from: lastMonthDate))~\(dateFmt.string(from: lastMonthEnd))，共\(lastMonthDays)天）⚠️ 我们只有近14天数据，仅覆盖\(monthName)的\(coveredDays)天（\(dateFmt.string(from: coveredStart))起），请说明数据不完整")
                }
            } else {
                hints.append("「上个月」= \(monthName)（\(dateFmt.string(from: lastMonthDate))~\(dateFmt.string(from: lastMonthEnd))）⚠️ 超出14天数据范围，无法回答，请告知用户")
            }
        }

        let thisMonthWords = ["这个月", "本月", "这月", "this month"]
        if thisMonthWords.contains(where: { lower.contains($0) }) {
            let thisMonthFmt = DateFormatter(); thisMonthFmt.dateFormat = "M月"
            let monthName = thisMonthFmt.string(from: now)
            if dayOfMonth <= 14 {
                hints.append("「这个月」= \(monthName)（\(dateFmt.string(from: thisMonthStart))~\(dateFmt.string(from: now))，已过\(dayOfMonth)天，数据完整覆盖）")
            } else {
                let dataStart = cal.date(byAdding: .day, value: -13, to: cal.startOfDay(for: now))!
                hints.append("「这个月」= \(monthName)（\(dateFmt.string(from: thisMonthStart))~\(dateFmt.string(from: now))，已过\(dayOfMonth)天）⚠️ 我们只有近14天数据，仅覆盖\(dateFmt.string(from: dataStart))起，月初\(dayOfMonth - 14)天无数据，请说明")
            }
        }

        // --- Specific weekday references ---
        // "周三有什么安排？" → resolve to exact date
        let weekdayNames = ["周一": 2, "周二": 3, "周三": 4, "周四": 5, "周五": 6, "周六": 7, "周日": 1,
                            "星期一": 2, "星期二": 3, "星期三": 4, "星期四": 5, "星期五": 6, "星期六": 7, "星期天": 1, "星期日": 1]
        for (name, targetWeekday) in weekdayNames {
            guard lower.contains(name) else { continue }
            // Determine if user means this week or last week's weekday.
            // If the referenced weekday has already passed this week, it likely
            // refers to last week (unless context suggests next week). If it hasn't
            // come yet, it's this week.
            let targetDaysSinceMonday = (targetWeekday + 5) % 7
            let targetThisWeek = cal.date(byAdding: .day, value: targetDaysSinceMonday, to: thisMonday)!

            if targetThisWeek <= cal.startOfDay(for: now) {
                // This weekday has passed — could be this week (past) or last week
                let targetLastWeek = cal.date(byAdding: .day, value: -7, to: targetThisWeek)!
                hints.append("「\(name)」→ 本周\(name) = \(dateFmt.string(from: targetThisWeek))（已过），上周\(name) = \(dateFmt.string(from: targetLastWeek))")
            } else {
                // This weekday hasn't come yet — this week
                hints.append("「\(name)」→ 本周\(name) = \(dateFmt.string(from: targetThisWeek))（即将到来）")
            }
            break // only resolve one weekday reference
        }

        guard !hints.isEmpty else { return "" }

        return "[时间聚焦]\n\(hints.joined(separator: "\n"))"
    }

    // MARK: - Section Builders

    /// Generates age-adjusted health reference benchmarks so GPT can provide
    /// contextual, personalized insights ("你达到了推荐步数目标的80%") instead
    /// of just repeating raw numbers. Sources: WHO, ACSM, NSF guidelines.
    private func healthBenchmarks() -> String {
        // Compute user's age from profile birthday
        let userAge: Int? = {
            guard let bd = profile.birthday else { return nil }
            let age = Calendar.current.dateComponents([.year], from: bd, to: Date()).year ?? 0
            return age > 0 ? age : nil
        }()

        var lines = ["[健康参考标准]"]

        // Steps — WHO/studies suggest 7000-10000 for adults, adjust by age
        let stepsTarget: String
        if let age = userAge {
            if age < 18 {
                stepsTarget = "青少年建议每天10000-12000步"
            } else if age < 60 {
                stepsTarget = "成人建议每天7000-10000步"
            } else {
                stepsTarget = "60岁以上建议每天6000-8000步"
            }
        } else {
            stepsTarget = "成人建议每天7000-10000步"
        }
        lines.append("步数：\(stepsTarget)")

        // Exercise — WHO recommends 150-300 min/week moderate intensity
        let exerciseTarget: String
        if let age = userAge, age >= 65 {
            exerciseTarget = "65+岁建议每周≥150分钟中等强度运动，含平衡/力量训练"
        } else {
            exerciseTarget = "成人建议每周150-300分钟中等强度运动（约每天22-43分钟）"
        }
        lines.append("运动：\(exerciseTarget)")

        // Sleep — National Sleep Foundation guidelines by age
        let sleepTarget: String
        if let age = userAge {
            if age < 18 {
                sleepTarget = "青少年建议8-10小时"
            } else if age < 65 {
                sleepTarget = "成人建议7-9小时，深睡占比15-25%为佳"
            } else {
                sleepTarget = "65+岁建议7-8小时，深睡比例自然下降属正常"
            }
        } else {
            sleepTarget = "成人建议7-9小时，深睡占比15-25%为佳"
        }
        lines.append("睡眠：\(sleepTarget)")

        // Resting heart rate — Mayo Clinic reference
        lines.append("静息心率：正常60-100bpm，经常运动者可低至40-60bpm")
        lines.append("心率范围：日间最低通常为静息值（睡眠时可更低），最高反映运动强度。持续静息>100bpm或<40bpm值得关注。运动时最高心率可参考220-年龄公式估算上限。")

        // Workout heart rate zones — helps GPT interpret per-workout avgHR and maxHR.
        // Based on max HR estimated from age (220 - age). Without zones, GPT sees
        // "均心率155bpm" but can't tell the user if that's easy jogging or intense cardio.
        if let age = userAge, age > 10 {
            let maxHR = 220 - age
            let zone2Low = Int(Double(maxHR) * 0.6)
            let zone2High = Int(Double(maxHR) * 0.7)
            let zone3High = Int(Double(maxHR) * 0.8)
            let zone4High = Int(Double(maxHR) * 0.9)
            lines.append("运动心率区间（估算最大心率\(maxHR)bpm）：轻松<\(zone2Low) | 燃脂\(zone2Low)-\(zone2High) | 有氧\(zone2High)-\(zone3High) | 无氧\(zone3High)-\(zone4High) | 极限>\(zone4High)bpm")
        } else {
            lines.append("运动心率区间（通用）：轻松<60%最大心率 | 燃脂60-70% | 有氧70-80% | 无氧80-90% | 极限>90%（最大心率≈220-年龄）")
        }

        // HRV
        lines.append("HRV：数值因人而异，趋势比绝对值更重要，持续下降可能提示疲劳或压力")

        // Stand time — Apple Watch Activity Ring
        lines.append("站立：Apple Watch 建议每天至少12个小时有站立活动（每小时站起来活动1分钟以上即计入）")

        // Activity Rings explanation
        lines.append("活动圆环（Apple Watch 三圆环）：🔴活动（Move）= 活动卡路里消耗（用户自定义目标，默认约500kcal），🟢健身（Exercise）= 30分钟运动，🔵站立（Stand）= 12小时站立。用户问「圆环合了吗」时，参考以上默认目标评估完成度。注意：我们只知道默认目标值，用户可能在 Apple Watch 上设置了不同的目标。")

        // Weight — BMI reference only when user has provided height or has weight data
        lines.append("体重：健康体重因身高而异，短期（1-3天）波动0.5-1kg属正常水分变化，关注周均趋势更有意义")

        lines.append("⚠️ 以上为一般参考，回答时结合用户实际数据自然引用，不要生硬罗列标准。用户没问具体指标时不必主动提及。")

        return lines.joined(separator: "\n")
    }

    private func healthSection(_ h: HealthSummary,
                               weeklyHealth: [HealthSummary] = [],
                               hourOfDay: Int = Calendar.current.component(.hour, from: Date()),
                               healthTimedOut: Bool = false) -> String {
        // Add time-of-day context so GPT knows this is partial-day data.
        // Without this, GPT sees "步数：5000" at 10am and might say "偏少",
        // when actually 5000 steps by 10am is excellent progress.
        let timeContext: String
        if hourOfDay < 5 {
            timeContext = "凌晨\(hourOfDay)点多，新的日历日刚开始，以下为日历「今天」的数据（用户可能指的是「昨天」）"
        } else if hourOfDay < 8 {
            timeContext = "清晨，数据刚开始积累"
        } else if hourOfDay < 12 {
            timeContext = "截至上午\(hourOfDay)点，数据持续更新中"
        } else if hourOfDay == 12 {
            timeContext = "截至中午12点，今天还在继续"
        } else if hourOfDay < 18 {
            timeContext = "截至下午\(hourOfDay - 12)点，今天还在继续"
        } else if hourOfDay < 22 {
            timeContext = "截至晚上\(hourOfDay - 12)点，接近一天结束"
        } else {
            timeContext = "截至晚\(hourOfDay - 12)点，今天即将结束"
        }
        var lines = ["[今日健康数据]（\(timeContext)）"]

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

        // Energy — show both active and total so GPT can answer "消耗了多少卡路里" accurately.
        // Users asking about "calories" usually mean total daily expenditure (TDEE), not just
        // exercise calories. TDEE = basal (resting metabolism) + active (exercise/movement).
        if h.activeCalories > 0 || h.basalCalories > 0 {
            let totalCal = Int(h.activeCalories + h.basalCalories)
            var line = "能量消耗：活动\(Int(h.activeCalories))kcal"
            if h.basalCalories > 0 {
                line += " + 基础代谢\(Int(h.basalCalories))kcal = 总计\(totalCal)kcal"
            }
            lines.append(line)
        }

        // Exercise — critical to show 0 so GPT answers "今天运动了吗？" accurately
        if h.exerciseMinutes > 0 {
            lines.append("运动时间：\(Int(h.exerciseMinutes))分钟")
        } else if healthAuthorized && hourOfDay >= 8 {
            lines.append("运动时间：0分钟（今天还没有运动记录）")
        }

        // Stand time — the third Activity Ring on Apple Watch.
        // Users commonly ask "圆环合了吗？" or "今天站了多久？"
        if h.standMinutes > 0 {
            let standHrs = h.standMinutes / 60.0
            if standHrs >= 1 {
                lines.append("站立时间：\(String(format: "%.1f", standHrs))小时（\(Int(h.standMinutes))分钟）")
            } else {
                lines.append("站立时间：\(Int(h.standMinutes))分钟")
            }
        } else if healthAuthorized && hourOfDay >= 8 {
            lines.append("站立时间：0分钟（今天还没有站立记录，可能未佩戴 Apple Watch）")
        }

        if h.heartRate > 0 {
            var line = "心率：均值\(Int(h.heartRate))bpm"
            // Include min-max range so GPT can detect anomalies and give richer insights.
            // "均值75bpm" is far less useful than "均值75bpm（范围52~145bpm）" — the range
            // reveals exercise peaks, nighttime lows, and potential arrhythmia signals.
            if h.heartRateMin > 0 && h.heartRateMax > 0 {
                line += "（范围\(Int(h.heartRateMin))~\(Int(h.heartRateMax))bpm）"
            }
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
                // Heart rate during workout — critical for intensity analysis
                if w.avgHeartRate > 0 {
                    s += " 均心率\(Int(w.avgHeartRate))bpm"
                    if w.maxHeartRate > 0 { s += "(峰值\(Int(w.maxHeartRate)))" }
                }
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
            if healthTimedOut {
                // HealthKit daemon didn't respond in time — don't mislead GPT about auth status.
                // This must match the "读取超时" message in the SYSTEM data availability section.
                lines.append("（HealthKit 读取超时，健康数据暂时无法获取，请稍后再试）")
            } else if healthAuthorized && hourOfDay < 8 {
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
        if y.standMinutes > 0 { lines.append("站立：\(Int(y.standMinutes))分钟") }
        if y.activeCalories > 0 || y.basalCalories > 0 {
            let total = Int(y.activeCalories + y.basalCalories)
            if y.basalCalories > 0 {
                lines.append("能量消耗：活动\(Int(y.activeCalories))kcal + 基础代谢\(Int(y.basalCalories))kcal = 总计\(total)kcal")
            } else {
                lines.append("活动消耗：\(Int(y.activeCalories))kcal")
            }
        }
        if y.sleepHours > 0 {
            var line = "睡眠：\(String(format: "%.1f", y.sleepHours))小时"
            if let onset = y.sleepOnset, let wake = y.wakeTime {
                let fmt = DateFormatter(); fmt.dateFormat = "HH:mm"
                line += "（\(fmt.string(from: onset))~\(fmt.string(from: wake))）"
            }
            lines.append(line)
        }
        if y.heartRate > 0 {
            var hrLine = "心率均值：\(Int(y.heartRate))bpm"
            if y.heartRateMin > 0 && y.heartRateMax > 0 {
                hrLine += "（\(Int(y.heartRateMin))~\(Int(y.heartRateMax))bpm）"
            }
            lines.append(hrLine)
        }
        return lines.joined(separator: "\n")
    }

    private func trendSection(_ summaries: [HealthSummary]) -> String {
        let fmt = DateFormatter(); fmt.dateFormat = "M/d"
        let weekdayFmt = DateFormatter(); weekdayFmt.locale = Locale(identifier: "zh_CN"); weekdayFmt.dateFormat = "EEE"
        let cal = Calendar.current
        // Show ALL available days (up to 14) so GPT can answer per-day questions
        // like "上周三走了多少步" with actual data, not just aggregate stats.
        // Previously limited to 7 days, which left days 8-14 invisible in the trend
        // table even though per-week stats and sleep/workout sections used all 14 days.
        let trendDays = Array(summaries.reversed()) // chronological: oldest→newest
        let hasWeightData = trendDays.contains { $0.bodyMassKg > 0 }

        let hasStandData = trendDays.contains { $0.standMinutes > 0 }
        // Distance column — only show when there's data (same pattern as weight/stand).
        // Walking+running distance is one of the most-asked metrics ("这周走了多远?")
        // but was previously only available in [今日健康数据], not the trend table.
        let hasDistanceData = trendDays.contains { $0.distanceKm > 0.01 }
        // Resting HR and HRV per day — critical for stress/recovery trend analysis.
        // Previously only available as weekly aggregates in weekSubTotal(), which hid
        // day-to-day variations. Users asking "昨天静息心率多少" or "HRV最近几天有变化吗"
        // need per-day data. These are the most medically relevant daily metrics for
        // detecting stress accumulation, overtraining, or illness onset.
        let hasRestingHRData = trendDays.contains { $0.restingHeartRate > 0 }
        let hasHRVData = trendDays.contains { $0.hrv > 0 }
        let headerWeight = hasWeightData ? " | 体重(kg)" : ""
        let headerStand = hasStandData ? " | 站立(分)" : ""
        let headerDistance = hasDistanceData ? " | 距离(km)" : ""
        let headerRHR = hasRestingHRData ? " | 静息HR" : ""
        let headerHRV = hasHRVData ? " | HRV(ms)" : ""
        let dayCount = trendDays.count
        var lines = ["[近\(dayCount)天健康趋势]", "日期  | 步数  | 运动(分) | 活动kcal | 总消耗kcal | 睡眠(h)（对应哪晚） | 心率avg(min~max)bpm\(headerRHR)\(headerHRV)\(headerDistance)\(headerStand)\(headerWeight)"]
        // Show oldest→newest so GPT can naturally read the trend direction
        let chronological = trendDays
        for s in chronological {
            // Include weekday name (周一~周日) so GPT can answer "周三运动了吗？" without date math.
            // Also include "前天" for consistency with calendar/location/life-event sections —
            // when user asks "前天走了多少步", GPT can directly match the label.
            let dayName: String
            if cal.isDateInToday(s.date) {
                // Annotate today's row with the current hour so GPT knows
                // this is partial/accumulating data and avoids premature
                // comparisons like "今天步数比昨天少很多" when it's only 10am.
                let hour = cal.component(.hour, from: Date())
                if hour < 6 {
                    dayName = "今天,凌晨"
                } else if hour < 12 {
                    dayName = "今天,截至\(hour)点"
                } else if hour < 22 {
                    dayName = "今天,截至\(hour)点⚠️未完整"
                } else {
                    dayName = "今天,接近全天"
                }
            } else if cal.isDateInYesterday(s.date) {
                dayName = "昨天"
            } else if let twoDaysAgo = cal.date(byAdding: .day, value: -2, to: cal.startOfDay(for: Date())),
                      cal.isDate(s.date, inSameDayAs: twoDaysAgo) {
                dayName = "前天"
            } else {
                dayName = weekdayFmt.string(from: s.date)
            }
            let dateLabel = "\(fmt.string(from: s.date))(\(dayName))"
            let steps = s.steps > 0 ? "\(Int(s.steps))" : "-"
            let ex = s.exerciseMinutes > 0 ? "\(Int(s.exerciseMinutes))" : "-"
            let activeCal = s.activeCalories > 0 ? "\(Int(s.activeCalories))" : "-"
            let totalCal = (s.activeCalories + s.basalCalories) > 0 ? "\(Int(s.activeCalories + s.basalCalories))" : "-"
            // Annotate sleep with the actual night it represents (sleep is attributed to
            // wake-up day, so "today" row = last night's sleep). This prevents GPT from
            // giving wrong data when user asks "昨晚睡了多久" and GPT looks at "yesterday" row.
            let sl: String
            if s.sleepHours > 0 {
                let prevDay = cal.date(byAdding: .day, value: -1, to: s.date) ?? s.date
                let nightLabel = "\(fmt.string(from: prevDay))晚→\(fmt.string(from: s.date))"
                sl = "\(String(format: "%.1f", s.sleepHours))(\(nightLabel))"
            } else {
                sl = "-"
            }
            let hr: String
            if s.heartRate > 0 {
                if s.heartRateMin > 0 && s.heartRateMax > 0 {
                    hr = "\(Int(s.heartRate))(\(Int(s.heartRateMin))~\(Int(s.heartRateMax)))"
                } else {
                    hr = "\(Int(s.heartRate))"
                }
            } else {
                hr = "-"
            }
            let rhrCol = hasRestingHRData ? (s.restingHeartRate > 0 ? "  | \(Int(s.restingHeartRate))" : "  | -") : ""
            let hrvCol = hasHRVData ? (s.hrv > 0 ? "  | \(Int(s.hrv))" : "  | -") : ""
            let distCol = hasDistanceData ? (s.distanceKm > 0.01 ? "  | \(String(format: "%.1f", s.distanceKm))" : "  | -") : ""
            let standCol = hasStandData ? (s.standMinutes > 0 ? "  | \(Int(s.standMinutes))" : "  | -") : ""
            let weightCol = hasWeightData ? (s.bodyMassKg > 0 ? "  | \(String(format: "%.1f", s.bodyMassKg))" : "  | -") : ""
            lines.append("\(dateLabel)  | \(steps)  | \(ex)  | \(activeCal)  | \(totalCal)  | \(sl)  | \(hr)\(rhrCol)\(hrvCol)\(distCol)\(standCol)\(weightCol)")
        }
        // Add weekly totals and averages with active-day counts so GPT can give
        // honest answers. E.g. "6天中有3天运动，共90分钟" is more useful than "日均30分钟"
        // which hides that the user only exercised 3 out of 7 days.
        //
        // IMPORTANT: Exclude today from aggregate stats because today's data is
        // still accumulating. Including partial-day data causes misleading summaries:
        // e.g. at 9am with 0 exercise, "7天中2天运动" implies today is a rest day,
        // but the user might exercise later. Using completed days only gives accurate
        // historical stats; today's progress is shown separately in [今日健康数据].
        let week = summaries.prefix(7)
        let completedDays = week.filter { !cal.isDateInToday($0.date) }
        let completedDayCount = completedDays.count
        let todaySummary = week.first { cal.isDateInToday($0.date) }

        // Use completed days for all aggregate calculations
        let validStepsDays = completedDays.filter { $0.steps > 0 }
        let validSleepDays = completedDays.filter { $0.sleepHours > 0 }
        let validExDays = completedDays.filter { $0.exerciseMinutes > 0 }
        var avgParts: [String] = []

        guard completedDayCount > 0 else {
            // Only today's data exists (e.g. first day using the app)
            lines.append("周统计：暂无完整天数据（今天数据尚在积累中）")
            return lines.joined(separator: "\n")
        }

        if !validStepsDays.isEmpty {
            let total = validStepsDays.map(\.steps).reduce(0, +)
            let avg = total / Double(completedDayCount)
            avgParts.append("过去\(completedDayCount)天日均步数\(Int(avg))")
        }
        if !validExDays.isEmpty {
            let totalMin = Int(validExDays.map(\.exerciseMinutes).reduce(0, +))
            avgParts.append("过去\(completedDayCount)天中\(validExDays.count)天有运动，共\(totalMin)分钟")
        }
        let validCalDays = completedDays.filter { $0.activeCalories > 0 || $0.basalCalories > 0 }
        if !validCalDays.isEmpty {
            let totalActive = Int(validCalDays.map(\.activeCalories).reduce(0, +))
            let totalAll = Int(validCalDays.map { $0.activeCalories + $0.basalCalories }.reduce(0, +))
            if totalAll > totalActive {
                avgParts.append("周总消耗\(totalAll)kcal（活动\(totalActive)kcal）")
            } else {
                avgParts.append("周活动消耗\(totalActive)kcal")
            }
        }
        // Distance — total walking+running km for the period.
        // Common queries: "这周走了多远？" / "最近跑了多少公里？"
        let validDistDays = completedDays.filter { $0.distanceKm > 0.01 }
        if !validDistDays.isEmpty {
            let totalKm = validDistDays.map(\.distanceKm).reduce(0, +)
            avgParts.append("总距离\(String(format: "%.1f", totalKm))km")
        }
        if !validSleepDays.isEmpty {
            let total = validSleepDays.map(\.sleepHours).reduce(0, +)
            let avg = total / Double(validSleepDays.count)
            if validSleepDays.count < completedDayCount {
                avgParts.append("\(validSleepDays.count)/\(completedDayCount)天有睡眠数据，均\(String(format: "%.1f", avg))h")
            } else {
                avgParts.append("日均睡眠\(String(format: "%.1f", avg))h")
            }
        }
        // Weight trend — show change when multiple days have weight data.
        // Users often ask "这周瘦了吗？" or "体重趋势", and GPT needs directional
        // context beyond just today's snapshot weight in [今日健康数据].
        let validWeightDays = completedDays.filter { $0.bodyMassKg > 0 }
            .sorted { $0.date < $1.date } // chronological for trend direction
        if validWeightDays.count >= 2 {
            let earliest = validWeightDays.first!
            let latest = validWeightDays.last!
            let change = latest.bodyMassKg - earliest.bodyMassKg
            let direction: String
            if abs(change) < 0.2 {
                direction = "基本持平"
            } else if change > 0 {
                direction = "增加了\(String(format: "%.1f", change))kg"
            } else {
                direction = "减少了\(String(format: "%.1f", abs(change)))kg"
            }
            let wFmt = DateFormatter(); wFmt.dateFormat = "M/d"
            avgParts.append("体重\(String(format: "%.1f", latest.bodyMassKg))kg（\(wFmt.string(from: earliest.date))→\(wFmt.string(from: latest.date))\(direction)，\(validWeightDays.count)次记录）")
        } else if let singleWeight = validWeightDays.first {
            avgParts.append("体重\(String(format: "%.1f", singleWeight.bodyMassKg))kg（仅1次记录）")
        }

        // Note today's partial contribution if it has any data
        if let today = todaySummary, today.hasData {
            avgParts.append("今天数据尚在积累中，未计入统计")
        }
        if !avgParts.isEmpty {
            lines.append("近7天统计（基于已完成的\(completedDayCount)天）：\(avgParts.joined(separator: "，"))")
        }

        // Per-week breakdowns so GPT can directly answer "这周运动了几次？" vs "上周走了多少步？"
        // without manually scanning and filtering rows from the trend table.
        // Uses Monday-based weeks consistent with weekBoundaryText in the SYSTEM prompt.
        // Pass ALL summaries (14 days) so "上周" always has complete Mon-Sun data,
        // even if the 7-day trend table only shows the most recent 7 days.
        let perWeekStats = buildPerWeekStats(summaries: Array(summaries), cal: cal)
        if !perWeekStats.isEmpty {
            lines.append(perWeekStats)
        }

        return lines.joined(separator: "\n")
    }

    /// Builds separate "本周" and "上周" sub-totals from the 14-day health data.
    /// With 14 days of data, "上周" always has complete Mon-Sun coverage regardless
    /// of which day of the week it currently is.
    /// This prevents GPT from misusing the combined 7-day aggregate for week-specific queries.
    private func buildPerWeekStats(summaries: [HealthSummary], cal: Calendar) -> String {
        let now = Date()
        let todayWeekday = cal.component(.weekday, from: now) // 1=Sun..7=Sat
        let daysSinceMonday = (todayWeekday + 5) % 7 // Mon=0, Tue=1, ..., Sun=6
        let thisMonday = cal.date(byAdding: .day, value: -daysSinceMonday, to: cal.startOfDay(for: now))!
        let lastMonday = cal.date(byAdding: .day, value: -7, to: thisMonday)!
        let twoWeeksAgoMonday = cal.date(byAdding: .day, value: -14, to: thisMonday)!

        // Split summaries into this week (Mon..today, excluding today) and last week
        let thisWeekDays = summaries.filter { s in
            let dayStart = cal.startOfDay(for: s.date)
            return dayStart >= thisMonday && !cal.isDateInToday(s.date)
        }
        let lastWeekDays = summaries.filter { s in
            let dayStart = cal.startOfDay(for: s.date)
            return dayStart >= lastMonday && dayStart < thisMonday
        }
        // Week before last — available from 14-day data for "大上周" queries
        let weekBeforeLastDays = summaries.filter { s in
            let dayStart = cal.startOfDay(for: s.date)
            return dayStart >= twoWeeksAgoMonday && dayStart < lastMonday
        }

        var parts: [String] = []

        // This week stats (completed days only — today excluded)
        if !thisWeekDays.isEmpty {
            let label = "本周（周一至昨天，\(thisWeekDays.count)天）"
            parts.append("\(label)：\(weekSubTotal(thisWeekDays))")
        }

        // Last week stats — with 14-day fetch, this should always have 7 days
        if !lastWeekDays.isEmpty {
            let label: String
            if lastWeekDays.count >= 7 {
                label = "上周（完整7天）"
            } else {
                // Rare edge case: data gap within last week
                label = "上周（\(lastWeekDays.count)/7天有数据）"
            }
            parts.append("\(label)：\(weekSubTotal(lastWeekDays))")
        }

        // Week before last — partial data (only days within 14-day window)
        if !weekBeforeLastDays.isEmpty {
            let label: String
            if weekBeforeLastDays.count >= 7 {
                label = "大上周（完整7天）"
            } else {
                let wkFmt = DateFormatter(); wkFmt.locale = Locale(identifier: "zh_CN"); wkFmt.dateFormat = "EEE"
                let coveredDays = weekBeforeLastDays
                    .sorted { $0.date < $1.date }
                    .map { wkFmt.string(from: $0.date) }
                label = "大上周（仅\(weekBeforeLastDays.count)/7天：\(coveredDays.joined(separator: "、"))）"
            }
            parts.append("\(label)：\(weekSubTotal(weekBeforeLastDays))")
        }

        guard !parts.isEmpty else { return "" }
        return parts.joined(separator: "\n")
    }

    /// Generates a compact one-line summary for a set of days.
    private func weekSubTotal(_ days: [HealthSummary]) -> String {
        var items: [String] = []

        let stepsTotal = days.map(\.steps).reduce(0, +)
        let stepsDays = days.filter { $0.steps > 0 }.count
        if stepsTotal > 0 {
            let avg = Int(stepsTotal / Double(days.count))
            items.append("日均\(avg)步（\(stepsDays)/\(days.count)天有步数）")
        }

        let exDays = days.filter { $0.exerciseMinutes > 0 }
        if !exDays.isEmpty {
            let totalMin = Int(exDays.map(\.exerciseMinutes).reduce(0, +))
            let avgMin = Int(Double(totalMin) / Double(days.count))
            items.append("\(exDays.count)/\(days.count)天运动共\(totalMin)分钟（日均\(avgMin)分钟）")
        } else {
            items.append("无运动记录")
        }

        // Stand time — third Activity Ring
        let standDays = days.filter { $0.standMinutes > 0 }
        if !standDays.isEmpty {
            let totalStand = Int(standDays.map(\.standMinutes).reduce(0, +))
            let avgStand = Int(Double(totalStand) / Double(days.count))
            items.append("日均站立\(avgStand)分钟")
        }

        // Distance — walking+running total for the period.
        // Commonly asked: "这周走了多远？" / "上周跑了多少公里？"
        let distanceDays = days.filter { $0.distanceKm > 0.01 }
        if !distanceDays.isEmpty {
            let totalKm = distanceDays.map(\.distanceKm).reduce(0, +)
            let avgKm = totalKm / Double(days.count)
            items.append("总距离\(String(format: "%.1f", totalKm))km（日均\(String(format: "%.1f", avgKm))km）")
        }

        let sleepDays = days.filter { $0.sleepHours > 0 }
        if !sleepDays.isEmpty {
            let avg = sleepDays.map(\.sleepHours).reduce(0, +) / Double(sleepDays.count)
            var sleepDesc = "\(sleepDays.count)/\(days.count)天有睡眠，均\(String(format: "%.1f", avg))h"

            // Deep sleep & REM averages — key quality metrics for cross-week comparison.
            // Without these, GPT sees "均睡7.2h" for both weeks but can't tell that one week
            // had much better deep sleep quality. Users asking "这周和上周睡眠哪个好" need
            // quality metrics, not just duration.
            let phaseDays = sleepDays.filter { $0.hasSleepPhases }
            if !phaseDays.isEmpty {
                let avgDeep = phaseDays.map(\.sleepDeepHours).reduce(0, +) / Double(phaseDays.count)
                let avgREM = phaseDays.map(\.sleepREMHours).reduce(0, +) / Double(phaseDays.count)
                sleepDesc += "（深睡\(String(format: "%.1f", avgDeep))h/REM\(String(format: "%.1f", avgREM))h"

                // Deep sleep ratio for quality assessment
                let avgTotal = phaseDays.map(\.sleepHours).reduce(0, +) / Double(phaseDays.count)
                if avgTotal > 0 {
                    let deepRatio = Int((avgDeep / avgTotal) * 100)
                    sleepDesc += "，深睡占\(deepRatio)%"
                }

                sleepDesc += "）"
            }

            // Average sleep efficiency — reveals how well the user actually sleeps in bed.
            // Two weeks with identical sleep hours can differ greatly: 92% vs 78% efficiency
            // tells a completely different story about sleep quality.
            let effDays = sleepDays.filter { $0.inBedHours > 0 && $0.inBedHours >= $0.sleepHours }
            if !effDays.isEmpty {
                let avgEff = effDays.map { Int(($0.sleepHours / $0.inBedHours) * 100) }
                    .reduce(0, +) / effDays.count
                sleepDesc += "，效率\(avgEff)%"
            }

            // Average onset time — sleep regularity across the week.
            // Helps GPT say "这周入睡时间比上周早了30分钟" for meaningful comparison.
            let cal = Calendar.current
            let onsets = sleepDays.compactMap { $0.sleepOnset }
            if onsets.count >= 2 {
                let onsetMinutes = onsets.map { onset -> Double in
                    let comps = cal.dateComponents([.hour, .minute], from: onset)
                    var mins = Double((comps.hour ?? 0) * 60 + (comps.minute ?? 0))
                    // Normalize: times before 18:00 are next-day (e.g. 01:00 = 25*60)
                    if mins < 18 * 60 { mins += 24 * 60 }
                    return mins
                }
                let meanMins = onsetMinutes.reduce(0, +) / Double(onsetMinutes.count)
                // Convert back to HH:mm display
                let displayMins = Int(meanMins) % (24 * 60)
                let hh = displayMins / 60
                let mm = displayMins % 60
                sleepDesc += "，均入睡\(String(format: "%02d:%02d", hh, mm))"
            }

            items.append(sleepDesc)
        }

        // Heart rate & HRV per-week averages — critical for weekly comparison.
        // Without these, GPT sees "这周均静息心率" only in individual trend rows and
        // has to manually scan & average them, often getting it wrong. Users commonly
        // ask "这周心率和上周比怎么样？" or "最近压力大吗？HRV 有变化吗？", and resting HR +
        // HRV are the best proxy metrics for stress/recovery trends.
        let rhrDays = days.filter { $0.restingHeartRate > 0 }
        if !rhrDays.isEmpty {
            let avgRHR = Int(rhrDays.map(\.restingHeartRate).reduce(0, +) / Double(rhrDays.count))
            var hrDesc = "均静息心率\(avgRHR)bpm"

            // HRV — Heart Rate Variability, key recovery/stress indicator.
            // Trending down across weeks suggests accumulated fatigue or stress.
            let hrvDays = days.filter { $0.hrv > 0 }
            if !hrvDays.isEmpty {
                let avgHRV = Int(hrvDays.map(\.hrv).reduce(0, +) / Double(hrvDays.count))
                hrDesc += "，均HRV \(avgHRV)ms"
            }

            // Average daily heart rate (not just resting) for overall activity level context
            let avgHRDays = days.filter { $0.heartRate > 0 }
            if !avgHRDays.isEmpty {
                let avgDayHR = Int(avgHRDays.map(\.heartRate).reduce(0, +) / Double(avgHRDays.count))
                hrDesc += "，日均心率\(avgDayHR)bpm"
            }

            items.append(hrDesc)
        }

        // Show both total and daily average for calories so GPT can fairly compare
        // weeks of different lengths. Without daily average, GPT sees "本周(4天)总消耗
        // 8500kcal" vs "上周(7天)总消耗14000kcal" and wrongly concludes "this week less
        // active" — but daily avg is 2125 vs 2000, meaning this week is actually better.
        let calDays = days.filter { $0.activeCalories > 0 || $0.basalCalories > 0 }
        if !calDays.isEmpty {
            let activeTotal = Int(calDays.map(\.activeCalories).reduce(0, +))
            let totalAll = Int(calDays.map { $0.activeCalories + $0.basalCalories }.reduce(0, +))
            if totalAll > activeTotal {
                let dailyAvg = Int(Double(totalAll) / Double(days.count))
                items.append("总消耗\(totalAll)kcal（日均\(dailyAvg)kcal）")
            } else {
                let dailyAvg = Int(Double(activeTotal) / Double(days.count))
                items.append("活动消耗\(activeTotal)kcal（日均\(dailyAvg)kcal）")
            }
        }

        // Weight — include latest reading and trend direction for per-week comparison
        let weightDays = days.filter { $0.bodyMassKg > 0 }.sorted { $0.date < $1.date }
        if let latest = weightDays.last {
            if weightDays.count >= 2, let earliest = weightDays.first {
                let change = latest.bodyMassKg - earliest.bodyMassKg
                let dir = abs(change) < 0.2 ? "持平" : (change > 0 ? "+\(String(format: "%.1f", change))" : "\(String(format: "%.1f", change))")
                items.append("体重\(String(format: "%.1f", latest.bodyMassKg))kg(\(dir))")
            } else {
                items.append("体重\(String(format: "%.1f", latest.bodyMassKg))kg")
            }
        }

        return items.joined(separator: "，")
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

            // Overall summary line so GPT can quickly answer "最近忙吗？" / "上周有几个会？"
            let totalPastEvents = past.count
            var calBreakdown: [String: Int] = [:]
            for e in past where !e.calendar.isEmpty {
                calBreakdown[e.calendar, default: 0] += 1
            }
            let breakdownStr = calBreakdown.sorted { $0.value > $1.value }
                .prefix(4)
                .map { "\($0.key)\($0.value)个" }
                .joined(separator: "、")
            // Total meeting time across all past events for "最近开了多少小时会？" queries.
            // Excludes all-day events (holidays, birthdays) which don't represent meeting time.
            let totalMeetingMins = past.filter { !$0.isAllDay }
                .map { Int($0.duration / 60) }.reduce(0, +)
            let meetingTimeSuffix: String
            if totalMeetingMins >= 60 {
                let hrs = totalMeetingMins / 60
                let mins = totalMeetingMins % 60
                meetingTimeSuffix = mins > 0 ? "，总会议时长\(hrs)小时\(mins)分钟" : "，总会议时长\(hrs)小时"
            } else if totalMeetingMins > 0 {
                meetingTimeSuffix = "，总会议时长\(totalMeetingMins)分钟"
            } else {
                meetingTimeSuffix = ""
            }
            let summaryNote = breakdownStr.isEmpty
                ? "过去14天共\(totalPastEvents)个日程\(meetingTimeSuffix)："
                : "过去14天共\(totalPastEvents)个日程（\(breakdownStr)）\(meetingTimeSuffix)："
            lines.append(summaryNote)

            // Determine the "recent detail threshold": show full event details only
            // for the past 3 days (yesterday, 前天, 大前天). Older days get a compact
            // daily summary (count + titles only) to save ~60-70% of tokens while
            // preserving data for GPT to answer common queries like "上周有几个会?"
            let recentCutoff = cal.date(byAdding: .day, value: -3, to: cal.startOfDay(for: now)) ?? now

            for day in sortedDays.prefix(14) {
                guard let dayEvents = dayGroups[day] else { continue }
                let dayLabel: String
                if cal.isDateInYesterday(day) {
                    dayLabel = "昨天"
                } else if let twoDaysAgo = cal.date(byAdding: .day, value: -2, to: cal.startOfDay(for: now)),
                          cal.isDate(day, inSameDayAs: twoDaysAgo) {
                    dayLabel = "前天"
                } else if let threeDaysAgo = cal.date(byAdding: .day, value: -3, to: cal.startOfDay(for: now)),
                          cal.isDate(day, inSameDayAs: threeDaysAgo) {
                    dayLabel = "大前天"
                } else {
                    dayLabel = dayNameFmt.string(from: day)
                }

                let isRecent = day >= recentCutoff
                if isRecent {
                    // Full detail for recent days — GPT can answer "昨天那个会议聊什么？"
                    let eventDescs = dayEvents.prefix(5).map { e -> String in
                        let timeStr = e.isAllDay ? "全天" : "\(timeFmt.string(from: e.startDate))–\(timeFmt.string(from: e.endDate))"
                        var desc = "\(timeStr) \(e.title)"
                        if !e.calendar.isEmpty { desc += " [\(e.calendar)]" }
                        if !e.location.isEmpty { desc += "（\(e.location)）" }
                        if let label = e.attendeeLabel { desc += " \(label)" }
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
                } else {
                    // Compact summary for older days — time range + title, no notes/location/attendees.
                    // Include both start AND end time so GPT can compute event duration for
                    // queries like "上周最长的会议是哪个?" or "上周开了多久的会?". Previously
                    // only showed start time, making duration invisible for ~10 days of data.
                    let titles = dayEvents.prefix(4).map { e -> String in
                        let timePrefix = e.isAllDay ? "全天" : "\(timeFmt.string(from: e.startDate))–\(timeFmt.string(from: e.endDate))"
                        var entry = "\(timePrefix) \(e.title)"
                        if !e.calendar.isEmpty { entry += "[\(e.calendar)]" }
                        return entry
                    }
                    // Calculate total meeting time for the day so GPT can answer
                    // "哪天会议最多" or "上周开了多少小时的会" without manual arithmetic.
                    let dayMeetingMins = dayEvents.filter { !$0.isAllDay }
                        .map { Int($0.duration / 60) }.reduce(0, +)
                    let meetingNote = dayMeetingMins > 0 ? "，共\(dayMeetingMins)分钟会议" : ""
                    var compactLine = "  \(dayLabel)：\(dayEvents.count)个日程\(meetingNote)"
                    compactLine += "（\(titles.joined(separator: "、"))）"
                    if dayEvents.count > 4 {
                        compactLine += "等"
                    }
                    lines.append(compactLine)
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

            // Summary: how many done vs remaining, plus total meeting time
            let nonAllDay = todayEvents.filter { !$0.isAllDay }
            let doneCount = nonAllDay.filter { $0.endDate <= now }.count
            let remainCount = nonAllDay.filter { $0.startDate > now }.count
            if nonAllDay.count >= 2 {
                let todayTotalMins = nonAllDay.map { Int($0.duration / 60) }.reduce(0, +)
                let doneMins = nonAllDay.filter { $0.endDate <= now }.map { Int($0.duration / 60) }.reduce(0, +)
                let remainMins = todayTotalMins - doneMins
                var summaryParts: [String] = ["已完成\(doneCount)项", "还剩\(remainCount)项"]
                if todayTotalMins >= 60 {
                    let hrs = todayTotalMins / 60
                    let mins = todayTotalMins % 60
                    let timeStr = mins > 0 ? "\(hrs)小时\(mins)分钟" : "\(hrs)小时"
                    summaryParts.append("全天共\(timeStr)会议")
                    if remainMins > 0 && doneMins > 0 {
                        summaryParts.append("剩余约\(remainMins)分钟")
                    }
                }
                lines.append("  （\(summaryParts.joined(separator: "，"))）")
            }
        }

        // Upcoming events (future, excluding today) — grouped by day for clarity.
        // Matches the past-events pattern: GPT can directly answer "明天有什么安排？"
        // by reading a grouped day block instead of scanning a flat list with
        // redundant per-event date prefixes.
        let futureEvents = Array(upcoming.filter { !cal.isDateInToday($0.startDate) })
        if !futureEvents.isEmpty {
            let weekdayFmt = DateFormatter()
            weekdayFmt.locale = Locale(identifier: "zh_CN")
            weekdayFmt.dateFormat = "EEEE"

            // Group by day
            var futureDayGroups: [Date: [CalendarEventItem]] = [:]
            for e in futureEvents {
                let dayStart = cal.startOfDay(for: e.startDate)
                futureDayGroups[dayStart, default: []].append(e)
            }
            let sortedFutureDays = futureDayGroups.keys.sorted() // chronological: nearest first

            // Overall count so GPT can answer "接下来忙吗？"
            let totalFutureEvents = futureEvents.count
            let dayCount = sortedFutureDays.count
            lines.append("近期（未来\(dayCount)天有日程，共\(totalFutureEvents)项）：")

            for day in sortedFutureDays.prefix(7) {
                guard let dayEvents = futureDayGroups[day] else { continue }

                // Build relative day label
                let relativeLabel: String
                if let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)),
                   cal.isDate(day, inSameDayAs: tomorrow) {
                    relativeLabel = "明天"
                } else if let dayAfter = cal.date(byAdding: .day, value: 2, to: cal.startOfDay(for: now)),
                          cal.isDate(day, inSameDayAs: dayAfter) {
                    relativeLabel = "后天"
                } else {
                    relativeLabel = weekdayFmt.string(from: day)
                }
                let dayHeader = "\(df.string(from: day))(\(relativeLabel))"

                // Detail for near days (tomorrow/day-after), compact for further out
                let isNearFuture: Bool = {
                    guard let twoDaysLater = cal.date(byAdding: .day, value: 3, to: cal.startOfDay(for: now)) else { return false }
                    return day < twoDaysLater
                }()

                if isNearFuture {
                    // Full detail — GPT can answer "明天那个会议几点？在哪开？"
                    let eventDescs = dayEvents.prefix(8).map { e -> String in
                        let timeStr = e.isAllDay ? "全天" : "\(timeFmt.string(from: e.startDate))–\(timeFmt.string(from: e.endDate))"
                        var desc = "\(timeStr) \(e.title)"
                        if !e.calendar.isEmpty { desc += " [\(e.calendar)]" }
                        if !e.location.isEmpty { desc += "（\(e.location)）" }
                        if let label = e.attendeeLabel { desc += " \(label)" }
                        let trimmedNotes = e.notes.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmedNotes.isEmpty {
                            let preview = trimmedNotes.count > 80 ? String(trimmedNotes.prefix(80)) + "…" : trimmedNotes
                            desc += " 备注：\(preview)"
                        }
                        return desc
                    }
                    lines.append("  \(dayHeader)：\(eventDescs.joined(separator: "；"))")
                    if dayEvents.count > 8 {
                        lines.append("    …还有\(dayEvents.count - 8)项")
                    }
                } else {
                    // Compact summary for further-out days — include both start AND end time
                    // so GPT can compute duration for "下周三的会要开多久?" queries.
                    let titles = dayEvents.prefix(4).map { e -> String in
                        let timePrefix = e.isAllDay ? "全天" : "\(timeFmt.string(from: e.startDate))–\(timeFmt.string(from: e.endDate))"
                        var entry = "\(timePrefix) \(e.title)"
                        if !e.calendar.isEmpty { entry += "[\(e.calendar)]" }
                        return entry
                    }
                    let dayMeetingMins = dayEvents.filter { !$0.isAllDay }
                        .map { Int($0.duration / 60) }.reduce(0, +)
                    let meetingNote = dayMeetingMins > 0 ? "，共\(dayMeetingMins)分钟" : ""
                    var compactLine = "  \(dayHeader)：\(dayEvents.count)项\(meetingNote)"
                    compactLine += "（\(titles.joined(separator: "、"))）"
                    if dayEvents.count > 4 {
                        compactLine += "等"
                    }
                    lines.append(compactLine)
                }
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
        // Coordinate fallback — GPT can identify approximate area from lat/lon.
        // Use correct hemisphere suffix (N/S for latitude, E/W for longitude)
        // so GPT interprets the location correctly worldwide.
        if r.latitude != 0 || r.longitude != 0 {
            let latSuffix = r.latitude >= 0 ? "N" : "S"
            let lonSuffix = r.longitude >= 0 ? "E" : "W"
            return String(format: "%.3f°%@, %.3f°%@",
                          abs(r.latitude), latSuffix,
                          abs(r.longitude), lonSuffix)
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

    private func locationSection(_ records: [CDLocationRecord],
                                  currentLocation: CLLocation? = nil,
                                  currentPlaceName: String? = nil,
                                  currentAddress: String? = nil) -> String {
        let cal = Calendar.current
        let dateFmt = DateFormatter(); dateFmt.dateFormat = "M月d日（EEEE）"
        dateFmt.locale = Locale(identifier: "zh_CN")
        let timeFmt = DateFormatter(); timeFmt.dateFormat = "HH:mm"

        var lines = ["[位置记录（近14天）]"]

        // Show the device's current live position when available.
        // CDLocationRecord only persists on 200m+ significant moves, so the
        // latest position may be hours old. The live CLLocation gives GPT a
        // fresh answer for "我现在在哪？" or "我在哪里？".
        if let loc = currentLocation {
            let age = Date().timeIntervalSince(loc.timestamp)
            let freshness: String
            if age < 60 {
                freshness = "刚刚更新"
            } else if age < 3600 {
                freshness = "\(Int(age / 60))分钟前更新"
            } else {
                freshness = "\(Int(age / 3600))小时前更新"
            }
            let latS = loc.coordinate.latitude >= 0 ? "N" : "S"
            let lonS = loc.coordinate.longitude >= 0 ? "E" : "W"
            let coords = String(format: "%.4f°%@, %.4f°%@",
                                abs(loc.coordinate.latitude), latS,
                                abs(loc.coordinate.longitude), lonS)
            // Resolve human-readable name with priority:
            // 1. Live reverse-geocoded name (most accurate — geocoded from this exact position)
            // 2. Nearest CDLocationRecord within 500m (previously geocoded nearby point)
            // 3. Raw coordinates fallback (GPT can approximate area from lat/lon)
            var resolvedName: String?
            var resolvedAddr: String?

            // Priority 1: Live geocoded name from LocationService
            if let liveName = currentPlaceName, !liveName.isEmpty {
                resolvedName = liveName
                resolvedAddr = currentAddress
            }

            // Priority 2: Nearest CDLocationRecord
            if resolvedName == nil {
                for r in records {
                    let dist = Self.haversineKm(lat1: loc.coordinate.latitude, lon1: loc.coordinate.longitude,
                                                lat2: r.latitude, lon2: r.longitude)
                    if dist < 0.5 {
                        let name = locationDisplayName(for: r)
                        if name != "未知地点" {
                            resolvedName = name
                            break
                        }
                    }
                }
            }

            if let name = resolvedName {
                // Include city/district context from address if available
                var locationStr = name
                if let addr = resolvedAddr, !addr.isEmpty,
                   let city = cityFromAddress(addr), !name.contains(city) {
                    locationStr += "，\(city)"
                }
                lines.append("📍 当前位置：\(locationStr)（\(coords)，\(freshness)）")
            } else {
                lines.append("📍 当前位置：\(coords)（\(freshness)）")
            }
        }

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

        for day in sortedDays.prefix(14) {
            guard let dayRecords = dayGroups[day] else { continue }
            let dayLabel: String
            if cal.isDateInToday(day) {
                dayLabel = "今天"
            } else if cal.isDateInYesterday(day) {
                dayLabel = "昨天"
            } else if let twoDaysAgo = cal.date(byAdding: .day, value: -2, to: cal.startOfDay(for: Date())),
                      cal.isDate(day, inSameDayAs: twoDaysAgo) {
                dayLabel = "前天"
            } else {
                dayLabel = dateFmt.string(from: day)
            }
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

    private func photoSection(_ photos: [PhotoMetadataItem],
                              locationRecords: [CDLocationRecord] = []) -> String {
        let cal = Calendar.current
        let total = photos.count
        let videos = photos.filter { $0.isVideo }.count
        let geoTagged = photos.filter { $0.hasLocation }.count
        let favorites = photos.filter { $0.isFavorite }.count
        let screenshots = photos.filter { $0.isScreenshot }.count
        var lines = ["[照片统计（近14天）]"]
        lines.append("共 \(total - videos) 张照片，\(videos) 个视频")
        if geoTagged > 0 { lines.append("含地理位置：\(geoTagged) 张") }
        if favorites > 0 { lines.append("已收藏：\(favorites) 张") }
        if screenshots > 0 { lines.append("截图：\(screenshots) 张") }

        // Build a lookup table from location records so we can resolve photo
        // coordinates to human-readable place names. Without this, GPT only
        // sees "you took 5 photos yesterday" but can't say "you took 5 photos
        // at 星巴克". Cross-referencing with CDLocationRecord (which has reverse-
        // geocoded place names) bridges the gap cheaply.
        let placeRecords = locationRecords.filter {
            $0.latitude != 0 || $0.longitude != 0
        }

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
            for day in sortedDays.prefix(14) {
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

                // Time-of-day clustering so GPT can answer "昨天下午拍的照片" or
                // "今天上午的照片". Without this, GPT only sees total count per day
                // and can't distinguish morning vs afternoon vs evening photos.
                // Only show when there are enough photos to make time breakdown useful.
                if dayPhotos.count >= 3 {
                    let timeClusters = photoTimeClusters(dayPhotos, cal: cal)
                    if !timeClusters.isEmpty {
                        lines.append("    时段：\(timeClusters)")
                    }
                }

                // Add location clusters for this day's geo-tagged photos so GPT can
                // answer "我在哪拍了照片？" or "昨天在哪些地方拍了照？" with place names.
                let locationNote = photoLocationClusters(dayPhotos, placeRecords: placeRecords)
                if !locationNote.isEmpty {
                    lines.append("    拍摄地点：\(locationNote)")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Clusters photos by time-of-day periods (凌晨/上午/下午/晚上) so GPT can
    /// answer "昨天下午拍了什么照片?" or "今天上午拍了几张?". Returns a compact
    /// summary like "上午3张、下午5张、晚上2张" with hour ranges for context.
    private func photoTimeClusters(_ photos: [PhotoMetadataItem], cal: Calendar) -> String {
        // Time period definitions (hour ranges)
        // 凌晨 0-5, 上午 6-11, 下午 12-17, 晚上 18-23
        struct TimePeriod {
            let label: String
            let range: Range<Int>
        }
        let periods = [
            TimePeriod(label: "凌晨", range: 0..<6),
            TimePeriod(label: "上午", range: 6..<12),
            TimePeriod(label: "下午", range: 12..<18),
            TimePeriod(label: "晚上", range: 18..<24)
        ]

        var periodCounts: [String: Int] = [:]
        for p in photos {
            let hour = cal.component(.hour, from: p.date)
            for period in periods where period.range.contains(hour) {
                periodCounts[period.label, default: 0] += 1
                break
            }
        }

        // Only show periods that have photos, in chronological order
        let parts = periods.compactMap { period -> String? in
            guard let count = periodCounts[period.label], count > 0 else { return nil }
            return "\(period.label)\(count)张"
        }

        // Skip if all photos are in a single period (not informative)
        guard parts.count >= 2 else { return "" }

        return parts.joined(separator: "、")
    }

    /// Groups geo-tagged photos into location clusters and resolves place names
    /// by matching against nearby CDLocationRecord entries (within ~1km).
    /// Returns a compact summary like "星巴克(3张)、外滩(2张)" or falls back to
    /// coordinates when no location record matches.
    private func photoLocationClusters(_ photos: [PhotoMetadataItem],
                                        placeRecords: [CDLocationRecord]) -> String {
        let geoPhotos = photos.filter { $0.hasLocation }
        guard !geoPhotos.isEmpty else { return "" }

        // Cluster photos by proximity (~500m threshold).
        // Simple greedy clustering: assign each photo to the first existing cluster
        // within threshold, or create a new cluster.
        let clusterThresholdKm = 0.5
        var clusters: [(lat: Double, lon: Double, count: Int)] = []

        for p in geoPhotos {
            guard let lat = p.latitude, let lon = p.longitude else { continue }
            var assigned = false
            for i in clusters.indices {
                let dist = Self.haversineKm(lat1: clusters[i].lat, lon1: clusters[i].lon,
                                            lat2: lat, lon2: lon)
                if dist < clusterThresholdKm {
                    // Update cluster center to weighted average for better accuracy
                    let n = Double(clusters[i].count)
                    clusters[i].lat = (clusters[i].lat * n + lat) / (n + 1)
                    clusters[i].lon = (clusters[i].lon * n + lon) / (n + 1)
                    clusters[i].count += 1
                    assigned = true
                    break
                }
            }
            if !assigned {
                clusters.append((lat: lat, lon: lon, count: 1))
            }
        }

        // Sort by photo count descending (most-photographed location first)
        clusters.sort { $0.count > $1.count }

        // Resolve each cluster to a place name via nearest location record (within 1km)
        let matchThresholdKm = 1.0
        let clusterNames: [String] = clusters.prefix(4).map { cluster in
            // Find the nearest location record with a place name
            var bestName: String?
            var bestDist = Double.greatestFiniteMagnitude
            for r in placeRecords {
                let name = r.placeName ?? ""
                let addr = r.address ?? ""
                guard !name.isEmpty || !addr.isEmpty else { continue }
                let dist = Self.haversineKm(lat1: cluster.lat, lon1: cluster.lon,
                                            lat2: r.latitude, lon2: r.longitude)
                if dist < matchThresholdKm && dist < bestDist {
                    bestDist = dist
                    bestName = !name.isEmpty ? name : addr
                }
            }

            let label: String
            if let name = bestName {
                label = name
            } else {
                // Fallback to coordinates — GPT knows world geography well
                let latS = cluster.lat >= 0 ? "N" : "S"
                let lonS = cluster.lon >= 0 ? "E" : "W"
                label = String(format: "%.3f°%@,%.3f°%@",
                               abs(cluster.lat), latS, abs(cluster.lon), lonS)
            }
            return cluster.count > 1 ? "\(label)(\(cluster.count)张)" : label
        }

        return clusterNames.joined(separator: "、")
    }

    /// Haversine formula — great-circle distance in km between two lat/lon points.
    private static func haversineKm(lat1: Double, lon1: Double,
                                     lat2: Double, lon2: Double) -> Double {
        let R = 6371.0 // Earth radius in km
        let dLat = (lat2 - lat1) * .pi / 180.0
        let dLon = (lon2 - lon1) * .pi / 180.0
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180.0) * cos(lat2 * .pi / 180.0)
            * sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return R * c
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

    /// Extracts individual workout sessions from all available summaries (up to 14 days)
    /// so GPT can answer questions like "when was my last run?" or "上周做了什么运动?"
    /// with specific session details, not just aggregate stats from buildPerWeekStats.
    private func weeklyWorkoutSection(_ summaries: [HealthSummary]) -> String {
        let cal = Calendar.current
        let dateFmt = DateFormatter(); dateFmt.dateFormat = "M/d"
        let weekdayFmt = DateFormatter(); weekdayFmt.locale = Locale(identifier: "zh_CN"); weekdayFmt.dateFormat = "EEE"
        let timeFmt = DateFormatter(); timeFmt.dateFormat = "HH:mm"

        // Collect all workouts from ALL days (14-day window), not just 7.
        // This ensures GPT can see individual workout sessions from last week,
        // matching the per-week stats from buildPerWeekStats. Without this,
        // GPT sees "上周 3天运动共90分钟" but can't name the actual workouts.
        var allWorkouts: [(date: Date, workout: WorkoutRecord)] = []
        for s in summaries {
            for w in s.workouts {
                allWorkouts.append((date: s.date, workout: w))
            }
        }

        guard !allWorkouts.isEmpty else { return "" }

        // Sort chronologically (newest first) for easy reading
        allWorkouts.sort { $0.workout.startDate > $1.workout.startDate }

        let dayCount = Set(summaries.map { cal.startOfDay(for: $0.date) }).count
        var lines = ["[近\(dayCount)天运动记录]"]
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
            } else if let twoDaysAgo = cal.date(byAdding: .day, value: -2, to: cal.startOfDay(for: Date())),
                      cal.isDate(item.date, inSameDayAs: twoDaysAgo) {
                dayLabel = "前天"
            } else {
                dayLabel = "\(dateFmt.string(from: item.date))(\(weekdayFmt.string(from: item.date)))"
            }
            let timeStr = timeFmt.string(from: w.startDate)
            let dur = Int(w.duration / 60)
            var line = "\(dayLabel) \(timeStr) \(name) \(dur)分钟"
            if w.totalCalories > 0 { line += " \(Int(w.totalCalories))kcal" }
            if w.totalDistance > 100 { line += " \(String(format: "%.1f", w.totalDistance / 1000))km" }
            // Per-workout heart rate for intensity analysis
            if w.avgHeartRate > 0 {
                line += " 均心率\(Int(w.avgHeartRate))bpm"
                if w.maxHeartRate > 0 { line += "(峰值\(Int(w.maxHeartRate)))" }
            }
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

    /// Builds a per-day sleep quality breakdown for all available days (up to 14).
    /// Enables GPT to answer "上周睡得怎么样？", "哪天睡得最好？",
    /// "我入睡时间规律吗？" with precise phase-level data from both this week and last.
    /// Returns empty string if fewer than 2 days have sleep data.
    private func weeklySleepSection(_ summaries: [HealthSummary]) -> String {
        let cal = Calendar.current
        let dateFmt = DateFormatter(); dateFmt.dateFormat = "M/d"
        let weekdayFmt = DateFormatter()
        weekdayFmt.locale = Locale(identifier: "zh_CN")
        weekdayFmt.dateFormat = "EEE"
        let timeFmt = DateFormatter(); timeFmt.dateFormat = "HH:mm"

        // Use ALL summaries (up to 14 days) so GPT has per-night details for last week too.
        // Without this, "上周睡得怎么样" only gets aggregate stats from buildPerWeekStats
        // but no individual night data (onset time, phases, efficiency).
        let daysWithSleep = summaries.filter { $0.sleepHours > 0 }
        guard daysWithSleep.count >= 2 else { return "" }

        let dayCount = Set(summaries.map { cal.startOfDay(for: $0.date) }).count
        var lines = ["[近\(dayCount)天睡眠质量分析]"]

        // Show oldest → newest for natural trend reading
        let chronological = Array(daysWithSleep.reversed())

        for s in chronological {
            // Label with actual sleep night (e.g. "3/19晚→3/20") since sleep is attributed
            // to the wake-up day. This matches the SYSTEM prompt's sleep date rule.
            let prevDay = cal.date(byAdding: .day, value: -1, to: s.date) ?? s.date
            let nightLabel = "\(dateFmt.string(from: prevDay))晚→\(dateFmt.string(from: s.date))"
            let dayName: String
            if cal.isDateInToday(s.date) {
                dayName = "昨晚"
            } else if cal.isDateInYesterday(s.date) {
                dayName = "前晚"
            } else if let threeDaysAgo = cal.date(byAdding: .day, value: -2, to: cal.startOfDay(for: Date())),
                      cal.isDate(s.date, inSameDayAs: threeDaysAgo) {
                dayName = "大前晚"
            } else {
                dayName = weekdayFmt.string(from: prevDay) + "晚"
            }
            let dateLabel = "\(nightLabel)(\(dayName))"

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

        // Sleep schedule metrics — average bedtime, wake time, and regularity.
        // Pre-computed so GPT can directly answer "我一般几点睡？几点起？" and
        // "我睡眠规律吗？" without manually averaging 14 data points.
        // IMPORTANT: Use `chronological` (oldest→newest) not `daysWithSleep` (newest→oldest).
        // The bedtime drift analysis below compares first-half (older) vs second-half (newer)
        // averages, so the order must be chronological. Using daysWithSleep inverts the
        // trend direction — GPT would say "入睡渐早" when the user is actually sleeping later.
        let onsets = chronological.compactMap { $0.sleepOnset }
        let wakes = chronological.compactMap { $0.wakeTime }

        // Helper: convert time to minutes-since-18:00 (handles cross-midnight bedtimes)
        let toNormalizedMinutes: (Date) -> Double = { time in
            let comps = cal.dateComponents([.hour, .minute], from: time)
            var mins = Double((comps.hour ?? 0) * 60 + (comps.minute ?? 0))
            if mins < 18 * 60 { mins += 24 * 60 }  // e.g. 01:00 → 25*60
            return mins
        }
        // Helper: convert normalized minutes back to HH:mm display
        let normalizedToTimeStr: (Double) -> String = { mins in
            var totalMins = Int(mins.rounded())
            if totalMins >= 24 * 60 { totalMins -= 24 * 60 }
            let h = totalMins / 60
            let m = totalMins % 60
            return String(format: "%02d:%02d", h, m)
        }

        if onsets.count >= 3 {
            let onsetMinutes = onsets.map(toNormalizedMinutes)
            let mean = onsetMinutes.reduce(0, +) / Double(onsetMinutes.count)
            let variance = onsetMinutes.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(onsetMinutes.count)
            let stdDevMins = Int(variance.squareRoot())

            // Average bedtime display (e.g. "平均入睡23:15")
            summaryParts.append("平均入睡\(normalizedToTimeStr(mean))")

            // Regularity assessment
            if stdDevMins <= 30 {
                summaryParts.append("入睡较规律（波动≈\(stdDevMins)分钟）")
            } else if stdDevMins <= 60 {
                summaryParts.append("入睡有波动（波动≈\(stdDevMins)分钟）")
            } else {
                summaryParts.append("入睡不规律（波动≈\(stdDevMins)分钟）")
            }

            // Bedtime trend — is the user sleeping later or earlier over the period?
            // Compare first half vs second half average to detect drift direction.
            if onsetMinutes.count >= 6 {
                let half = onsetMinutes.count / 2
                // chronological order: reversed() already applied to daysWithSleep
                let firstHalfAvg = onsetMinutes.prefix(half).reduce(0, +) / Double(half)
                let secondHalfAvg = onsetMinutes.suffix(half).reduce(0, +) / Double(half)
                let driftMins = Int((secondHalfAvg - firstHalfAvg).rounded())
                if driftMins > 20 {
                    summaryParts.append("入睡渐晚（近期比早期晚约\(driftMins)分钟）")
                } else if driftMins < -20 {
                    summaryParts.append("入睡渐早（近期比早期早约\(abs(driftMins))分钟）")
                }
            }
        }

        // Wake time schedule — same analysis for wake regularity.
        // Without this, GPT can answer "几点睡" but not "几点起" questions,
        // and can't assess overall circadian regularity (which needs both).
        if wakes.count >= 3 {
            // Wake times are morning times — normalize differently (minutes from midnight)
            let wakeMinutes = wakes.map { wake -> Double in
                let comps = cal.dateComponents([.hour, .minute], from: wake)
                return Double((comps.hour ?? 0) * 60 + (comps.minute ?? 0))
            }
            let wakeMean = wakeMinutes.reduce(0, +) / Double(wakeMinutes.count)
            let wakeVariance = wakeMinutes.map { ($0 - wakeMean) * ($0 - wakeMean) }.reduce(0, +) / Double(wakeMinutes.count)
            let wakeStdDev = Int(wakeVariance.squareRoot())

            let wakeH = Int(wakeMean) / 60
            let wakeM = Int(wakeMean) % 60
            let wakeTimeStr = String(format: "%02d:%02d", wakeH, wakeM)
            summaryParts.append("平均起床\(wakeTimeStr)")

            if wakeStdDev <= 30 {
                summaryParts.append("起床较规律（波动≈\(wakeStdDev)分钟）")
            } else if wakeStdDev <= 60 {
                summaryParts.append("起床有波动（波动≈\(wakeStdDev)分钟）")
            } else {
                summaryParts.append("起床不规律（波动≈\(wakeStdDev)分钟）")
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
        let genericKeywords = [
            "帮我找", "给我找", "搜一下", "找一下",
            "看看", "给我看", "看一下", "有没有", "有多少", "有哪些",
            "show me", "find me", "look for"
        ]
        let photoContext = ["照片", "图片", "相片", "photo", "picture", "拍", "自拍", "截图", "视频"]

        let hasSpecific = specificKeywords.contains(where: { lower.contains($0) })
        let hasGenericWithContext = genericKeywords.contains(where: { lower.contains($0) })
            && photoContext.contains(where: { lower.contains($0) })

        // Descriptive photo query detection: when a photo context word appears
        // alongside descriptive content (e.g. "海边照片", "猫照片", "风景照片"),
        // trigger search even without explicit action verbs. This covers natural
        // Chinese patterns where users omit "的" between descriptor and "照片".
        // Require at least 2 chars beyond the photo word to avoid triggering on
        // bare "照片" (which is a stats question, not a search).
        let hasDescriptivePhotoQuery: Bool = {
            let photoWords = ["照片", "图片", "相片", "photo", "picture"]
            for pw in photoWords {
                if lower.contains(pw) {
                    // Strip the photo word and check remaining content is descriptive
                    let stripped = lower.replacingOccurrences(of: pw, with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "我的", with: "")
                        .replacingOccurrences(of: "那些", with: "")
                        .replacingOccurrences(of: "那张", with: "")
                        .replacingOccurrences(of: "那个", with: "")
                        .replacingOccurrences(of: "的", with: "")
                        .replacingOccurrences(of: "吗", with: "")
                        .replacingOccurrences(of: "呢", with: "")
                        .replacingOccurrences(of: "？", with: "")
                        .replacingOccurrences(of: "?", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    // After stripping common particles, if 2+ chars of descriptive
                    // content remain, this is a search query (e.g. "海边", "猫", "风景")
                    if stripped.count >= 2 {
                        return true
                    }
                }
            }
            return false
        }()

        guard hasSpecific || hasGenericWithContext || hasDescriptivePhotoQuery else { return ([], nil) }

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

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
        - 睡眠分析中包含预计算的「工作日vs周末」对比数据和「睡眠负债」数据。用户问「周末有没有补觉」「工作日和周末睡眠差多少」「我作息规律吗」时，直接引用该对比数据，不需要自己分类统计。工作日 = 周一至周五醒来的夜晚，周末 = 周六/周日醒来的夜晚。用户问「需要补觉吗」「这周睡够了吗」「欠了多少觉」「睡眠负债」时，直接引用睡眠负债数据回答。
        - 涉及多天数据时，可引用「近14天趋势」进行对比分析，指出趋势变化。
        - ⚠️ 使用预计算统计数据（重要，避免算错）：
          • 回答「这周运动了几次」「上周走了多少步」等聚合问题时，必须使用「本周/上周」周统计中的预计算数据（如「5天中3天有运动，共120分钟」），绝对不要自己手动数趋势表的行数或逐行加总。手动逐行统计14天数据极易出错（漏数、看错行、把上周数据算入本周）。
          • 周环比数据已预计算（如「日均步数↑1200步(+18%)」），直接引用，不要自己做减法或算百分比。
          • 睡眠概要中的「平均入睡/起床时间」「工作日vs周末」「睡眠负债」已预计算，直接引用，不要自己从14行中挑选和平均。
          • [健康趋势提醒]中的异常模式已预检测（如「连续3晚睡眠不足」「静息心率突升」），直接引用即可。
          • 趋势表是供你查看某一天的具体数据的（如用户问「昨天走了多少步」→ 看「昨天」行），不是让你逐行汇总的。
        - 周统计中会标注「X天中Y天有运动」，回答时要如实反映活跃天数，不要把少数几天的数据当作每天都达到了。例如7天中2天运动共60分钟，应该说「这周运动了2天，共60分钟」，而不是「日均运动30分钟」。
        - ⚠️ 跨周对比时，务必使用「日均」数据进行公平比较，因为本周天数可能不足7天。例如本周4天日均消耗2100kcal vs 上周7天日均2000kcal → 说明本周消耗更高，而不是比较总量（8400 vs 14000）得出本周更少的错误结论。
        - ⚠️ 体重数据说明：趋势表和周统计中会包含体重数据（如有记录）。体重数据来自智能体重秤或手动录入，不一定每天都有。回答体重趋势时，关注变化方向和幅度，短期波动（0.5kg以内）通常是正常的水分变化，不要过度解读。如果只有1-2天的记录，说明数据有限，不宜下趋势结论。
        - [生活模式洞察] 包含系统自动分析的跨领域关联（如运动→睡眠、晚睡→步数、会议→运动等）。用户问「为什么睡不好」「运动有用吗」「怎么改善」「有什么规律」时，直接引用这些洞察数据回答，比泛泛建议更有说服力。例如不要说「建议多运动有助睡眠」，而是说「从你的数据来看，运动的日子平均多睡X小时」。
        - 不要重复罗列所有数据，只回答用户问到的内容。
        - [生活记录]中包含预计算的「心情分布」「心情趋势」和「分类心情」数据。用户问「最近心情怎么样」「情绪好吗」「开心的时候多吗」时，直接引用这些预计算数据，不要自己从记录列表中逐条数 emoji。如果心情趋势显示下滑，可以关切地询问用户是否需要聊聊。
        - 如果用户提到家人（如"我妈"、"我爸"等），参考下方[用户信息]中的家庭成员数据来回答。
        - 日历日程中 [日历名] 标签表示事件来源（如 [Work]、[个人]、[家庭]），用户问「工作会议」时参考此标签区分。日程的「备注」字段包含议程或描述，用户问「那个会议聊什么」时可引用。日历数据已标注星期几和相对日期（昨天/前天/明天/后天），用户问「周三有什么安排」时直接匹配对应日期即可。
        - 今天的日程带有时间状态标注（已结束/进行中），回答日程问题时优先告诉用户接下来的安排，而不是罗列全天。例如下午3点问「今天有什么安排」，重点说还有哪些未完成的，已结束的可简要带过。
        - 日历数据中包含预计算的「空闲时段」（今天剩余空闲 / 明天空闲时段）。用户问「有空吗」「什么时候能约」「忙不忙」时，直接引用这些空闲时段回答，不需要自己计算事件间隔。空闲时段仅覆盖8:00–22:00的活跃时间。
        - 日程中带有 🔄 标记的是重复日程（如每周例会、每天站会），「固定日程」汇总列出了所有重复事件及其频率。用户问「这个会每周都有吗」「有哪些固定会议」「下周还有这个会吗」时，直接引用重复频率回答。注意：重复日程的未来实例已包含在未来日程中，无需额外推测。
        - 对话历史中的内容是之前的对话，注意用户可能会用「那…呢」「昨天的呢」「详细说说」等方式追问。如果用户的问题很短且含指代词（如「那个」「它」「上面说的」），结合对话历史推断用户指的是什么。
        - 如果[特别日期提醒]中有即将到来的生日（≤3天），在问候性对话（「你好」「今天怎么样」「有什么特别的吗」等）中可以自然地主动提及，但不要在无关话题中硬塞。生日当天应热情祝贺。

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
            // Include the actual birthday date so GPT can answer "我生日什么时候？"
            // and "距离我生日还有多久？". Previously only age was shown, making
            // birthday-date queries unanswerable when the birthday was >7 days away
            // (outside the [特别日期提醒] 7-day window).
            let bdFmt = DateFormatter(); bdFmt.dateFormat = "M月d日"
            let bdStr = bdFmt.string(from: bd)
            if age > 0 {
                profileParts.append("\(age)岁（生日：\(bdStr)）")
            } else {
                profileParts.append("生日：\(bdStr)")
            }
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

        // SPECIAL DATE REMINDERS — birthdays of user and family members within 7 days.
        // This is the "personal mirror" differentiator: GPT can proactively say "你妈妈
        // 后天过生日" in a morning greeting, or respond to "这周有什么特别的" with birthday
        // context. Without explicit proximity hints, GPT only sees "生日：5月15日" in the
        // profile section and has to mentally compute how close that is to today — which it
        // often doesn't bother doing, missing a huge personalization opportunity.
        let specialDates = buildSpecialDateReminders(now: now)
        if !specialDates.isEmpty {
            parts.append(specialDates)
        }

        // TOPIC-BASED SECTION GATING — conditionally include data sections based on
        // the detected query topic. For specific queries (e.g. "今天走了多少步" → health
        // only), skip unrelated heavy sections (calendar 14-day history, location records,
        // photo stats) to reduce token waste by 40-60% and eliminate noise that causes GPT
        // to over-reference irrelevant data. For general/ambiguous queries, include
        // everything (safe fallback, same as previous behavior).
        //
        // This is the prompt-level counterpart to buildRelevanceHint: the hint tells GPT
        // what to focus on, but the data was still present as distraction. Now irrelevant
        // data is actually removed, so GPT can't reference it even if confused.
        let previousUserQueryForTopics = conversationHistory
            .filter { $0.isUser && $0.content != userQuery }
            .last?.content
        let queryTopics = detectQueryTopics(userQuery, previousUserQuery: previousUserQueryForTopics)
        let includeAllSections = queryTopics.contains(.general) || queryTopics == Set(QueryTopic.allCases)

        // LIGHTWEIGHT GREETING MODE — when the user is just saying "hi" / "你好" /
        // "谢谢" etc., skip heavy data sections (14-day trend, sleep analysis, workout
        // history, cross-domain insights). This reduces the prompt from ~5000+ tokens to
        // ~500, cutting latency significantly and preventing GPT from over-referencing
        // data in its greeting (e.g. dumping health stats when the user just said "嗨").
        //
        // Only today's health snapshot + today's calendar are included so GPT can
        // naturally mention a highlight ("你今天走了5000步！") without exhaustive detail.
        // Special date reminders are still included (birthday greetings are high-value).
        //
        // Safety: if the query also matches a specific topic (health, calendar, etc.),
        // isLightweightGreeting stays false → full data is included as before.
        //
        // IMPORTANT: We must check raw topics (skipGeneralExpansion: true) here, NOT
        // the expanded `queryTopics`. Greetings like "你好" match generalWords in
        // detectQueryTopics, which triggers the general→all expansion, setting ALL
        // topics. Checking `queryTopics.contains(.health)` would always be true for
        // greetings, making lightweight mode unreachable (dead code). By checking raw
        // topics, we correctly detect that "你好" only matches {.general} — no specific
        // data topic — so lightweight mode activates. "你好，今天步数多少" matches
        // {.general, .health} in raw topics, so lightweight mode correctly stays off.
        let rawTopics = detectQueryTopics(userQuery, skipGeneralExpansion: true)
        let hasSpecificDataTopic = rawTopics.contains(.health) || rawTopics.contains(.calendar)
            || rawTopics.contains(.location) || rawTopics.contains(.photos)
            || rawTopics.contains(.lifeEvents)
        let isLightweightGreeting = isGreetingQuery(userQuery) && !hasSpecificDataTopic

        // HEALTH sections — benchmarks, today, yesterday, trend, sleep, workout, insights
        if includeAllSections || queryTopics.contains(.health) {
            // For greetings: only today's health snapshot (no benchmarks, trends, analysis).
            // GPT can still mention a highlight ("你今天走了5000步！") but won't dump data.
            if isLightweightGreeting {
                parts.append(healthSection(todayHealth, weeklyHealth: weeklyHealth, hourOfDay: hourOfDay, healthTimedOut: healthTimedOut))
            } else {
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

                // HEALTH INSIGHT ALERTS — pre-computed anomalies and noteworthy patterns.
                if weeklyHealth.count >= 3 {
                    let insights = healthInsightAlerts(weeklyHealth)
                    if !insights.isEmpty {
                        parts.append(insights)
                    }
                }

                // CROSS-DOMAIN INSIGHTS — correlations between exercise, sleep, calendar, and activity.
                if weeklyHealth.count >= 5 {
                    let allPastEvents = pastEvents + todayEvents
                    let crossInsights = crossDomainInsights(
                        healthSummaries: weeklyHealth,
                        calendarEvents: allPastEvents
                    )
                    if !crossInsights.isEmpty {
                        parts.append(crossInsights)
                    }
                }
            }
        }

        // CALENDAR — only include when topic-relevant AND (authorized or has data).
        // For greetings: only today's events (skip past 14 days + future 7 days to save tokens).
        // GPT can still say "你今天有3个会议" but won't dump a full calendar history.
        if includeAllSections || queryTopics.contains(.calendar) {
            if isLightweightGreeting {
                // Greeting mode: only today's events for a brief status mention
                if !todayEvents.isEmpty {
                    parts.append(calendarSection(todayEvents: todayEvents, upcoming: [], past: []))
                }
            } else {
                let hasCalendarData = !todayEvents.isEmpty || !upcomingEvents.isEmpty || !pastEvents.isEmpty
                if hasCalendarData || self.calendarService.isAuthorized {
                    // When the user is specifically asking about calendar events, extend
                    // the "full detail" window from 3 days to 7 days. This enables GPT to
                    // answer "上周三那个会议讲了什么？" with full notes/attendees/location —
                    // questions that fail with compact format (notes stripped for events >3 days old).
                    // For non-calendar queries that happen to include the calendar section
                    // (e.g. general "总结这周"), keep 3-day detail to save tokens.
                    let calendarFocused = queryTopics.contains(.calendar) && !includeAllSections
                    let detailDays = calendarFocused ? 7 : 3
                    parts.append(calendarSection(todayEvents: todayEvents, upcoming: upcomingEvents, past: pastEvents, recentDetailDays: detailDays))
                }
            }
        }

        // LOCATION — skip entirely for greetings (users don't expect location in a "hi" response).
        if !isLightweightGreeting && (includeAllSections || queryTopics.contains(.location)) {
            if !locationRecords.isEmpty || self.locationService.currentLocation != nil {
                parts.append(locationSection(locationRecords,
                                             currentLocation: self.locationService.currentLocation,
                                             currentPlaceName: self.locationService.currentPlaceName,
                                             currentAddress: self.locationService.currentAddress))
            }
        }

        // PHOTO sections — skip entirely for greetings.
        if !isLightweightGreeting && (includeAllSections || queryTopics.contains(.photos)) {
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
        } else if !isLightweightGreeting {
            // Even when photos topic is not detected, still include photo search results
            // if a search was explicitly triggered — the user's query contained photo
            // keywords that were caught by searchPhotosIfNeeded but not by detectQueryTopics.
            if !photoSearchResults.isEmpty {
                parts.append(photoSearchSection(photoSearchResults, query: photoSearchQuery))
            }
        }

        // LIFE EVENTS — skip for greetings.
        if !isLightweightGreeting && (includeAllSections || queryTopics.contains(.lifeEvents)) {
            if !lifeEvents.isEmpty {
                parts.append(lifeEventsSection(lifeEvents))
            }
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

        // Skip relevance/temporal hints for greetings — they're unnecessary when
        // only minimal data is included, and omitting them saves additional tokens.
        if !isLightweightGreeting {
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
        }

        // CURRENT QUESTION
        parts.append("[当前问题]\n用户说：\(userQuery)")

        return parts.joined(separator: "\n\n")
    }

    // MARK: - Greeting Detection

    /// Detects whether a query is a pure greeting or small talk that doesn't need
    /// detailed data context. This enables "lightweight mode" in the prompt builder,
    /// reducing token count by ~80% for common interactions like "你好", "嗨", "谢谢".
    ///
    /// The key distinction from `detectQueryTopics(.general)` is intent:
    /// - "总结这周" → `.general` → needs ALL data (summary request)
    /// - "你好" → `.general` AND isGreeting → needs only today's snapshot
    ///
    /// Short queries (≤4 chars) that match greeting patterns are treated as greetings.
    /// Longer queries that ONLY contain greeting words (no data-referencing content)
    /// are also treated as greetings (e.g. "你好啊" "谢谢你的帮助").
    private func isGreetingQuery(_ query: String) -> Bool {
        let lower = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Pure greeting words — must be exhaustive but conservative.
        // Only words that NEVER imply a data question. "怎么样" is excluded because
        // "怎么样" alone could be a follow-up to a data question.
        let greetingPatterns = [
            // Chinese greetings
            "你好", "嗨", "哈喽", "早上好", "下午好", "晚上好", "早安", "晚安",
            "在吗", "在不在", "hi", "hello", "hey", "good morning", "good evening",
            // Thanks / pleasantries
            "谢谢", "谢了", "感谢", "多谢", "thanks", "thank you", "thx",
            // Goodbye
            "拜拜", "再见", "bye", "晚安",
            // Identity
            "你是谁", "你叫什么", "你是什么", "who are you", "what are you",
            // Affirmations / fillers
            "好的", "好吧", "嗯", "哦", "ok", "okay", "知道了", "明白了",
            "收到", "了解", "没事", "没关系", "不用了",
            // Emoji-only
            "👋", "😊", "🙂", "❤️", "👍"
        ]

        // Short queries (≤6 chars) that exactly match a greeting pattern
        if lower.count <= 6 && greetingPatterns.contains(where: { lower.contains($0) }) {
            return true
        }

        // Longer queries: check if after removing greeting words and common particles,
        // no substantive content remains. "谢谢你的帮助" → "帮助" remains → false (might be asking for help).
        // "你好呀" → "" remains → true.
        let particles = ["呀", "啊", "吧", "呢", "哦", "嘛", "了", "的", "你", "我", "！", "!", "~", "～", "。", ".", ",", "，", " "]
        var stripped = lower
        for pattern in greetingPatterns {
            stripped = stripped.replacingOccurrences(of: pattern, with: "")
        }
        for p in particles {
            stripped = stripped.replacingOccurrences(of: p, with: "")
        }
        stripped = stripped.trimmingCharacters(in: .whitespacesAndNewlines)

        // If nothing substantive remains after stripping greetings + particles, it's a greeting
        return stripped.isEmpty && greetingPatterns.contains(where: { lower.contains($0) })
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
    /// When `skipGeneralExpansion` is true, returns only the raw keyword-matched
    /// topics without expanding `.general` → all cases. This lets callers distinguish
    /// "matched no specific topic" (→ {.general} or empty) from "matched health+calendar".
    /// Used by lightweight greeting detection to check if a greeting query ALSO contains
    /// specific data-topic keywords (e.g. "你好，今天步数多少").
    private func detectQueryTopics(_ query: String, previousUserQuery: String? = nil, skipGeneralExpansion: Bool = false) -> Set<QueryTopic> {
        let lower = query.lowercased()
        var topics: Set<QueryTopic> = []

        // NOTE on Chinese single-character matching: avoid standalone single chars
        // like "步" that appear in many non-health words ("下一步", "进步", "步骤").
        // Use 2+ char compounds instead (e.g. "步数", "步行", "散步"). Similarly,
        // "约" matches "大约" (approximately), "远" matches "远程" (remote) — removed
        // and replaced with more specific compounds to reduce false-positive topic tags
        // that dilute the relevance hint's focus.
        let healthWords = [
            "步数", "走步", "步行", "走路", "走了", "跑步", "跑了", "运动", "锻炼", "健身",
            "睡眠", "睡觉", "睡了", "睡得", "入睡", "起床", "失眠", "早起", "熬夜", "晚睡",
            "补觉", "作息", "赖床", "欠觉", "睡够", "睡眠负债", "sleep debt",
            "心率", "心跳", "卡路里", "热量", "消耗", "能量",
            "体重", "胖", "瘦", "血氧", "VO2", "减肥", "增重",
            // Direct health/body terms — "我的健康数据怎么样" or "身体状况如何"
            // Without these, the relevance hint misses the most literal health queries
            "健康", "身体",
            // Specific workout types — users often ask about specific activities
            "游泳", "骑车", "骑行", "瑜伽", "散步", "爬山", "徒步", "举铁", "力量训练",
            "拉伸", "冥想", "太极", "跳绳", "划船", "椭圆机", "高强度",
            // Ball sports — common in Chinese daily life
            "打球", "篮球", "足球", "网球", "乒乓", "羽毛球", "排球", "高尔夫",
            // Physical condition — often relates to health/sleep data
            "好累", "太累", "疲劳", "精力", "恢复", "酸痛",
            // Stress / mental state — HRV, resting HR, and sleep are direct indicators
            // "压力大吗" "最近焦虑" "状态不好" should focus on health data, not scatter all sections
            "压力", "焦虑", "紧张", "放松", "状态不好", "状态差", "不舒服",
            "头疼", "头痛", "胸闷", "心慌", "难受",
            // Activity Rings (Apple Watch) — users commonly ask "圆环合了吗？"
            "圆环", "活动圆环", "站立", "站了",
            // Step count with unit/quantifier — bare "步" excluded (false positives: "下一步",
            // "进步", "步骤") but "N万步"/"N千步"/"多少步"/"几步" are unambiguously health.
            // Without these, "一万步够吗"/"日均多少步"/"8000步" miss health detection entirely,
            // causing all sections to be included and wasting ~40% tokens.
            "万步", "千步", "多少步", "几步",
            // Calorie unit variants — "卡路里" is in the list but "千卡" and "大卡" are
            // common Chinese shorthand. "消耗了500千卡" would miss without these.
            "千卡", "大卡",
            "exercise", "sleep", "step", "heart", "workout", "calorie", "weight",
            "hrv", "vo2", "bpm", "kcal", "swimming", "cycling", "yoga", "hiking", "running",
            "stand", "ring", "activity ring", "health", "body",
            "stress", "anxious", "anxiety", "tired", "fatigue", "recovery", "relax"
        ]
        if healthWords.contains(where: { lower.contains($0) }) {
            topics.insert(.health)
        }
        // Regex fallback for numeric step patterns: "8000步", "5000步", "10000步".
        // These are extremely common queries ("够8000步了吗", "今天3000步") that
        // don't match any compound keyword above because bare "步" is excluded.
        // The digit prefix makes false positives impossible (no Chinese word is "N步"
        // in a non-health context).
        if !topics.contains(.health) && lower.range(of: #"\d+步"#, options: .regularExpression) != nil {
            topics.insert(.health)
        }

        let calendarWords = [
            "日程", "日历", "会议", "安排", "行程", "计划", "开会",
            // Appointment & work-related terms — "约" removed (matches "大约"),
            // "活动" removed (matches "运动活动量"), kept specific compounds only
            "预约", "面试", "上班", "下班", "提醒", "截止", "deadline",
            "见面", "聚餐", "聚会", "约会", "约了",
            // Recurring event queries — "这个会每周都有吗？" "有哪些固定会议？"
            "重复", "例会", "周会", "站会", "recurring",
            // Free time / availability queries — map to calendar for free slot analysis
            "有空", "空闲", "有时间", "忙不忙", "忙吗", "free", "available", "busy",
            // "Am I in a meeting?" patterns — "在开会吗" "开着会呢" "现在有会吗"
            "在开会", "开着会", "在做什么",
            "schedule", "calendar", "meeting", "event", "appointment", "interview"
        ]
        if calendarWords.contains(where: { lower.contains($0) }) {
            topics.insert(.calendar)
        }

        let locationWords = [
            "去了", "去过", "地方", "位置", "在哪", "哪里", "足迹", "出门",
            "城市", "回家", "公司", "地点",
            // Movement & commute terms — "远" removed (matches "远程", "远不如"),
            // replaced with more specific patterns
            "附近", "通勤", "出差", "旅行", "路线", "距离", "好远", "多远", "逛",
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
            // When caller only needs raw keyword matches (e.g. for greeting detection),
            // skip the general→all expansion and follow-up inheritance.
            if skipGeneralExpansion { return topics }

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
            sectionNames.append("[今日健康数据]、[近14天健康趋势]、[睡眠质量分析]、[运动记录]、[生活模式洞察]")
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
        let hourOfDay = cal.component(.hour, from: now)

        // --- Single-day references ---

        let yesterdayDate = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now))!
        let twoDaysAgo = cal.date(byAdding: .day, value: -2, to: cal.startOfDay(for: now))!
        let threeDaysAgo = cal.date(byAdding: .day, value: -3, to: cal.startOfDay(for: now))!
        let tomorrowDate = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
        let dayAfterTomorrow = cal.date(byAdding: .day, value: 2, to: cal.startOfDay(for: now))!

        // "今天" / "today" — seems obvious, but critical at late-night hours (0-4am)
        // when "today" in the user's mind almost always means "the day that just ended"
        // (calendar yesterday). Without an explicit hint, GPT sees "[今日健康数据]" showing
        // zeros and answers "0步" instead of citing yesterday's real data. Also, during
        // normal hours the hint reinforces that today's data is partial.
        let todayWords = ["今天", "今日", "today"]
        // Avoid triggering on "今天晚上" (handled separately below as "tonight")
        let hasTodayWord = todayWords.contains(where: { lower.contains($0) })
        let hasTonightOverride = ["今天晚上", "今晚", "tonight"].contains(where: { lower.contains($0) })
        if hasTodayWord && !hasTonightOverride {
            if hourOfDay < 5 {
                hints.append("「今天」→ ⚠️ 现在是凌晨\(hourOfDay)点，用户说「今天」几乎一定指刚过去的那一天（日历上的「昨天」\(dateFmt.string(from: yesterdayDate))）。请回答「昨天」行的数据，不要引用日历「今天」的0值数据。")
            } else if hourOfDay < 12 {
                hints.append("「今天」= \(dateFmt.string(from: now))（\(weekdayFmt.string(from: now))）→ 趋势表中标记为「今天」的行。注意：今天数据截至上午\(hourOfDay)点，还在持续积累中。")
            } else {
                hints.append("「今天」= \(dateFmt.string(from: now))（\(weekdayFmt.string(from: now))）→ 趋势表中标记为「今天」的行")
            }
        }

        // "今晚" / "tonight" — never previously handled. Context-dependent:
        //   - During daytime/evening: tonight = today's evening, check today's remaining calendar
        //   - Late night (0-4am): "tonight" = the night the user is currently in, which started
        //     "yesterday evening". Sleep data (if any) would be in today's row (wake-up attribution).
        let tonightWords = ["今晚", "今天晚上", "今夜", "tonight"]
        if tonightWords.contains(where: { lower.contains($0) }) {
            if hourOfDay < 5 {
                hints.append("「今晚」→ 现在是凌晨\(hourOfDay)点，用户说「今晚」指的是当前正在经历的这个夜晚（从\(dateFmt.string(from: yesterdayDate))晚上开始）。如果问睡眠相关，这段睡眠醒来后会归属到日历今天（\(dateFmt.string(from: now))）的睡眠行。如果问日程相关，指的是\(dateFmt.string(from: yesterdayDate))晚上的安排。")
            } else {
                hints.append("「今晚」= \(dateFmt.string(from: now))晚上 → 查看今天的日历日程中晚间时段（18:00之后）的安排")
            }
        }

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

        // "最近N天" / "近N天" — very common Chinese temporal patterns.
        // "最近3天睡得怎么样" or "近7天运动了几次" need exact date resolution,
        // otherwise GPT gets only a vague "近3~7天" hint and has to guess
        // which trend-table rows to aggregate — often miscounting.
        // Must be checked BEFORE the bare "最近" handler below, so "最近3天"
        // gets a precise hint instead of the generic fallback.
        var recentNDaysHandled = false
        let recentNDayPatterns: [(pattern: String, days: Int)] = [
            // Chinese numeral variants
            ("最近两天", 2), ("最近三天", 3), ("最近四天", 4), ("最近五天", 5),
            ("最近六天", 6), ("最近七天", 7), ("最近十天", 10),
            ("近两天", 2), ("近三天", 3), ("近四天", 4), ("近五天", 5),
            ("近六天", 6), ("近七天", 7), ("近十天", 10),
            // Duration-based variants
            ("最近一周", 7), ("最近两周", 14), ("近一周", 7), ("近两周", 14),
            ("近一个月", 30), ("最近一个月", 30),
            // English
            ("last few days", 3), ("recent days", 5),
            ("last 3 days", 3), ("last 5 days", 5), ("last 7 days", 7)
        ]
        for (pattern, requestedDays) in recentNDayPatterns {
            guard lower.contains(pattern) else { continue }
            recentNDaysHandled = true
            if requestedDays <= 14 {
                let rangeStart = cal.date(byAdding: .day, value: -(requestedDays - 1), to: cal.startOfDay(for: now))!
                hints.append("「\(pattern)」= \(dateFmt.string(from: rangeStart))~\(dateFmt.string(from: now))（\(requestedDays)天，数据完整覆盖）→ 对应趋势表中这\(requestedDays)天的数据行")
            } else {
                let dataStart = cal.date(byAdding: .day, value: -13, to: cal.startOfDay(for: now))!
                hints.append("「\(pattern)」= 用户期望\(requestedDays)天数据，⚠️ 但我们只有近14天（\(dateFmt.string(from: dataStart))~\(dateFmt.string(from: now))）。请说明只有14天数据，基于已有数据回答。")
            }
            break
        }
        // Also handle Arabic numeral patterns: "最近3天", "近5天", "最近10天" etc.
        if !recentNDaysHandled {
            if let range = lower.range(of: #"(?:最近|近)(\d+)天"#, options: .regularExpression) {
                let matched = String(lower[range])
                // Extract the number: remove "最近"/"近" prefix and "天" suffix
                let numStr = matched.replacingOccurrences(of: "最近", with: "")
                    .replacingOccurrences(of: "近", with: "")
                    .replacingOccurrences(of: "天", with: "")
                if let requestedDays = Int(numStr), requestedDays >= 2 && requestedDays <= 30 {
                    recentNDaysHandled = true
                    if requestedDays <= 14 {
                        let rangeStart = cal.date(byAdding: .day, value: -(requestedDays - 1), to: cal.startOfDay(for: now))!
                        hints.append("「\(matched)」= \(dateFmt.string(from: rangeStart))~\(dateFmt.string(from: now))（\(requestedDays)天，数据完整覆盖）→ 对应趋势表中这\(requestedDays)天的数据行")
                    } else {
                        let dataStart = cal.date(byAdding: .day, value: -13, to: cal.startOfDay(for: now))!
                        hints.append("「\(matched)」= 用户期望\(requestedDays)天数据，⚠️ 但我们只有近14天（\(dateFmt.string(from: dataStart))~\(dateFmt.string(from: now))）。请说明只有14天数据，基于已有数据回答。")
                    }
                }
            }
        }

        // "最近" / "前几天" / "这几天" — bare ambiguous terms (no specific N)
        // Only fire the generic hint when "最近N天" was NOT already handled above,
        // to avoid conflicting/redundant hints (e.g. "最近3天" getting both
        // the precise "3月18日~3月21日" hint AND the vague "近3~7天" hint).
        if !recentNDaysHandled {
            let recentWords = ["最近", "近来", "近期", "recently", "lately"]
            if recentWords.contains(where: { lower.contains($0) }) {
                hints.append("「最近」→ 优先参考近3~7天数据，结合上下文判断具体范围")
            }
        }
        let fewDaysWords = ["前几天", "前些天", "这几天", "这两天"]
        if fewDaysWords.contains(where: { lower.contains($0) }) {
            let threeDaysAgoDate = cal.date(byAdding: .day, value: -3, to: cal.startOfDay(for: now))!
            hints.append("「\(fewDaysWords.first { lower.contains($0) } ?? "前几天")」→ 大约\(dateFmt.string(from: threeDaysAgoDate))~\(dateFmt.string(from: now))（近3~4天）")
        }

        // --- Approximate day-range expressions ---
        // Chinese speakers commonly use vague multi-day expressions like "好几天",
        // "两三天前", "一两天前", "这段时间", "这阵子", "半个月" that don't match any
        // of the precise "N天" patterns above. Without hints, GPT receives NO temporal
        // guidance for these queries — it has to guess the date range, often picking
        // wrong rows from the trend table or giving vague answers without data.

        // "好几天" / "好久" — colloquial "several days/quite a while"
        let severalDaysWords = ["好几天", "好多天"]
        if severalDaysWords.contains(where: { lower.contains($0) }) {
            let fiveDaysAgo = cal.date(byAdding: .day, value: -5, to: cal.startOfDay(for: now))!
            hints.append("「\(severalDaysWords.first { lower.contains($0) }!)」→ 大约\(dateFmt.string(from: fiveDaysAgo))~\(dateFmt.string(from: now))（近5~7天），查看趋势表对应数据行")
        }

        // "两三天前" / "三四天前" / "四五天前" — approximate range references.
        // Very natural in Chinese: "两三天前好像去了什么地方", "四五天前跑的步"
        let approxDayPatterns: [(pattern: String, minDays: Int, maxDays: Int)] = [
            ("一两天前", 1, 2), ("一两天", 1, 2),
            ("两三天前", 2, 3), ("两三天", 2, 3),
            ("三四天前", 3, 4), ("三四天", 3, 4),
            ("四五天前", 4, 5), ("四五天", 4, 5),
            ("五六天前", 5, 6), ("五六天", 5, 6),
            ("六七天前", 6, 7), ("六七天", 6, 7)
        ]
        for (pattern, minD, maxD) in approxDayPatterns {
            if lower.contains(pattern) {
                let startDate = cal.date(byAdding: .day, value: -maxD, to: cal.startOfDay(for: now))!
                let endDate = cal.date(byAdding: .day, value: -minD, to: cal.startOfDay(for: now))!
                hints.append("「\(pattern)」→ 大约\(dateFmt.string(from: startDate))~\(dateFmt.string(from: endDate))（\(minD)~\(maxD)天前）→ 查看趋势表/日历/位置中对应日期")
                break // only match the first (most specific) approximate pattern
            }
        }

        // "半个月" — extremely common Chinese expression ≈ 15 days.
        // "近半个月" or "最近半个月" or bare "半个月" all refer to ~15 days.
        // Our 14-day data window almost exactly covers this. Without this hint,
        // GPT receives no guidance and may either overshoot (assume 30 days) or
        // undershoot (assume 7 days) the intended range.
        if !recentNDaysHandled {
            let halfMonthWords = ["半个月", "半月"]
            if halfMonthWords.contains(where: { lower.contains($0) }) {
                let dataStart = cal.date(byAdding: .day, value: -13, to: cal.startOfDay(for: now))!
                hints.append("「\(halfMonthWords.first { lower.contains($0) }!)」≈ 15天 → 我们有近14天数据（\(dateFmt.string(from: dataStart))~\(dateFmt.string(from: now))），基本覆盖。使用全部14天数据回答即可。")
            }
        }

        // "这段时间" / "这阵子" / "这些天" — vague "this period" expressions.
        // Without a hint, GPT has no anchor for the intended range.
        // Default to ~7 days (one week) as a balanced interpretation.
        let vagueRecentWords = ["这段时间", "这阵子", "这些天", "这些日子", "这段日子"]
        if vagueRecentWords.contains(where: { lower.contains($0) }) {
            let sevenDaysAgo = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: now))!
            hints.append("「\(vagueRecentWords.first { lower.contains($0) }!)」→ 大约近一周（\(dateFmt.string(from: sevenDaysAgo))~\(dateFmt.string(from: now))），可结合上下文扩大至近14天")
        }

        // "半年" / "几个月" — clearly beyond our data range, must warn.
        // Users say "半年前还在跑步呢" or "这几个月运动少了" — GPT must not fabricate.
        let longRangeWords = ["半年", "几个月", "好几个月", "大半年"]
        if longRangeWords.contains(where: { lower.contains($0) }) {
            let dataStart = cal.date(byAdding: .day, value: -13, to: cal.startOfDay(for: now))!
            hints.append("「\(longRangeWords.first { lower.contains($0) }!)」⚠️ 远超14天数据范围（\(dateFmt.string(from: dataStart))~\(dateFmt.string(from: now))），无法回答。请坦诚告知用户我们只有近两周的数据，然后基于已有数据给出部分参考。")
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

        // --- Year references ---
        // Users commonly ask "今年运动了多少次" or "去年这个时候我在干嘛".
        // Without explicit guidance, GPT silently extrapolates 14 days → 365 days,
        // giving wildly misleading answers (e.g. "今年跑步了52次" from 2 weeks of data).
        let yearFmt = DateFormatter(); yearFmt.dateFormat = "yyyy年"
        let thisYearStart = cal.date(from: cal.dateComponents([.year], from: now))!
        let dayOfYear = cal.ordinality(of: .day, in: .year, for: now) ?? 1

        let thisYearWords = ["今年", "今年以来", "this year"]
        if thisYearWords.contains(where: { lower.contains($0) }) {
            let dataStart = cal.date(byAdding: .day, value: -13, to: cal.startOfDay(for: now))!
            if dayOfYear <= 14 {
                hints.append("「今年」= \(yearFmt.string(from: now))（\(dateFmt.string(from: thisYearStart))~\(dateFmt.string(from: now))，已过\(dayOfYear)天，数据完整覆盖）")
            } else {
                hints.append("「今年」= \(yearFmt.string(from: now))（\(dateFmt.string(from: thisYearStart))~\(dateFmt.string(from: now))，已过\(dayOfYear)天）⚠️ 我们只有近14天数据（\(dateFmt.string(from: dataStart))起），无法回答全年问题。请先说明只有近两周数据，然后基于这14天给出部分回答，明确标注「近两周内」而非「今年」。绝不要将14天数据外推为全年结论。")
            }
        }

        let lastYearWords = ["去年", "last year"]
        if lastYearWords.contains(where: { lower.contains($0) }) {
            let lastYearDate = cal.date(byAdding: .year, value: -1, to: thisYearStart)!
            hints.append("「去年」= \(yearFmt.string(from: lastYearDate))（\(dateFmt.string(from: lastYearDate))~\(dateFmt.string(from: cal.date(byAdding: .day, value: -1, to: thisYearStart)!))）⚠️ 完全超出14天数据范围，无法回答。请坦诚告知用户我们只有近两周的数据，无法查看去年的记录。")
        }

        // --- "N天前" patterns ---
        // Users say "三天前去了哪里" or "5天前", currently only "前天"/"大前天" are
        // handled. This regex catches "三天前", "四天前", "5天前", "7天前" etc.
        let nDaysAgoPatterns: [(pattern: String, days: Int)] = [
            ("三天前", 3), ("四天前", 4), ("五天前", 5),
            ("六天前", 6), ("七天前", 7), ("八天前", 8),
            ("九天前", 9), ("十天前", 10)
        ]
        for (pattern, daysAgo) in nDaysAgoPatterns {
            if lower.contains(pattern) {
                let targetDate = cal.date(byAdding: .day, value: -daysAgo, to: cal.startOfDay(for: now))!
                let dataStart = cal.date(byAdding: .day, value: -13, to: cal.startOfDay(for: now))!
                if targetDate >= dataStart {
                    hints.append("「\(pattern)」= \(dateFmt.string(from: targetDate))（\(weekdayFmt.string(from: targetDate))）→ 在数据范围内")
                } else {
                    hints.append("「\(pattern)」= \(dateFmt.string(from: targetDate))（\(weekdayFmt.string(from: targetDate))）⚠️ 超出14天数据范围")
                }
            }
        }
        // Also handle Arabic numeral patterns like "3天前", "5天前"
        if let range = lower.range(of: #"(\d+)天前"#, options: .regularExpression) {
            let numStr = lower[range].dropLast(2) // remove "天前"
            if let daysAgo = Int(numStr), daysAgo >= 3 && daysAgo <= 30 {
                // Skip if already handled by Chinese numeral patterns above
                let alreadyHandled = nDaysAgoPatterns.contains { lower.contains($0.pattern) && $0.days == daysAgo }
                if !alreadyHandled {
                    let targetDate = cal.date(byAdding: .day, value: -daysAgo, to: cal.startOfDay(for: now))!
                    let dataStart = cal.date(byAdding: .day, value: -13, to: cal.startOfDay(for: now))!
                    if targetDate >= dataStart {
                        hints.append("「\(daysAgo)天前」= \(dateFmt.string(from: targetDate))（\(weekdayFmt.string(from: targetDate))）→ 在数据范围内")
                    } else {
                        hints.append("「\(daysAgo)天前」= \(dateFmt.string(from: targetDate))（\(weekdayFmt.string(from: targetDate))）⚠️ 超出14天数据范围，无此日期数据")
                    }
                }
            }
        }

        // --- "过去N天" / "过去一个月" range patterns ---
        // Users say "过去30天运动了几次" or "过去一个月的睡眠" — need to clarify
        // our 14-day data boundary so GPT doesn't silently extrapolate.
        let pastRangePatterns: [(pattern: String, days: Int)] = [
            ("过去一个月", 30), ("过去一月", 30), ("past month", 30),
            ("过去30天", 30), ("past 30 days", 30),
            ("过去两周", 14), ("过去2周", 14), ("past two weeks", 14),
            ("过去三周", 21), ("过去3周", 21),
            ("过去一周", 7), ("past week", 7)
        ]
        for (pattern, requestedDays) in pastRangePatterns {
            if lower.contains(pattern) {
                if requestedDays <= 14 {
                    let rangeStart = cal.date(byAdding: .day, value: -(requestedDays - 1), to: cal.startOfDay(for: now))!
                    hints.append("「\(pattern)」= \(dateFmt.string(from: rangeStart))~\(dateFmt.string(from: now))（\(requestedDays)天，数据完整覆盖）")
                } else {
                    let dataStart = cal.date(byAdding: .day, value: -13, to: cal.startOfDay(for: now))!
                    hints.append("「\(pattern)」= 用户期望\(requestedDays)天数据，⚠️ 但我们只有近14天（\(dateFmt.string(from: dataStart))~\(dateFmt.string(from: now))）。请说明只有14天数据，基于已有数据回答，标注「近两周内」。")
                }
                break // Only match the first (most specific) pattern
            }
        }

        // --- Specific weekday references ---
        // "周三有什么安排？" → resolve to exact date.
        // Handles three patterns with increasing specificity:
        //   1. "上周X" → directly resolve to last week (no ambiguity)
        //   2. "下周X" → directly resolve to next week (no ambiguity)
        //   3. Bare "周X" → disambiguate: today / past this week / upcoming this week
        // Does NOT `break` after first match — "周三和周五" resolves both.
        let weekdayMap: [(short: String, long: String, weekday: Int)] = [
            ("周一", "星期一", 2), ("周二", "星期二", 3), ("周三", "星期三", 4),
            ("周四", "星期四", 5), ("周五", "星期五", 6), ("周六", "星期六", 7),
            ("周日", "星期日", 1)
        ]
        // Also handle colloquial aliases:
        //  - "星期天" / "周天" — very common colloquial Chinese for Sunday
        //  - "礼拜一"~"礼拜天"/"礼拜日" — regional/dialect variant used widely
        //  - English full weekday names — SYSTEM prompt says "用英文提问，用英文回答",
        //    so English queries like "what did I do on Wednesday?" need date resolution.
        //    Without these, GPT receives no temporal hint for English weekday references
        //    and must guess the date — frequently picking the wrong week.
        //    Use full names only to avoid false matches ("mon" in "money", "sat" in "satisfaction").
        let extraAliases: [(String, Int)] = [
            ("星期天", 1), ("周天", 1),
            ("礼拜一", 2), ("礼拜二", 3), ("礼拜三", 4),
            ("礼拜四", 5), ("礼拜五", 6), ("礼拜六", 7),
            ("礼拜天", 1), ("礼拜日", 1),
            // English weekday names (full form to avoid false positives)
            ("monday", 2), ("tuesday", 3), ("wednesday", 4),
            ("thursday", 5), ("friday", 6), ("saturday", 7), ("sunday", 1)
        ]

        // Pre-check "上周X", "下周X", and "这周X" prefixes to avoid ambiguous fallback.
        // MUST include "上礼拜" (without "个") — otherwise "上礼拜三" triggers
        // the ambiguous "本周三(已过) / 上周三" fallback instead of definitively
        // resolving to last Wednesday. Same applies to "下礼拜" and "这礼拜".
        //
        // "这周X" / "本周X" / "这个星期X" must also be recognized: when the user
        // says "这周三做了什么运动？", they unambiguously mean THIS week's Wednesday.
        // Without this check, "这周三" falls through to the bare "周三" handler which
        // presents both this-week and last-week options as ambiguous — even though
        // the user's intent is clear.
        // Include English prefixes so "last Monday", "next Friday", "this Wednesday"
        // resolve unambiguously, matching the Chinese prefix behavior. Without these,
        // "last monday" falls through to the bare weekday handler which shows both
        // this-week and last-week dates as ambiguous options.
        //
        // English prefix detection: match "last/next/this" only when followed by a weekday
        // name (via regex) to avoid false positives from "at last..." or "this is...".
        // Chinese prefixes don't need this guard because "上周"/"下周" are unambiguous.
        let englishWeekdayNames = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
        let hasEnglishLastPrefix = englishWeekdayNames.contains { lower.contains("last \($0)") }
        let hasEnglishNextPrefix = englishWeekdayNames.contains { lower.contains("next \($0)") }
        let hasEnglishThisPrefix = englishWeekdayNames.contains { lower.contains("this \($0)") }

        let hasLastWeekPrefix = hasEnglishLastPrefix
            || ["上周", "上个星期", "上星期", "上个礼拜", "上礼拜"]
            .contains(where: { lower.contains($0) })
        let hasNextWeekPrefix = hasEnglishNextPrefix
            || ["下周", "下个星期", "下星期", "下个礼拜", "下礼拜"]
            .contains(where: { lower.contains($0) })
        let hasThisWeekPrefix = hasEnglishThisPrefix
            || ["这周", "本周", "这个星期", "这星期", "这个礼拜", "这礼拜"]
            .contains(where: { lower.contains($0) })

        var resolvedWeekdays = Set<Int>() // avoid duplicates (周三 + 星期三)
        let allNameMappings: [(String, Int)] = weekdayMap.flatMap { [($0.short, $0.weekday), ($0.long, $0.weekday)] }
            + extraAliases

        for (name, targetWeekday) in allNameMappings {
            guard lower.contains(name) else { continue }
            guard !resolvedWeekdays.contains(targetWeekday) else { continue }
            resolvedWeekdays.insert(targetWeekday)

            let targetDaysSinceMonday = (targetWeekday + 5) % 7
            let targetThisWeek = cal.date(byAdding: .day, value: targetDaysSinceMonday, to: thisMonday)!
            let targetLastWeek = cal.date(byAdding: .day, value: -7, to: targetThisWeek)!
            let targetNextWeek = cal.date(byAdding: .day, value: 7, to: targetThisWeek)!
            let shortName = weekdayMap.first { $0.weekday == targetWeekday }?.short ?? name

            if hasLastWeekPrefix {
                // "上周三" → unambiguously last week
                hints.append("「上\(shortName)」= \(dateFmt.string(from: targetLastWeek))")
            } else if hasNextWeekPrefix {
                // "下周三" → unambiguously next week
                hints.append("「下\(shortName)」= \(dateFmt.string(from: targetNextWeek))→ 查看日历日程中对应日期")
            } else if hasThisWeekPrefix {
                // "这周三" / "本周三" → unambiguously this week.
                // Users who say "这周三" intend this week even if Wednesday already passed.
                // Without this, "这周三运动了吗" on Friday gets an ambiguous hint showing
                // both this week and last week options, causing GPT to hedge or pick wrong.
                if cal.isDate(targetThisWeek, inSameDayAs: cal.startOfDay(for: now)) {
                    hints.append("「这\(shortName)」= \(dateFmt.string(from: targetThisWeek))（今天）")
                } else if targetThisWeek < cal.startOfDay(for: now) {
                    hints.append("「这\(shortName)」= \(dateFmt.string(from: targetThisWeek))（本周，已过）")
                } else {
                    hints.append("「这\(shortName)」= \(dateFmt.string(from: targetThisWeek))（本周，即将到来）→ 查看日历日程中对应日期")
                }
            } else if cal.isDate(targetThisWeek, inSameDayAs: cal.startOfDay(for: now)) {
                // The referenced weekday IS today — "周五" asked on Friday
                hints.append("「\(shortName)」= \(dateFmt.string(from: targetThisWeek))（今天）")
            } else if targetThisWeek < cal.startOfDay(for: now) {
                // This weekday already passed this week — provide both options
                hints.append("「\(shortName)」→ 本周\(shortName) = \(dateFmt.string(from: targetThisWeek))（已过），上\(shortName) = \(dateFmt.string(from: targetLastWeek))")
            } else {
                // This weekday hasn't come yet — upcoming this week
                hints.append("「\(shortName)」→ 本周\(shortName) = \(dateFmt.string(from: targetThisWeek))（即将到来）")
            }
        }

        // --- Absolute date references ---
        // Users commonly ask "3月15日走了多少步" or "15号有什么安排" with explicit dates.
        // GPT can parse these dates, but critically it doesn't know whether the date
        // falls within our 14-day data window. Without a hint, GPT may silently fabricate
        // data for dates outside the range, or miss that "18号" in late March means "3月18日".
        // Pre-resolving to exact dates with data-range checks prevents these errors.

        let dataRangeStart = cal.date(byAdding: .day, value: -13, to: cal.startOfDay(for: now))!
        let futureRangeEnd = cal.date(byAdding: .day, value: 7, to: cal.startOfDay(for: now))!

        // Helper: check a resolved date against our data windows and produce a hint
        let resolveAbsoluteDate: (Date, String) -> String? = { [cal] targetDate, originalText in
            let targetStart = cal.startOfDay(for: targetDate)
            let todayStart = cal.startOfDay(for: now)

            // Determine relative label (today, yesterday, etc.)
            let relativeLabel: String
            if cal.isDateInToday(targetDate) {
                relativeLabel = "今天"
            } else if cal.isDateInYesterday(targetDate) {
                relativeLabel = "昨天"
            } else if let twoDaysAgo = cal.date(byAdding: .day, value: -2, to: todayStart),
                      cal.isDate(targetDate, inSameDayAs: twoDaysAgo) {
                relativeLabel = "前天"
            } else if let tomorrow = cal.date(byAdding: .day, value: 1, to: todayStart),
                      cal.isDate(targetDate, inSameDayAs: tomorrow) {
                relativeLabel = "明天"
            } else {
                relativeLabel = weekdayFmt.string(from: targetDate)
            }

            let dateStr = dateFmt.string(from: targetDate)

            if targetStart >= dataRangeStart && targetStart <= todayStart {
                // Within health/location/photo data range
                let daysAgo = cal.dateComponents([.day], from: targetStart, to: todayStart).day ?? 0
                return "「\(originalText)」= \(dateStr)（\(relativeLabel)，\(daysAgo)天前）→ 在数据范围内，查看趋势表/日历/位置中对应日期"
            } else if targetStart > todayStart && targetStart <= futureRangeEnd {
                // Within future calendar range
                let daysAhead = cal.dateComponents([.day], from: todayStart, to: targetStart).day ?? 0
                return "「\(originalText)」= \(dateStr)（\(relativeLabel)，\(daysAhead)天后）→ 查看日历日程中对应日期"
            } else if targetStart > futureRangeEnd {
                // Beyond future calendar range
                return "「\(originalText)」= \(dateStr)（\(relativeLabel)）⚠️ 超出日历数据范围（未来仅覆盖7天），无此日期日程数据"
            } else {
                // Before data range start
                let daysAgo = cal.dateComponents([.day], from: targetStart, to: todayStart).day ?? 0
                return "「\(originalText)」= \(dateStr)（\(daysAgo)天前）⚠️ 超出14天数据范围，无此日期的健康/日历/位置数据，请坦诚告知用户"
            }
        }

        // Pattern 1: "X月Y日" / "X月Y号" — e.g. "3月15日", "3月15号"
        // Use regex to extract month and day numbers.
        var absoluteDateHandled = false
        if let range = lower.range(of: #"(\d{1,2})月(\d{1,2})[日号]?"#, options: .regularExpression) {
            let matched = String(lower[range])
            let digits = matched.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
            if digits.count >= 2, let month = Int(digits[0]), let day = Int(digits[1]),
               month >= 1 && month <= 12 && day >= 1 && day <= 31 {
                // Resolve to the nearest occurrence of this date (this year or last year)
                let currentYear = cal.component(.year, from: now)
                var comps = DateComponents()
                comps.year = currentYear
                comps.month = month
                comps.day = day
                if let targetDate = cal.date(from: comps) {
                    // If this date is far in the future (>6 months ahead), the user likely means last year
                    let targetToUse: Date
                    if targetDate.timeIntervalSince(now) > 180 * 24 * 3600 {
                        comps.year = currentYear - 1
                        targetToUse = cal.date(from: comps) ?? targetDate
                    } else {
                        targetToUse = targetDate
                    }
                    if let hint = resolveAbsoluteDate(targetToUse, matched) {
                        hints.append(hint)
                        absoluteDateHandled = true
                    }
                }
            }
        }

        // Pattern 2: "N号" — e.g. "15号去了哪里", "18号有什么会"
        // Only match bare "N号" without "月" prefix (which is handled above).
        // Resolve to the current month by default; if the day hasn't come yet this month,
        // it's upcoming; if it already passed, it was earlier this month (or last month
        // if outside data range).
        if !absoluteDateHandled {
            if let range = lower.range(of: #"(?<!\d月)(\d{1,2})号"#, options: .regularExpression) {
                let matched = String(lower[range])
                let numStr = matched.replacingOccurrences(of: "号", with: "")
                if let day = Int(numStr), day >= 1 && day <= 31 {
                    let currentMonth = cal.component(.month, from: now)
                    let currentYear = cal.component(.year, from: now)

                    var comps = DateComponents()
                    comps.year = currentYear
                    comps.month = currentMonth
                    comps.day = day

                    if let targetDate = cal.date(from: comps) {
                        let targetStart = cal.startOfDay(for: targetDate)
                        let todayStart = cal.startOfDay(for: now)

                        // If the day this month is far in the future (>15 days), user likely
                        // means last month's N号. E.g., on March 5, "28号" → Feb 28.
                        let targetToUse: Date
                        if targetStart > todayStart && cal.dateComponents([.day], from: todayStart, to: targetStart).day ?? 0 > 15 {
                            comps.month = currentMonth - 1
                            if comps.month == 0 { comps.month = 12; comps.year = currentYear - 1 }
                            targetToUse = cal.date(from: comps) ?? targetDate
                        } else {
                            targetToUse = targetDate
                        }

                        if let hint = resolveAbsoluteDate(targetToUse, matched) {
                            hints.append(hint)
                        }
                    }
                }
            }
        }

        // Pattern 3: "M/D" or "M.D" date format — e.g. "3/15", "3.18"
        // Common in casual Chinese digital communication.
        if !absoluteDateHandled {
            if let range = lower.range(of: #"(\d{1,2})[/.](\d{1,2})"#, options: .regularExpression) {
                let matched = String(lower[range])
                let parts = matched.split(whereSeparator: { $0 == "/" || $0 == "." })
                if parts.count == 2, let month = Int(parts[0]), let day = Int(parts[1]),
                   month >= 1 && month <= 12 && day >= 1 && day <= 31 {
                    let currentYear = cal.component(.year, from: now)
                    var comps = DateComponents()
                    comps.year = currentYear
                    comps.month = month
                    comps.day = day
                    if let targetDate = cal.date(from: comps) {
                        let targetToUse: Date
                        if targetDate.timeIntervalSince(now) > 180 * 24 * 3600 {
                            comps.year = currentYear - 1
                            targetToUse = cal.date(from: comps) ?? targetDate
                        } else {
                            targetToUse = targetDate
                        }
                        if let hint = resolveAbsoluteDate(targetToUse, matched) {
                            hints.append(hint)
                        }
                    }
                }
            }
        }

        guard !hints.isEmpty else { return "" }

        return "[时间聚焦]\n\(hints.joined(separator: "\n"))"
    }

    // MARK: - Special Date Reminders

    /// Checks the user's and family members' birthdays against the current date
    /// and surfaces upcoming birthdays within 7 days. Also detects "today is the
    /// birthday" so GPT can proactively congratulate.
    ///
    /// This is a core personalization feature: the assistant should feel like it
    /// "knows" the user. A generic AI can't tell you your mom's birthday is in
    /// 2 days — iosclaw can, because it has the profile data.
    private func buildSpecialDateReminders(now: Date) -> String {
        let cal = Calendar.current
        let dateFmt = DateFormatter(); dateFmt.dateFormat = "M月d日"
        dateFmt.locale = Locale(identifier: "zh_CN")
        let weekdayFmt = DateFormatter()
        weekdayFmt.locale = Locale(identifier: "zh_CN")
        weekdayFmt.dateFormat = "EEEE"

        var reminders: [String] = []

        /// Computes how many days until the next occurrence of a birthday (month+day)
        /// relative to `now`. Returns 0 if today is the birthday, 1–7 for upcoming,
        /// or nil if >7 days away.
        func daysUntilBirthday(_ birthday: Date) -> Int? {
            let bdComponents = cal.dateComponents([.month, .day], from: birthday)
            guard let bdMonth = bdComponents.month, let bdDay = bdComponents.day else { return nil }

            let todayComponents = cal.dateComponents([.year, .month, .day], from: now)
            guard let thisYear = todayComponents.year else { return nil }

            // Build this year's birthday date
            var targetComponents = DateComponents()
            targetComponents.year = thisYear
            targetComponents.month = bdMonth
            targetComponents.day = bdDay
            guard let thisYearBD = cal.date(from: targetComponents) else { return nil }

            let todayStart = cal.startOfDay(for: now)
            let bdStart = cal.startOfDay(for: thisYearBD)
            let diff = cal.dateComponents([.day], from: todayStart, to: bdStart).day ?? 999

            if diff >= 0 && diff <= 7 {
                return diff
            }

            // Birthday may have passed this year — check next year
            if diff < 0 {
                targetComponents.year = thisYear + 1
                if let nextYearBD = cal.date(from: targetComponents) {
                    let nextDiff = cal.dateComponents([.day], from: todayStart, to: cal.startOfDay(for: nextYearBD)).day ?? 999
                    if nextDiff >= 0 && nextDiff <= 7 {
                        return nextDiff
                    }
                }
            }
            return nil
        }

        // Check user's own birthday
        if let userBD = profile.birthday, let daysAway = daysUntilBirthday(userBD) {
            let age = cal.dateComponents([.year], from: userBD, to: now).year ?? 0
            // For "today", the age is already incremented; for upcoming, it will be next age
            let upcomingAge = daysAway == 0 ? age : age + 1
            let ageNote = upcomingAge > 0 ? "（\(upcomingAge)岁）" : ""

            if daysAway == 0 {
                reminders.append("🎂 今天是你的生日！\(ageNote)生日快乐！GPT 可以主动送上祝福。")
            } else if daysAway == 1 {
                reminders.append("🎂 明天是你的生日\(ageNote)")
            } else if daysAway == 2 {
                reminders.append("🎂 后天是你的生日\(ageNote)")
            } else {
                let bdDate = cal.date(byAdding: .day, value: daysAway, to: cal.startOfDay(for: now))!
                reminders.append("🎂 \(daysAway)天后（\(dateFmt.string(from: bdDate))，\(weekdayFmt.string(from: bdDate))）是你的生日\(ageNote)")
            }
        }

        // Check family members' birthdays
        for member in profile.familyMembers {
            guard let bd = member.birthday, let daysAway = daysUntilBirthday(bd) else { continue }

            let relation = member.relation.isEmpty ? member.name : member.relation
            let name = member.name

            if daysAway == 0 {
                reminders.append("🎂 今天是\(relation)\(name)的生日！可以提醒用户送祝福或准备礼物。")
            } else if daysAway == 1 {
                reminders.append("🎂 明天是\(relation)\(name)的生日，可以提醒用户提前准备。")
            } else if daysAway == 2 {
                reminders.append("🎂 后天是\(relation)\(name)的生日。")
            } else {
                let bdDate = cal.date(byAdding: .day, value: daysAway, to: cal.startOfDay(for: now))!
                reminders.append("🎂 \(daysAway)天后（\(dateFmt.string(from: bdDate))，\(weekdayFmt.string(from: bdDate))）是\(relation)\(name)的生日。")
            }
        }

        guard !reminders.isEmpty else { return "" }
        return "[特别日期提醒]\n以下日期在未来7天内，在问候、总结、或用户问「有什么特别的」时可主动提及：\n" + reminders.joined(separator: "\n")
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
            } else {
                // CRITICAL: Without basal data, GPT might tell the user their total daily
                // expenditure is only 200-500 kcal (active only), when real TDEE is typically
                // 1500-2500+ kcal. This note prevents that significant misrepresentation.
                line += "（⚠️ 基础代谢数据不可用，此值仅为运动/活动消耗。真实总消耗 = 活动 + 基础代谢，通常远高于此值。回答用户「消耗了多少卡路里」时务必说明这只是活动消耗，不含基础代谢。）"
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
            if h.sleepAwakenings > 0 {
                line += "，夜醒\(h.sleepAwakenings)次"
                if h.sleepAwakeMinutes >= 1 {
                    line += "（共\(Int(h.sleepAwakeMinutes))分钟）"
                }
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
            // Include start–end time range so GPT can answer "几点运动的？" or
            // "早上跑步了吗？" directly from [今日健康数据] without cross-referencing
            // the separate [运动记录] section. The workout section has times but
            // GPT often cites this section for today-specific questions.
            let wTimeFmt = DateFormatter(); wTimeFmt.dateFormat = "HH:mm"
            let wLines = h.workouts.prefix(5).map { w in
                let name = "\(w.typeEmoji) \(w.typeName)"
                let timeRange = "\(wTimeFmt.string(from: w.startDate))–\(wTimeFmt.string(from: w.endDate))"
                let dur = Int(w.duration / 60)
                var s = "\(name) \(timeRange) \(dur)分钟"
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
                lines.append("活动消耗：\(Int(y.activeCalories))kcal（仅运动/活动消耗，不含基础代谢）")
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
        // Only show "总消耗kcal" column when basal (resting) calorie data exists.
        // Without basal data, the "总消耗" column would show the same values as "活动kcal",
        // misleading GPT into treating active-only calories (200-500kcal) as total daily
        // expenditure (real TDEE is typically 1500-2500+kcal). Hiding the column prevents
        // this confusion entirely — GPT only sees "活动kcal" and knows it's partial.
        let hasBasalCalData = trendDays.contains { $0.basalCalories > 0 }
        let headerWeight = hasWeightData ? " | 体重(kg)" : ""
        let headerStand = hasStandData ? " | 站立(分)" : ""
        let headerDistance = hasDistanceData ? " | 距离(km)" : ""
        let headerRHR = hasRestingHRData ? " | 静息HR" : ""
        let headerHRV = hasHRVData ? " | HRV(ms)" : ""
        let headerTotalCal = hasBasalCalData ? " | 总消耗kcal" : ""
        let dayCount = trendDays.count
        var lines = ["[近\(dayCount)天健康趋势]", "日期  | 步数  | 运动(分) | 活动kcal\(headerTotalCal) | 睡眠(h)（对应哪晚） | 心率avg(min~max)bpm\(headerRHR)\(headerHRV)\(headerDistance)\(headerStand)\(headerWeight)"]
        // Show oldest→newest so GPT can naturally read the trend direction
        let chronological = trendDays

        // Pre-compute this week's Monday boundary for inserting a visual separator
        // between last week's and this week's data. Without this, GPT scanning a
        // 14-row table frequently conflates which rows belong to "this week" vs
        // "last week" — e.g. including last Sunday's data in a "这周" aggregate,
        // or excluding this Monday from "本周" because it's far from "today" in the table.
        // The separator makes the week boundary instantly unambiguous.
        let todayWeekday = cal.component(.weekday, from: Date()) // 1=Sun..7=Sat
        let daysSinceMonday = (todayWeekday + 5) % 7 // Mon=0..Sun=6
        let thisMondayStart = cal.date(byAdding: .day, value: -daysSinceMonday, to: cal.startOfDay(for: Date()))!
        var insertedWeekSeparator = false

        for s in chronological {
            // Insert week boundary separator when transitioning from last week to this week.
            // Placed BEFORE the first this-week row (this Monday's data) so the visual
            // break reads naturally: "上周 data... --- 本周 --- this week data..."
            if !insertedWeekSeparator && cal.startOfDay(for: s.date) >= thisMondayStart {
                insertedWeekSeparator = true
                lines.append("--- ↑ 上周 | 本周 ↓ ---")
            }

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
            let totalCalCol = hasBasalCalData ? {
                let val = s.activeCalories + s.basalCalories
                return val > 0 ? "  | \(Int(val))" : "  | -"
            }() : ""
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
            lines.append("\(dateLabel)  | \(steps)  | \(ex)  | \(activeCal)\(totalCalCol)  | \(sl)  | \(hr)\(rhrCol)\(hrvCol)\(distCol)\(standCol)\(weightCol)")
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
                avgParts.append("周活动消耗\(totalActive)kcal（仅运动/活动消耗，不含基础代谢）")
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

        // Exercise streak — consecutive days with exercise ending at today/yesterday.
        // Directly answers "我连续运动了几天？" / "运动连胜多少天？" which GPT
        // frequently gets wrong when manually scanning 14 trend rows.
        //
        // IMPORTANT: Skip today if it has no exercise data, because today's data is
        // still accumulating. At 9am the user hasn't exercised yet — exerciseMinutes=0
        // does NOT mean "rest day", it means "the day hasn't happened yet". Without
        // this skip, a user who exercised 7 days straight would see streak=0 every
        // morning, only recovering to streak=8 after their evening workout.
        // This matches healthInsightAlerts() which also skips today for gap detection.
        let allChronological = summaries.sorted { $0.date < $1.date }
        var currentStreak = 0
        var streakIncludesToday = false
        for s in allChronological.reversed() { // newest first
            let hasExercise = s.exerciseMinutes > 0 || !s.workouts.isEmpty
            if cal.isDateInToday(s.date) && !hasExercise {
                // Today has no exercise data yet — skip rather than break the streak.
                // If the user exercises later, the streak will include today on next query.
                continue
            }
            if hasExercise {
                currentStreak += 1
                if cal.isDateInToday(s.date) { streakIncludesToday = true }
            } else {
                break
            }
        }
        if currentStreak >= 2 {
            let streakNote: String
            if streakIncludesToday {
                streakNote = "（含今天，仍在进行中 🔥）"
            } else if cal.isDateInToday(allChronological.last?.date ?? Date()) {
                streakNote = "（今天还未运动，继续保持可延续连胜 💪）"
            } else {
                streakNote = ""
            }
            avgParts.append("当前运动连续\(currentStreak)天\(streakNote)")
        }

        // Best activity day — pre-computed so GPT doesn't misidentify it from 14 rows
        if let bestDay = completedDays.max(by: { $0.exerciseMinutes < $1.exerciseMinutes }),
           bestDay.exerciseMinutes > 0 {
            let bestDayFmt = DateFormatter(); bestDayFmt.dateFormat = "M/d"
            let bestLabel: String
            if cal.isDateInYesterday(bestDay.date) {
                bestLabel = "昨天"
            } else {
                bestLabel = bestDayFmt.string(from: bestDay.date)
            }
            avgParts.append("最活跃日\(bestLabel)（\(Int(bestDay.exerciseMinutes))分钟）")
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

        // GOAL PROGRESS — pre-computed comparison of current week's data against
        // health benchmarks so GPT can directly answer "运动够了吗？" / "步数达标了吗？"
        // / "这周睡够了没？" with precise gap numbers. Without this, GPT has to
        // cross-reference [健康参考标准] with [本周] stats and mentally subtract —
        // frequently miscalculating (e.g. comparing daily avg to weekly total, or
        // using the wrong benchmark for the user's age group).
        let goalProgress = buildGoalProgress(summaries: Array(summaries), cal: cal)
        if !goalProgress.isEmpty {
            lines.append(goalProgress)
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

        // Today's summary — used to supplement "本周" stats so GPT can answer
        // "这周运动了几次？" including today's ongoing data. Without this, GPT
        // sees "本周3天中2天运动" but misses that today also had a workout,
        // leading to undercounts. On Monday, thisWeekDays is empty and the "本周"
        // section was previously skipped entirely, leaving GPT with no week-level
        // reference at all for "这周" queries.
        let todaySummary = summaries.first { cal.isDateInToday($0.date) }
        let hourOfDay = cal.component(.hour, from: now)

        // This week stats (completed days only — today excluded from aggregates)
        // but supplemented with today's snapshot for completeness.
        if !thisWeekDays.isEmpty {
            let label = "本周（周一至昨天，\(thisWeekDays.count)天）"
            var line = "\(label)：\(weekSubTotal(thisWeekDays))"
            // Append today's key metrics so GPT includes them in week-level answers
            if let today = todaySummary, today.hasData {
                line += "\n  + 今天（截至\(hourOfDay)点，仍在积累）：\(todaySnapshot(today))"
            }
            // MERGED WORKOUT SUMMARY — When today has workouts, provide a combined
            // "本周合计（含今天）" per-type breakdown so GPT can directly answer
            // "这周跑步了几次？" without manual addition. The SYSTEM prompt instructs
            // GPT to "use pre-computed stats, never manually count", but weekSubTotal
            // excludes today. Without this merged line, GPT either: (1) quotes the
            // pre-computed count (wrong — misses today), or (2) tries to add today's
            // workouts manually (contradicts the instruction and GPT often miscounts).
            // This line eliminates the contradiction by providing the definitive total.
            if let today = todaySummary, !today.workouts.isEmpty {
                let mergedLine = mergedWorkoutSummary(completedDays: thisWeekDays, today: today, hourOfDay: hourOfDay)
                if !mergedLine.isEmpty {
                    line += "\n  → \(mergedLine)"
                }
            }
            parts.append(line)
        } else if let today = todaySummary, today.hasData {
            // Monday (or first day of week): no completed days yet, but today has data.
            // Show a "本周" section with just today's snapshot so GPT has a week-level
            // reference. Without this, "这周运动了几次" on Monday gets no "本周" section.
            parts.append("本周（仅今天，截至\(hourOfDay)点，数据仍在积累中）：\(todaySnapshot(today))")
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

        // Week-over-week comparison — pre-computed deltas so GPT doesn't have to
        // mentally compare two separate stat blocks. Users frequently ask "这周和
        // 上周比怎么样？" and GPT often miscalculates when doing arithmetic across
        // two text paragraphs (e.g. mixing up totals vs averages, or comparing
        // 4-day totals with 7-day totals). Pre-computing with daily averages for
        // fair comparison eliminates this entire class of errors.
        //
        // Require ≥1 completed day this week. Previously required ≥2, but this
        // meant on Monday and Tuesday the user asking "这周和上周比怎么样" got NO
        // pre-computed comparison — forcing GPT to manually compute deltas from
        // two separate stat blocks, which it frequently gets wrong (mixing up
        // total vs average, confusing which number belongs to which week, etc.).
        // Even a 1-day comparison is valuable when explicitly requested, because
        // the header clearly states "本周1天日均 vs 上周7天日均" so GPT and the
        // user know it's preliminary. Monday's 1-day comparison is especially
        // useful: the user just finished a week and wants to see how the new
        // week started vs the old one.
        if thisWeekDays.count >= 1 && !lastWeekDays.isEmpty {
            let comparison = weekOverWeekComparison(
                thisWeek: thisWeekDays,
                lastWeek: lastWeekDays
            )
            if !comparison.isEmpty {
                parts.append(comparison)
            }
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

        // Per-workout-type breakdown — lets GPT directly answer "这周跑步了几次？"
        // or "上周游泳了多长时间？" without scanning the separate [运动记录] section.
        // GPT frequently miscounts when manually searching through 15 individual workout
        // entries; pre-aggregating by type eliminates this error class entirely.
        let allWorkouts = days.flatMap(\.workouts)
        if !allWorkouts.isEmpty {
            // Group by typeName (e.g. "跑步", "游泳") and aggregate count + duration + calories
            var typeStats: [String: (emoji: String, count: Int, totalMins: Int, totalCal: Int, totalDistM: Double)] = [:]
            var typeOrder: [String] = []
            for w in allWorkouts {
                let name = w.typeName
                if typeStats[name] == nil {
                    typeOrder.append(name)
                    typeStats[name] = (emoji: w.typeEmoji, count: 0, totalMins: 0, totalCal: 0, totalDistM: 0)
                }
                typeStats[name]!.count += 1
                typeStats[name]!.totalMins += Int(w.duration / 60)
                typeStats[name]!.totalCal += Int(w.totalCalories)
                typeStats[name]!.totalDistM += w.totalDistance
            }
            // Format each type: "🏃跑步3次共45分钟12.5km 850kcal"
            let typeParts = typeOrder.prefix(6).compactMap { name -> String? in
                guard let s = typeStats[name] else { return nil }
                var part = "\(s.emoji)\(name)\(s.count)次\(s.totalMins)分钟"
                if s.totalDistM > 100 {
                    part += "\(String(format: "%.1f", s.totalDistM / 1000))km"
                }
                if s.totalCal > 0 { part += " \(s.totalCal)kcal" }
                return part
            }
            items.append("运动详情：\(typeParts.joined(separator: "、"))")
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

            // Average wake time — completes the sleep schedule picture.
            // Users commonly ask "这周几点起？" or "上周起得早吗？" and without
            // pre-computed wake time in per-week stats, GPT has to scan individual
            // sleep analysis rows and manually average them — often getting it wrong.
            // This parallels the onset time above for a complete bedtime→wake pair.
            let wakes = sleepDays.compactMap { $0.wakeTime }
            if wakes.count >= 2 {
                let wakeMinutes = wakes.map { wake -> Double in
                    let comps = cal.dateComponents([.hour, .minute], from: wake)
                    return Double((comps.hour ?? 0) * 60 + (comps.minute ?? 0))
                }
                let wakeMean = wakeMinutes.reduce(0, +) / Double(wakeMinutes.count)
                let wakeHH = Int(wakeMean) / 60
                let wakeMM = Int(wakeMean) % 60
                sleepDesc += "，均起床\(String(format: "%02d:%02d", wakeHH, wakeMM))"
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

    /// Generates a compact snapshot of today's key health metrics for inclusion
    /// in per-week stats. Unlike weekSubTotal (which aggregates multiple days),
    /// this shows a single day's raw values so GPT can add them to the week's
    /// picture without double-counting or confusion.
    private func todaySnapshot(_ s: HealthSummary) -> String {
        var items: [String] = []
        if s.steps > 0 { items.append("\(Int(s.steps))步") }
        if s.exerciseMinutes > 0 { items.append("运动\(Int(s.exerciseMinutes))分钟") }
        if !s.workouts.isEmpty {
            let names = s.workouts.prefix(3).map { "\($0.typeEmoji)\($0.typeName)" }
            items.append("\(s.workouts.count)次健身（\(names.joined(separator: "、"))）")
        }
        if s.activeCalories > 0 {
            let total = Int(s.activeCalories + s.basalCalories)
            if s.basalCalories > 0 {
                items.append("消耗\(total)kcal")
            } else {
                items.append("活动\(Int(s.activeCalories))kcal")
            }
        }
        if s.distanceKm > 0.01 { items.append("\(String(format: "%.1f", s.distanceKm))km") }
        if s.sleepHours > 0 { items.append("睡眠\(String(format: "%.1f", s.sleepHours))h") }
        if s.standMinutes > 0 { items.append("站立\(Int(s.standMinutes))分钟") }
        return items.isEmpty ? "暂无数据" : items.joined(separator: "，")
    }

    /// Merges completed days' workout stats with today's workouts to produce a single
    /// definitive "本周合计（含今天）" per-type breakdown. This prevents the contradiction
    /// where GPT is told to "use pre-computed stats, never manually count" but the
    /// pre-computed workout-type counts exclude today's completed workouts.
    ///
    /// Example output:
    ///   "本周合计（含今天截至15点）：运动5天，🏃跑步3次80分钟 8.5km、🚴骑行1次30分钟"
    private func mergedWorkoutSummary(completedDays: [HealthSummary],
                                       today: HealthSummary,
                                       hourOfDay: Int) -> String {
        let allWorkouts = completedDays.flatMap(\.workouts) + today.workouts
        guard !allWorkouts.isEmpty else { return "" }

        // Count total exercise days (completed days with exercise + today if exercised)
        let completedExDays = completedDays.filter { $0.exerciseMinutes > 0 }.count
        let todayExercised = today.exerciseMinutes > 0 || !today.workouts.isEmpty
        let totalExDays = completedExDays + (todayExercised ? 1 : 0)
        let totalDays = completedDays.count + 1 // +1 for today

        // Group by typeName and aggregate
        var typeStats: [String: (emoji: String, count: Int, totalMins: Int, totalDistM: Double)] = [:]
        var typeOrder: [String] = []
        for w in allWorkouts {
            let name = w.typeName
            if typeStats[name] == nil {
                typeOrder.append(name)
                typeStats[name] = (emoji: w.typeEmoji, count: 0, totalMins: 0, totalDistM: 0)
            }
            typeStats[name]!.count += 1
            typeStats[name]!.totalMins += Int(w.duration / 60)
            typeStats[name]!.totalDistM += w.totalDistance
        }

        let typeParts = typeOrder.prefix(6).compactMap { name -> String? in
            guard let s = typeStats[name] else { return nil }
            var part = "\(s.emoji)\(name)\(s.count)次\(s.totalMins)分钟"
            if s.totalDistM > 100 {
                part += " \(String(format: "%.1f", s.totalDistM / 1000))km"
            }
            return part
        }

        return "本周合计（含今天截至\(hourOfDay)点）：\(totalExDays)/\(totalDays)天运动，\(typeParts.joined(separator: "、"))"
    }

    /// Pre-computes week-over-week deltas using daily averages for fair comparison.
    /// GPT frequently miscalculates when comparing two separate per-week stat blocks:
    ///   - Compares 4-day totals with 7-day totals (unfair)
    ///   - Mixes up which number belongs to which week
    ///   - Gets percentage changes wrong
    /// By providing explicit "↑步数日均多1200步(+18%)" style deltas, GPT can directly
    /// quote the comparison without any arithmetic.
    private func weekOverWeekComparison(thisWeek: [HealthSummary],
                                         lastWeek: [HealthSummary]) -> String {
        var deltas: [String] = []

        // Helper: format a delta with direction arrow and percentage
        func formatDelta(_ label: String, thisVal: Double, lastVal: Double, unit: String, higherIsBetter: Bool = true) {
            guard thisVal > 0 || lastVal > 0 else { return }
            let diff = thisVal - lastVal
            // Skip negligible changes (< 3% of max value)
            let maxVal = max(thisVal, lastVal)
            guard maxVal > 0 && abs(diff) / maxVal >= 0.03 else {
                deltas.append("\(label)：持平")
                return
            }
            let arrow: String
            let qualifier: String
            if diff > 0 {
                arrow = "↑"
                // For metrics where higher is bad (e.g. resting HR), flag increases
                qualifier = higherIsBetter ? "" : "⚠️"
            } else {
                arrow = "↓"
                // For metrics where lower is better (e.g. resting HR), mark decreases positively;
                // for metrics where higher is better (e.g. steps), flag significant decreases
                qualifier = higherIsBetter ? "" : "👍"
            }
            // Show absolute delta + percentage for clear communication
            let absDiff: String
            if unit == "h" || unit == "km" {
                absDiff = String(format: "%.1f", abs(diff))
            } else {
                absDiff = "\(Int(abs(diff)))"
            }
            // Safe percentage: when lastVal is 0 (e.g. no exercise last week but
            // exercised this week), division by zero produces infinity and Int(inf)
            // causes a Swift runtime crash. Show "新增" instead of a percentage.
            let pctStr: String
            if lastVal == 0 {
                pctStr = "新增"
            } else if thisVal == 0 {
                pctStr = "-100%"
            } else {
                let pct = Int((diff / lastVal) * 100)
                pctStr = "\(pct >= 0 ? "+" : "")\(pct)%"
            }
            deltas.append("\(label)：\(arrow)\(absDiff)\(unit)（\(pctStr)）\(qualifier)")
        }

        let thisCount = Double(thisWeek.count)
        let lastCount = Double(lastWeek.count)

        // Steps — daily average
        let thisStepsAvg = thisWeek.map(\.steps).reduce(0, +) / thisCount
        let lastStepsAvg = lastWeek.map(\.steps).reduce(0, +) / lastCount
        formatDelta("日均步数", thisVal: thisStepsAvg, lastVal: lastStepsAvg, unit: "步")

        // Exercise — active days and daily average minutes
        let thisExDays = thisWeek.filter { $0.exerciseMinutes > 0 }
        let lastExDays = lastWeek.filter { $0.exerciseMinutes > 0 }
        let thisExTotal = thisExDays.map(\.exerciseMinutes).reduce(0, +)
        let lastExTotal = lastExDays.map(\.exerciseMinutes).reduce(0, +)
        if thisExTotal > 0 || lastExTotal > 0 {
            let thisExAvg = thisExTotal / thisCount
            let lastExAvg = lastExTotal / lastCount
            formatDelta("日均运动", thisVal: thisExAvg, lastVal: lastExAvg, unit: "分钟")
            // Active day ratio — "4/6天 vs 3/7天" is more informative than just averages
            let thisRatio = Double(thisExDays.count) / thisCount
            let lastRatio = Double(lastExDays.count) / lastCount
            if abs(thisRatio - lastRatio) > 0.1 {
                let thisRatioStr = "\(thisExDays.count)/\(thisWeek.count)天"
                let lastRatioStr = "\(lastExDays.count)/\(lastWeek.count)天"
                let dir = thisRatio > lastRatio ? "↑更频繁" : "↓减少"
                deltas.append("运动频率：本周\(thisRatioStr) vs 上周\(lastRatioStr) \(dir)")
            }
        }

        // Sleep — average hours and deep sleep ratio
        let thisSleepDays = thisWeek.filter { $0.sleepHours > 0 }
        let lastSleepDays = lastWeek.filter { $0.sleepHours > 0 }
        if !thisSleepDays.isEmpty && !lastSleepDays.isEmpty {
            let thisSleepAvg = thisSleepDays.map(\.sleepHours).reduce(0, +) / Double(thisSleepDays.count)
            let lastSleepAvg = lastSleepDays.map(\.sleepHours).reduce(0, +) / Double(lastSleepDays.count)
            formatDelta("均睡眠时长", thisVal: thisSleepAvg, lastVal: lastSleepAvg, unit: "h")

            // Deep sleep comparison — critical quality metric
            let thisDeepDays = thisSleepDays.filter { $0.hasSleepPhases }
            let lastDeepDays = lastSleepDays.filter { $0.hasSleepPhases }
            if !thisDeepDays.isEmpty && !lastDeepDays.isEmpty {
                let thisDeepAvg = thisDeepDays.map(\.sleepDeepHours).reduce(0, +) / Double(thisDeepDays.count)
                let lastDeepAvg = lastDeepDays.map(\.sleepDeepHours).reduce(0, +) / Double(lastDeepDays.count)
                formatDelta("均深睡", thisVal: thisDeepAvg, lastVal: lastDeepAvg, unit: "h")
            }

            // Sleep efficiency comparison — reveals whether sleep quality improved even
            // if duration stayed the same. Two weeks with 7h sleep can differ greatly:
            // 92% efficiency vs 78% tells a completely different quality story.
            // GPT gets this wrong when manually comparing two per-week stat blocks because
            // it has to find the efficiency% in each block and subtract — often miscalculating.
            let thisEffDays = thisSleepDays.filter { $0.inBedHours > 0 && $0.inBedHours >= $0.sleepHours }
            let lastEffDays = lastSleepDays.filter { $0.inBedHours > 0 && $0.inBedHours >= $0.sleepHours }
            if thisEffDays.count >= 2 && lastEffDays.count >= 2 {
                let thisEff = thisEffDays.map { ($0.sleepHours / $0.inBedHours) * 100 }.reduce(0, +) / Double(thisEffDays.count)
                let lastEff = lastEffDays.map { ($0.sleepHours / $0.inBedHours) * 100 }.reduce(0, +) / Double(lastEffDays.count)
                formatDelta("睡眠效率", thisVal: thisEff, lastVal: lastEff, unit: "%")
            }

            // Awakenings comparison — key sleep continuity metric.
            // "这周睡得安稳吗？" → compare average nightly awakenings.
            let thisAwakeDays = thisSleepDays.filter { $0.sleepAwakenings > 0 }
            let lastAwakeDays = lastSleepDays.filter { $0.sleepAwakenings > 0 }
            if thisAwakeDays.count >= 2 && lastAwakeDays.count >= 2 {
                let thisAwakeAvg = Double(thisAwakeDays.map(\.sleepAwakenings).reduce(0, +)) / Double(thisAwakeDays.count)
                let lastAwakeAvg = Double(lastAwakeDays.map(\.sleepAwakenings).reduce(0, +)) / Double(lastAwakeDays.count)
                // For awakenings, lower is better (fewer = more continuous sleep)
                formatDelta("均夜醒次数", thisVal: thisAwakeAvg, lastVal: lastAwakeAvg, unit: "次", higherIsBetter: false)
            }

            // Bedtime (onset) comparison — users commonly ask "这周比上周睡得晚吗？"
            // "我最近是不是越睡越晚？". Bedtime shift is one of the most actionable
            // lifestyle insights. GPT has to cross-reference onset times from two separate
            // per-week stat blocks and do cross-midnight time arithmetic — a frequent
            // source of errors (e.g. comparing 23:30 vs 00:15 as "23h difference").
            let cal = Calendar.current
            let thisOnsets = thisSleepDays.compactMap { $0.sleepOnset }
            let lastOnsets = lastSleepDays.compactMap { $0.sleepOnset }
            if thisOnsets.count >= 2 && lastOnsets.count >= 2 {
                // Convert onset times to minutes-since-18:00 to handle cross-midnight correctly
                let toNormMins: (Date) -> Double = { time in
                    let comps = cal.dateComponents([.hour, .minute], from: time)
                    var mins = Double((comps.hour ?? 0) * 60 + (comps.minute ?? 0))
                    if mins < 18 * 60 { mins += 24 * 60 } // e.g. 01:00 → 25*60
                    return mins
                }
                let normToTimeStr: (Double) -> String = { mins in
                    var totalMins = Int(mins.rounded())
                    if totalMins >= 24 * 60 { totalMins -= 24 * 60 }
                    return String(format: "%02d:%02d", totalMins / 60, totalMins % 60)
                }
                let thisOnsetAvg = thisOnsets.map(toNormMins).reduce(0, +) / Double(thisOnsets.count)
                let lastOnsetAvg = lastOnsets.map(toNormMins).reduce(0, +) / Double(lastOnsets.count)
                let onsetDiffMins = Int((thisOnsetAvg - lastOnsetAvg).rounded())
                // Only report if ≥10 min difference — smaller shifts are normal variation
                if abs(onsetDiffMins) >= 10 {
                    let thisTimeStr = normToTimeStr(thisOnsetAvg)
                    let lastTimeStr = normToTimeStr(lastOnsetAvg)
                    if onsetDiffMins > 0 {
                        deltas.append("入睡时间：本周均\(thisTimeStr) vs 上周均\(lastTimeStr)，晚了约\(onsetDiffMins)分钟")
                    } else {
                        deltas.append("入睡时间：本周均\(thisTimeStr) vs 上周均\(lastTimeStr)，早了约\(abs(onsetDiffMins))分钟👍")
                    }
                }
            }

            // Wake time comparison — completes the sleep schedule picture.
            // Bedtime shift is already tracked above; wake time shift answers the equally
            // common question "这周比上周起得早吗？" or "最近是不是越起越晚？"
            // Without this, GPT sees bedtime deltas but has to manually compute wake time
            // changes from individual sleep analysis rows — frequently getting it wrong.
            let thisWakes = thisSleepDays.compactMap { $0.wakeTime }
            let lastWakes = lastSleepDays.compactMap { $0.wakeTime }
            if thisWakes.count >= 2 && lastWakes.count >= 2 {
                // Wake times are morning times — normalize as minutes from midnight
                let toWakeMins: (Date) -> Double = { time in
                    let comps = cal.dateComponents([.hour, .minute], from: time)
                    return Double((comps.hour ?? 0) * 60 + (comps.minute ?? 0))
                }
                let wakeToTimeStr: (Double) -> String = { mins in
                    let totalMins = Int(mins.rounded())
                    return String(format: "%02d:%02d", totalMins / 60, totalMins % 60)
                }
                let thisWakeAvg = thisWakes.map(toWakeMins).reduce(0, +) / Double(thisWakes.count)
                let lastWakeAvg = lastWakes.map(toWakeMins).reduce(0, +) / Double(lastWakes.count)
                let wakeDiffMins = Int((thisWakeAvg - lastWakeAvg).rounded())
                // Only report if ≥10 min difference — smaller shifts are normal variation
                if abs(wakeDiffMins) >= 10 {
                    let thisWakeStr = wakeToTimeStr(thisWakeAvg)
                    let lastWakeStr = wakeToTimeStr(lastWakeAvg)
                    if wakeDiffMins > 0 {
                        deltas.append("起床时间：本周均\(thisWakeStr) vs 上周均\(lastWakeStr)，晚了约\(wakeDiffMins)分钟")
                    } else {
                        deltas.append("起床时间：本周均\(thisWakeStr) vs 上周均\(lastWakeStr)，早了约\(abs(wakeDiffMins))分钟👍")
                    }
                }
            }
        }

        // Calories — daily average total expenditure
        let thisCalDays = thisWeek.filter { $0.activeCalories > 0 || $0.basalCalories > 0 }
        let lastCalDays = lastWeek.filter { $0.activeCalories > 0 || $0.basalCalories > 0 }
        if !thisCalDays.isEmpty && !lastCalDays.isEmpty {
            let thisHasBasal = thisCalDays.contains { $0.basalCalories > 0 }
            let lastHasBasal = lastCalDays.contains { $0.basalCalories > 0 }
            if thisHasBasal && lastHasBasal {
                // Compare total expenditure (active + basal) — this is what users mean by "消耗"
                let thisTotalAvg = thisCalDays.map { $0.activeCalories + $0.basalCalories }.reduce(0, +) / thisCount
                let lastTotalAvg = lastCalDays.map { $0.activeCalories + $0.basalCalories }.reduce(0, +) / lastCount
                formatDelta("日均总消耗", thisVal: thisTotalAvg, lastVal: lastTotalAvg, unit: "kcal")
            } else {
                // Only active calories available — compare those, but label clearly
                let thisActiveAvg = thisCalDays.map(\.activeCalories).reduce(0, +) / thisCount
                let lastActiveAvg = lastCalDays.map(\.activeCalories).reduce(0, +) / lastCount
                formatDelta("日均活动消耗", thisVal: thisActiveAvg, lastVal: lastActiveAvg, unit: "kcal")
            }
        }

        // Resting heart rate — lower is generally better (inverted comparison)
        let thisRHRDays = thisWeek.filter { $0.restingHeartRate > 0 }
        let lastRHRDays = lastWeek.filter { $0.restingHeartRate > 0 }
        if !thisRHRDays.isEmpty && !lastRHRDays.isEmpty {
            let thisRHR = thisRHRDays.map(\.restingHeartRate).reduce(0, +) / Double(thisRHRDays.count)
            let lastRHR = lastRHRDays.map(\.restingHeartRate).reduce(0, +) / Double(lastRHRDays.count)
            // For resting HR, lower is better — so "higher is NOT better"
            formatDelta("均静息心率", thisVal: thisRHR, lastVal: lastRHR, unit: "bpm", higherIsBetter: false)
        }

        // HRV (Heart Rate Variability) — key stress/recovery indicator.
        // Users commonly ask "这周压力是不是比上周大？" or "HRV有变化吗？"
        // HRV trending down across weeks suggests accumulated fatigue or stress;
        // trending up suggests better recovery. Without this pre-computed delta,
        // GPT has to manually extract HRV averages from two separate per-week
        // stat blocks and do the subtraction — frequently miscalculating or
        // confusing HRV with resting HR. Higher HRV = better recovery.
        let thisHRVDays = thisWeek.filter { $0.hrv > 0 }
        let lastHRVDays = lastWeek.filter { $0.hrv > 0 }
        if !thisHRVDays.isEmpty && !lastHRVDays.isEmpty {
            let thisHRV = thisHRVDays.map(\.hrv).reduce(0, +) / Double(thisHRVDays.count)
            let lastHRV = lastHRVDays.map(\.hrv).reduce(0, +) / Double(lastHRVDays.count)
            formatDelta("均HRV", thisVal: thisHRV, lastVal: lastHRV, unit: "ms")
        }

        // Distance — daily average km
        let thisDistDays = thisWeek.filter { $0.distanceKm > 0.01 }
        let lastDistDays = lastWeek.filter { $0.distanceKm > 0.01 }
        if !thisDistDays.isEmpty && !lastDistDays.isEmpty {
            let thisDistAvg = thisDistDays.map(\.distanceKm).reduce(0, +) / thisCount
            let lastDistAvg = lastDistDays.map(\.distanceKm).reduce(0, +) / lastCount
            formatDelta("日均距离", thisVal: thisDistAvg, lastVal: lastDistAvg, unit: "km")
        }

        guard !deltas.isEmpty else { return "" }

        // Note: comparison is always based on daily averages, which is the only fair
        // way to compare weeks of different lengths (this week may have 3 completed days
        // vs last week's full 7 days). This is stated explicitly so GPT quotes it properly.
        return "周环比（本周\(thisWeek.count)天日均 vs 上周\(lastWeek.count)天日均）：\(deltas.joined(separator: "，"))"
    }

    /// Pre-computes goal progress for the current week against health benchmarks.
    /// Users commonly ask "运动够了吗？" "步数达标吗？" "这周睡够了没？" — GPT has
    /// both the benchmarks and the weekly stats, but has to mentally cross-reference
    /// them and often miscalculates (confusing daily vs weekly targets, using the
    /// wrong age-bracket benchmark, comparing incomplete week totals to full-week
    /// targets without prorating). Pre-computing these comparisons eliminates the
    /// entire error class and lets GPT give confident, data-backed answers.
    private func buildGoalProgress(summaries: [HealthSummary], cal: Calendar) -> String {
        let now = Date()
        let todayWeekday = cal.component(.weekday, from: now)
        let daysSinceMonday = (todayWeekday + 5) % 7 // Mon=0..Sun=6
        let thisMonday = cal.date(byAdding: .day, value: -daysSinceMonday, to: cal.startOfDay(for: now))!

        // This week's completed days (Mon..yesterday, excluding today's partial data)
        let thisWeekCompleted = summaries.filter { s in
            let dayStart = cal.startOfDay(for: s.date)
            return dayStart >= thisMonday && !cal.isDateInToday(s.date)
        }
        let todaySummary = summaries.first { cal.isDateInToday($0.date) }

        // Need at least 1 completed day for meaningful goal assessment
        guard !thisWeekCompleted.isEmpty else { return "" }

        let completedCount = thisWeekCompleted.count
        let hourOfDay = cal.component(.hour, from: now)

        // Compute user's age from profile birthday for age-adjusted targets
        let userAge: Int? = {
            guard let bd = profile.birthday else { return nil }
            let age = Calendar.current.dateComponents([.year], from: bd, to: Date()).year ?? 0
            return age > 0 ? age : nil
        }()

        var items: [String] = []

        // --- Steps goal ---
        let stepsTarget: Int
        if let age = userAge {
            if age < 18 { stepsTarget = 10000 }
            else if age < 60 { stepsTarget = 7000 }
            else { stepsTarget = 6000 }
        } else {
            stepsTarget = 7000
        }

        let completedStepsAvg = thisWeekCompleted.map(\.steps).reduce(0, +) / Double(completedCount)
        if completedStepsAvg > 0 {
            let stepsGap = Double(stepsTarget) - completedStepsAvg
            let pct = Int((completedStepsAvg / Double(stepsTarget)) * 100)
            if stepsGap <= 0 {
                items.append("步数：日均\(Int(completedStepsAvg))步 ✅ 达标（目标\(stepsTarget)步，完成\(pct)%）")
            } else {
                items.append("步数：日均\(Int(completedStepsAvg))步，距目标\(stepsTarget)步还差\(Int(stepsGap))步（完成\(pct)%）")
            }
        }

        // --- Exercise goal (WHO: 150min/week moderate intensity) ---
        let weeklyExTarget = 150 // minutes per week
        let exerciseDays = thisWeekCompleted.filter { $0.exerciseMinutes > 0 }
        let completedExTotal = Int(exerciseDays.map(\.exerciseMinutes).reduce(0, +))
        // Include today's exercise if available (today's exercise data is typically
        // finalized by the time a user asks "运动够了吗？" in the evening)
        let todayEx = Int(todaySummary?.exerciseMinutes ?? 0)
        let totalExWithToday = completedExTotal + todayEx

        if completedExTotal > 0 || todayEx > 0 {
            // Prorate target based on how much of the week has passed
            let totalDaysThisWeek = daysSinceMonday + 1 // Mon=1..Sun=7
            let proRatedTarget = weeklyExTarget * totalDaysThisWeek / 7
            let exGap = proRatedTarget - totalExWithToday
            let weekPct = Int((Double(totalExWithToday) / Double(weeklyExTarget)) * 100)

            if totalExWithToday >= weeklyExTarget {
                items.append("运动：本周已\(totalExWithToday)分钟 ✅ 达标（WHO建议\(weeklyExTarget)分钟/周，完成\(weekPct)%）")
            } else if exGap <= 0 {
                // Hit prorated target but not full week target
                items.append("运动：本周已\(totalExWithToday)分钟，进度正常（周目标\(weeklyExTarget)分钟，已完成\(weekPct)%，按当前节奏本周可达标）")
            } else {
                let remainDays = 7 - totalDaysThisWeek
                let remainNeeded = weeklyExTarget - totalExWithToday
                if remainDays > 0 {
                    let dailyNeeded = Int(ceil(Double(remainNeeded) / Double(remainDays)))
                    items.append("运动：本周已\(totalExWithToday)分钟（\(exerciseDays.count + (todayEx > 0 ? 1 : 0))天运动），周目标\(weeklyExTarget)分钟还差\(remainNeeded)分钟（剩\(remainDays)天，每天需\(dailyNeeded)分钟）")
                } else {
                    items.append("运动：本周共\(totalExWithToday)分钟，目标\(weeklyExTarget)分钟，完成\(weekPct)%")
                }
            }
        } else {
            // No exercise this week at all
            let remainDays = 7 - (daysSinceMonday + 1)
            if remainDays > 0 {
                let dailyNeeded = Int(ceil(Double(weeklyExTarget) / Double(remainDays)))
                items.append("运动：本周暂无运动记录，WHO建议每周\(weeklyExTarget)分钟，剩\(remainDays)天需每天\(dailyNeeded)分钟")
            } else {
                items.append("运动：本周无运动记录（WHO建议每周\(weeklyExTarget)分钟）")
            }
        }

        // --- Sleep goal ---
        let sleepTargetLow: Double
        let sleepTargetHigh: Double
        if let age = userAge {
            if age < 18 { sleepTargetLow = 8.0; sleepTargetHigh = 10.0 }
            else if age < 65 { sleepTargetLow = 7.0; sleepTargetHigh = 9.0 }
            else { sleepTargetLow = 7.0; sleepTargetHigh = 8.0 }
        } else {
            sleepTargetLow = 7.0; sleepTargetHigh = 9.0
        }

        let sleepDays = thisWeekCompleted.filter { $0.sleepHours > 0 }
        if !sleepDays.isEmpty {
            let avgSleep = sleepDays.map(\.sleepHours).reduce(0, +) / Double(sleepDays.count)
            let shortNights = sleepDays.filter { $0.sleepHours < sleepTargetLow }.count

            if avgSleep >= sleepTargetLow && avgSleep <= sleepTargetHigh {
                items.append("睡眠：均\(String(format: "%.1f", avgSleep))h ✅ 在\(String(format: "%.0f", sleepTargetLow))-\(String(format: "%.0f", sleepTargetHigh))h推荐范围内")
            } else if avgSleep < sleepTargetLow {
                let deficit = sleepTargetLow - avgSleep
                var desc = "睡眠：均\(String(format: "%.1f", avgSleep))h，低于推荐\(String(format: "%.0f", sleepTargetLow))h（日均不足\(String(format: "%.1f", deficit))h"
                if shortNights > 0 {
                    desc += "，\(shortNights)/\(sleepDays.count)晚不足\(String(format: "%.0f", sleepTargetLow))h"
                }
                desc += "）"
                items.append(desc)
            } else {
                // Sleeping more than recommended — not necessarily bad but worth noting
                items.append("睡眠：均\(String(format: "%.1f", avgSleep))h，超过推荐\(String(format: "%.0f", sleepTargetHigh))h上限（可能为补觉或日程允许）")
            }
        }

        guard !items.isEmpty else { return "" }

        let todayNote = todayEx > 0 ? "（含今天截至\(hourOfDay)点）" : "（不含今天进行中的数据）"
        return "[本周目标进度]\(todayNote)\n" + items.joined(separator: "\n") + "\n⚠️ 用户问「够了吗」「达标吗」「运动够不够」时直接引用以上数据回答，不要自己重新计算。"
    }

    /// `recentDetailDays` controls how many past days get full event detail (notes,
    /// attendees, etc.) vs compact summary. Default 3 is adequate for general queries;
    /// calendar-focused queries use 7 so GPT can answer "上周三那个会议讲了什么？"
    private func calendarSection(todayEvents: [CalendarEventItem], upcoming: [CalendarEventItem], past: [CalendarEventItem] = [], recentDetailDays: Int = 3) -> String {
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

        // Recurring event summary — helps GPT answer "有哪些固定会议" and
        // "这个会议是每周都有的吗". Group by title to deduplicate instances of
        // the same recurring event across different days.
        let recurringEvents = allEvents.filter { !$0.recurrenceDescription.isEmpty }
        if !recurringEvents.isEmpty {
            var recurringByTitle: [String: String] = [:]  // title → recurrenceDescription
            for e in recurringEvents {
                if recurringByTitle[e.title] == nil {
                    recurringByTitle[e.title] = e.recurrenceDescription
                }
            }
            let recurringList = recurringByTitle
                .sorted { $0.key < $1.key }
                .prefix(8)
                .map { "🔄 \($0.key)（\($0.value)）" }
            lines.append("固定日程：\(recurringList.joined(separator: "、"))")
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
            let recentCutoff = cal.date(byAdding: .day, value: -recentDetailDays, to: cal.startOfDay(for: now)) ?? now

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
                        if !e.recurrenceDescription.isEmpty { desc += " 🔄\(e.recurrenceDescription)" }
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
                    // Compact summary for older days — time range + title + location (if any).
                    // Include both start AND end time so GPT can compute event duration for
                    // queries like "上周最长的会议是哪个?" or "上周开了多久的会?". Previously
                    // only showed start time, making duration invisible for ~10 days of data.
                    // Location is included because users commonly ask "上周在哪开的会？" or
                    // "上周三那个会在什么地方？" — without it, GPT can't answer location-specific
                    // calendar queries for events older than 3 days.
                    let titles = dayEvents.prefix(4).map { e -> String in
                        let timePrefix = e.isAllDay ? "全天" : "\(timeFmt.string(from: e.startDate))–\(timeFmt.string(from: e.endDate))"
                        var entry = "\(timePrefix) \(e.title)"
                        if !e.calendar.isEmpty { entry += "[\(e.calendar)]" }
                        if !e.recurrenceDescription.isEmpty { entry += "🔄" }
                        if !e.location.isEmpty { entry += "(\(e.location))" }
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
            // CURRENT MOMENT STATUS — a single, prominent line that tells GPT exactly
            // what's happening RIGHT NOW. This eliminates the most common GPT error
            // for calendar queries: when the user asks "我现在在开会吗？" / "现在有空吗？"
            // / "我在做什么？", GPT had to scan per-event annotations and mentally compute
            // the answer — often getting it wrong (e.g. citing a finished meeting as ongoing,
            // or missing that two meetings overlap). This pre-computed status line gives GPT
            // a definitive, unambiguous answer at a glance.
            let ongoingNow = todayEvents.filter { !$0.isAllDay && $0.startDate <= now && $0.endDate > now }
            let nextEvent = todayEvents.first { !$0.isAllDay && $0.startDate > now }
            if !ongoingNow.isEmpty {
                // Currently in one or more events — show titles and remaining time
                let descriptions = ongoingNow.prefix(3).map { e -> String in
                    let remainMins = Int(e.endDate.timeIntervalSince(now) / 60)
                    let remainStr: String
                    if remainMins <= 1 {
                        remainStr = "即将结束"
                    } else if remainMins < 60 {
                        remainStr = "还剩\(remainMins)分钟"
                    } else {
                        let hrs = remainMins / 60
                        let mins = remainMins % 60
                        remainStr = mins > 0 ? "还剩\(hrs)小时\(mins)分钟" : "还剩\(hrs)小时"
                    }
                    var desc = "\(e.title)（\(remainStr)）"
                    if !e.location.isEmpty { desc += "@\(e.location)" }
                    return desc
                }
                var statusLine = "📍 当前状态：正在进行 \(descriptions.joined(separator: "；"))"
                // Also hint what's next after the current event(s) ends
                if let next = nextEvent {
                    let minsUntilNext = Int(next.startDate.timeIntervalSince(now) / 60)
                    if minsUntilNext <= 120 {
                        statusLine += " → 之后：\(next.title)（\(minsUntilNext)分钟后）"
                    }
                }
                lines.append(statusLine)
            } else if let next = nextEvent {
                // Currently free — show when the next event starts
                let minutesUntil = Int(next.startDate.timeIntervalSince(now) / 60)
                if minutesUntil <= 15 {
                    lines.append("📍 当前状态：空闲，但 \(next.title) 即将开始（\(minutesUntil)分钟后）")
                } else if minutesUntil <= 120 {
                    lines.append("📍 当前状态：空闲 → 下一个日程：\(next.title)（\(minutesUntil)分钟后，\(timeFmt.string(from: next.startDate))开始）")
                } else {
                    let nextTimeStr = timeFmt.string(from: next.startDate)
                    lines.append("📍 当前状态：空闲 → 下一个日程：\(next.title)（\(nextTimeStr)开始）")
                }
            } else {
                // All events are done for the day
                let nonAllDay = todayEvents.filter { !$0.isAllDay }
                if nonAllDay.isEmpty {
                    lines.append("📍 当前状态：今天只有全天事件，无具体时间段的日程")
                } else {
                    lines.append("📍 当前状态：今天的日程已全部结束")
                }
            }

            lines.append("今天：")
            for e in todayEvents.prefix(10) {
                // Determine temporal status for non-all-day events
                // Annotate temporal status for non-all-day events.
                // Ongoing events include remaining minutes so GPT can directly
                // answer "这个会还有多久结束？" without computing time differences.
                // Upcoming events within 60 minutes show countdown for urgency.
                let status: String
                if e.isAllDay {
                    status = ""
                } else if e.endDate <= now {
                    status = "（已结束）"
                } else if e.startDate <= now && e.endDate > now {
                    let remainMins = Int(e.endDate.timeIntervalSince(now) / 60)
                    if remainMins <= 1 {
                        status = "（进行中，即将结束）"
                    } else if remainMins < 60 {
                        status = "（进行中，还剩\(remainMins)分钟）"
                    } else {
                        let hrs = remainMins / 60
                        let mins = remainMins % 60
                        let timeStr = mins > 0 ? "\(hrs)小时\(mins)分钟" : "\(hrs)小时"
                        status = "（进行中，还剩\(timeStr)）"
                    }
                } else if e.startDate.timeIntervalSince(now) <= 60 * 60 {
                    let minsUntil = Int(e.startDate.timeIntervalSince(now) / 60)
                    status = minsUntil <= 1 ? "（即将开始）" : "（\(minsUntil)分钟后开始）"
                } else {
                    status = ""
                }

                var line = "  \(e.timeDisplay) \(e.title)\(status)"
                if !e.calendar.isEmpty { line += " [\(e.calendar)]" }
                if !e.recurrenceDescription.isEmpty { line += " 🔄\(e.recurrenceDescription)" }
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

            // Summary: how many done / ongoing / remaining, plus accurate remaining time.
            // Previously omitted ongoing events from the count, so "已完成2项，还剩2项"
            // hid a currently-running meeting. Also, "剩余约X分钟" included the FULL
            // duration of ongoing events instead of just the remaining portion.
            let nonAllDay = todayEvents.filter { !$0.isAllDay }
            let doneCount = nonAllDay.filter { $0.endDate <= now }.count
            let ongoingEvents = nonAllDay.filter { $0.startDate <= now && $0.endDate > now }
            let ongoingCount = ongoingEvents.count
            let upcomingEvents = nonAllDay.filter { $0.startDate > now }
            let remainCount = upcomingEvents.count
            if nonAllDay.count >= 2 {
                let todayTotalMins = nonAllDay.map { Int($0.duration / 60) }.reduce(0, +)
                // Remaining time = remaining portion of ongoing events + full duration of upcoming.
                // Old calculation used (total - done), which counted the FULL duration of
                // ongoing events — e.g. a 60-min meeting that started 45 min ago would
                // contribute 60 min to "remaining" instead of the actual 15 min left.
                let ongoingRemainingMins = ongoingEvents
                    .map { max(0, Int($0.endDate.timeIntervalSince(now) / 60)) }.reduce(0, +)
                let upcomingMins = upcomingEvents
                    .map { Int($0.duration / 60) }.reduce(0, +)
                let remainMins = ongoingRemainingMins + upcomingMins
                var summaryParts: [String] = ["已完成\(doneCount)项"]
                if ongoingCount > 0 {
                    // Surface ongoing events explicitly so GPT can say "你现在有一个会议正在进行"
                    // instead of requiring manual scan of individual event "(进行中)" annotations.
                    let ongoingTitles = ongoingEvents.prefix(2).map(\.title).joined(separator: "、")
                    summaryParts.append("\(ongoingCount)项进行中（\(ongoingTitles)）")
                }
                summaryParts.append("还剩\(remainCount)项")
                if todayTotalMins >= 60 {
                    let hrs = todayTotalMins / 60
                    let mins = todayTotalMins % 60
                    let timeStr = mins > 0 ? "\(hrs)小时\(mins)分钟" : "\(hrs)小时"
                    summaryParts.append("全天共\(timeStr)会议")
                    if remainMins > 0 && doneCount > 0 {
                        summaryParts.append("剩余约\(remainMins)分钟")
                    }
                }
                lines.append("  （\(summaryParts.joined(separator: "，"))）")
            }

            // Free time slots for today — GPT frequently gets this wrong when computing
            // manually. Users commonly ask "今天下午有空吗？", "什么时候能约人？",
            // "接下来有多少空闲时间？". Pre-computing slots eliminates arithmetic errors.
            let todayFreeSlots = computeFreeSlots(
                events: todayEvents,
                dayStart: max(now, cal.startOfDay(for: now)),
                dayEnd: cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!,
                now: now
            )
            if !todayFreeSlots.isEmpty {
                let slotDescs = todayFreeSlots.map { slot -> String in
                    let startStr = timeFmt.string(from: slot.start)
                    let endStr = timeFmt.string(from: slot.end)
                    let durMins = Int(slot.end.timeIntervalSince(slot.start) / 60)
                    let durStr: String
                    if durMins >= 60 {
                        let hrs = durMins / 60
                        let mins = durMins % 60
                        durStr = mins > 0 ? "\(hrs)h\(mins)m" : "\(hrs)h"
                    } else {
                        durStr = "\(durMins)分钟"
                    }
                    return "\(startStr)–\(endStr)（\(durStr)）"
                }
                let totalFreeMins = todayFreeSlots.map { Int($0.end.timeIntervalSince($0.start) / 60) }.reduce(0, +)
                let totalFreeStr: String
                if totalFreeMins >= 60 {
                    let hrs = totalFreeMins / 60
                    let mins = totalFreeMins % 60
                    totalFreeStr = mins > 0 ? "\(hrs)小时\(mins)分钟" : "\(hrs)小时"
                } else {
                    totalFreeStr = "\(totalFreeMins)分钟"
                }
                lines.append("  今日剩余空闲：\(slotDescs.joined(separator: "、"))，共\(totalFreeStr)")
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
                        if !e.recurrenceDescription.isEmpty { desc += " 🔄\(e.recurrenceDescription)" }
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

                    // Free time slots for near-future days (tomorrow/day-after) so GPT can
                    // accurately answer "明天下午有空吗？" or "后天什么时候能约？"
                    let futureDayStart = day
                    let futureDayEnd = cal.date(byAdding: .day, value: 1, to: day)!
                    // For future days, also include events from todayEvents/past if they
                    // span into that day (unlikely but possible for multi-day events).
                    // The dayEvents already come from the upcoming array for that day.
                    let futureFreeSlots = computeFreeSlots(
                        events: dayEvents,
                        dayStart: futureDayStart,
                        dayEnd: futureDayEnd,
                        now: nil  // full day analysis, not "from now"
                    )
                    if !futureFreeSlots.isEmpty && futureFreeSlots.count <= 8 {
                        let slotDescs = futureFreeSlots.map { slot -> String in
                            let startStr = timeFmt.string(from: slot.start)
                            let endStr = timeFmt.string(from: slot.end)
                            let durMins = Int(slot.end.timeIntervalSince(slot.start) / 60)
                            let durStr: String
                            if durMins >= 60 {
                                let hrs = durMins / 60
                                let mins = durMins % 60
                                durStr = mins > 0 ? "\(hrs)h\(mins)m" : "\(hrs)h"
                            } else {
                                durStr = "\(durMins)分钟"
                            }
                            return "\(startStr)–\(endStr)（\(durStr)）"
                        }
                        lines.append("    空闲时段：\(slotDescs.joined(separator: "、"))")
                    }
                } else {
                    // Compact summary for further-out days — include both start AND end time
                    // so GPT can compute duration for "下周三的会要开多久?" queries.
                    // Location included so GPT can answer "下周的会在哪？" for distant days.
                    let titles = dayEvents.prefix(4).map { e -> String in
                        let timePrefix = e.isAllDay ? "全天" : "\(timeFmt.string(from: e.startDate))–\(timeFmt.string(from: e.endDate))"
                        var entry = "\(timePrefix) \(e.title)"
                        if !e.calendar.isEmpty { entry += "[\(e.calendar)]" }
                        if !e.recurrenceDescription.isEmpty { entry += "🔄" }
                        if !e.location.isEmpty { entry += "(\(e.location))" }
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

        // Per-week calendar stats — pre-computed so GPT can directly answer
        // "这周忙吗？" "上周有几个会？" "这周和上周哪个忙？" without manually counting
        // events from the per-day listing. Mirrors the per-week health stats pattern.
        let weeklyCalStats = buildPerWeekCalendarStats(
            todayEvents: todayEvents,
            pastEvents: past,
            upcomingEvents: upcoming,
            cal: cal
        )
        if !weeklyCalStats.isEmpty {
            lines.append(weeklyCalStats)
        }

        return lines.joined(separator: "\n")
    }

    /// Builds per-week calendar stats ("本周" vs "上周") with event counts,
    /// meeting time, and comparison — so GPT can directly answer "这周忙不忙？"
    /// or "和上周比呢？" without manually scanning day-by-day event listings.
    private func buildPerWeekCalendarStats(
        todayEvents: [CalendarEventItem],
        pastEvents: [CalendarEventItem],
        upcomingEvents: [CalendarEventItem],
        cal: Calendar
    ) -> String {
        let now = Date()
        let todayWeekday = cal.component(.weekday, from: now) // 1=Sun..7=Sat
        let daysSinceMonday = (todayWeekday + 5) % 7 // Mon=0..Sun=6
        let thisMonday = cal.date(byAdding: .day, value: -daysSinceMonday, to: cal.startOfDay(for: now))!
        let lastMonday = cal.date(byAdding: .day, value: -7, to: thisMonday)!
        let thisSunday = cal.date(byAdding: .day, value: 7, to: thisMonday)! // start of next week

        // Combine all events for classification
        let allEvents = todayEvents + pastEvents + upcomingEvents
        // Deduplicate by title + startDate to avoid double-counting today's events
        // (todayEvents and upcoming/past may overlap)
        var seen = Set<String>()
        let uniqueEvents = allEvents.filter { e in
            let key = "\(e.title)|\(e.startDate.timeIntervalSince1970)"
            return seen.insert(key).inserted
        }

        // Split into this week and last week
        let thisWeekEvents = uniqueEvents.filter { e in
            let dayStart = cal.startOfDay(for: e.startDate)
            return dayStart >= thisMonday && dayStart < thisSunday
        }
        let lastWeekEvents = uniqueEvents.filter { e in
            let dayStart = cal.startOfDay(for: e.startDate)
            return dayStart >= lastMonday && dayStart < thisMonday
        }

        guard !thisWeekEvents.isEmpty || !lastWeekEvents.isEmpty else { return "" }

        var parts: [String] = []

        // Helper to summarize a week's events
        func weekSummary(_ events: [CalendarEventItem]) -> String {
            let total = events.count
            let nonAllDay = events.filter { !$0.isAllDay }
            let totalMeetingMins = nonAllDay.map { Int($0.duration / 60) }.reduce(0, +)
            let activeDays = Set(events.map { cal.startOfDay(for: $0.startDate) }).count

            var desc = "\(total)个日程，\(activeDays)天有安排"

            if totalMeetingMins >= 60 {
                let hrs = totalMeetingMins / 60
                let mins = totalMeetingMins % 60
                let timeStr = mins > 0 ? "\(hrs)小时\(mins)分钟" : "\(hrs)小时"
                desc += "，会议总时长\(timeStr)"
            } else if totalMeetingMins > 0 {
                desc += "，会议总时长\(totalMeetingMins)分钟"
            }

            // Per-calendar breakdown if multiple calendars
            var calBreakdown: [String: Int] = [:]
            for e in events where !e.calendar.isEmpty {
                calBreakdown[e.calendar, default: 0] += 1
            }
            if calBreakdown.count >= 2 {
                let breakdown = calBreakdown.sorted { $0.value > $1.value }
                    .prefix(3)
                    .map { "\($0.key)\($0.value)个" }
                desc += "（\(breakdown.joined(separator: "、"))）"
            }

            return desc
        }

        // This week stats
        if !thisWeekEvents.isEmpty {
            // Split into past (completed) and future (upcoming) for richer context
            let thisWeekPast = thisWeekEvents.filter { $0.endDate <= now }
            let thisWeekFuture = thisWeekEvents.filter { $0.startDate > now }
            let thisWeekOngoing = thisWeekEvents.filter { $0.startDate <= now && $0.endDate > now }

            var thisWeekDesc = "本周（周一至周日）：\(weekSummary(thisWeekEvents))"
            if !thisWeekPast.isEmpty && !thisWeekFuture.isEmpty {
                thisWeekDesc += "，已完成\(thisWeekPast.count)个，待办\(thisWeekFuture.count)个"
            }
            if !thisWeekOngoing.isEmpty {
                thisWeekDesc += "，进行中\(thisWeekOngoing.count)个"
            }
            parts.append(thisWeekDesc)
        }

        // Last week stats
        if !lastWeekEvents.isEmpty {
            parts.append("上周（完整7天）：\(weekSummary(lastWeekEvents))")
        }

        // Week-over-week comparison — pre-computed so GPT can directly say
        // "这周比上周忙" without counting events from two separate day listings
        if !thisWeekEvents.isEmpty && !lastWeekEvents.isEmpty {
            let thisCount = thisWeekEvents.count
            let lastCount = lastWeekEvents.count
            let diff = thisCount - lastCount

            let thisNonAllDay = thisWeekEvents.filter { !$0.isAllDay }
            let lastNonAllDay = lastWeekEvents.filter { !$0.isAllDay }
            let thisMeetingMins = thisNonAllDay.map { Int($0.duration / 60) }.reduce(0, +)
            let lastMeetingMins = lastNonAllDay.map { Int($0.duration / 60) }.reduce(0, +)

            var comparisons: [String] = []

            // Event count comparison
            if diff > 0 {
                comparisons.append("日程数↑多\(diff)个")
            } else if diff < 0 {
                comparisons.append("日程数↓少\(abs(diff))个")
            } else {
                comparisons.append("日程数持平")
            }

            // Meeting time comparison
            if thisMeetingMins > 0 || lastMeetingMins > 0 {
                let meetingDiff = thisMeetingMins - lastMeetingMins
                if abs(meetingDiff) >= 15 {  // Only report if ≥15min difference
                    let absDiff = abs(meetingDiff)
                    let diffStr: String
                    if absDiff >= 60 {
                        let hrs = absDiff / 60
                        let mins = absDiff % 60
                        diffStr = mins > 0 ? "\(hrs)小时\(mins)分钟" : "\(hrs)小时"
                    } else {
                        diffStr = "\(absDiff)分钟"
                    }
                    if meetingDiff > 0 {
                        comparisons.append("会议时长↑多\(diffStr)")
                    } else {
                        comparisons.append("会议时长↓少\(diffStr)")
                    }
                } else {
                    comparisons.append("会议时长持平")
                }
            }

            // Note: this week may be incomplete (today is not Sunday yet)
            let daysElapsed = daysSinceMonday + 1
            let incompleteness = daysElapsed < 7
                ? "（注：本周仅过\(daysElapsed)/7天，包含\(7 - daysElapsed)天未来日程）" : ""
            parts.append("周对比：\(comparisons.joined(separator: "，"))\(incompleteness)")
        }

        guard !parts.isEmpty else { return "" }
        return "日程周统计：\n\(parts.joined(separator: "\n"))"
    }

    // MARK: - Free Time Slot Computation

    /// Represents a free time slot between calendar events.
    private struct FreeSlot {
        let start: Date
        let end: Date
    }

    /// Computes free time slots within a given time range by finding gaps between events.
    /// - Parameters:
    ///   - events: Calendar events for the day (may include all-day events, which are excluded)
    ///   - dayStart: Start of the analysis window (for today, this is `now`; for future days, start of day)
    ///   - dayEnd: End of the analysis window (typically end of the calendar day)
    ///   - now: If non-nil, slots before `now` are excluded (for today's remaining free time).
    ///          For future days, pass nil to analyze the full 8:00–22:00 range.
    /// - Returns: Array of free slots ≥ 15 minutes, within the 8:00–22:00 "active hours" window.
    ///
    /// Only considers 8:00–22:00 as "useful" free time — nobody schedules meetings at 3am.
    /// Minimum slot duration is 15 minutes — shorter gaps aren't practically useful.
    private func computeFreeSlots(events: [CalendarEventItem],
                                   dayStart: Date,
                                   dayEnd: Date,
                                   now: Date?) -> [FreeSlot] {
        let cal = Calendar.current
        let dayBase = cal.startOfDay(for: dayStart)

        // Define active hours: 8:00 – 22:00
        guard let activeStart = cal.date(bySettingHour: 8, minute: 0, second: 0, of: dayBase),
              let activeEnd = cal.date(bySettingHour: 22, minute: 0, second: 0, of: dayBase) else {
            return []
        }

        // Window start: max of (activeStart, now, dayStart)
        var windowStart = activeStart
        if let now = now, now > windowStart { windowStart = now }
        if dayStart > windowStart { windowStart = dayStart }

        // Window end: min of (activeEnd, dayEnd)
        let windowEnd = min(activeEnd, dayEnd)

        guard windowStart < windowEnd else { return [] }

        // Collect non-all-day event intervals, clipped to window
        let busyIntervals: [(start: Date, end: Date)] = events
            .filter { !$0.isAllDay }
            .compactMap { e -> (start: Date, end: Date)? in
                let s = max(e.startDate, windowStart)
                let e2 = min(e.endDate, windowEnd)
                guard s < e2 else { return nil }
                return (start: s, end: e2)
            }
            .sorted { $0.start < $1.start }

        // Merge overlapping intervals
        var merged: [(start: Date, end: Date)] = []
        for interval in busyIntervals {
            if let last = merged.last, interval.start <= last.end {
                // Overlapping or adjacent — extend
                merged[merged.count - 1] = (start: last.start, end: max(last.end, interval.end))
            } else {
                merged.append(interval)
            }
        }

        // Find gaps between merged busy intervals
        var slots: [FreeSlot] = []
        var cursor = windowStart

        for busy in merged {
            if busy.start > cursor {
                let gap = busy.start.timeIntervalSince(cursor)
                if gap >= 15 * 60 {  // ≥ 15 minutes
                    slots.append(FreeSlot(start: cursor, end: busy.start))
                }
            }
            cursor = max(cursor, busy.end)
        }

        // Trailing free time after last event
        if cursor < windowEnd {
            let gap = windowEnd.timeIntervalSince(cursor)
            if gap >= 15 * 60 {
                slots.append(FreeSlot(start: cursor, end: windowEnd))
            }
        }

        return slots
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
        // Accumulate dwell time per place across all days for the summary section.
        // Enables GPT to answer "这周在公司待了多少小时？" with aggregate duration.
        var totalDwellByPlace: [String: TimeInterval] = [:]
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
            // Deduplicate by place name, keep chronological order and visit times.
            // Also track first arrival timestamps so we can estimate dwell time at
            // each place — critical for answering "在公司待了多久？" or "哪里待得最久？"
            var seenPlaces: [String: (count: Int, firstArrival: Date?, times: [String], address: String?)] = [:]
            var placeOrder: [String] = []
            var chronologicalArrivals: [(name: String, time: Date)] = []
            for r in dayRecords.sorted(by: { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }) {
                let name = locationDisplayName(for: r)
                if seenPlaces[name] == nil {
                    placeOrder.append(name)
                    seenPlaces[name] = (count: 0, firstArrival: r.timestamp, times: [], address: r.address)
                    if let ts = r.timestamp {
                        chronologicalArrivals.append((name: name, time: ts))
                    }
                }
                let timeStr = r.timestamp.map { timeFmt.string(from: $0) } ?? ""
                seenPlaces[name]!.count += 1
                if !timeStr.isEmpty && seenPlaces[name]!.times.count < 3 {
                    seenPlaces[name]!.times.append(timeStr)
                }
            }

            // Estimate dwell time at each place: duration from this place's first
            // arrival to the next (different) place's first arrival. The last place
            // has no departure time — we leave it unknown rather than guessing.
            var dwellTimes: [String: TimeInterval] = [:]
            for (idx, arrival) in chronologicalArrivals.enumerated() {
                if idx + 1 < chronologicalArrivals.count {
                    let duration = chronologicalArrivals[idx + 1].time.timeIntervalSince(arrival.time)
                    if duration > 0 && duration < 24 * 3600 {
                        dwellTimes[arrival.name] = duration
                    }
                }
            }
            // Accumulate into cross-day totals for the summary section
            for (name, dwell) in dwellTimes {
                totalDwellByPlace[name, default: 0] += dwell
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
                // Show arrival time + estimated dwell duration when available.
                // "星巴克（10:00,约1.5h）" is far more useful than just "星巴克（10:00）"
                // for queries like "在星巴克待了多久？" or "哪里待得最久？"
                if let dwell = dwellTimes[name] {
                    let arrival = info.times.first ?? ""
                    let dwellMins = Int(dwell / 60)
                    if dwellMins >= 60 {
                        let hrs = dwellMins / 60
                        let mins = dwellMins % 60
                        let dwellStr = mins > 0 ? "\(hrs)h\(mins)m" : "\(hrs)h"
                        part += arrival.isEmpty ? "（约\(dwellStr)）" : "（\(arrival),约\(dwellStr)）"
                    } else if dwellMins >= 5 {
                        part += arrival.isEmpty ? "（约\(dwellMins)分钟）" : "（\(arrival),约\(dwellMins)分钟）"
                    } else if !info.times.isEmpty {
                        part += "（\(info.times.joined(separator: "、"))）"
                    }
                } else if !info.times.isEmpty {
                    part += "（\(info.times.joined(separator: "、"))）"
                }
                if info.count > 1 { part += "×\(info.count)" }
                return part
            }
            dayLine += placeParts.joined(separator: " → ")
            lines.append(dayLine)
        }

        // Summary: frequently visited places across the period, with total dwell time.
        // Dwell time answers "这周在公司待了多少小时？" — a common and valuable query
        // that was previously impossible to answer without duration data.
        var totalCounts: [String: Int] = [:]
        for r in records {
            let name = locationDisplayName(for: r)
            totalCounts[name, default: 0] += 1
        }
        let topPlaces = totalCounts.sorted { $0.value > $1.value }.prefix(5)
        if topPlaces.count > 1 {
            let summaryParts = topPlaces.map { place -> String in
                var desc = "\(place.key)(\(place.value)次"
                if let dwell = totalDwellByPlace[place.key], dwell >= 300 {
                    let hrs = Int(dwell / 3600)
                    let mins = Int(dwell.truncatingRemainder(dividingBy: 3600) / 60)
                    if hrs > 0 {
                        desc += ",共约\(hrs)h\(mins > 0 ? "\(mins)m" : "")"
                    } else {
                        desc += ",共约\(mins)分钟"
                    }
                }
                desc += ")"
                return desc
            }
            lines.append("常去地点：\(summaryParts.joined(separator: "、"))")
        }

        return lines.joined(separator: "\n")
    }

    private func photoSection(_ photos: [PhotoMetadataItem],
                              locationRecords: [CDLocationRecord] = []) -> String {
        let cal = Calendar.current
        let total = photos.count
        let videoItems = photos.filter { $0.isVideo }
        let videos = videoItems.count
        let geoTagged = photos.filter { $0.hasLocation }.count
        let favorites = photos.filter { $0.isFavorite }.count
        let screenshots = photos.filter { $0.isScreenshot }.count
        var lines = ["[照片统计（近14天）]"]
        // Include total video duration so GPT can answer "最近拍了多长时间的视频？"
        let totalVideoDuration = videoItems.map(\.duration).reduce(0, +)
        if videos > 0 && totalVideoDuration >= 60 {
            let totalMins = Int(totalVideoDuration / 60)
            let totalSecs = Int(totalVideoDuration.truncatingRemainder(dividingBy: 60))
            let durStr = totalSecs > 0 ? "\(totalMins)分\(totalSecs)秒" : "\(totalMins)分钟"
            lines.append("共 \(total - videos) 张照片，\(videos) 个视频（总时长\(durStr)）")
        } else if videos > 0 && totalVideoDuration > 0 {
            lines.append("共 \(total - videos) 张照片，\(videos) 个视频（总时长\(Int(totalVideoDuration))秒）")
        } else {
            lines.append("共 \(total - videos) 张照片，\(videos) 个视频")
        }
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
                // Use consistent relative day labels matching calendar/location/health sections.
                // Previously missing "前天" caused GPT to fail matching temporal hints
                // (e.g. [时间聚焦] says "前天=3月19日" but photo section showed "3月19日(周三)").
                let dayLabel: String
                if cal.isDateInToday(day) {
                    dayLabel = "今天"
                } else if cal.isDateInYesterday(day) {
                    dayLabel = "昨天"
                } else if let twoDaysAgo = cal.date(byAdding: .day, value: -2, to: cal.startOfDay(for: Date())),
                          cal.isDate(day, inSameDayAs: twoDaysAgo) {
                    dayLabel = "前天"
                } else if let threeDaysAgo = cal.date(byAdding: .day, value: -3, to: cal.startOfDay(for: Date())),
                          cal.isDate(day, inSameDayAs: threeDaysAgo) {
                    dayLabel = "大前天"
                } else {
                    dayLabel = "\(dateFmt.string(from: day))(\(weekdayFmt.string(from: day)))"
                }

                let dayPhotosOnly = dayPhotos.filter { !$0.isVideo }
                let dayVideos = dayPhotos.filter { $0.isVideo }
                var countParts: [String] = []
                if !dayPhotosOnly.isEmpty { countParts.append("\(dayPhotosOnly.count)张照片") }
                if !dayVideos.isEmpty {
                    // Surface video duration so GPT can answer "昨天录了多长时间的视频?"
                    // PhotoMetadataItem.duration is populated from PHAsset but was previously
                    // unused in the prompt — GPT saw "2个视频" but couldn't report total length.
                    let totalDuration = dayVideos.map(\.duration).reduce(0, +)
                    if totalDuration >= 60 {
                        let mins = Int(totalDuration / 60)
                        let secs = Int(totalDuration.truncatingRemainder(dividingBy: 60))
                        let durStr = secs > 0 ? "\(mins)分\(secs)秒" : "\(mins)分钟"
                        countParts.append("\(dayVideos.count)个视频（共\(durStr)）")
                    } else if totalDuration > 0 {
                        countParts.append("\(dayVideos.count)个视频（共\(Int(totalDuration))秒）")
                    } else {
                        countParts.append("\(dayVideos.count)个视频")
                    }
                }

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

        // MOOD ANALYSIS — pre-computed so GPT can directly answer "心情怎么样？"
        // "最近情绪好吗？" "我开心的时候多吗？" without manually counting emoji from
        // 15 individual entries. Manual counting across entries is exactly the pattern
        // that causes GPT miscounts (per SYSTEM prompt: "绝对不要自己手动数").
        let moodAnalysis = buildMoodAnalysis(events, cal: cal)
        if !moodAnalysis.isEmpty {
            lines.append(moodAnalysis)
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

    // MARK: - Mood Analysis

    /// Builds a pre-computed mood summary from life events so GPT can directly answer
    /// "心情怎么样？" / "最近情绪好吗？" / "我开心的时候多吗？" without manually scanning
    /// and counting mood emojis across 15 entries — a task GPT frequently miscounts.
    ///
    /// Includes:
    /// 1. Mood distribution (positive/neutral/negative counts)
    /// 2. Mood trend (recent vs older entries — getting happier or sadder?)
    /// 3. Mood × category correlation (are work events more stressful? social events happier?)
    private func buildMoodAnalysis(_ events: [CDLifeEvent], cal: Calendar) -> String {
        // Need at least 3 events for meaningful analysis
        guard events.count >= 3 else { return "" }

        // Classify moods into positive/neutral/negative groups
        var posCount = 0  // great, good
        var neuCount = 0  // neutral
        var negCount = 0  // tired, stressed, sad
        var moodCounts: [String: Int] = [:]  // label → count

        for e in events {
            let mood = MoodType(rawValue: e.mood ?? "") ?? .neutral
            moodCounts["\(mood.emoji)\(mood.label)", default: 0] += 1
            switch mood {
            case .great, .good: posCount += 1
            case .neutral: neuCount += 1
            case .tired, .stressed, .sad: negCount += 1
            }
        }

        let total = events.count
        var parts: [String] = []

        // Overall mood distribution
        let distParts = moodCounts.sorted { $0.value > $1.value }
            .map { "\($0.key)\($0.value)次" }
        parts.append("心情分布（\(total)条记录）：\(distParts.joined(separator: "、"))")

        // Positive/negative ratio — a single-line summary GPT can quote directly
        let posPct = Int(Double(posCount) / Double(total) * 100)
        let negPct = Int(Double(negCount) / Double(total) * 100)
        if posCount > negCount * 2 {
            parts.append("整体偏积极（\(posPct)%正面，\(negPct)%负面）")
        } else if negCount > posCount * 2 {
            parts.append("整体偏低落（\(negPct)%负面，\(posPct)%正面）")
        } else if posCount > 0 || negCount > 0 {
            parts.append("正面\(posPct)%，负面\(negPct)%，中性\(100 - posPct - negPct)%")
        }

        // Mood trend: compare recent half vs older half
        // Split by chronological order (events are already newest-first from fetchRecent)
        if events.count >= 6 {
            let midpoint = events.count / 2
            let recentHalf = Array(events.prefix(midpoint))  // newer entries
            let olderHalf = Array(events.suffix(from: midpoint))  // older entries

            // Score: great=2, good=1, neutral=0, tired=-1, stressed=-1, sad=-2
            let moodScore: (CDLifeEvent) -> Int = { e in
                let mood = MoodType(rawValue: e.mood ?? "") ?? .neutral
                switch mood {
                case .great: return 2
                case .good: return 1
                case .neutral: return 0
                case .tired: return -1
                case .stressed: return -1
                case .sad: return -2
                }
            }
            let recentAvg = Double(recentHalf.map(moodScore).reduce(0, +)) / Double(recentHalf.count)
            let olderAvg = Double(olderHalf.map(moodScore).reduce(0, +)) / Double(olderHalf.count)
            let diff = recentAvg - olderAvg

            if diff >= 0.5 {
                parts.append("趋势：近期心情变好 ↑（较早期记录改善）")
            } else if diff <= -0.5 {
                parts.append("趋势：近期心情下滑 ↓（较早期记录变差）")
            } else {
                parts.append("趋势：心情基本稳定 →")
            }
        }

        // Mood × category correlation — "工作的时候心情怎么样？"
        // Only show if there are at least 2 categories with 2+ entries each
        var catMoodScores: [String: (total: Int, count: Int)] = [:]
        for e in events {
            let cat = EventCategory(rawValue: e.category ?? "life") ?? .life
            let mood = MoodType(rawValue: e.mood ?? "") ?? .neutral
            let score: Int
            switch mood {
            case .great: score = 2
            case .good: score = 1
            case .neutral: score = 0
            case .tired: score = -1
            case .stressed: score = -1
            case .sad: score = -2
            }
            if catMoodScores[cat.label] == nil {
                catMoodScores[cat.label] = (total: 0, count: 0)
            }
            catMoodScores[cat.label]!.total += score
            catMoodScores[cat.label]!.count += 1
        }

        let qualifiedCats = catMoodScores.filter { $0.value.count >= 2 }
        if qualifiedCats.count >= 2 {
            let ranked = qualifiedCats
                .map { (cat: $0.key, avg: Double($0.value.total) / Double($0.value.count), count: $0.value.count) }
                .sorted { $0.avg > $1.avg }

            let catMoodParts = ranked.map { item -> String in
                let indicator: String
                if item.avg >= 1.0 { indicator = "😊" }
                else if item.avg >= 0 { indicator = "😐" }
                else { indicator = "😟" }
                return "\(item.cat)\(indicator)(\(item.count)条)"
            }
            parts.append("分类心情：\(catMoodParts.joined(separator: "、"))")
        }

        return parts.joined(separator: "\n")
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

        // Week boundary for workout list — workouts are sorted newest→oldest,
        // so the separator fires when we transition FROM this week TO last week.
        let wkTodayWeekday = cal.component(.weekday, from: Date())
        let wkDaysSinceMonday = (wkTodayWeekday + 5) % 7
        let wkThisMonday = cal.date(byAdding: .day, value: -wkDaysSinceMonday, to: cal.startOfDay(for: Date()))!
        var insertedWorkoutWeekSep = false

        // List each workout (cap at 15 to avoid token bloat)
        for item in allWorkouts.prefix(15) {
            let w = item.workout
            let name = "\(w.typeEmoji) \(w.typeName)"

            // Insert separator when crossing from this week into last week (newest→oldest order)
            if !insertedWorkoutWeekSep && cal.startOfDay(for: item.date) < wkThisMonday {
                insertedWorkoutWeekSep = true
                lines.append("--- ↑ 本周 | 上周 ↓ ---")
            }

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

        // Week boundary separator (same logic as trendSection) so GPT doesn't mix up
        // this week's vs last week's sleep data when answering "这周睡得怎么样".
        let todayWeekday = cal.component(.weekday, from: Date())
        let daysSinceMonday = (todayWeekday + 5) % 7
        let thisMondayStart = cal.date(byAdding: .day, value: -daysSinceMonday, to: cal.startOfDay(for: Date()))!
        var insertedSleepWeekSep = false

        for s in chronological {
            // Insert week separator before the first this-week sleep entry.
            // Sleep is attributed to wake-up day, so a row dated Monday = Sunday night's sleep.
            // The separator still belongs before Monday's row because the row IS in this week.
            if !insertedSleepWeekSep && cal.startOfDay(for: s.date) >= thisMondayStart {
                insertedSleepWeekSep = true
                lines.append("--- ↑ 上周 | 本周 ↓ ---")
            }

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

            // Awakenings — key sleep continuity metric
            if s.sleepAwakenings > 0 {
                var awakePart = "夜醒\(s.sleepAwakenings)次"
                if s.sleepAwakeMinutes >= 1 {
                    awakePart += "(\(Int(s.sleepAwakeMinutes))分钟)"
                }
                parts.append(awakePart)
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

        // Average awakenings — restless sleep detection
        let daysWithAwakenings = daysWithSleep.filter { $0.sleepAwakenings > 0 }
        if !daysWithAwakenings.isEmpty {
            let avgAwakenings = Double(daysWithAwakenings.map(\.sleepAwakenings).reduce(0, +)) / Double(daysWithAwakenings.count)
            let avgAwakeMins = daysWithAwakenings.map(\.sleepAwakeMinutes).reduce(0, +) / Double(daysWithAwakenings.count)
            if avgAwakenings >= 1.0 {
                var awakeDesc = "均夜醒\(String(format: "%.1f", avgAwakenings))次"
                if avgAwakeMins >= 1 {
                    awakeDesc += "(\(Int(avgAwakeMins))分钟)"
                }
                summaryParts.append(awakeDesc)
            }
        }

        // Best/worst sleep nights — pre-computed so GPT can directly answer
        // "哪天睡得最好？" or "最近睡得最差是哪晚？" without scanning 14 rows.
        // GPT frequently misidentifies extremes when comparing float values across
        // a dense table (e.g. 7.2 vs 7.1 vs 7.3 across 14 entries).
        if daysWithSleep.count >= 3 {
            let sleepDateFmt = DateFormatter(); sleepDateFmt.dateFormat = "M/d"
            let bestSleep = daysWithSleep.max { $0.sleepHours < $1.sleepHours }
            let worstSleep = daysWithSleep.min { $0.sleepHours < $1.sleepHours }
            if let best = bestSleep {
                let prevDay = cal.date(byAdding: .day, value: -1, to: best.date) ?? best.date
                let nightLabel = "\(sleepDateFmt.string(from: prevDay))晚"
                var bestDesc = "最佳\(nightLabel)\(String(format: "%.1f", best.sleepHours))h"
                if best.hasSleepPhases && best.sleepDeepHours > 0 {
                    bestDesc += "（深睡\(String(format: "%.1f", best.sleepDeepHours))h）"
                }
                summaryParts.append(bestDesc)
            }
            if let worst = worstSleep, worst.sleepHours != bestSleep?.sleepHours {
                let prevDay = cal.date(byAdding: .day, value: -1, to: worst.date) ?? worst.date
                let nightLabel = "\(sleepDateFmt.string(from: prevDay))晚"
                summaryParts.append("最差\(nightLabel)\(String(format: "%.1f", worst.sleepHours))h")
            }
        }

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

        // Weekday vs weekend sleep comparison — pre-computed so GPT can directly
        // answer "周末和工作日睡眠差多少？" "周末有没有补觉？" "我平时几点睡？"
        // without manually categorizing 14 rows into weekday/weekend buckets.
        // Users commonly have very different sleep patterns on work days vs rest days,
        // and this contrast is one of the most actionable health insights.
        // Classify sleep into weekday vs weekend based on wake-up day.
        // Sleep is attributed to the wake-up day, so:
        //   - Weekday sleep: wake-up Mon(2)..Fri(6) — i.e. Sun night through Thu night
        //   - Weekend sleep: wake-up Sat(7) or Sun(1) — i.e. Fri night and Sat night
        // This matches the intuitive meaning: "周末睡眠" = the nights you sleep in on Sat/Sun.
        let weekdaySleepCorrected = chronological.filter { s in
            let wakeWd = cal.component(.weekday, from: s.date)
            return wakeWd >= 2 && wakeWd <= 6
        }
        let weekendSleep = chronological.filter { s in
            let wakeWd = cal.component(.weekday, from: s.date)
            return wakeWd == 1 || wakeWd == 7 // Sun or Sat
        }

        // Only show comparison when we have enough data for both groups
        if weekdaySleepCorrected.count >= 2 && weekendSleep.count >= 1 {
            let wdAvgHrs = weekdaySleepCorrected.map(\.sleepHours).reduce(0, +) / Double(weekdaySleepCorrected.count)
            let weAvgHrs = weekendSleep.map(\.sleepHours).reduce(0, +) / Double(weekendSleep.count)
            let diff = weAvgHrs - wdAvgHrs

            var wdweParts: [String] = []
            wdweParts.append("工作日（\(weekdaySleepCorrected.count)晚）均\(String(format: "%.1f", wdAvgHrs))h")
            wdweParts.append("周末（\(weekendSleep.count)晚）均\(String(format: "%.1f", weAvgHrs))h")

            if abs(diff) >= 0.3 {
                if diff > 0 {
                    wdweParts.append("周末多睡\(String(format: "%.1f", diff))h")
                } else {
                    wdweParts.append("工作日反而多睡\(String(format: "%.1f", abs(diff)))h")
                }
            } else {
                wdweParts.append("差异不大")
            }

            // Bedtime comparison: weekday vs weekend onset times
            let wdOnsets = weekdaySleepCorrected.compactMap { $0.sleepOnset }
            let weOnsets = weekendSleep.compactMap { $0.sleepOnset }
            if wdOnsets.count >= 2 && !weOnsets.isEmpty {
                let wdOnsetMean = wdOnsets.map(toNormalizedMinutes).reduce(0, +) / Double(wdOnsets.count)
                let weOnsetMean = weOnsets.map(toNormalizedMinutes).reduce(0, +) / Double(weOnsets.count)
                let onsetDiff = Int((weOnsetMean - wdOnsetMean).rounded())
                if abs(onsetDiff) >= 15 {
                    wdweParts.append("工作日均入睡\(normalizedToTimeStr(wdOnsetMean))，周末\(normalizedToTimeStr(weOnsetMean))")
                    if onsetDiff > 0 {
                        wdweParts.append("周末晚睡约\(onsetDiff)分钟")
                    } else {
                        wdweParts.append("周末早睡约\(abs(onsetDiff))分钟")
                    }
                }
            }

            // Deep sleep comparison — weekend rest sometimes improves deep sleep quality
            let wdDeep = weekdaySleepCorrected.filter { $0.hasSleepPhases }
            let weDeep = weekendSleep.filter { $0.hasSleepPhases }
            if !wdDeep.isEmpty && !weDeep.isEmpty {
                let wdDeepAvg = wdDeep.map(\.sleepDeepHours).reduce(0, +) / Double(wdDeep.count)
                let weDeepAvg = weDeep.map(\.sleepDeepHours).reduce(0, +) / Double(weDeep.count)
                if abs(weDeepAvg - wdDeepAvg) >= 0.2 {
                    wdweParts.append("深睡：工作日\(String(format: "%.1f", wdDeepAvg))h vs 周末\(String(format: "%.1f", weDeepAvg))h")
                }
            }

            lines.append("工作日vs周末：\(wdweParts.joined(separator: "，"))")
        }

        // Cumulative sleep debt — pre-computed so GPT can directly answer "需要补觉吗？"
        // "这周睡够了吗？" "欠了多少睡眠？" without mentally summing deficits across 14 rows.
        // Sleep debt = sum of (recommended - actual) for each night where actual < recommended.
        // Clinically, sleep debt accumulates: 5 nights of 6h when you need 7h = 5h debt,
        // which cannot be fully recovered in a single night. This metric makes advice concrete:
        // "你这周累计少睡了3.5小时" is far more actionable than "平均睡6.5小时，低于推荐".
        do {
            // Determine age-adjusted sleep target
            let sleepTargetH: Double = {
                guard let bd = profile.birthday else { return 7.0 }
                let age = cal.dateComponents([.year], from: bd, to: Date()).year ?? 0
                if age > 0 && age < 18 { return 8.0 }      // teens: 8-10h, use lower bound
                else if age >= 65 { return 7.0 }             // seniors: 7-8h
                else { return 7.0 }                          // adults: 7-9h, use lower bound
            }()

            // Split sleep days into this week and last week (same calendar-week alignment
            // as buildPerWeekStats for consistency).
            let todayWd = cal.component(.weekday, from: Date())
            let dmSinceMon = (todayWd + 5) % 7
            let thisMon = cal.date(byAdding: .day, value: -dmSinceMon, to: cal.startOfDay(for: Date()))!

            let thisWeekSleep = chronological.filter { s in
                let ds = cal.startOfDay(for: s.date)
                return ds >= thisMon
            }
            let lastWeekSleep = chronological.filter { s in
                let ds = cal.startOfDay(for: s.date)
                let lastMon = cal.date(byAdding: .day, value: -7, to: thisMon)!
                return ds >= lastMon && ds < thisMon
            }

            // Compute debt for a set of sleep nights
            let computeDebt: ([HealthSummary]) -> (debt: Double, nights: Int, belowTarget: Int) = { nights in
                var totalDebt: Double = 0
                var belowCount = 0
                for n in nights {
                    let deficit = sleepTargetH - n.sleepHours
                    if deficit > 0 {
                        totalDebt += deficit
                        belowCount += 1
                    }
                }
                return (totalDebt, nights.count, belowCount)
            }

            var debtParts: [String] = []

            if !thisWeekSleep.isEmpty {
                let tw = computeDebt(thisWeekSleep)
                if tw.debt >= 1.0 {
                    debtParts.append("本周累计少睡\(String(format: "%.1f", tw.debt))h（\(tw.nights)晚中\(tw.belowTarget)晚不足\(String(format: "%.0f", sleepTargetH))h）")
                } else if tw.debt > 0 {
                    debtParts.append("本周睡眠接近达标（仅欠\(String(format: "%.1f", tw.debt))h）")
                } else {
                    debtParts.append("本周睡眠充足 ✅（每晚均≥\(String(format: "%.0f", sleepTargetH))h）")
                }
            }

            if !lastWeekSleep.isEmpty {
                let lw = computeDebt(lastWeekSleep)
                if lw.debt >= 1.0 {
                    debtParts.append("上周累计少睡\(String(format: "%.1f", lw.debt))h（\(lw.nights)晚中\(lw.belowTarget)晚不足\(String(format: "%.0f", sleepTargetH))h）")
                } else if lw.debt > 0 {
                    debtParts.append("上周睡眠接近达标（仅欠\(String(format: "%.1f", lw.debt))h）")
                } else {
                    debtParts.append("上周睡眠充足 ✅")
                }
            }

            // Week-over-week debt comparison
            if !thisWeekSleep.isEmpty && !lastWeekSleep.isEmpty {
                let twDebt = computeDebt(thisWeekSleep).debt
                let lwDebt = computeDebt(lastWeekSleep).debt
                let debtChange = twDebt - lwDebt
                // Normalize per night for fair comparison (this week may be incomplete)
                let twAvgDebt = thisWeekSleep.isEmpty ? 0 : twDebt / Double(thisWeekSleep.count)
                let lwAvgDebt = lastWeekSleep.isEmpty ? 0 : lwDebt / Double(lastWeekSleep.count)
                let avgChange = twAvgDebt - lwAvgDebt
                if abs(avgChange) >= 0.3 {
                    if avgChange > 0 {
                        debtParts.append("本周日均欠睡比上周增加\(String(format: "%.1f", avgChange))h，睡眠状况恶化")
                    } else {
                        debtParts.append("本周日均欠睡比上周减少\(String(format: "%.1f", abs(avgChange)))h，睡眠有所改善")
                    }
                }
            }

            if !debtParts.isEmpty {
                lines.append("睡眠负债（基准：每晚\(String(format: "%.0f", sleepTargetH))h）：\(debtParts.joined(separator: "；"))")
                lines.append("⚠️ 用户问「需要补觉吗」「睡够了吗」「欠了多少觉」时直接引用以上睡眠负债数据回答。睡眠负债>5h提示严重不足，需多晚逐步补回；<2h属正常波动。")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Health Insight Alerts

    /// Pre-computes noteworthy health patterns and anomalies from 14-day data.
    /// GPT is unreliable at detecting patterns across dense tabular data — it frequently
    /// misses 4-night sleep decline trends, sudden resting HR spikes, or exercise gaps.
    /// These alerts give GPT explicit cues to surface in relevant conversations.
    ///
    /// Only flags patterns that are genuinely noteworthy to avoid alert fatigue:
    /// - Sleep deprivation: 3+ consecutive nights under 6 hours
    /// - Sleep trend: consistent decline or improvement over recent nights
    /// - Resting HR anomaly: sudden spike >10bpm above recent baseline
    /// - HRV trend: decline ≥15% signals stress/overtraining before resting HR rises
    /// - Exercise gap: broke a 3+ day exercise streak
    /// - Activity drop: step count fell >40% vs prior week average
    /// - Late bedtime drift: bedtime shifted >30 min later over the past week
    private func healthInsightAlerts(_ summaries: [HealthSummary]) -> String {
        let cal = Calendar.current
        // Work with chronological order (oldest → newest)
        let chrono = summaries.sorted { $0.date < $1.date }
        // Exclude today's partial data from pattern detection to avoid false alarms
        // (e.g. 0 steps at 8am flagged as "activity drop")
        let completed = chrono.filter { !cal.isDateInToday($0.date) }
        guard completed.count >= 3 else { return "" }

        let dateFmt = DateFormatter(); dateFmt.dateFormat = "M/d"
        var alerts: [String] = []

        // 1. Sleep deprivation streak — 3+ consecutive nights under 6h
        //    This is clinically significant: chronic short sleep (<6h) accumulates
        //    "sleep debt" that impairs cognition, mood, and immunity.
        let sleepDays = completed.filter { $0.sleepHours > 0 }
        if sleepDays.count >= 3 {
            var shortSleepStreak = 0
            var maxShortStreak = 0
            var streakEndDate: Date?
            for s in sleepDays {
                if s.sleepHours < 6.0 {
                    shortSleepStreak += 1
                    if shortSleepStreak > maxShortStreak {
                        maxShortStreak = shortSleepStreak
                        streakEndDate = s.date
                    }
                } else {
                    shortSleepStreak = 0
                }
            }
            // Check if the streak is still active (ends at the most recent sleep day)
            if maxShortStreak >= 3 {
                let isOngoing = streakEndDate == sleepDays.last?.date
                if isOngoing {
                    alerts.append("⚠️ 连续\(maxShortStreak)晚睡眠不足6小时（仍在持续），可能累积睡眠债务，建议关注")
                } else if let end = streakEndDate {
                    alerts.append("📋 近期曾连续\(maxShortStreak)晚睡眠不足6小时（截至\(dateFmt.string(from: end))），已恢复")
                }
            }
        }

        // 2. Sleep trend — consistent decline or improvement over recent 5 nights
        //    Detect if the last 5 sleep values show a clear directional trend.
        let recentSleep = Array(sleepDays.suffix(5))
        if recentSleep.count >= 5 {
            let values = recentSleep.map(\.sleepHours)
            // Count consecutive increases or decreases
            var declines = 0
            var increases = 0
            for i in 1..<values.count {
                if values[i] < values[i-1] - 0.1 { declines += 1 }
                if values[i] > values[i-1] + 0.1 { increases += 1 }
            }
            if declines >= 4 {
                let drop = values.first! - values.last!
                alerts.append("📉 近5晚睡眠持续减少（从\(String(format: "%.1f", values.first!))h降至\(String(format: "%.1f", values.last!))h，减少\(String(format: "%.1f", drop))h），建议留意作息")
            } else if increases >= 4 {
                let gain = values.last! - values.first!
                alerts.append("📈 近5晚睡眠持续改善（从\(String(format: "%.1f", values.first!))h升至\(String(format: "%.1f", values.last!))h，增加\(String(format: "%.1f", gain))h），状态不错👍")
            }
        }

        // 3. Resting heart rate anomaly — sudden spike above baseline
        //    A resting HR spike of >10bpm can indicate illness, stress, poor recovery,
        //    or dehydration. This is one of the most clinically actionable daily metrics.
        let rhrDays = completed.filter { $0.restingHeartRate > 0 }
        if rhrDays.count >= 5 {
            let baseline = rhrDays.dropLast(2) // all except last 2 days
            let recent = Array(rhrDays.suffix(2))
            if !baseline.isEmpty {
                let baselineAvg = baseline.map(\.restingHeartRate).reduce(0, +) / Double(baseline.count)
                for day in recent {
                    let spike = day.restingHeartRate - baselineAvg
                    if spike >= 10 {
                        let dayLabel = cal.isDateInYesterday(day.date) ? "昨天" : dateFmt.string(from: day.date)
                        alerts.append("⚠️ \(dayLabel)静息心率\(Int(day.restingHeartRate))bpm，比近期基线（\(Int(baselineAvg))bpm）高\(Int(spike))bpm，可能提示疲劳/压力/生病")
                        break // Only flag the most recent spike
                    }
                }
            }
        }

        // 3b. HRV trend — declining HRV is the earliest biomarker for accumulated
        //     stress, overtraining, or illness onset — often dropping 1-2 days BEFORE
        //     resting heart rate rises (alert #3 above). This makes it the most
        //     proactive health signal we can offer. Users asking "最近压力大吗？"
        //     "身体恢复得好吗？" "状态怎么样？" get a data-backed answer instead of
        //     generic advice. HRV is already collected per-day in the trend table but
        //     had no pattern detection — a major gap given its clinical significance.
        //
        //     Compare recent 3-day HRV average vs baseline (older days). Flag when:
        //     - Decline ≥15% AND ≥8ms absolute drop (avoids noise on high-HRV individuals)
        //     - Improvement ≥15% AND ≥8ms absolute gain (positive reinforcement)
        let hrvDays = completed.filter { $0.hrv > 0 }
        if hrvDays.count >= 5 {
            let recentHRV = Array(hrvDays.suffix(3))
            let baselineHRV = Array(hrvDays.dropLast(3)) // all days before recent 3
            if recentHRV.count >= 3 && !baselineHRV.isEmpty {
                let recentAvg = recentHRV.map(\.hrv).reduce(0, +) / Double(recentHRV.count)
                let baselineAvg = baselineHRV.map(\.hrv).reduce(0, +) / Double(baselineHRV.count)
                let absDiff = recentAvg - baselineAvg
                let pctChange = baselineAvg > 0 ? (absDiff / baselineAvg) * 100 : 0

                if absDiff <= -8 && pctChange <= -15 {
                    // Significant decline — stress/overtraining/illness warning
                    alerts.append("⚠️ HRV近3天均值\(Int(recentAvg))ms，比之前基线（\(Int(baselineAvg))ms）下降\(Int(abs(absDiff)))ms（\(Int(abs(pctChange)))%），可能提示压力累积、恢复不足或身体疲劳。HRV下降通常先于静息心率升高，建议关注休息和恢复")
                } else if absDiff >= 8 && pctChange >= 15 {
                    // Significant improvement — positive reinforcement
                    alerts.append("💚 HRV近3天均值\(Int(recentAvg))ms，比之前基线（\(Int(baselineAvg))ms）提升\(Int(absDiff))ms（+\(Int(pctChange))%），身体恢复状态良好👍")
                }
            }
        }

        // 4. Exercise gap after streak — user was exercising regularly then stopped
        //    Breaking a habit is a key moment where encouragement matters most.
        //
        //    Two-phase scan (newest→oldest):
        //    Phase 1: Count consecutive rest days at the end (the "gap").
        //    Phase 2: Count consecutive exercise days before the gap (the "streak").
        //    Stop as soon as we exit each phase — avoids off-by-one errors from the
        //    previous implementation which accidentally counted a pre-streak rest day
        //    as part of the gap, inflating gapDays by 1 and causing false positives.
        let allChrono = chrono // includes today
        var exerciseStreak = 0
        var gapDays = 0
        var streakBroken = false
        for s in allChrono.reversed() {
            let hasExercise = s.exerciseMinutes > 0 || !s.workouts.isEmpty
            if !streakBroken {
                // Phase 1: counting the gap (most recent consecutive rest days)
                if cal.isDateInToday(s.date) && !hasExercise {
                    // Skip today's partial data — 0 exercise at 9am doesn't mean rest day
                    continue
                }
                if !hasExercise {
                    gapDays += 1
                } else if gapDays > 0 {
                    // First exercise day found — transition to counting the streak
                    streakBroken = true
                    exerciseStreak = 1
                } else {
                    break // still exercising (no gap at all)
                }
            } else {
                // Phase 2: counting the exercise streak before the gap
                if hasExercise {
                    exerciseStreak += 1
                } else {
                    break // reached the end of the streak
                }
            }
        }
        // Only flag if a meaningful streak (3+ days) was broken by 2+ rest days
        if streakBroken && exerciseStreak >= 3 && gapDays >= 2 {
            alerts.append("💪 之前连续运动\(exerciseStreak)天，已休息\(gapDays)天。适当休息是好的，但别忘了保持节奏")
        }

        // 4b. Extended inactivity — 5+ consecutive days without exercise, regardless
        //     of whether there was a prior streak. The gap detection above only fires
        //     when breaking a 3+ day streak, so a user who simply hasn't exercised
        //     in a week gets no nudge. This catches that case.
        //     Only fire when gap detection above didn't already produce an alert.
        if !streakBroken || exerciseStreak < 3 {
            // Count consecutive rest days from the most recent completed day backward
            var consecutiveRest = 0
            for s in completed.reversed() {
                let hasExercise = s.exerciseMinutes > 0 || !s.workouts.isEmpty
                if !hasExercise {
                    consecutiveRest += 1
                } else {
                    break
                }
            }
            if consecutiveRest >= 5 {
                alerts.append("🛋️ 已连续\(consecutiveRest)天没有运动记录，适量活动有益身心")
            }
        }

        // 5. Step count significant drop — weekly average dropped >40%
        //    Sudden inactivity may indicate illness, injury, or lifestyle change.
        let recentStepDays = Array(completed.suffix(7))
        let olderStepDays = completed.count > 7 ? Array(completed.prefix(completed.count - 7).suffix(7)) : []
        if recentStepDays.count >= 5 && olderStepDays.count >= 5 {
            let recentWithSteps = recentStepDays.filter { $0.steps > 0 }
            let olderWithSteps = olderStepDays.filter { $0.steps > 0 }
            if recentWithSteps.count >= 3 && olderWithSteps.count >= 3 {
                let recentAvg = recentWithSteps.map(\.steps).reduce(0, +) / Double(recentWithSteps.count)
                let olderAvg = olderWithSteps.map(\.steps).reduce(0, +) / Double(olderWithSteps.count)
                if olderAvg > 1000 && recentAvg < olderAvg * 0.6 {
                    let dropPct = Int((1.0 - recentAvg / olderAvg) * 100)
                    alerts.append("📉 近7天日均步数\(Int(recentAvg))步，比之前（\(Int(olderAvg))步）下降\(dropPct)%")
                } else if olderAvg > 1000 && recentAvg > olderAvg * 1.4 {
                    let gainPct = Int((recentAvg / olderAvg - 1.0) * 100)
                    alerts.append("📈 近7天日均步数\(Int(recentAvg))步，比之前（\(Int(olderAvg))步）增加\(gainPct)%，活动量明显提升👍")
                }
            }
        }

        // 6. Deep sleep quality decline — deep sleep ratio dropping even if total
        //    hours are stable. This is one of the most medically significant sleep
        //    quality indicators: users who say "感觉最近睡得不好" often have normal
        //    total hours but declining deep sleep %. The existing sleep trend check
        //    (#2 above) only looks at total hours, completely missing quality changes.
        //    Deep sleep (N3 stage) is the most restorative phase — declining ratio
        //    correlates with daytime fatigue, reduced immunity, and cognitive fog.
        let phaseDays = sleepDays.filter { $0.hasSleepPhases && $0.sleepHours > 0 }
        if phaseDays.count >= 5 {
            let recentPhase = Array(phaseDays.suffix(3))
            let olderPhase = Array(phaseDays.dropLast(3).suffix(3))
            if recentPhase.count >= 3 && olderPhase.count >= 2 {
                let recentDeepRatio = recentPhase.map { $0.sleepDeepHours / $0.sleepHours * 100 }
                    .reduce(0, +) / Double(recentPhase.count)
                let olderDeepRatio = olderPhase.map { $0.sleepDeepHours / $0.sleepHours * 100 }
                    .reduce(0, +) / Double(olderPhase.count)
                let ratioDrop = olderDeepRatio - recentDeepRatio
                // Flag if deep sleep ratio dropped by ≥5 percentage points (e.g. 22% → 15%)
                // This is a meaningful decline — normal deep sleep is 15-25% of total.
                if ratioDrop >= 5 && recentDeepRatio < 20 {
                    let recentDeepAvg = recentPhase.map(\.sleepDeepHours).reduce(0, +) / Double(recentPhase.count)
                    alerts.append("😴 近3晚深度睡眠质量下降：深睡占比\(Int(recentDeepRatio))%（之前\(Int(olderDeepRatio))%），均深睡仅\(String(format: "%.1f", recentDeepAvg))h。总睡眠时长可能正常，但恢复效果变差，可能与压力、晚间屏幕时间、或睡前饮食有关")
                } else if ratioDrop <= -5 && recentDeepRatio > olderDeepRatio {
                    alerts.append("💤 近3晚深度睡眠改善：深睡占比\(Int(recentDeepRatio))%（之前\(Int(olderDeepRatio))%），睡眠质量提升👍")
                }
            }
        }

        // 7. Sleep efficiency decline — spending more time in bed but sleeping less.
        //    Sleep efficiency = actual sleep / time in bed. Declining efficiency (e.g.
        //    from 92% to 75%) often indicates insomnia, restlessness, or excessive
        //    phone use in bed. This is invisible from total sleep hours alone:
        //    "7h sleep" with 7.5h in-bed (93%) vs 9.5h in-bed (74%) are vastly
        //    different quality experiences.
        let effDays = sleepDays.filter { $0.inBedHours > 0 && $0.inBedHours >= $0.sleepHours && $0.sleepHours > 0 }
        if effDays.count >= 5 {
            let recentEff = Array(effDays.suffix(3))
            let olderEff = Array(effDays.dropLast(3).suffix(3))
            if recentEff.count >= 3 && olderEff.count >= 2 {
                let recentEffAvg = recentEff.map { ($0.sleepHours / $0.inBedHours) * 100 }
                    .reduce(0, +) / Double(recentEff.count)
                let olderEffAvg = olderEff.map { ($0.sleepHours / $0.inBedHours) * 100 }
                    .reduce(0, +) / Double(olderEff.count)
                let effDrop = olderEffAvg - recentEffAvg
                // Flag if efficiency dropped by ≥8 percentage points — clinically meaningful
                // (normal sleep efficiency is >85%, <75% suggests insomnia)
                if effDrop >= 8 && recentEffAvg < 85 {
                    alerts.append("🛏️ 近3晚睡眠效率下降至\(Int(recentEffAvg))%（之前\(Int(olderEffAvg))%），在床上躺的时间更长但实际睡着的时间变少，可能与入睡困难、夜醒增多有关")
                } else if effDrop <= -8 && recentEffAvg >= 85 {
                    alerts.append("🛏️ 近3晚睡眠效率提升至\(Int(recentEffAvg))%（之前\(Int(olderEffAvg))%），入睡更快、夜醒更少👍")
                }
            }
        }

        // 7b. Frequent awakenings — 3+ consecutive nights with ≥3 awakenings.
        //     Frequent night waking degrades sleep quality even when total hours look
        //     normal. Users saying "最近睡不安稳" or "总是醒" are describing this pattern.
        //     Unlike total hours (caught by check #1) or efficiency (check #7), awakenings
        //     specifically indicate sleep fragmentation — a distinct clinical concern
        //     associated with sleep apnea, stress, or environmental disturbances.
        let awakeDays = sleepDays.filter { $0.sleepAwakenings > 0 }
        if awakeDays.count >= 3 {
            let recentAwake = Array(awakeDays.suffix(3))
            let allFrequent = recentAwake.allSatisfy { $0.sleepAwakenings >= 3 }
            if allFrequent {
                let avgAwakenings = Double(recentAwake.map(\.sleepAwakenings).reduce(0, +)) / Double(recentAwake.count)
                let avgAwakeMins = recentAwake.map(\.sleepAwakeMinutes).reduce(0, +) / Double(recentAwake.count)
                var desc = "⚠️ 近\(recentAwake.count)晚频繁夜醒（均\(String(format: "%.0f", avgAwakenings))次"
                if avgAwakeMins >= 1 { desc += "，共约\(Int(avgAwakeMins))分钟" }
                desc += "），睡眠碎片化可能导致白天疲劳，即使总时长足够。可能与压力、环境噪音、睡前屏幕或咖啡因有关"
                alerts.append(desc)
            }
        }

        // 8. Blood oxygen (SpO2) anomaly — sudden drop below normal range.
        //    Normal SpO2 is 95-100%. A reading below 92% may indicate respiratory
        //    issues (sleep apnea, altitude effects, illness). Apple Watch measures
        //    SpO2 in the background during sleep, so low readings correlate strongly
        //    with sleep-disordered breathing. This is one of the most medically
        //    actionable alerts we can provide.
        let spo2Days = completed.filter { $0.oxygenSaturation > 0 }
        if spo2Days.count >= 3 {
            let recentSpo2 = Array(spo2Days.suffix(3))
            let lowSpo2 = recentSpo2.filter { $0.oxygenSaturation < 94 }
            if lowSpo2.count >= 2 {
                let avgSpo2 = recentSpo2.map(\.oxygenSaturation).reduce(0, +) / Double(recentSpo2.count)
                let minSpo2 = recentSpo2.map(\.oxygenSaturation).min() ?? 0
                alerts.append("⚠️ 近\(recentSpo2.count)天血氧偏低：均值\(Int(avgSpo2))%，最低\(Int(minSpo2))%（正常≥95%）。可能与呼吸问题、睡眠呼吸暂停或高海拔有关，建议关注")
            }
        }

        // 9. Late bedtime drift — bedtime shifting later over the past week
        //    Already detected in weeklySleepSection's drift analysis, but that only
        //    fires with 6+ data points split into halves. This catches shorter-term
        //    3-night trends: "最近三晚越睡越晚".
        let recentOnsets = Array(sleepDays.suffix(4)).compactMap { $0.sleepOnset }
        if recentOnsets.count >= 3 {
            let toMins: (Date) -> Double = { time in
                let c = cal.dateComponents([.hour, .minute], from: time)
                var m = Double((c.hour ?? 0) * 60 + (c.minute ?? 0))
                if m < 18 * 60 { m += 24 * 60 } // handle cross-midnight
                return m
            }
            let onsetMins = recentOnsets.map(toMins)
            // Check if each night is later than the previous
            var allLater = true
            for i in 1..<onsetMins.count {
                if onsetMins[i] <= onsetMins[i-1] + 10 { // allow 10min tolerance
                    allLater = false
                    break
                }
            }
            if allLater {
                let totalDrift = Int(onsetMins.last! - onsetMins.first!)
                if totalDrift >= 30 {
                    alerts.append("🌙 最近\(onsetMins.count)晚入睡时间逐渐推迟（共推迟约\(totalDrift)分钟），注意作息规律")
                }
            }
        }

        guard !alerts.isEmpty else { return "" }
        return "[健康趋势提醒]\n⚠️ 以下为系统自动检测的健康模式变化，在相关问题中可主动提及，但不要在不相关的对话中硬塞：\n" + alerts.joined(separator: "\n")
    }

    // MARK: - Cross-Domain Insights

    /// Computes correlations across different data domains (health × calendar × activity)
    /// to surface insights that GPT cannot derive from separate data sections.
    ///
    /// Example insights this produces:
    /// - "运动日平均睡7.3h，休息日仅6.1h" → exercise improves sleep
    /// - "入睡超过00:00的夜晚，次日平均仅4200步" → late sleep hurts next-day activity
    /// - "有3+场会议的日子，运动概率仅20%" → busy days block exercise
    ///
    /// These cross-domain patterns are exactly what makes iosclaw insightful —
    /// it's the "mirror" that shows connections the user wouldn't see themselves.
    private func crossDomainInsights(
        healthSummaries: [HealthSummary],
        calendarEvents: [CalendarEventItem]
    ) -> String {
        let cal = Calendar.current
        // Work with completed days only — today's partial data would skew correlations.
        let completed = healthSummaries
            .filter { !cal.isDateInToday($0.date) }
            .sorted { $0.date < $1.date }  // chronological

        guard completed.count >= 5 else { return "" }

        var insights: [String] = []

        // --- 1. Exercise → Sleep quality correlation ---
        // Compare sleep quality on nights following exercise days vs rest days.
        // Sleep is attributed to wake-up day, so "exercise on day N → sleep on day N"
        // means: did the user exercise during the day, and how did they sleep that night?
        // This is the most valuable correlation — users constantly ask "运动对睡眠有帮助吗？"
        let exerciseDays = completed.filter { $0.exerciseMinutes > 0 || !$0.workouts.isEmpty }
        let restDays = completed.filter { $0.exerciseMinutes == 0 && $0.workouts.isEmpty }

        // For "exercise today → tonight's sleep", we need sleep from the NEXT day's row
        // (because sleep is attributed to wake-up day). Build a date→summary lookup.
        //
        // IMPORTANT: Use ALL summaries (including today), not just `completed`.
        // Sleep is attributed to the wake-up day, so today's sleep data = last night's
        // sleep, which is already complete/finalized. If yesterday was an exercise day,
        // we need summaryByDate[today] to correlate yesterday's exercise with last
        // night's sleep. Previously this used `completed` which excluded today,
        // systematically dropping the most recent exercise→sleep data point.
        // Exercise/rest day classification still uses `completed` (correct — today's
        // exercise data is partial/accumulating), but sleep lookups need today's row.
        let summaryByDate: [Date: HealthSummary] = Dictionary(
            uniqueKeysWithValues: healthSummaries.map { (cal.startOfDay(for: $0.date), $0) }
        )

        let exerciseDaySleepHours: [Double] = exerciseDays.compactMap { day in
            let nextDay = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: day.date))!
            return summaryByDate[nextDay]?.sleepHours
        }.filter { $0 > 0 }

        let restDaySleepHours: [Double] = restDays.compactMap { day in
            let nextDay = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: day.date))!
            return summaryByDate[nextDay]?.sleepHours
        }.filter { $0 > 0 }

        if exerciseDaySleepHours.count >= 2 && restDaySleepHours.count >= 2 {
            let exSleepAvg = exerciseDaySleepHours.reduce(0, +) / Double(exerciseDaySleepHours.count)
            let restSleepAvg = restDaySleepHours.reduce(0, +) / Double(restDaySleepHours.count)
            let diff = exSleepAvg - restSleepAvg

            if abs(diff) >= 0.3 {
                if diff > 0 {
                    insights.append("🏃→😴 运动日当晚平均睡\(String(format: "%.1f", exSleepAvg))h，休息日仅\(String(format: "%.1f", restSleepAvg))h（运动日多睡\(String(format: "%.1f", diff))h）")
                } else {
                    insights.append("🏃→😴 运动日当晚平均睡\(String(format: "%.1f", exSleepAvg))h，休息日\(String(format: "%.1f", restSleepAvg))h（休息日反而睡得更多，可能运动时间较晚影响入睡）")
                }
            }

            // Deep sleep comparison on exercise vs rest days (if phase data available)
            let exDeepHours: [Double] = exerciseDays.compactMap { day in
                let nextDay = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: day.date))!
                guard let s = summaryByDate[nextDay], s.hasSleepPhases else { return nil }
                return s.sleepDeepHours
            }.filter { $0 > 0 }

            let restDeepHours: [Double] = restDays.compactMap { day in
                let nextDay = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: day.date))!
                guard let s = summaryByDate[nextDay], s.hasSleepPhases else { return nil }
                return s.sleepDeepHours
            }.filter { $0 > 0 }

            if exDeepHours.count >= 2 && restDeepHours.count >= 2 {
                let exDeepAvg = exDeepHours.reduce(0, +) / Double(exDeepHours.count)
                let restDeepAvg = restDeepHours.reduce(0, +) / Double(restDeepHours.count)
                let deepDiff = exDeepAvg - restDeepAvg
                if deepDiff >= 0.2 {
                    insights.append("  深睡方面：运动日均深睡\(String(format: "%.1f", exDeepAvg))h vs 休息日\(String(format: "%.1f", restDeepAvg))h")
                }
            }
        }

        // --- 2. Late bedtime → Next-day activity correlation ---
        // Users who sleep late tend to be less active the next day. Quantifying this
        // makes the advice "早点睡" concrete: "你晚睡的第二天平均少走3000步".
        let daysWithOnset = completed.filter { $0.sleepOnset != nil && $0.sleepHours > 0 }
        if daysWithOnset.count >= 4 {
            // Classify bedtimes: "early" (before midnight) vs "late" (after midnight)
            let midnightThresholdMinutes: Double = 24 * 60  // midnight in normalized minutes (since 18:00 baseline)
            let toNormMins: (Date) -> Double = { time in
                let c = cal.dateComponents([.hour, .minute], from: time)
                var m = Double((c.hour ?? 0) * 60 + (c.minute ?? 0))
                if m < 18 * 60 { m += 24 * 60 }
                return m
            }

            var earlyBedNextDaySteps: [Double] = []
            var lateBedNextDaySteps: [Double] = []

            for day in daysWithOnset {
                guard let onset = day.sleepOnset else { continue }
                let onsetMins = toNormMins(onset)
                // "day" is the wake-up day (sleep attributed to it). The "next day" for
                // activity correlation is actually the same day — the user woke up on this
                // day and their activity happens during this day.
                if day.steps > 0 {
                    if onsetMins >= midnightThresholdMinutes {
                        lateBedNextDaySteps.append(day.steps)
                    } else {
                        earlyBedNextDaySteps.append(day.steps)
                    }
                }
            }

            if earlyBedNextDaySteps.count >= 2 && lateBedNextDaySteps.count >= 2 {
                let earlyAvg = earlyBedNextDaySteps.reduce(0, +) / Double(earlyBedNextDaySteps.count)
                let lateAvg = lateBedNextDaySteps.reduce(0, +) / Double(lateBedNextDaySteps.count)
                let stepDiff = earlyAvg - lateAvg
                if stepDiff >= 1000 {
                    insights.append("🌙→👟 0点前入睡的日子平均\(Int(earlyAvg))步，0点后入睡的日子仅\(Int(lateAvg))步（早睡多走\(Int(stepDiff))步）")
                } else if stepDiff <= -1000 {
                    insights.append("🌙→👟 0点后入睡的日子平均\(Int(lateAvg))步，0点前入睡的日子\(Int(earlyAvg))步（夜猫子反而更活跃）")
                }
            }
        }

        // --- 3. Calendar busyness → Exercise correlation ---
        // Busy meeting days often block exercise. Quantifying this helps GPT advise
        // "这周会议多，可以尝试在早上会议前运动" instead of generic tips.
        if !calendarEvents.isEmpty {
            // Count non-all-day events per day
            var eventCountByDay: [Date: Int] = [:]
            for event in calendarEvents where !event.isAllDay {
                let dayStart = cal.startOfDay(for: event.startDate)
                eventCountByDay[dayStart, default: 0] += 1
            }

            // Classify days as "busy" (≥3 events) vs "light" (0-1 events)
            var busyDayExercise: [Double] = []
            var lightDayExercise: [Double] = []

            for day in completed {
                let dayStart = cal.startOfDay(for: day.date)
                let eventCount = eventCountByDay[dayStart] ?? 0
                if eventCount >= 3 {
                    busyDayExercise.append(day.exerciseMinutes)
                } else if eventCount <= 1 {
                    lightDayExercise.append(day.exerciseMinutes)
                }
            }

            if busyDayExercise.count >= 2 && lightDayExercise.count >= 2 {
                let busyExPct = Double(busyDayExercise.filter { $0 > 0 }.count) / Double(busyDayExercise.count) * 100
                let lightExPct = Double(lightDayExercise.filter { $0 > 0 }.count) / Double(lightDayExercise.count) * 100

                if lightExPct - busyExPct >= 20 {
                    let busyAvgEx = busyDayExercise.reduce(0, +) / Double(busyDayExercise.count)
                    let lightAvgEx = lightDayExercise.reduce(0, +) / Double(lightDayExercise.count)
                    insights.append("📅→🏃 会议较多（≥3场）的日子运动概率\(Int(busyExPct))%（均\(Int(busyAvgEx))分钟），清闲日运动概率\(Int(lightExPct))%（均\(Int(lightAvgEx))分钟）")
                }
            }
        }

        // --- 4. Step count → Resting HR correlation ---
        // Higher activity levels typically correlate with lower resting HR the next morning.
        // This validates exercise benefits with the user's own data.
        let daysWithRHR = completed.filter { $0.restingHeartRate > 0 && $0.steps > 0 }
        if daysWithRHR.count >= 5 {
            let sorted = daysWithRHR.sorted { $0.steps < $1.steps }
            let lowActivityHalf = Array(sorted.prefix(sorted.count / 2))
            let highActivityHalf = Array(sorted.suffix(sorted.count / 2))

            if !lowActivityHalf.isEmpty && !highActivityHalf.isEmpty {
                let lowRHR = lowActivityHalf.map(\.restingHeartRate).reduce(0, +) / Double(lowActivityHalf.count)
                let highRHR = highActivityHalf.map(\.restingHeartRate).reduce(0, +) / Double(highActivityHalf.count)
                let rhrDiff = lowRHR - highRHR

                if rhrDiff >= 3 {
                    let lowStepsAvg = Int(lowActivityHalf.map(\.steps).reduce(0, +) / Double(lowActivityHalf.count))
                    let highStepsAvg = Int(highActivityHalf.map(\.steps).reduce(0, +) / Double(highActivityHalf.count))
                    insights.append("👟→❤️ 活动量高的日子（≈\(highStepsAvg)步）静息心率均\(Int(highRHR))bpm，活动量低的日子（≈\(lowStepsAvg)步）均\(Int(lowRHR))bpm")
                }
            }
        }

        guard !insights.isEmpty else { return "" }
        return "[生活模式洞察]\n以下为系统分析的跨领域关联（基于近\(completed.count)天数据），在用户问「为什么」「有什么规律」「怎么改善」等问题时可引用：\n" + insights.joined(separator: "\n")
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

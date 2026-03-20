import Foundation

/// Handles conversational greetings, thanks, farewells, and self-introduction.
///
/// The hello greeting is **data-aware**: it fetches real HealthKit + Calendar data
/// and surfaces a personalized snapshot — making the user feel that iosclaw truly
/// knows them, from the very first interaction of each session.
struct GreetingSkill: ClawSkill {

    let id = "greeting"

    func canHandle(intent: QueryIntent) -> Bool {
        if case .greeting = intent { return true }
        return false
    }

    func execute(intent: QueryIntent, context: SkillContext, completion: @escaping (String) -> Void) {
        guard case .greeting(let type) = intent else {
            completion("你好！有什么可以帮你的吗？")
            return
        }

        let userName = context.profile.name.isEmpty ? "" : context.profile.name
        let hour = Calendar.current.component(.hour, from: Date())

        switch type {
        case .hello:
            buildDataAwareHello(userName: userName, hour: hour, context: context, completion: completion)
        case .thanks:
            completion(buildThanksResponse(userName: userName))
        case .farewell:
            buildDataAwareFarewell(userName: userName, hour: hour, context: context, completion: completion)
        case .presence:
            completion(buildPresenceResponse(userName: userName))
        case .selfIntro:
            completion(buildSelfIntroResponse())
        case .howAreYou:
            buildDataAwareHowAreYou(userName: userName, hour: hour, context: context, completion: completion)
        case .capabilities:
            buildCapabilitiesShowcase(context: context, completion: completion)
        }
    }

    // MARK: - Data-Aware Hello

    /// Fetches today's health + calendar data and composes a personalized greeting.
    /// Morning → last night's sleep + today's schedule
    /// Afternoon → steps so far + remaining events
    /// Evening → day's activity recap + tomorrow preview
    /// Late night → gentle reminder to rest
    private func buildDataAwareHello(userName: String, hour: Int, context: SkillContext,
                                     completion: @escaping (String) -> Void) {
        let greeting = timeGreeting(hour)
        let name = userName.isEmpty ? "" : "，\(userName)"

        // If HealthKit is not available, fall back to calendar-only greeting
        guard context.healthService.isHealthDataAvailable else {
            let calSnippet = calendarSnippet(hour: hour, context: context)
            var response = "\(greeting)\(name)！😊"
            if !calSnippet.isEmpty {
                response += "\n\n\(calSnippet)"
            }
            response += "\n\n有什么我能帮到你的吗？"
            completion(response)
            return
        }

        // Fetch 2 days of health data: yesterday (sleep) + today (activity)
        context.healthService.fetchSummaries(days: 2) { summaries in
            let cal = Calendar.current
            let today = summaries.first { cal.isDateInToday($0.date) }
                ?? HealthSummary(date: Date())
            let yesterday = summaries.first { cal.isDateInYesterday($0.date) }
                ?? HealthSummary(date: cal.date(byAdding: .day, value: -1, to: Date()) ?? Date())

            var response = "\(greeting)\(name)！😊"

            // Build time-of-day specific data snapshot
            let snapshot = self.buildTimeSnapshot(
                hour: hour, today: today, lastNight: yesterday, context: context
            )
            if !snapshot.isEmpty {
                response += "\n\n" + snapshot
            }

            // Calendar context
            let calSnippet = self.calendarSnippet(hour: hour, context: context)
            if !calSnippet.isEmpty {
                response += "\n\n" + calSnippet
            }

            // Friendly closing — only if we showed some data
            if snapshot.isEmpty && calSnippet.isEmpty {
                response += "\n\n有什么我能帮到你的吗？"
            }

            completion(response)
        }
    }

    /// Builds a health snapshot appropriate for the current time of day.
    private func buildTimeSnapshot(hour: Int, today: HealthSummary,
                                   lastNight: HealthSummary, context: SkillContext) -> String {
        var parts: [String] = []

        switch hour {
        case 6..<12:
            // Morning: focus on last night's sleep + early activity
            if lastNight.sleepHours > 0 {
                let sleepEmoji = lastNight.sleepHours >= 7 ? "😴" : "💤"
                var sleepLine = "\(sleepEmoji) 昨晚睡了 \(String(format: "%.1f", lastNight.sleepHours)) 小时"
                if lastNight.hasSleepPhases {
                    let deepMin = Int(lastNight.sleepDeepHours * 60)
                    if deepMin > 0 {
                        sleepLine += "，深睡 \(deepMin) 分钟"
                    }
                }
                if lastNight.sleepHours >= 7.5 {
                    sleepLine += " ✅"
                } else if lastNight.sleepHours < 6 {
                    sleepLine += "  — 有点少哦"
                }
                parts.append(sleepLine)
            }
            if today.steps > 100 {
                parts.append("👟 今天已走 \(Int(today.steps).formatted()) 步")
            }

        case 12..<18:
            // Afternoon: activity progress
            if today.steps > 0 {
                let stepGoal = 8000.0
                let pct = min(Int(today.steps / stepGoal * 100), 999)
                var stepLine = "👟 今天已走 \(Int(today.steps).formatted()) 步"
                if pct >= 100 {
                    stepLine += " 🏅 达标！"
                } else if pct >= 60 {
                    stepLine += "（\(pct)%，继续保持）"
                }
                parts.append(stepLine)
            }
            if today.exerciseMinutes >= 5 {
                parts.append("⏱ 运动 \(Int(today.exerciseMinutes)) 分钟")
            }
            if today.activeCalories > 100 {
                parts.append("🔥 消耗 \(Int(today.activeCalories).formatted()) 千卡")
            }

        case 18..<23:
            // Evening: day recap
            var recapParts: [String] = []
            if today.steps > 0 {
                recapParts.append("\(Int(today.steps).formatted()) 步")
            }
            if today.exerciseMinutes >= 5 {
                recapParts.append("运动 \(Int(today.exerciseMinutes)) 分钟")
            }
            if today.activeCalories > 100 {
                recapParts.append("\(Int(today.activeCalories).formatted()) 千卡")
            }
            if !recapParts.isEmpty {
                let verdict = today.steps >= 8000 && today.exerciseMinutes >= 30
                    ? "充实的一天！💪"
                    : (today.steps >= 5000 ? "还不错 👍" : "")
                parts.append("📊 今天：\(recapParts.joined(separator: " · "))\(verdict.isEmpty ? "" : " — \(verdict)")")
            }
            // Sleep from last night as context
            if lastNight.sleepHours > 0 && lastNight.sleepHours < 6.5 {
                parts.append("😴 昨晚只睡了 \(String(format: "%.1f", lastNight.sleepHours))h，今晚记得早点休息")
            }

        default:
            // Late night (23-6)
            if today.steps > 0 || today.exerciseMinutes > 0 {
                var lateParts: [String] = []
                if today.steps > 0 { lateParts.append("\(Int(today.steps).formatted()) 步") }
                if today.exerciseMinutes >= 5 { lateParts.append("运动 \(Int(today.exerciseMinutes))min") }
                parts.append("📊 今天：\(lateParts.joined(separator: " · "))")
            }
            parts.append("🌙 夜深了，注意休息哦")
        }

        return parts.joined(separator: "\n")
    }

    /// Builds a brief calendar snippet for the greeting.
    private func calendarSnippet(hour: Int, context: SkillContext) -> String {
        guard context.calendarService.isAuthorized else { return "" }

        let cal = Calendar.current
        let now = Date()

        switch hour {
        case 6..<12:
            // Morning: show today's schedule count + first event
            let events = context.calendarService.todayEvents()
            let timed = events.filter { !$0.isAllDay }
            if timed.isEmpty { return "📅 今天没有安排，自由的一天！" }
            let fmt = DateFormatter()
            fmt.dateFormat = "H:mm"
            let firstEvent = timed.sorted { $0.startDate < $1.startDate }.first!
            var line = "📅 今天有 \(timed.count) 个安排"
            if firstEvent.startDate > now {
                line += "，最近的是 \(fmt.string(from: firstEvent.startDate))「\(firstEvent.title)」"
            }
            return line

        case 12..<18:
            // Afternoon: remaining events
            let events = context.calendarService.todayEvents()
            let remaining = events.filter { !$0.isAllDay && $0.endDate > now }
            if remaining.isEmpty { return "📅 今天剩余时间没有安排了" }
            if remaining.count == 1 {
                let fmt = DateFormatter()
                fmt.dateFormat = "H:mm"
                return "📅 还剩 1 个：\(fmt.string(from: remaining[0].startDate))「\(remaining[0].title)」"
            }
            return "📅 今天还剩 \(remaining.count) 个安排"

        case 18..<23:
            // Evening: tomorrow preview
            let tomorrowStart = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
            let tomorrowEnd = cal.date(byAdding: .day, value: 1, to: tomorrowStart)!
            let tomorrowEvents = context.calendarService.fetchEvents(from: tomorrowStart, to: tomorrowEnd)
            let timed = tomorrowEvents.filter { !$0.isAllDay }
            if timed.isEmpty { return "📅 明天暂时没有安排" }
            let fmt = DateFormatter()
            fmt.dateFormat = "H:mm"
            let first = timed.sorted { $0.startDate < $1.startDate }.first!
            return "📅 明天有 \(timed.count) 个安排，最早 \(fmt.string(from: first.startDate)) 开始"

        default:
            return ""
        }
    }

    // MARK: - Data-Aware Farewell

    /// Evening/night farewell includes a brief day recap to close the loop.
    private func buildDataAwareFarewell(userName: String, hour: Int, context: SkillContext,
                                        completion: @escaping (String) -> Void) {
        let name = userName.isEmpty ? "" : "，\(userName)"

        // Only enrich farewell at night with health data
        guard (hour >= 20 || hour < 6), context.healthService.isHealthDataAvailable else {
            completion(buildStaticFarewell(name: name, hour: hour))
            return
        }

        context.healthService.fetchDailySummary(for: Date()) { today in
            var response = ""

            if hour >= 22 || hour < 6 {
                response = "晚安\(name)！🌙"
            } else {
                response = "再见\(name)！✨"
            }

            // Brief day recap on farewell
            var recap: [String] = []
            if today.steps > 0 { recap.append("\(Int(today.steps).formatted()) 步") }
            if today.exerciseMinutes >= 5 { recap.append("运动 \(Int(today.exerciseMinutes))min") }
            if !recap.isEmpty {
                response += "\n今天的你：\(recap.joined(separator: " · "))"
                if today.steps >= 8000 && today.exerciseMinutes >= 30 {
                    response += " 💪"
                }
            }

            if hour >= 22 || hour < 6 {
                response += "\n好好休息，明天见 💤"
            } else {
                response += "\n接下来的时间也加油！"
            }

            completion(response)
        }
    }

    private func buildStaticFarewell(name: String, hour: Int) -> String {
        if hour >= 22 || hour < 6 {
            let nightResponses = [
                "晚安\(name)！祝你做个好梦 🌙",
                "晚安\(name)！好好休息，明天见 💤",
                "晚安\(name)！早点休息哦 🌟"
            ]
            return nightResponses[Int.random(in: 0..<nightResponses.count)]
        }

        let responses = [
            "再见\(name)！下次聊 👋",
            "拜拜\(name)！随时都可以回来找我 😊",
            "下次见\(name)！祝你接下来一切顺利 ✨"
        ]
        return responses[Int.random(in: 0..<responses.count)]
    }

    // MARK: - Static Response Builders

    private func buildThanksResponse(userName: String) -> String {
        let responses = [
            "不客气！随时都可以找我帮忙 😊",
            "很高兴能帮到你！还有什么需要的吗？",
            "不用谢！这是我应该做的 🤗",
            "客气啦！有任何问题随时问我 ✨",
            "能帮到你真好！下次有需要再叫我 😄"
        ]
        return responses[Int.random(in: 0..<responses.count)]
    }

    private func buildPresenceResponse(userName: String) -> String {
        let name = userName.isEmpty ? "" : "，\(userName)"
        let responses = [
            "我在呢\(name)！有什么事吗？😊",
            "在的在的！需要帮忙吗？🙋",
            "我一直在\(name)！说吧，什么事？✨",
            "嗯嗯，我在！你说 😄"
        ]
        return responses[Int.random(in: 0..<responses.count)]
    }

    private func buildSelfIntroResponse() -> String {
        return """
        我是 iosclaw 🤖 —— 你的本地私人 AI 助理！

        我运行在你的 iPhone 上，所有数据都保存在本地，不会上传到任何服务器。

        我最擅长帮你了解「自己」：
        • 🏃 健康数据 — 步数、运动、睡眠、心率、HRV
        • 📍 足迹回顾 — 去过的地方、常去场所
        • 📅 日程管理 — 查看日历、分析忙碌程度
        • 📸 照片搜索 — 用自然语言找到记忆中的照片
        • 📝 生活记录 — 记事件、追踪心情

        也支持待办、习惯打卡、倒计时、记账等日常工具。

        试试问我「今天运动了多少」或「昨晚睡得怎么样」？
        """
    }

    // MARK: - Data-Aware "How Are You"

    /// When the user asks "你好吗" / "你怎么样", the AI flips the question:
    /// instead of a canned "I'm fine", it shows genuine care by surfacing
    /// the user's actual health and schedule state — a core iosclaw moment.
    private func buildDataAwareHowAreYou(userName: String, hour: Int, context: SkillContext,
                                          completion: @escaping (String) -> Void) {
        let name = userName.isEmpty ? "" : "，\(userName)"

        guard context.healthService.isHealthDataAvailable else {
            // No HealthKit → still try calendar for a personal touch
            let calInsight = howAreYouCalendarInsight(hour: hour, context: context)
            var response = "我很好呀，谢谢关心\(name)！😊"
            if !calInsight.isEmpty {
                response += "\n\n不过比起我，我更在意你：\n\(calInsight)"
            } else {
                response += "\n你今天过得怎么样？"
            }
            completion(response)
            return
        }

        // Fetch 7 days: today + 6 days for personal baseline
        context.healthService.fetchSummaries(days: 7) { summaries in
            let cal = Calendar.current
            let today = summaries.first { cal.isDateInToday($0.date) } ?? HealthSummary(date: Date())
            let yesterday = summaries.first { cal.isDateInYesterday($0.date) } ?? HealthSummary(date: Date())
            // Baseline: recent days excluding today, with actual data
            let baseline = summaries.filter { !cal.isDateInToday($0.date) && $0.hasData }

            var response = "我很好，随时待命！😊"
            response += "\n\n不过比起我，我更关心你\(name)："

            var insights: [String] = []

            // Sleep insight (from last night / yesterday's data)
            let sleepData = yesterday.sleepHours > 0 ? yesterday : today
            if sleepData.sleepHours > 0 {
                let baselineAvg = baseline.isEmpty ? 0.0
                    : baseline.filter { $0.sleepHours > 0 }.reduce(0) { $0 + $1.sleepHours }
                      / Double(max(1, baseline.filter { $0.sleepHours > 0 }.count))

                if sleepData.sleepHours >= 7.5 {
                    var line = "😴 昨晚睡了 \(String(format: "%.1f", sleepData.sleepHours))h，休息得不错"
                    if baselineAvg > 0 && sleepData.sleepHours - baselineAvg >= 0.5 {
                        line += "，比平时还多 ✨"
                    }
                    insights.append(line)
                } else if sleepData.sleepHours < 6 {
                    var line = "😴 昨晚只睡了 \(String(format: "%.1f", sleepData.sleepHours))h，有些不足"
                    if baselineAvg > 0 && baselineAvg - sleepData.sleepHours >= 0.5 {
                        line += "，比平时少了不少"
                    }
                    if hour < 14 {
                        line += "，今天注意休息"
                    }
                    insights.append(line)
                } else {
                    insights.append("😴 昨晚睡了 \(String(format: "%.1f", sleepData.sleepHours))h")
                }
            }

            // Activity insight (today's progress)
            if today.steps > 100 || today.exerciseMinutes >= 5 {
                var parts: [String] = []
                if today.steps > 100 {
                    let pct = min(Int(today.steps / 8000.0 * 100), 999)
                    if pct >= 100 {
                        parts.append("已走 \(Int(today.steps).formatted()) 步 🏅")
                    } else {
                        parts.append("已走 \(Int(today.steps).formatted()) 步（\(pct)%）")
                    }
                }
                if today.exerciseMinutes >= 5 {
                    parts.append("运动 \(Int(today.exerciseMinutes))min")
                }
                insights.append("👟 今天\(parts.joined(separator: "，"))")
            }

            // HRV/RHR recovery signal
            if today.restingHeartRate > 0 {
                let baselineRHR = baseline.filter { $0.restingHeartRate > 0 }
                let avgRHR = baselineRHR.isEmpty ? 0.0
                    : baselineRHR.reduce(0) { $0 + $1.restingHeartRate } / Double(baselineRHR.count)
                if avgRHR > 0 && today.restingHeartRate - avgRHR >= 5 {
                    insights.append("❤️ 静息心率偏高（\(Int(today.restingHeartRate)) vs 平时 \(Int(avgRHR))），身体可能需要多休息")
                } else if today.heartRate > 0 {
                    insights.append("❤️ 心率 \(Int(today.heartRate)) bpm，状态正常")
                }
            }

            // Calendar context
            let calInsight = self.howAreYouCalendarInsight(hour: hour, context: context)
            if !calInsight.isEmpty {
                insights.append(calInsight)
            }

            // Assemble
            if insights.isEmpty {
                response += "\n今天的数据还在积累中，晚点再来问我，我能告诉你更多 😊"
            } else {
                response += "\n" + insights.joined(separator: "\n")

                // Closing: a brief caring remark based on overall picture
                let closing = self.howAreYouClosing(
                    sleepHours: sleepData.sleepHours,
                    steps: today.steps,
                    exerciseMin: today.exerciseMinutes,
                    hour: hour
                )
                if !closing.isEmpty {
                    response += "\n\n\(closing)"
                }
            }

            completion(response)
        }
    }

    /// Builds a brief calendar insight for the "how are you" response.
    private func howAreYouCalendarInsight(hour: Int, context: SkillContext) -> String {
        guard context.calendarService.isAuthorized else { return "" }
        let events = context.calendarService.todayEvents()
        let timed = events.filter { !$0.isAllDay }

        if timed.isEmpty { return "" }

        let remaining = timed.filter { $0.endDate > Date() }
        if hour < 12 {
            if timed.count >= 4 {
                return "📅 今天有 \(timed.count) 个安排，比较忙碌的一天"
            } else if timed.count > 0 {
                return "📅 今天有 \(timed.count) 个安排"
            }
        } else {
            if remaining.isEmpty {
                return "📅 今天的 \(timed.count) 个安排都结束了，可以放松一下"
            } else if remaining.count >= 3 {
                return "📅 还有 \(remaining.count) 个安排，继续加油"
            } else if remaining.count > 0 {
                return "📅 还剩 \(remaining.count) 个安排"
            }
        }
        return ""
    }

    /// Produces a caring closing remark based on the user's overall state.
    private func howAreYouClosing(sleepHours: Double, steps: Double, exerciseMin: Double, hour: Int) -> String {
        // Poor sleep + busy day → extra care
        if sleepHours > 0 && sleepHours < 6 && hour < 18 {
            return "💡 昨晚睡得不够，今天别太拼，适当休息一下"
        }
        // Great activity + good sleep → encouragement
        if steps >= 8000 && exerciseMin >= 30 && sleepHours >= 7 {
            return "💪 从数据来看，你的状态很好！继续保持"
        }
        // Evening with good activity
        if hour >= 18 && (steps >= 8000 || exerciseMin >= 30) {
            return "✨ 今天活动量不错，好好休息，明天继续"
        }
        // Morning with good sleep
        if hour < 12 && sleepHours >= 7.5 {
            return "☀️ 休息得不错，今天会是充满能量的一天！"
        }
        return ""
    }

    // MARK: - Data-Aware Capabilities Showcase

    /// Demonstrates iosclaw's capabilities by showing **real user data** for each skill area.
    /// Instead of a static feature list, this creates a "wow moment" — the user immediately
    /// sees that iosclaw already knows about their health, schedule, location, and photos.
    ///
    /// Falls back gracefully: each data source shows a static description if no data is available.
    private func buildCapabilitiesShowcase(context: SkillContext, completion: @escaping (String) -> Void) {
        let cal = Calendar.current

        // Calendar + Location + Photos can be fetched synchronously
        let calendarSnippet = buildCalendarCapabilitySnippet(context: context)
        let locationSnippet = buildLocationCapabilitySnippet(cal: cal, context: context)
        let photoSnippet = buildPhotoCapabilitySnippet(cal: cal, context: context)

        // Health requires async fetch
        guard context.healthService.isHealthDataAvailable else {
            let response = assembleCapabilitiesResponse(
                healthSnippet: nil,
                calendarSnippet: calendarSnippet,
                locationSnippet: locationSnippet,
                photoSnippet: photoSnippet
            )
            completion(response)
            return
        }

        context.healthService.fetchSummaries(days: 2) { summaries in
            let today = summaries.first { cal.isDateInToday($0.date) }
            let yesterday = summaries.first { !cal.isDateInToday($0.date) && $0.hasData }
            let healthData = (today?.hasData == true) ? today : yesterday
            let healthSnippet = self.buildHealthCapabilitySnippet(data: healthData)

            let response = self.assembleCapabilitiesResponse(
                healthSnippet: healthSnippet,
                calendarSnippet: calendarSnippet,
                locationSnippet: locationSnippet,
                photoSnippet: photoSnippet
            )
            completion(response)
        }
    }

    private func buildHealthCapabilitySnippet(data: HealthSummary?) -> String? {
        guard let d = data else { return nil }
        var parts: [String] = []
        if d.steps > 0 { parts.append("\(Int(d.steps).formatted()) 步") }
        if d.exerciseMinutes > 0 { parts.append("运动 \(Int(d.exerciseMinutes))min") }
        if d.sleepHours > 0 { parts.append("睡 \(String(format: "%.1f", d.sleepHours))h") }
        if d.heartRate > 0 { parts.append("心率 \(Int(d.heartRate))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func buildCalendarCapabilitySnippet(context: SkillContext) -> String? {
        guard context.calendarService.isAuthorized else { return nil }
        let events = context.calendarService.todayEvents()
        let timed = events.filter { !$0.isAllDay }
        if timed.isEmpty { return "今天没有安排" }
        let remaining = timed.filter { $0.endDate > Date() }
        if remaining.isEmpty {
            return "今天 \(timed.count) 个安排已全部结束"
        }
        return "今天 \(timed.count) 个安排，还剩 \(remaining.count) 个"
    }

    private func buildLocationCapabilitySnippet(cal: Calendar, context: SkillContext) -> String? {
        let weekStart = cal.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let records = CDLocationRecord.fetch(from: weekStart, to: Date(), in: context.coreDataContext)
        guard !records.isEmpty else { return nil }
        // Count unique places by name (skip empty names from geocoding failures)
        let uniquePlaces = Set(records.map(\.placeName).filter { !$0.isEmpty })
        if uniquePlaces.isEmpty { return "这周有 \(records.count) 条位置记录" }
        return "这周去了 \(uniquePlaces.count) 个地方"
    }

    private func buildPhotoCapabilitySnippet(cal: Calendar, context: SkillContext) -> String? {
        let weekStart = cal.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let dailyCounts = context.photoService.dailyPhotoCounts(from: weekStart, to: Date())
        let totalCount = dailyCounts.values.reduce(0, +)
        guard totalCount > 0 else { return nil }
        return "这周拍了 \(totalCount) 张照片"
    }

    /// Assembles the final capabilities response with real data snippets where available.
    private func assembleCapabilitiesResponse(
        healthSnippet: String?,
        calendarSnippet: String?,
        locationSnippet: String?,
        photoSnippet: String?
    ) -> String {
        var lines: [String] = []

        lines.append("👋 我是 iosclaw — 你的本地 AI 私人助理")
        lines.append("所有数据都在 iPhone 上，不联网、不上传。\n")
        lines.append("我最擅长帮你了解「自己」：\n")

        // Health — show real data or static description
        if let snippet = healthSnippet {
            lines.append("🏃 健康数据 — \(snippet)")
            lines.append("   试试：「今天运动了多少」「昨晚睡得怎么样」「心率」")
        } else {
            lines.append("🏃 健康数据 — 步数、运动、睡眠、心率、HRV")
            lines.append("   试试：「今天走了多少步」「这周睡眠怎么样」")
        }

        // Calendar
        if let snippet = calendarSnippet {
            lines.append("📅 日程 — \(snippet)")
            lines.append("   试试：「今天有什么安排」「接下来有什么」")
        } else {
            lines.append("📅 日程 — 查看日历、分析忙碌程度、找空闲时段")
            lines.append("   试试：「今天有什么安排」「本周什么时候有空」")
        }

        // Location
        if let snippet = locationSnippet {
            lines.append("📍 足迹 — \(snippet)")
            lines.append("   试试：「最近去了哪些地方」「去过星巴克几次」")
        } else {
            lines.append("📍 足迹 — 去过的地方、常去场所、活动范围")
            lines.append("   试试：「这周去了哪些地方」「最远去了哪」")
        }

        // Photos
        if let snippet = photoSnippet {
            lines.append("📸 照片 — \(snippet)")
            lines.append("   试试：「这周拍了哪些照片」「帮我找海边的照片」")
        } else {
            lines.append("📸 照片 — 用自然语言搜索记忆中的照片")
            lines.append("   试试：「最近拍了什么照片」「找上周的照片」")
        }

        // Secondary capabilities
        lines.append("")
        lines.append("还可以帮你：")
        lines.append("📝 记录生活 — 「今天去爬山了，感觉很棒」")
        lines.append("😊 追踪心情 — 「最近心情怎么样」")
        lines.append("📋 总结回顾 — 「帮我总结这周」「这周怎么样」")
        lines.append("📊 数据比较 — 「比上周运动多了吗」")

        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private func timeGreeting(_ hour: Int) -> String {
        switch hour {
        case 6..<12: return "早上好"
        case 12..<14: return "中午好"
        case 14..<18: return "下午好"
        case 18..<22: return "晚上好"
        default: return "夜深了"
        }
    }
}

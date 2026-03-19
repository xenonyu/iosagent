import Foundation

/// Handles mood and emotion analysis queries with cross-data correlation.
/// Correlates mood entries with HealthKit (sleep, exercise, steps) and location data
/// to discover personal patterns the user might not notice on their own.
struct MoodSkill: ClawSkill {

    let id = "mood"

    func canHandle(intent: QueryIntent) -> Bool {
        if case .mood = intent { return true }
        return false
    }

    func execute(intent: QueryIntent, context: SkillContext, completion: @escaping (String) -> Void) {
        guard case .mood(let range) = intent else { return }
        let interval = range.interval
        let events = CDLifeEvent.fetch(from: interval.start, to: interval.end, in: context.coreDataContext)

        if events.isEmpty {
            // Detect if user arrived here via an emotional expression (e.g. "好累", "压力大")
            let query = context.originalQuery.lowercased()
            let emotionalWords = ["累", "疲惫", "压力", "焦虑", "烦", "崩溃", "郁闷", "低落",
                                  "难过", "伤心", "开心", "兴奋", "紧张", "无聊", "孤独", "沮丧",
                                  "放松", "舒服", "丧", "满足", "充实"]
            let isEmotionalExpression = emotionalWords.contains(where: { query.contains($0) })

            if isEmotionalExpression {
                // Empathize first, then check health + calendar data for possible explanations
                let empathy = self.buildPersonalizedEmpathy(query: query)
                let isNegative = empathy.isNegative

                // Fetch recent health data to provide context for the emotion
                context.healthService.fetchSummaries(days: 3) { summaries in
                    let healthContext = self.buildHealthContextForEmotion(
                        summaries: summaries,
                        isNegative: isNegative,
                        query: query
                    )

                    // Check today's calendar for meeting overload context
                    let calendarContext = self.buildCalendarContextForEmotion(
                        context: context,
                        isNegative: isNegative
                    )

                    var response = empathy.text

                    // Combine health + calendar context into a unified "possible reasons" block
                    var clues: [String] = []
                    if let calCtx = calendarContext { clues.append(calCtx) }
                    if let healthCtx = healthContext { clues.append(healthCtx) }

                    if !clues.isEmpty {
                        response += "\n\n" + clues.joined(separator: "\n\n")
                    }

                    // Suggest recording with a natural phrasing
                    let emotionWord = self.extractDominantEmotion(from: query) ?? "心情"
                    response += "\n\n📝 说「记录一下，\(emotionWord)」我会帮你保存。积累几天后就能发现你的心情规律。"
                    completion(response)
                }
            } else {
                completion("😊 \(range.label)暂无心情记录。\n通过对话告诉我你今天的心情，我会帮你记录下来！\n\n💡 试试说：「今天心情不错」、「有点累」或「今天很开心」，我会帮你记录并分析趋势。")
            }
            return
        }

        // Count mood distribution
        var moodCount: [MoodType: Int] = [:]
        events.forEach { moodCount[$0.mood, default: 0] += 1 }
        let dominant = moodCount.max(by: { $0.value < $1.value })?.key ?? .neutral

        // Collect unique days with mood records for health correlation
        let cal = Calendar.current
        var moodByDay: [String: [MoodType]] = [:]
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "yyyy-MM-dd"
        for e in events {
            let key = dayFmt.string(from: e.timestamp)
            moodByDay[key, default: []].append(e.mood)
        }

        // Determine how many days of health data to fetch
        let dayCount = max(cal.dateComponents([.day], from: interval.start, to: interval.end).day ?? 7, 7)

        // Fetch health data for correlation
        context.healthService.fetchSummaries(days: min(dayCount, 30)) { healthSummaries in
            // Build health lookup by date
            var healthByDay: [String: HealthSummary] = [:]
            for s in healthSummaries {
                healthByDay[dayFmt.string(from: s.date)] = s
            }

            // Fetch location data for place correlation
            let locationRecords = CDLocationRecord.fetch(
                from: interval.start, to: interval.end,
                in: context.coreDataContext
            )
            var locationByDay: [String: [LocationRecord]] = [:]
            for r in locationRecords {
                let key = dayFmt.string(from: r.timestamp)
                locationByDay[key, default: []].append(r)
            }

            // Build the response
            var sections: [String] = []

            // 1. Header + mood distribution
            sections.append(self.buildMoodOverview(range: range, dominant: dominant, moodCount: moodCount, events: events))

            // 2. Mood trend (if multi-day)
            if moodByDay.count >= 3 {
                if let trend = self.buildMoodTrend(moodByDay: moodByDay, dayFmt: dayFmt) {
                    sections.append(trend)
                }
            }

            // 3. Health–mood correlation (the key insight)
            if !healthSummaries.isEmpty && moodByDay.count >= 2 {
                if let correlation = self.buildHealthCorrelation(
                    moodByDay: moodByDay,
                    healthByDay: healthByDay
                ) {
                    sections.append(correlation)
                }
            }

            // 4. Location–mood correlation
            if !locationRecords.isEmpty && moodByDay.count >= 2 {
                if let locationInsight = self.buildLocationCorrelation(
                    moodByDay: moodByDay,
                    locationByDay: locationByDay
                ) {
                    sections.append(locationInsight)
                }
            }

            // 5. Recent entries
            let recentCount = min(events.count, 5)
            let recentEvents = events.prefix(recentCount)
            if !recentEvents.isEmpty {
                var recentLines = ["📋 最近记录："]
                for e in recentEvents {
                    recentLines.append("  \(e.timestamp.shortDisplay) \(e.mood.emoji) \(e.title)")
                }
                sections.append(recentLines.joined(separator: "\n"))
            }

            completion(sections.joined(separator: "\n\n"))
        }
    }

    // MARK: - Mood Overview

    private func buildMoodOverview(range: QueryTimeRange, dominant: MoodType, moodCount: [MoodType: Int], events: [LifeEvent]) -> String {
        let total = events.count
        var lines: [String] = ["💭 \(range.label)的心情状态"]

        // Mood score: great=5, good=4, neutral=3, tired=2, stressed=1.5, sad=1
        let score = events.reduce(0.0) { $0 + moodScore($1.mood) } / Double(total)
        let scoreEmoji: String
        let scoreLabel: String
        if score >= 4.0 {
            scoreEmoji = "🌟"; scoreLabel = "状态很好"
        } else if score >= 3.0 {
            scoreEmoji = "☀️"; scoreLabel = "整体不错"
        } else if score >= 2.0 {
            scoreEmoji = "🌤️"; scoreLabel = "有些波动"
        } else {
            scoreEmoji = "🌧️"; scoreLabel = "有点低落"
        }
        lines.append("\(scoreEmoji) 综合心情指数：\(String(format: "%.1f", score))/5（\(scoreLabel)）")
        lines.append("\(dominant.emoji) 主要状态：\(dominant.label)（共 \(total) 条记录）\n")

        // Distribution bars
        let sorted = MoodType.allCases.filter { moodCount[$0] != nil }
        for mood in sorted {
            if let count = moodCount[mood], count > 0 {
                let pct = Int(Double(count) / Double(total) * 100)
                let barLen = max(1, pct / 10)
                let bar = String(repeating: "▓", count: barLen) + String(repeating: "░", count: max(0, 10 - barLen))
                lines.append("\(mood.emoji) \(mood.label) \(bar) \(count)次（\(pct)%）")
            }
        }

        // Positive vs negative ratio
        let positive = events.filter { $0.mood == .great || $0.mood == .good }.count
        let negative = events.filter { $0.mood == .sad || $0.mood == .stressed || $0.mood == .tired }.count
        if positive > 0 && negative > 0 {
            let ratio = Double(positive) / Double(negative)
            if ratio >= 2.0 {
                lines.append("\n✨ 积极情绪远多于消极，状态不错！")
            } else if ratio >= 1.0 {
                lines.append("\n💪 积极情绪略多，保持住！")
            } else {
                lines.append("\n🤗 消极情绪偏多，多关注自己的身心状态。")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Mood Trend

    private func buildMoodTrend(moodByDay: [String: [MoodType]], dayFmt: DateFormatter) -> String? {
        // Sort days chronologically
        let sortedDays = moodByDay.keys.sorted()
        guard sortedDays.count >= 3 else { return nil }

        // Split into first half and second half
        let mid = sortedDays.count / 2
        let firstHalf = sortedDays.prefix(mid)
        let secondHalf = sortedDays.suffix(from: mid)

        let firstAvg = firstHalf.flatMap { moodByDay[$0] ?? [] }.reduce(0.0) { $0 + moodScore($1) }
            / Double(max(1, firstHalf.flatMap { moodByDay[$0] ?? [] }.count))
        let secondAvg = secondHalf.flatMap { moodByDay[$0] ?? [] }.reduce(0.0) { $0 + moodScore($1) }
            / Double(max(1, secondHalf.flatMap { moodByDay[$0] ?? [] }.count))

        let diff = secondAvg - firstAvg
        if abs(diff) < 0.3 { return nil } // No meaningful trend

        let arrow: String
        let message: String
        if diff > 0.5 {
            arrow = "📈"; message = "心情在逐渐好转，保持这个势头！"
        } else if diff > 0 {
            arrow = "↗️"; message = "心情有轻微改善的趋势。"
        } else if diff < -0.5 {
            arrow = "📉"; message = "心情有下降趋势，注意休息和放松。"
        } else {
            arrow = "↘️"; message = "心情略有波动，多关注自己的状态。"
        }

        return "\(arrow) 趋势：\(message)"
    }

    // MARK: - Health–Mood Correlation

    private func buildHealthCorrelation(moodByDay: [String: [MoodType]], healthByDay: [String: HealthSummary]) -> String? {
        // Classify each day as "positive" or "negative" mood
        var positiveDayHealth: [HealthSummary] = []
        var negativeDayHealth: [HealthSummary] = []

        for (day, moods) in moodByDay {
            guard let health = healthByDay[day], health.hasData else { continue }
            let avgScore = moods.reduce(0.0) { $0 + moodScore($1) } / Double(moods.count)
            if avgScore >= 3.5 {
                positiveDayHealth.append(health)
            } else if avgScore < 2.5 {
                negativeDayHealth.append(health)
            }
        }

        // Need at least 1 day in each group to compare
        guard !positiveDayHealth.isEmpty && !negativeDayHealth.isEmpty else {
            // Even without comparison, show single-group insight
            return buildSingleGroupInsight(
                positiveDays: positiveDayHealth,
                negativeDays: negativeDayHealth
            )
        }

        var insights: [String] = ["🔬 心情与健康数据的关联："]

        // Compare sleep
        let posSleep = avg(positiveDayHealth.map { $0.sleepHours })
        let negSleep = avg(negativeDayHealth.map { $0.sleepHours })
        if posSleep > 0.5 && negSleep > 0.5 {
            let diff = posSleep - negSleep
            if abs(diff) >= 0.5 {
                if diff > 0 {
                    insights.append("  😴 心情好的日子平均睡 \(String(format: "%.1f", posSleep))h，低落时只有 \(String(format: "%.1f", negSleep))h → 睡眠充足时心情更好")
                } else {
                    insights.append("  😴 心情好时睡 \(String(format: "%.1f", posSleep))h，低落时 \(String(format: "%.1f", negSleep))h → 睡太多可能反映低能量状态")
                }
            }
        }

        // Compare exercise
        let posExercise = avg(positiveDayHealth.map { $0.exerciseMinutes })
        let negExercise = avg(negativeDayHealth.map { $0.exerciseMinutes })
        if posExercise > 1 || negExercise > 1 {
            let diff = posExercise - negExercise
            if abs(diff) >= 5 {
                if diff > 0 {
                    insights.append("  🏃 心情好时平均运动 \(Int(posExercise))min，低落时 \(Int(negExercise))min → 运动对心情有积极影响")
                } else {
                    insights.append("  🏃 低落时运动 \(Int(negExercise))min，好心情时 \(Int(posExercise))min → 你可能通过运动来调节情绪")
                }
            }
        }

        // Compare steps
        let posSteps = avg(positiveDayHealth.map { $0.steps })
        let negSteps = avg(negativeDayHealth.map { $0.steps })
        if posSteps > 100 && negSteps > 100 {
            let ratio = posSteps / max(1, negSteps)
            if ratio > 1.3 {
                insights.append("  👟 心情好时日均 \(Int(posSteps)) 步，低落时 \(Int(negSteps)) 步 → 活动量与心情正相关")
            } else if ratio < 0.7 {
                insights.append("  👟 低落时日均 \(Int(negSteps)) 步，好心情时 \(Int(posSteps)) 步")
            }
        }

        // Compare heart rate
        let posHR = avg(positiveDayHealth.filter { $0.heartRate > 0 }.map { $0.heartRate })
        let negHR = avg(negativeDayHealth.filter { $0.heartRate > 0 }.map { $0.heartRate })
        if posHR > 40 && negHR > 40 {
            let diff = abs(posHR - negHR)
            if diff >= 5 {
                let higher = posHR > negHR ? "好心情" : "低落"
                insights.append("  💓 \(higher)时心率偏高（\(Int(max(posHR, negHR))) vs \(Int(min(posHR, negHR))) bpm）")
            }
        }

        guard insights.count > 1 else { return nil } // No meaningful correlations found

        // Add data-driven actionable summary — quantify how much each factor matters for this user
        let sleepDiff = posSleep - negSleep
        let exerciseDiff = posExercise - negExercise
        let sleepSignificant = sleepDiff > 0.5
        let exerciseSignificant = exerciseDiff > 5

        if sleepSignificant && exerciseSignificant {
            // Both matter — tell the user which matters MORE based on their data
            let sleepImpact = posSleep > 0.1 ? sleepDiff / posSleep : 0
            let exerciseImpact = posExercise > 0.1 ? exerciseDiff / posExercise : 0
            if sleepImpact > exerciseImpact * 1.5 {
                insights.append("\n💡 你的数据显示睡眠和运动都有影响，但**睡眠差距更大**（好心情日多睡 \(String(format: "%.1f", sleepDiff))h）。优先保证睡眠。")
            } else if exerciseImpact > sleepImpact * 1.5 {
                insights.append("\n💡 睡眠和运动都有影响，但**运动差距更明显**（好心情日多运动 \(Int(exerciseDiff))min）。心情不好时先动起来。")
            } else {
                insights.append("\n💡 对你来说，充足睡眠（多 \(String(format: "%.1f", sleepDiff))h）+ 适量运动（多 \(Int(exerciseDiff))min）= 更好的心情。")
            }
        } else if sleepSignificant {
            insights.append("\n💡 对你来说，睡眠对心情影响最大——好心情的日子比低落时多睡 \(String(format: "%.1f", sleepDiff)) 小时。")
        } else if exerciseSignificant {
            insights.append("\n💡 运动是你最有效的情绪调节方式——好心情时平均多运动 \(Int(exerciseDiff)) 分钟。心情不好时试试动起来。")
        }

        return insights.joined(separator: "\n")
    }

    /// When only one mood group has health data, still provide useful info.
    private func buildSingleGroupInsight(positiveDays: [HealthSummary], negativeDays: [HealthSummary]) -> String? {
        let days = positiveDays.isEmpty ? negativeDays : positiveDays
        guard days.count >= 2 else { return nil }

        let label = positiveDays.isEmpty ? "低落" : "好心情"
        let avgSleep = avg(days.map { $0.sleepHours })
        let avgExercise = avg(days.map { $0.exerciseMinutes })
        let avgSteps = avg(days.map { $0.steps })

        var lines = ["🔬 \(label)日子的健康数据特征："]
        if avgSleep > 0.5 {
            lines.append("  😴 平均睡眠 \(String(format: "%.1f", avgSleep)) 小时")
        }
        if avgExercise > 1 {
            lines.append("  🏃 平均运动 \(Int(avgExercise)) 分钟")
        }
        if avgSteps > 100 {
            lines.append("  👟 平均步数 \(Int(avgSteps)) 步")
        }
        lines.append("\n📝 记录更多心情数据后，我可以对比好心情和低落时的差异")
        return lines.count > 2 ? lines.joined(separator: "\n") : nil
    }

    // MARK: - Location–Mood Correlation

    private func buildLocationCorrelation(moodByDay: [String: [MoodType]], locationByDay: [String: [LocationRecord]]) -> String? {
        // Track mood scores by place
        var placeScores: [String: (total: Double, count: Int)] = [:]

        for (day, moods) in moodByDay {
            guard let locations = locationByDay[day] else { continue }
            let dayScore = moods.reduce(0.0) { $0 + moodScore($1) } / Double(moods.count)

            // Attribute this day's mood to all visited places
            let uniquePlaces = Set(locations.map { $0.displayName })
            for place in uniquePlaces {
                var existing = placeScores[place] ?? (total: 0, count: 0)
                existing.total += dayScore
                existing.count += 1
                placeScores[place] = existing
            }
        }

        // Need at least 2 places with data
        let scored = placeScores.filter { $0.value.count >= 1 }
            .map { (name: $0.key, avg: $0.value.total / Double($0.value.count), visits: $0.value.count) }
            .sorted { $0.avg > $1.avg }

        guard scored.count >= 2 else { return nil }

        var lines = ["📍 去过的地方与心情："]

        // Show top happy places and low-mood places
        let happyPlaces = scored.prefix(2).filter { $0.avg >= 3.0 }
        let sadPlaces = scored.suffix(2).filter { $0.avg < 3.0 }

        for p in happyPlaces {
            let emoji = p.avg >= 4.0 ? "😄" : "😊"
            lines.append("  \(emoji) \(p.name)：心情指数 \(String(format: "%.1f", p.avg))（去了 \(p.visits) 天）")
        }
        for p in sadPlaces {
            let emoji = p.avg < 2.0 ? "😢" : "😐"
            lines.append("  \(emoji) \(p.name)：心情指数 \(String(format: "%.1f", p.avg))（去了 \(p.visits) 天）")
        }

        // Activity level insight
        let daysWithLocations = Set(locationByDay.keys)
        let daysWithoutLocations = Set(moodByDay.keys).subtracting(daysWithLocations)

        if !daysWithLocations.isEmpty && !daysWithoutLocations.isEmpty {
            let outScore = daysWithLocations.compactMap { moodByDay[$0] }
                .flatMap { $0 }.reduce(0.0) { $0 + moodScore($1) }
            let outCount = daysWithLocations.compactMap { moodByDay[$0] }.flatMap { $0 }.count
            let homeScore = daysWithoutLocations.compactMap { moodByDay[$0] }
                .flatMap { $0 }.reduce(0.0) { $0 + moodScore($1) }
            let homeCount = daysWithoutLocations.compactMap { moodByDay[$0] }.flatMap { $0 }.count

            if outCount > 0 && homeCount > 0 {
                let outAvg = outScore / Double(outCount)
                let homeAvg = homeScore / Double(homeCount)
                let diff = outAvg - homeAvg
                if abs(diff) >= 0.5 {
                    if diff > 0 {
                        lines.append("\n🚶 外出活动的日子心情更好（\(String(format: "%.1f", outAvg)) vs \(String(format: "%.1f", homeAvg))），多出去走走吧！")
                    } else {
                        lines.append("\n🏠 待在家的日子心情更好（\(String(format: "%.1f", homeAvg)) vs \(String(format: "%.1f", outAvg))），适当给自己独处时间")
                    }
                }
            }
        }

        return lines.count > 1 ? lines.joined(separator: "\n") : nil
    }

    // MARK: - Helpers

    private func moodScore(_ mood: MoodType) -> Double {
        switch mood {
        case .great:    return 5.0
        case .good:     return 4.0
        case .neutral:  return 3.0
        case .tired:    return 2.0
        case .stressed: return 1.5
        case .sad:      return 1.0
        }
    }

    private func avg(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    // MARK: - Personalized Empathy

    /// Empathy response container.
    private struct EmpathyResult {
        let text: String
        let isNegative: Bool
    }

    /// Build empathy that mirrors the user's actual emotion word instead of a generic template.
    private func buildPersonalizedEmpathy(query: String) -> EmpathyResult {
        // Fatigue / Exhaustion / Pressure
        if SkillRouter.containsAny(query, ["累", "疲惫"]) {
            return EmpathyResult(text: "听起来你很疲惫，辛苦了 🫂", isNegative: true)
        }
        if SkillRouter.containsAny(query, ["压力", "崩溃", "扛不住", "受不了"]) {
            return EmpathyResult(text: "压力大的时候能说出来就好，我在听 🫂", isNegative: true)
        }
        // Anxiety
        if SkillRouter.containsAny(query, ["焦虑", "紧张", "不安", "慌"]) {
            return EmpathyResult(text: "感受到你现在有些焦虑，先深呼吸一下 🫂", isNegative: true)
        }
        // Sadness / Low mood
        if SkillRouter.containsAny(query, ["难过", "伤心", "沮丧", "郁闷", "低落", "丧"]) {
            return EmpathyResult(text: "抱抱你，不开心的时候能说出来就好 🫂", isNegative: true)
        }
        // Frustration / Anger
        if SkillRouter.containsAny(query, ["烦", "恼火", "生气", "愤怒"]) {
            return EmpathyResult(text: "听起来今天遇到了烦心事 😮‍💨", isNegative: true)
        }
        // Loneliness
        if SkillRouter.containsAny(query, ["孤独", "寂寞", "空虚", "无聊"]) {
            return EmpathyResult(text: "我陪着你呢，有什么想聊的都可以说 🤗", isNegative: true)
        }
        // Positive emotions
        if SkillRouter.containsAny(query, ["开心", "高兴", "快乐", "兴奋", "激动"]) {
            return EmpathyResult(text: "能感受到你的开心！什么好事？😊", isNegative: false)
        }
        if SkillRouter.containsAny(query, ["满足", "充实", "舒服", "放松", "惬意", "愉快"]) {
            return EmpathyResult(text: "这种状态很好，享受当下 ☀️", isNegative: false)
        }
        if SkillRouter.containsAny(query, ["平静", "安心"]) {
            return EmpathyResult(text: "内心平静是最好的状态 🌿", isNegative: false)
        }
        return EmpathyResult(text: "我听到你了 😊", isNegative: false)
    }

    /// Extract the most prominent emotion word from the query for natural record suggestions.
    private func extractDominantEmotion(from query: String) -> String? {
        // Try to extract a natural phrase segment containing the emotion
        let emotionPhrases: [(keywords: [String], phrase: String)] = [
            (["好累", "很累", "太累"], "今天好累"),
            (["累"], "有点累"),
            (["疲惫"], "感觉疲惫"),
            (["压力大", "压力好大"], "压力大"),
            (["压力"], "有压力"),
            (["崩溃"], "快崩溃了"),
            (["焦虑"], "有些焦虑"),
            (["紧张"], "有点紧张"),
            (["难过"], "有点难过"),
            (["伤心"], "很伤心"),
            (["郁闷", "低落", "丧", "沮丧"], "心情低落"),
            (["烦", "烦躁"], "有点烦"),
            (["开心", "高兴"], "很开心"),
            (["兴奋", "激动"], "很兴奋"),
            (["放松", "舒服", "惬意"], "很放松"),
            (["满足", "充实"], "很充实"),
            (["无聊"], "有点无聊"),
            (["孤独", "寂寞"], "感觉孤独"),
        ]
        for ep in emotionPhrases {
            if ep.keywords.contains(where: { query.contains($0) }) {
                return ep.phrase
            }
        }
        return nil
    }

    // MARK: - Calendar-Aware Emotional Context

    /// Check today's calendar for patterns that might explain the user's emotional state.
    /// "好累" + 6 back-to-back meetings → "你今天有6个会议，难怪会觉得累"
    private func buildCalendarContextForEmotion(context: SkillContext, isNegative: Bool) -> String? {
        guard context.calendarService.isAuthorized else { return nil }

        let cal = Calendar.current
        let now = Date()
        let dayStart = cal.startOfDay(for: now)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? now
        let events = context.calendarService.fetchEvents(from: dayStart, to: dayEnd)

        let timedEvents = events.filter { !$0.isAllDay }
        guard !timedEvents.isEmpty else { return nil }

        let totalMinutes = timedEvents.reduce(0.0) { $0 + $1.duration } / 60.0

        // Detect back-to-back meetings
        let sorted = timedEvents.sorted { $0.startDate < $1.startDate }
        var backToBackCount = 0
        for i in 0..<(sorted.count - 1) {
            let gap = sorted[i + 1].startDate.timeIntervalSince(sorted[i].endDate) / 60
            if gap < 15 { backToBackCount += 1 }
        }

        // Past events (already finished)
        let pastEvents = timedEvents.filter { $0.endDate <= now }
        let pastMinutes = pastEvents.reduce(0.0) { $0 + $1.duration } / 60.0

        var clues: [String] = []

        if isNegative {
            // Heavy meeting day explanation
            if timedEvents.count >= 5 && totalMinutes >= 300 {
                clues.append("📅 今天有 \(timedEvents.count) 个会议、约 \(Int(totalMinutes / 60)) 小时日程，节奏确实紧张")
            } else if timedEvents.count >= 4 {
                clues.append("📅 今天安排了 \(timedEvents.count) 个会议")
            }

            // Already spent many hours in meetings
            if pastMinutes >= 180 && pastEvents.count >= 3 {
                clues.append("📅 到现在已经开了 \(pastEvents.count) 个会、\(Int(pastMinutes / 60)) 小时，难怪会累")
            }

            // Back-to-back meetings without breaks
            if backToBackCount >= 2 {
                clues.append("⚠️ 有 \(backToBackCount + 1) 个会议几乎连轴转，中间没什么休息")
            }

            // Still have meetings ahead
            let upcoming = timedEvents.filter { $0.startDate > now }
            if !upcoming.isEmpty && pastEvents.count >= 2 {
                clues.append("📌 后面还有 \(upcoming.count) 个安排，记得抽空休息一下")
            }
        } else {
            // Positive: light day might explain good mood
            if timedEvents.count <= 2 && totalMinutes < 120 {
                clues.append("📅 今天日程轻松，只有 \(timedEvents.count) 个安排，难怪心情不错")
            }
        }

        guard !clues.isEmpty else { return nil }
        return "📋 看了下你今天的日程：\n" + clues.map { "  \($0)" }.joined(separator: "\n")
    }

    // MARK: - Health-Aware Emotional Context

    /// When a user expresses an emotion (e.g. "好累"), check their recent health data
    /// to provide possible explanations — connecting feelings to real body signals.
    private func buildHealthContextForEmotion(summaries: [HealthSummary], isNegative: Bool, query: String) -> String? {
        guard !summaries.isEmpty else { return nil }

        let today = summaries.first(where: { Calendar.current.isDateInToday($0.date) })
        let yesterday = summaries.first(where: { Calendar.current.isDateInYesterday($0.date) })
        // Use today's data first; fall back to yesterday if today hasn't accumulated yet
        let recent = today?.hasData == true ? today : yesterday

        var clues: [String] = []

        let isTiredQuery = SkillRouter.containsAny(query, ["累", "疲惫", "压力", "崩溃", "扛不住", "没精神", "困"])

        // 1. Sleep deficit — most common cause of fatigue
        if let sleep = recent, sleep.sleepHours > 0 {
            if sleep.sleepHours < 6 {
                clues.append("😴 你昨晚只睡了 \(String(format: "%.1f", sleep.sleepHours)) 小时，睡眠严重不足可能是主要原因")
            } else if sleep.sleepHours < 7 && isTiredQuery {
                clues.append("😴 昨晚睡了 \(String(format: "%.1f", sleep.sleepHours)) 小时，略低于建议的 7 小时")
            } else if sleep.sleepHours >= 7 && !isNegative {
                clues.append("😴 昨晚睡了 \(String(format: "%.1f", sleep.sleepHours)) 小时，休息充足！")
            }
        }

        // Accumulated sleep debt over recent days
        let sleepDays = summaries.filter { $0.sleepHours > 0 }
        if sleepDays.count >= 2 {
            let totalDebt = sleepDays.reduce(0.0) { $0 + max(0, 7.0 - $1.sleepHours) }
            if totalDebt >= 3 && isTiredQuery {
                clues.append("💸 最近 \(sleepDays.count) 天累计少睡 \(String(format: "%.1f", totalDebt)) 小时，睡眠债务在积累")
            }
        }

        // 2. High exercise load — may explain physical tiredness
        if let health = recent {
            if health.exerciseMinutes > 60 && isTiredQuery {
                clues.append("🏃 \(Calendar.current.isDateInToday(health.date) ? "今天" : "昨天")运动了 \(Int(health.exerciseMinutes)) 分钟，运动量较大，身体可能需要恢复")
            } else if health.exerciseMinutes > 30 && !isNegative {
                clues.append("🏃 \(Calendar.current.isDateInToday(health.date) ? "今天" : "昨天")运动了 \(Int(health.exerciseMinutes)) 分钟，保持运动是好心情的助力")
            }

            if health.steps > 15000 && isTiredQuery {
                clues.append("👟 已经走了 \(Int(health.steps).formatted()) 步，活动量很大")
            }
        }

        // 3. HRV — low HRV indicates stress / poor recovery
        if let health = recent, health.hrv > 0 {
            // Check against recent average for personal baseline
            let hrvDays = summaries.filter { $0.hrv > 0 }
            if hrvDays.count >= 2 {
                let avgHRV = hrvDays.reduce(0) { $0 + $1.hrv } / Double(hrvDays.count)
                if health.hrv < avgHRV * 0.8 && isNegative {
                    clues.append("📳 HRV \(Int(health.hrv))ms，低于你近期均值 \(Int(avgHRV))ms — 身体恢复状态偏低")
                } else if health.hrv > avgHRV * 1.1 && !isNegative {
                    clues.append("📳 HRV \(Int(health.hrv))ms，高于均值 — 身体恢复状态良好")
                }
            }
        }

        // 4. Resting heart rate — elevated RHR can indicate fatigue or stress
        if let health = recent, health.restingHeartRate > 0 {
            let rhrDays = summaries.filter { $0.restingHeartRate > 0 }
            if rhrDays.count >= 2 {
                let avgRHR = rhrDays.reduce(0) { $0 + $1.restingHeartRate } / Double(rhrDays.count)
                if health.restingHeartRate > avgRHR + 5 && isNegative {
                    clues.append("🫀 静息心率 \(Int(health.restingHeartRate))bpm，高于近期均值 \(Int(avgRHR))bpm — 可能反映身体压力")
                }
            }
        }

        guard !clues.isEmpty else { return nil }

        var result = "🔍 看了下你最近的健康数据：\n" + clues.map { "  \($0)" }.joined(separator: "\n")

        // Add actionable suggestion based on findings
        if isTiredQuery {
            let hasSleepIssue = clues.contains(where: { $0.contains("睡") })
            let hasExerciseLoad = clues.contains(where: { $0.contains("运动") || $0.contains("步") })
            if hasSleepIssue && hasExerciseLoad {
                result += "\n\n💡 睡眠不足 + 高运动量，身体确实需要休息。今晚试着早睡 30 分钟？"
            } else if hasSleepIssue {
                result += "\n\n💡 睡眠不足可能是疲惫的主因，今晚早点休息吧。"
            } else if hasExerciseLoad {
                result += "\n\n💡 活动量较大，记得补充水分和营养，让身体恢复。"
            }
        }

        return result
    }
}

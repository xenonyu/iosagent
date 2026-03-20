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
                                  "放松", "舒服", "丧", "满足", "充实",
                                  // Internet slang
                                  "emo", "破防", "裂开", "麻了", "心塞", "摆烂", "躺平",
                                  // Colloquial
                                  "闹心", "心烦", "烦闷", "揪心", "心累", "窒息",
                                  "憋屈", "委屈", "抓狂", "暴躁",
                                  // Physical-emotional
                                  "虚弱", "乏力", "没力气", "浑身无力", "提不起劲", "不在状态",
                                  // Existential
                                  "迷茫", "困惑", "纠结", "不知所措", "彷徨",
                                  // Positive colloquial
                                  "舒坦", "治愈", "感恩", "感动", "知足"]
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

    /// Emotion intensity level — detected from Chinese modifiers surrounding the emotion word.
    private enum EmotionIntensity {
        case mild      // 有点、略微、稍微
        case moderate  // no modifier, or neutral modifier
        case strong    // 很、好、太、非常、特别、超级、真的、实在
        case extreme   // 累死了、崩溃、受不了、要疯了、扛不住 (hyperbolic expressions)
    }

    /// Detect emotion intensity from Chinese modifier patterns.
    /// e.g. "有点累" → mild, "累" → moderate, "好累" → strong, "累死了" → extreme
    private func detectIntensity(query: String, emotionWord: String) -> EmotionIntensity {
        // Extreme: hyperbolic suffixes or inherently extreme words
        let extremeSuffixes = ["死了", "死我了", "炸了", "爆了", "透了", "惨了", "坏了"]
        for suffix in extremeSuffixes {
            if query.contains(emotionWord + suffix) { return .extreme }
        }
        let extremeStandalone = ["崩溃", "扛不住", "受不了", "要疯了", "快疯了", "撑不住", "顶不住"]
        if extremeStandalone.contains(where: { query.contains($0) }) { return .extreme }

        // Strong: intensity amplifiers before the emotion word
        let strongPrefixes = ["很", "好", "太", "非常", "特别", "超", "超级", "真的", "实在",
                              "相当", "极其", "十分", "万分", "无比", "格外"]
        for prefix in strongPrefixes {
            if query.contains(prefix + emotionWord) { return .strong }
        }
        // Also catch "太…了" pattern (e.g. "太累了")
        if query.contains("太" + emotionWord) { return .strong }

        // Mild: softening modifiers
        let mildPrefixes = ["有点", "有些", "略微", "稍微", "稍稍", "一点", "一丝", "些许", "多少有点"]
        for prefix in mildPrefixes {
            if query.contains(prefix + emotionWord) || query.contains(prefix + "儿" + emotionWord) { return .mild }
        }
        // "不太" pattern (e.g. "不太开心" = mildly negative)
        if query.contains("不太" + emotionWord) { return .mild }

        return .moderate
    }

    /// Build empathy that mirrors the user's actual emotion word AND intensity level.
    /// "有点累" gets gentle acknowledgment; "累死了" gets strong validation.
    private func buildPersonalizedEmpathy(query: String) -> EmpathyResult {
        // Fatigue / Exhaustion
        if SkillRouter.containsAny(query, ["累", "疲惫", "没精神", "困"]) {
            let intensity = detectIntensity(query: query, emotionWord: query.contains("疲惫") ? "疲惫" : "累")
            switch intensity {
            case .mild:
                return EmpathyResult(text: "有点累了？注意休息 ☕", isNegative: true)
            case .moderate:
                return EmpathyResult(text: "听起来你挺累的，辛苦了 🫂", isNegative: true)
            case .strong:
                return EmpathyResult(text: "真的辛苦了，你已经很努力了 🫂", isNegative: true)
            case .extreme:
                return EmpathyResult(text: "能感觉到你已经筋疲力尽了，先别硬撑，让自己喘口气 🫂", isNegative: true)
            }
        }
        // Pressure / Breakdown
        if SkillRouter.containsAny(query, ["压力", "崩溃", "扛不住", "受不了"]) {
            let intensity = detectIntensity(query: query, emotionWord: "压力")
            switch intensity {
            case .mild:
                return EmpathyResult(text: "有些压力是正常的，能意识到就好 💪", isNegative: true)
            case .moderate:
                return EmpathyResult(text: "压力大的时候能说出来就好，我在听 🫂", isNegative: true)
            case .strong, .extreme:
                return EmpathyResult(text: "压力大到这种程度真的不容易，你不用一个人扛着 🫂\n先放下手头的事，深呼吸几次。", isNegative: true)
            }
        }
        // Anxiety
        if SkillRouter.containsAny(query, ["焦虑", "紧张", "不安", "慌"]) {
            let intensity = detectIntensity(query: query, emotionWord: query.contains("焦虑") ? "焦虑" : "紧张")
            switch intensity {
            case .mild:
                return EmpathyResult(text: "有点紧张？没关系，这很正常 😊", isNegative: true)
            case .moderate:
                return EmpathyResult(text: "感受到你现在有些焦虑，先深呼吸一下 🫂", isNegative: true)
            case .strong, .extreme:
                return EmpathyResult(text: "焦虑感很强的时候，试着把注意力放到呼吸上，一呼一吸 🫂\n你现在是安全的。", isNegative: true)
            }
        }
        // Sadness / Low mood
        if SkillRouter.containsAny(query, ["难过", "伤心", "沮丧", "郁闷", "低落", "丧"]) {
            let coreWord = ["难过", "伤心", "沮丧", "郁闷", "低落", "丧"].first(where: { query.contains($0) }) ?? "难过"
            let intensity = detectIntensity(query: query, emotionWord: coreWord)
            switch intensity {
            case .mild:
                return EmpathyResult(text: "心情有点低？没事的，每个人都会有这样的时候 🤗", isNegative: true)
            case .moderate:
                return EmpathyResult(text: "抱抱你，不开心的时候能说出来就好 🫂", isNegative: true)
            case .strong, .extreme:
                return EmpathyResult(text: "听到你这么难过，真的很心疼 🫂\n想哭就哭出来吧，不用忍着。", isNegative: true)
            }
        }
        // Frustration / Anger
        if SkillRouter.containsAny(query, ["烦", "恼火", "生气", "愤怒"]) {
            let coreWord = ["愤怒", "恼火", "生气", "烦"].first(where: { query.contains($0) }) ?? "烦"
            let intensity = detectIntensity(query: query, emotionWord: coreWord)
            switch intensity {
            case .mild:
                return EmpathyResult(text: "有点不顺心？说出来就好了 😮‍💨", isNegative: true)
            case .moderate:
                return EmpathyResult(text: "听起来今天遇到了烦心事 😮‍💨", isNegative: true)
            case .strong, .extreme:
                return EmpathyResult(text: "能感受到你真的很生气 😤 这种感受完全可以理解。", isNegative: true)
            }
        }
        // Loneliness
        if SkillRouter.containsAny(query, ["孤独", "寂寞", "空虚", "无聊"]) {
            let intensity = detectIntensity(query: query, emotionWord: query.contains("孤独") ? "孤独" : "无聊")
            switch intensity {
            case .mild:
                return EmpathyResult(text: "有点无聊？来跟我聊聊天吧 😊", isNegative: true)
            case .moderate:
                return EmpathyResult(text: "我陪着你呢，有什么想聊的都可以说 🤗", isNegative: true)
            case .strong, .extreme:
                return EmpathyResult(text: "孤独的感觉很难受，但你不是一个人 🫂\n想聊什么都可以，我一直在。", isNegative: true)
            }
        }
        // Positive emotions
        if SkillRouter.containsAny(query, ["开心", "高兴", "快乐", "兴奋", "激动"]) {
            let coreWord = ["开心", "高兴", "快乐", "兴奋", "激动"].first(where: { query.contains($0) }) ?? "开心"
            let intensity = detectIntensity(query: query, emotionWord: coreWord)
            switch intensity {
            case .mild:
                return EmpathyResult(text: "有好事发生？😊", isNegative: false)
            case .moderate:
                return EmpathyResult(text: "能感受到你的开心！什么好事？😊", isNegative: false)
            case .strong, .extreme:
                return EmpathyResult(text: "哇，看得出你超开心的！🎉 快说说发生了什么好事！", isNegative: false)
            }
        }
        if SkillRouter.containsAny(query, ["满足", "充实", "舒服", "放松", "惬意", "愉快"]) {
            let coreWord = ["满足", "充实", "舒服", "放松", "惬意", "愉快"].first(where: { query.contains($0) }) ?? "舒服"
            let intensity = detectIntensity(query: query, emotionWord: coreWord)
            switch intensity {
            case .mild:
                return EmpathyResult(text: "不错的状态 ☀️", isNegative: false)
            case .moderate:
                return EmpathyResult(text: "这种状态很好，享受当下 ☀️", isNegative: false)
            case .strong, .extreme:
                return EmpathyResult(text: "这种感觉太好了！值得好好记住这一刻 🌟", isNegative: false)
            }
        }
        if SkillRouter.containsAny(query, ["平静", "安心"]) {
            return EmpathyResult(text: "内心平静是最好的状态 🌿", isNegative: false)
        }
        // Internet slang / youth emotional expressions
        if SkillRouter.containsAny(query, ["emo", "破防", "裂开"]) {
            let intensity = detectIntensity(query: query, emotionWord: "emo")
            switch intensity {
            case .mild:
                return EmpathyResult(text: "有点 emo？没关系，情绪波动很正常 🫂", isNegative: true)
            case .moderate:
                return EmpathyResult(text: "破防了？说明这件事对你很重要 🫂 想聊聊吗？", isNegative: true)
            case .strong, .extreme:
                return EmpathyResult(text: "听起来真的绷不住了 🫂 先允许自己难过一会儿，不用假装没事。", isNegative: true)
            }
        }
        if SkillRouter.containsAny(query, ["麻了", "无语", "心塞"]) {
            let intensity = detectIntensity(query: query, emotionWord: query.contains("心塞") ? "心塞" : "无语")
            switch intensity {
            case .mild:
                return EmpathyResult(text: "有点无语？哎，有些事确实让人没话说 😮‍💨", isNegative: true)
            case .moderate:
                return EmpathyResult(text: "心塞的感觉不好受，说出来会好一些 🫂", isNegative: true)
            case .strong, .extreme:
                return EmpathyResult(text: "麻了说明已经承受太多了，先给自己放个假吧 🫂", isNegative: true)
            }
        }
        if SkillRouter.containsAny(query, ["摆烂", "躺平"]) {
            return EmpathyResult(text: "想躺平的时候就躺一会儿 🛋️ 休息够了再说，不用强迫自己。", isNegative: true)
        }
        // Colloquial negative: 闹心/心烦/揪心/心累/窒息
        if SkillRouter.containsAny(query, ["闹心", "心烦", "烦闷", "揪心", "心累"]) {
            let coreWord = ["心累", "揪心", "闹心", "心烦", "烦闷"].first(where: { query.contains($0) }) ?? "心烦"
            let intensity = detectIntensity(query: query, emotionWord: coreWord)
            switch intensity {
            case .mild:
                return EmpathyResult(text: "心里有点不舒服？跟我说说 🫂", isNegative: true)
            case .moderate:
                return EmpathyResult(text: "心累的时候最需要的不是鼓励，是被理解 🫂 我在听。", isNegative: true)
            case .strong, .extreme:
                return EmpathyResult(text: "心里堵得慌对吧？你已经很不容易了 🫂\n先什么都别想，让自己歇一歇。", isNegative: true)
            }
        }
        if SkillRouter.containsAny(query, ["窒息"]) {
            return EmpathyResult(text: "喘不过气的感觉很难受 🫂 先深呼吸，一切会好起来的。", isNegative: true)
        }
        // Grievance: 憋屈/委屈
        if SkillRouter.containsAny(query, ["憋屈", "委屈"]) {
            let intensity = detectIntensity(query: query, emotionWord: query.contains("委屈") ? "委屈" : "憋屈")
            switch intensity {
            case .mild:
                return EmpathyResult(text: "有点委屈？你的感受是对的 🫂", isNegative: true)
            case .moderate:
                return EmpathyResult(text: "委屈的时候就别憋着了，想说就说 🫂", isNegative: true)
            case .strong, .extreme:
                return EmpathyResult(text: "受了这么大委屈，真的辛苦了 🫂 你值得被好好对待。", isNegative: true)
            }
        }
        // Rage: 抓狂/暴躁
        if SkillRouter.containsAny(query, ["抓狂", "暴躁"]) {
            let intensity = detectIntensity(query: query, emotionWord: query.contains("暴躁") ? "暴躁" : "抓狂")
            switch intensity {
            case .mild:
                return EmpathyResult(text: "有点抓狂？先离开让你烦的事一会儿 😮‍💨", isNegative: true)
            case .moderate:
                return EmpathyResult(text: "快抓狂了？先让自己冷静一下，别做冲动的决定 😤", isNegative: true)
            case .strong, .extreme:
                return EmpathyResult(text: "暴躁说明底线被触碰了 😤 你的愤怒是合理的，先深呼吸几次。", isNegative: true)
            }
        }
        // Physical-emotional: 虚弱/乏力/没力气/提不起劲/不在状态
        if SkillRouter.containsAny(query, ["虚弱", "乏力", "没力气", "浑身无力", "提不起劲", "不在状态"]) {
            let intensity = detectIntensity(query: query, emotionWord: "虚弱")
            switch intensity {
            case .mild:
                return EmpathyResult(text: "感觉没什么力气？可能需要好好休息一下 🫂", isNegative: true)
            case .moderate:
                return EmpathyResult(text: "身体在发信号了，可能最近太操劳了 🫂 照顾好自己。", isNegative: true)
            case .strong, .extreme:
                return EmpathyResult(text: "浑身无力的感觉很不好受 🫂 身体是最诚实的，该休息就休息。", isNegative: true)
            }
        }
        // Existential / confused: 迷茫/困惑/纠结/不知所措/彷徨
        if SkillRouter.containsAny(query, ["迷茫", "困惑", "纠结", "犹豫", "不知所措", "彷徨"]) {
            let coreWord = ["迷茫", "困惑", "纠结", "犹豫", "不知所措", "彷徨"].first(where: { query.contains($0) }) ?? "迷茫"
            let intensity = detectIntensity(query: query, emotionWord: coreWord)
            switch intensity {
            case .mild:
                return EmpathyResult(text: "有点纠结？慢慢想，不急 🤗", isNegative: true)
            case .moderate:
                return EmpathyResult(text: "迷茫的时候说明你在思考，这本身就是好事 🌱", isNegative: true)
            case .strong, .extreme:
                return EmpathyResult(text: "不知所措的感觉很难熬 🫂 不用急着找答案，有些事需要时间。", isNegative: true)
            }
        }
        // Positive colloquial: 舒坦/治愈/感恩/感动/知足/美滋滋
        if SkillRouter.containsAny(query, ["舒坦", "治愈", "感恩", "感动", "知足", "美滋滋"]) {
            let coreWord = ["感动", "感恩", "治愈", "知足", "舒坦", "美滋滋"].first(where: { query.contains($0) }) ?? "舒坦"
            let intensity = detectIntensity(query: query, emotionWord: coreWord)
            switch intensity {
            case .mild:
                return EmpathyResult(text: "不错的心情 ☀️ 记住这个感觉。", isNegative: false)
            case .moderate:
                return EmpathyResult(text: "这种感觉真好 🌟 生活里这样的时刻值得珍惜。", isNegative: false)
            case .strong, .extreme:
                return EmpathyResult(text: "能被治愈、能感动，说明你是个有温度的人 🌟", isNegative: false)
            }
        }
        return EmpathyResult(text: "我听到你了 😊", isNegative: false)
    }

    /// Extract the most prominent emotion word from the query for natural record suggestions.
    /// Uses intensity detection so "有点累" suggests "有点累", "累死了" suggests "累死了".
    private func extractDominantEmotion(from query: String) -> String? {
        // Each entry: (core emotion word, mild phrase, moderate phrase, strong/extreme phrase)
        let emotionMap: [(words: [String], mild: String, moderate: String, strong: String)] = [
            (["累", "疲惫", "困", "没精神"],  "有点累",     "今天挺累的",   "累到不行"),
            (["压力"],                        "有些压力",    "压力挺大",     "压力爆表"),
            (["崩溃", "扛不住", "受不了"],     "快崩溃了",    "快崩溃了",     "快崩溃了"),
            (["焦虑", "不安"],                "有些焦虑",    "比较焦虑",     "焦虑到不行"),
            (["紧张", "慌"],                  "有点紧张",    "很紧张",       "紧张到不行"),
            (["难过", "伤心"],                "有点难过",    "很难过",       "特别难过"),
            (["沮丧", "郁闷", "低落", "丧"],   "心情有点低", "心情低落",     "心情糟透了"),
            (["烦", "烦躁", "恼火"],          "有点烦",      "很烦",        "烦透了"),
            (["生气", "愤怒"],                "有点生气",    "很生气",       "气炸了"),
            (["孤独", "寂寞"],                "有点孤独",    "感觉孤独",     "特别孤独"),
            (["空虚", "无聊"],                "有点无聊",    "很无聊",       "无聊到不行"),
            (["开心", "高兴", "快乐"],         "有点开心",    "很开心",       "超级开心"),
            (["兴奋", "激动"],                "有点兴奋",    "很兴奋",       "超级兴奋"),
            (["放松", "舒服", "惬意"],         "挺放松",     "很放松",       "超级放松"),
            (["满足", "充实"],                "挺充实",      "很充实",       "特别充实"),
            // Internet slang
            (["emo", "破防", "裂开"],          "有点 emo",   "破防了",       "彻底破防"),
            (["麻了", "无语", "心塞"],          "有点无语",    "心塞了",       "彻底麻了"),
            (["摆烂", "躺平"],                "想躺平",      "想摆烂",       "彻底躺平"),
            // Colloquial negative
            (["闹心", "心烦", "烦闷", "揪心", "心累"], "有点心累", "挺心累的",   "心累到不行"),
            (["窒息"],                        "有点窒息",    "快窒息了",     "要窒息了"),
            (["憋屈", "委屈"],                "有点委屈",    "很委屈",       "委屈到不行"),
            (["抓狂", "暴躁"],                "有点抓狂",    "快抓狂了",     "彻底暴躁"),
            // Physical-emotional
            (["虚弱", "乏力", "没力气", "浑身无力", "提不起劲", "不在状态"],
                                              "有点没力气",  "浑身没劲",     "完全提不起劲"),
            // Existential
            (["迷茫", "困惑", "纠结", "犹豫", "不知所措", "彷徨"],
                                              "有点迷茫",    "很迷茫",       "完全不知所措"),
            // Positive colloquial
            (["舒坦", "治愈", "美滋滋"],        "挺舒坦",     "很治愈",       "超级治愈"),
            (["感恩", "感动", "知足"],          "有点感动",    "很感动",       "特别感动"),
        ]

        for entry in emotionMap {
            guard let matchedWord = entry.words.first(where: { query.contains($0) }) else { continue }
            let intensity = detectIntensity(query: query, emotionWord: matchedWord)
            switch intensity {
            case .mild:    return entry.mild
            case .moderate: return entry.moderate
            case .strong, .extreme: return entry.strong
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

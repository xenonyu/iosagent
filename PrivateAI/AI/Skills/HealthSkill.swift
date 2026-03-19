import Foundation

/// Handles exercise, health metrics, step streaks, and week-over-week comparison.
/// Provides trend analysis and personalized insights instead of raw numbers.
struct HealthSkill: ClawSkill {

    let id = "health"

    func canHandle(intent: QueryIntent) -> Bool {
        switch intent {
        case .exercise, .health, .streak, .comparison:
            return true
        default:
            return false
        }
    }

    func execute(intent: QueryIntent, context: SkillContext, completion: @escaping (String) -> Void) {
        switch intent {
        case .exercise(let range):
            respondExercise(range: range, context: context, completion: completion)
        case .health(let metric, let range):
            respondHealth(metric: metric, range: range, context: context, completion: completion)
        case .streak:
            respondStreak(context: context, completion: completion)
        case .comparison:
            respondComparison(context: context, completion: completion)
        default:
            break
        }
    }

    // MARK: - Exercise

    private func respondExercise(range: QueryTimeRange, context: SkillContext, completion: @escaping (String) -> Void) {
        let interval = range.interval
        let events = CDLifeEvent.fetch(from: interval.start, to: interval.end, in: context.coreDataContext)
            .filter { $0.category == .health }

        context.healthService.fetchSummaries(days: 14) { allSummaries in
            let filtered = allSummaries.filter { interval.contains($0.date) }
            var lines: [String] = ["🏃 \(range.label)的运动数据\n"]

            if filtered.isEmpty && events.isEmpty {
                lines.append("暂无运动记录。开启健康权限后可以自动追踪你的运动数据。")
                completion(lines.joined(separator: "\n"))
                return
            }

            let daysWithData = filtered.filter { $0.hasData }
            guard !daysWithData.isEmpty else {
                lines.append("这段时间暂无运动数据记录。")
                completion(lines.joined(separator: "\n"))
                return
            }

            let totalSteps = filtered.reduce(0) { $0 + $1.steps }
            let totalExercise = filtered.reduce(0) { $0 + $1.exerciseMinutes }
            let totalCalories = filtered.reduce(0) { $0 + $1.activeCalories }
            let totalDistance = filtered.reduce(0) { $0 + $1.distanceKm }
            let dayCount = Double(max(daysWithData.count, 1))

            // Core metrics
            if totalSteps > 0 {
                lines.append("👟 总步数：\(Int(totalSteps).formatted()) 步（日均 \(Int(totalSteps / dayCount).formatted())）")
            }
            if totalDistance > 0.1 {
                lines.append("📏 总距离：\(String(format: "%.1f", totalDistance)) 公里")
            }
            if totalExercise > 0 {
                lines.append("⏱ 运动时长：\(Int(totalExercise)) 分钟（日均 \(Int(totalExercise / dayCount))）")
            }
            if totalCalories > 0 {
                lines.append("🔥 消耗热量：\(Int(totalCalories).formatted()) 千卡")
            }
            let totalFlights = filtered.reduce(0) { $0 + $1.flightsClimbed }
            if totalFlights > 0 {
                lines.append("🏢 爬楼：\(Int(totalFlights)) 层")
            }

            // Best day highlight
            if daysWithData.count > 1 {
                if let bestDay = daysWithData.max(by: { $0.steps < $1.steps }), bestDay.steps > 0 {
                    let fmt = DateFormatter()
                    fmt.dateFormat = "M月d日(E)"
                    fmt.locale = Locale(identifier: "zh_CN")
                    lines.append("\n🏆 最活跃的一天：\(fmt.string(from: bestDay.date))")
                    lines.append("   \(Int(bestDay.steps).formatted()) 步 · \(Int(bestDay.exerciseMinutes)) 分钟运动")
                }
            }

            // Trend insight (compare first half vs second half of the period)
            if daysWithData.count >= 4 {
                let mid = daysWithData.count / 2
                let recentHalf = Array(daysWithData.prefix(mid))
                let olderHalf = Array(daysWithData.suffix(from: mid))
                let recentAvg = recentHalf.reduce(0) { $0 + $1.steps } / Double(recentHalf.count)
                let olderAvg = olderHalf.reduce(0) { $0 + $1.steps } / Double(olderHalf.count)

                if olderAvg > 0 {
                    let changePercent = ((recentAvg - olderAvg) / olderAvg) * 100
                    if abs(changePercent) >= 10 {
                        let trend = changePercent > 0
                            ? "📈 步数呈上升趋势（+\(Int(changePercent))%），保持这个势头！"
                            : "📉 步数略有下降（\(Int(changePercent))%），试试每天多走一站路？"
                        lines.append("\n\(trend)")
                    } else {
                        lines.append("\n📊 步数保持稳定，节奏不错！")
                    }
                }
            }

            // Related life events
            if !events.isEmpty {
                lines.append("\n📝 相关记录：")
                events.prefix(5).forEach { lines.append("• \($0.timestamp.shortDisplay)：\($0.title)") }
            }

            completion(lines.joined(separator: "\n"))
        }
    }

    // MARK: - Health Metric

    private func respondHealth(metric: String, range: QueryTimeRange, context: SkillContext, completion: @escaping (String) -> Void) {
        context.healthService.fetchSummaries(days: 14) { allSummaries in
            let interval = range.interval
            let filtered = allSummaries.filter { interval.contains($0.date) }
            let withData = filtered.filter { $0.hasData }

            guard !withData.isEmpty else {
                completion("📊 暂无健康数据。\n请在设置中开启健康权限以获取详细数据。")
                return
            }

            switch metric {
            case "sleep":
                respondSleep(summaries: withData, range: range, completion: completion)
            case "heartRate":
                respondHeartRate(summaries: withData, range: range, completion: completion)
            case "steps":
                respondSteps(summaries: withData, range: range, completion: completion)
            case "flights":
                respondFlights(summaries: withData, range: range, completion: completion)
            case "distance":
                respondDistance(summaries: withData, range: range, completion: completion)
            default:
                respondOverview(summaries: withData, range: range, completion: completion)
            }
        }
    }

    private func respondSleep(summaries: [HealthSummary], range: QueryTimeRange, completion: @escaping (String) -> Void) {
        let sleepDays = summaries.filter { $0.sleepHours > 0 }
        guard !sleepDays.isEmpty else {
            completion("😴 \(range.label)暂无睡眠记录。\n请确保 iPhone 或 Apple Watch 的睡眠追踪已开启。")
            return
        }

        var lines: [String] = ["😴 \(range.label)的睡眠分析\n"]
        let avg = sleepDays.reduce(0) { $0 + $1.sleepHours } / Double(sleepDays.count)
        let maxSleep = sleepDays.max(by: { $0.sleepHours < $1.sleepHours })!
        let minSleep = sleepDays.min(by: { $0.sleepHours < $1.sleepHours })!

        lines.append("💤 平均睡眠：\(String(format: "%.1f", avg)) 小时")
        lines.append("📊 波动范围：\(String(format: "%.1f", minSleep.sleepHours))~\(String(format: "%.1f", maxSleep.sleepHours)) 小时")

        if sleepDays.count > 1 {
            let fmt = DateFormatter()
            fmt.dateFormat = "E"
            fmt.locale = Locale(identifier: "zh_CN")
            lines.append("🌙 睡最久：\(fmt.string(from: maxSleep.date))（\(String(format: "%.1f", maxSleep.sleepHours))h）")
            lines.append("⏰ 睡最少：\(fmt.string(from: minSleep.date))（\(String(format: "%.1f", minSleep.sleepHours))h）")
        }

        // Sleep phase breakdown (requires Apple Watch data)
        let phaseDays = sleepDays.filter { $0.hasSleepPhases }
        if !phaseDays.isEmpty {
            let avgDeep = phaseDays.reduce(0) { $0 + $1.sleepDeepHours } / Double(phaseDays.count)
            let avgREM = phaseDays.reduce(0) { $0 + $1.sleepREMHours } / Double(phaseDays.count)
            let avgCore = phaseDays.reduce(0) { $0 + $1.sleepCoreHours } / Double(phaseDays.count)
            let avgPhaseTotal = avgDeep + avgREM + avgCore

            lines.append("\n🧠 睡眠阶段分析")

            // Show phase durations with percentage bars
            if avgPhaseTotal > 0 {
                let deepPct = avgDeep / avgPhaseTotal * 100
                let remPct = avgREM / avgPhaseTotal * 100
                let corePct = avgCore / avgPhaseTotal * 100

                lines.append("🟣 深睡眠：\(String(format: "%.1f", avgDeep))h（\(Int(deepPct))%）\(phaseBar(pct: deepPct))")
                lines.append("🔵 REM 睡眠：\(String(format: "%.1f", avgREM))h（\(Int(remPct))%）\(phaseBar(pct: remPct))")
                lines.append("⚪ 核心睡眠：\(String(format: "%.1f", avgCore))h（\(Int(corePct))%）\(phaseBar(pct: corePct))")

                // Sleep quality insights based on phase ratios
                lines.append("")
                lines.append(contentsOf: sleepPhaseInsights(deepPct: deepPct, remPct: remPct, avgDeep: avgDeep, avgREM: avgREM))
            }

            // Phase consistency across days (only if multiple days)
            if phaseDays.count >= 3 {
                let deepValues = phaseDays.map { $0.sleepDeepHours }
                let deepVariation = coefficient(of: deepValues)
                if deepVariation > 0.4 {
                    lines.append("📉 深睡眠波动较大，尽量保持固定的睡眠时间有助于稳定。")
                } else if deepVariation < 0.2 {
                    lines.append("📊 深睡眠非常稳定，说明你的睡眠节律很好。")
                }
            }
        }

        // Personalized insight based on total duration
        let goodDays = sleepDays.filter { $0.sleepHours >= 7 && $0.sleepHours <= 9 }.count
        let goodRate = Double(goodDays) / Double(sleepDays.count) * 100

        if phaseDays.isEmpty {
            // No phase data — give duration-based insight only
            lines.append("")
        }

        if goodRate >= 80 {
            lines.append("✅ \(Int(goodRate))% 的夜晚在 7-9 小时的健康范围内，睡眠习惯很棒！")
        } else if goodRate >= 50 {
            lines.append("💡 \(Int(goodRate))% 的夜晚在健康范围（7-9h），还有提升空间。")
            if avg < 7 {
                lines.append("建议尝试提前 \(Int((7 - avg) * 60)) 分钟上床。")
            }
        } else {
            lines.append("⚠️ 仅 \(Int(goodRate))% 的夜晚在健康范围内。")
            if avg < 6 {
                lines.append("长期睡眠不足 6 小时会影响注意力和免疫力，试着调整作息吧。")
            } else if avg > 9 {
                lines.append("睡眠过多可能反而影响精力，试试固定起床时间。")
            }
        }

        completion(lines.joined(separator: "\n"))
    }

    /// Builds a mini bar chart for sleep phase percentage (max 10 blocks).
    private func phaseBar(pct: Double) -> String {
        let blocks = max(1, Int(pct / 10))
        return String(repeating: "▓", count: blocks) + String(repeating: "░", count: 10 - blocks)
    }

    /// Returns personalized insights based on sleep phase ratios.
    /// Healthy adults: ~15-25% deep, ~20-25% REM.
    private func sleepPhaseInsights(deepPct: Double, remPct: Double, avgDeep: Double, avgREM: Double) -> [String] {
        var insights: [String] = []

        // Deep sleep analysis (healthy: 15-25%, or ~1.5-2h for 8h sleep)
        if deepPct >= 15 && deepPct <= 25 {
            insights.append("✅ 深睡眠比例健康，身体恢复充分。")
        } else if deepPct < 15 {
            insights.append("💡 深睡眠偏少（理想为 15-25%），这是身体修复的关键阶段。")
            if avgDeep < 1.0 {
                insights.append("   避免睡前饮酒和大量咖啡因，有助于增加深睡眠。")
            }
        } else {
            insights.append("💤 深睡眠比例较高，可能与近期运动量大或身体疲劳有关。")
        }

        // REM sleep analysis (healthy: 20-25%, important for memory)
        if remPct >= 20 && remPct <= 25 {
            insights.append("✅ REM 睡眠充足，有利于记忆巩固和情绪调节。")
        } else if remPct < 20 {
            insights.append("💡 REM 偏少（理想为 20-25%），REM 对学习和记忆力很重要。")
            if avgREM < 1.0 {
                insights.append("   规律作息和减少睡前屏幕时间有助于改善 REM。")
            }
        } else {
            insights.append("🔵 REM 比例较高，可能与近期压力或活跃的梦境有关。")
        }

        return insights
    }

    /// Coefficient of variation: stddev / mean. Lower = more consistent.
    private func coefficient(of values: [Double]) -> Double {
        guard values.count >= 2 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        guard mean > 0 else { return 0 }
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return (variance.squareRoot()) / mean
    }

    private func respondHeartRate(summaries: [HealthSummary], range: QueryTimeRange, completion: @escaping (String) -> Void) {
        let hrDays = summaries.filter { $0.heartRate > 0 }
        guard !hrDays.isEmpty else {
            completion("❤️ \(range.label)暂无心率数据。\n需要 Apple Watch 来追踪心率。")
            return
        }

        var lines: [String] = ["❤️ \(range.label)的心率数据\n"]
        let avg = hrDays.reduce(0) { $0 + $1.heartRate } / Double(hrDays.count)
        let maxHR = hrDays.max(by: { $0.heartRate < $1.heartRate })!
        let minHR = hrDays.min(by: { $0.heartRate < $1.heartRate })!

        lines.append("💓 平均心率：\(Int(avg)) BPM")
        lines.append("📊 波动范围：\(Int(minHR.heartRate))~\(Int(maxHR.heartRate)) BPM")

        // Context-aware insight
        if avg < 60 {
            lines.append("\n🏅 静息心率较低，说明心肺功能不错！")
        } else if avg <= 80 {
            lines.append("\n✅ 心率处于正常范围（60-80 BPM）。")
        } else if avg <= 100 {
            lines.append("\n💡 心率偏高，可能与压力、缺乏运动或咖啡因有关。")
        } else {
            lines.append("\n⚠️ 平均心率超过 100 BPM，建议关注并咨询医生。")
        }

        // Variability insight
        let spread = maxHR.heartRate - minHR.heartRate
        if spread > 15 && hrDays.count > 2 {
            lines.append("心率日间波动 \(Int(spread)) BPM，运动日和休息日差异明显。")
        }

        completion(lines.joined(separator: "\n"))
    }

    private func respondSteps(summaries: [HealthSummary], range: QueryTimeRange, completion: @escaping (String) -> Void) {
        let stepDays = summaries.filter { $0.steps > 0 }
        guard !stepDays.isEmpty else {
            completion("👟 \(range.label)暂无步数记录。")
            return
        }

        var lines: [String] = ["👟 \(range.label)的步数详情\n"]
        let total = stepDays.reduce(0) { $0 + $1.steps }
        let avg = total / Double(stepDays.count)
        let best = stepDays.max(by: { $0.steps < $1.steps })!
        let worst = stepDays.min(by: { $0.steps < $1.steps })!

        lines.append("📊 总步数：\(Int(total).formatted()) 步")
        lines.append("📈 日均：\(Int(avg).formatted()) 步")

        if stepDays.count > 1 {
            let fmt = DateFormatter()
            fmt.dateFormat = "M月d日(E)"
            fmt.locale = Locale(identifier: "zh_CN")
            lines.append("🏆 最多：\(fmt.string(from: best.date)) \(Int(best.steps).formatted()) 步")
            lines.append("📉 最少：\(fmt.string(from: worst.date)) \(Int(worst.steps).formatted()) 步")
        }

        // Goal analysis
        let goalDays = stepDays.filter { $0.steps >= 8000 }.count
        let goalRate = Double(goalDays) / Double(stepDays.count) * 100
        lines.append("\n🎯 达标天数（≥8000步）：\(goalDays)/\(stepDays.count) 天（\(Int(goalRate))%）")

        if goalRate >= 80 {
            lines.append("太棒了！大部分时间都达标了 🏅")
        } else if goalRate >= 50 {
            lines.append("过半天数达标，继续保持！💪")
        } else if avg >= 5000 {
            lines.append("离目标还差一点，试试饭后散步 15 分钟？")
        } else {
            lines.append("活动量偏少，可以从每天增加 1000 步开始。")
        }

        completion(lines.joined(separator: "\n"))
    }

    // MARK: - Flights Climbed

    private func respondFlights(summaries: [HealthSummary], range: QueryTimeRange, completion: @escaping (String) -> Void) {
        let flightDays = summaries.filter { $0.flightsClimbed > 0 }
        guard !flightDays.isEmpty else {
            completion("🏢 \(range.label)暂无爬楼数据。\niPhone 会自动记录爬楼层数，确保已开启健康权限。")
            return
        }

        var lines: [String] = ["🏢 \(range.label)的爬楼数据\n"]
        let total = flightDays.reduce(0) { $0 + $1.flightsClimbed }
        let avg = total / Double(flightDays.count)
        let best = flightDays.max(by: { $0.flightsClimbed < $1.flightsClimbed })!

        lines.append("🪜 总楼层：\(Int(total)) 层（日均 \(Int(avg)) 层）")
        // 1 flight ≈ 3 meters of elevation gain
        let totalMeters = total * 3
        lines.append("📐 约等于爬升 \(Int(totalMeters)) 米")

        if flightDays.count > 1 {
            let fmt = DateFormatter()
            fmt.dateFormat = "M月d日(E)"
            fmt.locale = Locale(identifier: "zh_CN")
            lines.append("🏆 最多的一天：\(fmt.string(from: best.date))，\(Int(best.flightsClimbed)) 层")
        }

        // Fun comparisons for motivation
        lines.append("")
        if total >= 163 {
            let percent = Int(total / 163 * 100)
            lines.append("🏔 相当于爬了 \(percent)% 座广州塔（\(Int(totalMeters))m / 489m）")
        } else if total >= 50 {
            lines.append("🏗 相当于爬了一栋 \(Int(total)) 层的大楼，很有毅力！")
        } else if total >= 10 {
            lines.append("👍 积少成多，每天多爬几层楼对心肺有益。")
        }

        // Daily goal insight (WHO recommends regular stair climbing)
        let activeDays = flightDays.filter { $0.flightsClimbed >= 10 }.count
        if activeDays > 0 {
            lines.append("🎯 有 \(activeDays) 天达到了 10 层以上，爬楼是很好的有氧运动！")
        }

        completion(lines.joined(separator: "\n"))
    }

    // MARK: - Distance

    private func respondDistance(summaries: [HealthSummary], range: QueryTimeRange, completion: @escaping (String) -> Void) {
        let distanceDays = summaries.filter { $0.distanceKm > 0.01 }
        guard !distanceDays.isEmpty else {
            completion("📏 \(range.label)暂无步行距离数据。\n开启健康权限后可以自动追踪步行和跑步距离。")
            return
        }

        var lines: [String] = ["📏 \(range.label)的步行/跑步距离\n"]
        let total = distanceDays.reduce(0) { $0 + $1.distanceKm }
        let avg = total / Double(distanceDays.count)
        let best = distanceDays.max(by: { $0.distanceKm < $1.distanceKm })!

        lines.append("🛣 总距离：\(String(format: "%.1f", total)) 公里（日均 \(String(format: "%.1f", avg)) 公里）")

        if distanceDays.count > 1 {
            let fmt = DateFormatter()
            fmt.dateFormat = "M月d日(E)"
            fmt.locale = Locale(identifier: "zh_CN")
            lines.append("🏆 最远的一天：\(fmt.string(from: best.date))，\(String(format: "%.1f", best.distanceKm)) 公里")
        }

        // Correlate with steps if available
        let totalSteps = distanceDays.reduce(0) { $0 + $1.steps }
        if totalSteps > 0 && total > 0 {
            let strideCm = Int(total * 100000 / totalSteps)
            lines.append("👣 平均步幅约 \(strideCm) cm")
        }

        // Fun distance comparisons
        lines.append("")
        if total >= 42.195 {
            let marathons = total / 42.195
            lines.append("🏅 累计距离超过 \(String(format: "%.1f", marathons)) 个马拉松！")
        } else if total >= 21.1 {
            lines.append("🏅 累计距离超过一个半马拉松（21.1km），继续加油！")
        } else if total >= 10 {
            let remaining = 21.1 - total
            lines.append("🎯 再走 \(String(format: "%.1f", remaining)) 公里就达到半马距离了。")
        } else if total >= 5 {
            lines.append("🚶 保持日常步行，积少成多。")
        }

        // Trend (compare first half vs second half)
        if distanceDays.count >= 4 {
            let mid = distanceDays.count / 2
            let recentAvg = distanceDays.prefix(mid).reduce(0) { $0 + $1.distanceKm } / Double(mid)
            let olderAvg = distanceDays.suffix(from: mid).reduce(0) { $0 + $1.distanceKm } / Double(distanceDays.count - mid)
            if olderAvg > 0 {
                let pct = ((recentAvg - olderAvg) / olderAvg) * 100
                if pct >= 10 {
                    lines.append("📈 步行距离呈上升趋势（+\(Int(pct))%），活动量在增加！")
                } else if pct <= -10 {
                    lines.append("📉 步行距离有所下降（\(Int(pct))%），试试换条新路线散步？")
                }
            }
        }

        completion(lines.joined(separator: "\n"))
    }

    private func respondOverview(summaries: [HealthSummary], range: QueryTimeRange, completion: @escaping (String) -> Void) {
        var lines: [String] = ["📊 \(range.label)健康概览\n"]
        let dayCount = Double(max(summaries.count, 1))
        let cal = Calendar.current

        // --- Core metrics ---
        let totalSteps = summaries.reduce(0) { $0 + $1.steps }
        let totalExercise = summaries.reduce(0) { $0 + $1.exerciseMinutes }
        let sleepDays = summaries.filter { $0.sleepHours > 0 }
        let avgSleep = sleepDays.isEmpty ? 0 : sleepDays.reduce(0) { $0 + $1.sleepHours } / Double(sleepDays.count)
        let hrDays = summaries.filter { $0.heartRate > 0 }
        let avgHR = hrDays.isEmpty ? 0 : hrDays.reduce(0) { $0 + $1.heartRate } / Double(hrDays.count)
        let totalDistance = summaries.reduce(0) { $0 + $1.distanceKm }
        let totalFlights = summaries.reduce(0) { $0 + $1.flightsClimbed }

        let avgSteps = totalSteps / dayCount
        let avgExercise = totalExercise / dayCount

        if totalSteps > 0 { lines.append("👟 日均 \(Int(avgSteps).formatted()) 步") }
        if totalDistance > 0.1 { lines.append("📏 累计 \(String(format: "%.1f", totalDistance)) 公里") }
        if totalExercise > 0 { lines.append("⏱ 日均运动 \(Int(avgExercise)) 分钟") }
        if avgSleep > 0 {
            lines.append("😴 均睡 \(String(format: "%.1f", avgSleep)) 小时")
            let phaseDays = summaries.filter { $0.hasSleepPhases }
            if !phaseDays.isEmpty {
                let avgDeep = phaseDays.reduce(0) { $0 + $1.sleepDeepHours } / Double(phaseDays.count)
                lines.append("   🟣 深睡眠 \(String(format: "%.1f", avgDeep))h · 查看「睡眠」获取详细分析")
            }
        }
        if avgHR > 0 { lines.append("❤️ 均心率 \(Int(avgHR)) BPM") }
        if totalFlights > 0 { lines.append("🏢 爬楼 \(Int(totalFlights)) 层（日均 \(Int(totalFlights / dayCount))）") }

        // --- Sparkline: day-by-day step trend ---
        if summaries.count >= 3 {
            let sorted = summaries.sorted { $0.date < $1.date }
            let maxSteps = sorted.map(\.steps).max() ?? 1
            if maxSteps > 0 {
                let sparkChars: [Character] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
                let spark = sorted.map { day -> Character in
                    let idx = min(Int(day.steps / maxSteps * 7), 7)
                    return sparkChars[idx]
                }
                lines.append("\n📈 步数趋势：\(String(spark))")
            }
        }

        // --- Weekday vs Weekend patterns ---
        if summaries.count >= 5 {
            let weekdays = summaries.filter { !cal.isDateInWeekend($0.date) }
            let weekends = summaries.filter { cal.isDateInWeekend($0.date) }

            if !weekdays.isEmpty && !weekends.isEmpty {
                let wdAvgSteps = weekdays.reduce(0) { $0 + $1.steps } / Double(weekdays.count)
                let weAvgSteps = weekends.reduce(0) { $0 + $1.steps } / Double(weekends.count)
                let wdAvgExercise = weekdays.reduce(0) { $0 + $1.exerciseMinutes } / Double(weekdays.count)
                let weAvgExercise = weekends.reduce(0) { $0 + $1.exerciseMinutes } / Double(weekends.count)

                // Only show if there's a meaningful difference (>15%)
                let stepsDiff = wdAvgSteps > 0 ? abs(weAvgSteps - wdAvgSteps) / wdAvgSteps * 100 : 0
                let exerciseDiff = wdAvgExercise > 0 ? abs(weAvgExercise - wdAvgExercise) / wdAvgExercise * 100 : 0

                if stepsDiff > 15 || exerciseDiff > 15 {
                    lines.append("\n🗓 工作日 vs 周末")
                    if stepsDiff > 15 {
                        let moreActive = weAvgSteps > wdAvgSteps ? "周末" : "工作日"
                        lines.append("   步数：工作日均 \(Int(wdAvgSteps).formatted()) · 周末均 \(Int(weAvgSteps).formatted())（\(moreActive)更活跃）")
                    }
                    if exerciseDiff > 15 && wdAvgExercise > 0 {
                        let moreActive = weAvgExercise > wdAvgExercise ? "周末" : "工作日"
                        lines.append("   运动：工作日均 \(Int(wdAvgExercise))min · 周末均 \(Int(weAvgExercise))min（\(moreActive)更多）")
                    }
                }

                // Sleep pattern: weekday vs weekend
                let wdSleep = weekdays.filter { $0.sleepHours > 0 }
                let weSleep = weekends.filter { $0.sleepHours > 0 }
                if !wdSleep.isEmpty && !weSleep.isEmpty {
                    let wdAvgSleep = wdSleep.reduce(0) { $0 + $1.sleepHours } / Double(wdSleep.count)
                    let weAvgSleep = weSleep.reduce(0) { $0 + $1.sleepHours } / Double(weSleep.count)
                    let sleepDiffH = weAvgSleep - wdAvgSleep
                    if abs(sleepDiffH) >= 0.5 {
                        if sleepDiffH > 0 {
                            lines.append("   😴 周末多睡 \(String(format: "%.1f", sleepDiffH))h — 工作日可能欠下了睡眠债")
                        } else {
                            lines.append("   😴 工作日反而多睡 \(String(format: "%.1f", -sleepDiffH))h — 周末活动较多")
                        }
                    }
                }
            }
        }

        // --- Consistency score (coefficient of variation for steps) ---
        let stepValues = summaries.map(\.steps).filter { $0 > 0 }
        if stepValues.count >= 3 {
            let cv = coefficient(of: stepValues)
            lines.append("")
            if cv < 0.2 {
                lines.append("🎯 活动非常规律（波动仅 \(Int(cv * 100))%），节律感很好！")
            } else if cv < 0.4 {
                lines.append("📊 活动比较规律（波动 \(Int(cv * 100))%），偶有高低起伏。")
            } else {
                lines.append("🎢 活动波动较大（\(Int(cv * 100))%），试试每天固定时间散步来建立节奏。")
            }
        }

        // --- Cross-metric insight: sleep vs exercise correlation ---
        if summaries.count >= 4 {
            let paired = summaries.filter { $0.exerciseMinutes > 0 && $0.sleepHours > 0 }
            if paired.count >= 3 {
                let exerciseThreshold = paired.reduce(0) { $0 + $1.exerciseMinutes } / Double(paired.count)
                let activeDays = paired.filter { $0.exerciseMinutes >= exerciseThreshold }
                let restDays = paired.filter { $0.exerciseMinutes < exerciseThreshold }

                if !activeDays.isEmpty && !restDays.isEmpty {
                    let sleepOnActive = activeDays.reduce(0) { $0 + $1.sleepHours } / Double(activeDays.count)
                    let sleepOnRest = restDays.reduce(0) { $0 + $1.sleepHours } / Double(restDays.count)
                    let diff = sleepOnActive - sleepOnRest

                    if abs(diff) >= 0.3 {
                        if diff > 0 {
                            lines.append("💡 运动多的日子平均多睡 \(String(format: "%.1f", diff))h — 运动促进了睡眠质量。")
                        } else {
                            lines.append("💡 运动多的日子反而少睡 \(String(format: "%.1f", -diff))h — 注意运动后留够恢复时间。")
                        }
                    }
                }
            }
        }

        // --- Anomaly detection: flag unusually low days ---
        if stepValues.count >= 5 {
            let mean = stepValues.reduce(0, +) / Double(stepValues.count)
            let threshold = mean * 0.4 // Below 40% of average
            let lowDays = summaries.filter { $0.steps > 0 && $0.steps < threshold }
            if !lowDays.isEmpty && lowDays.count <= 2 {
                let fmt = DateFormatter()
                fmt.dateFormat = "M月d日(E)"
                fmt.locale = Locale(identifier: "zh_CN")
                let dayNames = lowDays.prefix(2).map { fmt.string(from: $0.date) }.joined(separator: "、")
                lines.append("⚠️ \(dayNames)活动量明显偏低，那天是否身体不适或特别忙碌？")
            } else if lowDays.count > 2 {
                lines.append("⚠️ 有 \(lowDays.count) 天活动量低于平均的 40%，建议关注每日基础活动量。")
            }
        }

        // --- Overall verdict (enhanced with cross-metric awareness) ---
        var score = 0
        var weakAreas: [String] = []
        if avgSteps >= 8000 { score += 1 } else { weakAreas.append("步数") }
        if avgExercise >= 30 { score += 1 } else if totalExercise > 0 { weakAreas.append("运动时长") }
        if avgSleep >= 7 && avgSleep <= 9 { score += 1 } else if avgSleep > 0 { weakAreas.append("睡眠") }

        lines.append("")
        switch score {
        case 3:
            lines.append("✅ 整体状态很好！步数、运动和睡眠都在健康范围。")
        case 2:
            lines.append("💪 状态不错！\(weakAreas.joined(separator: "和"))还有提升空间。")
        case 1:
            let tip = weakAreas.first ?? "活动"
            lines.append("💡 \(tip)是最容易改善的一项，从它开始试试？")
        default:
            lines.append("🌱 健康之旅从第一步开始，慢慢来。")
        }

        completion(lines.joined(separator: "\n"))
    }

    // MARK: - Streak

    private func respondStreak(context: SkillContext, completion: @escaping (String) -> Void) {
        context.healthService.fetchSummaries(days: 30) { summaries in
            let sorted = summaries.sorted { $0.date > $1.date }
            var currentStreak = 0
            var longestStreak = 0
            var tempStreak = 0
            var date = Calendar.current.startOfDay(for: Date())

            // Calculate current streak
            for summary in sorted {
                let summaryDay = Calendar.current.startOfDay(for: summary.date)
                if summaryDay == date && summary.steps >= 8000 {
                    currentStreak += 1
                    date = Calendar.current.date(byAdding: .day, value: -1, to: date) ?? date
                } else if summaryDay == date {
                    break
                }
            }

            // Calculate longest streak in the 30-day window
            let chronological = summaries.sorted { $0.date < $1.date }
            for summary in chronological {
                if summary.steps >= 8000 {
                    tempStreak += 1
                    longestStreak = max(longestStreak, tempStreak)
                } else {
                    tempStreak = 0
                }
            }

            let todaySteps = sorted.first?.steps ?? 0
            var lines: [String] = []

            if currentStreak == 0 {
                lines.append("🎯 步数打卡（≥8000步）\n")
                if todaySteps > 0 {
                    let remaining = max(0, Int(8000 - todaySteps))
                    lines.append("今天已走 \(Int(todaySteps).formatted()) 步")
                    if remaining > 0 {
                        lines.append("还差 \(remaining.formatted()) 步达标，大约 \(remaining / 100) 分钟步行 🚶")
                    }
                } else {
                    lines.append("今天还没有步数记录哦！")
                }
                if longestStreak > 0 {
                    lines.append("\n📊 近 30 天最长连续：\(longestStreak) 天，可以再挑战一次！")
                }
            } else {
                lines.append("🔥 步数连续打卡：**\(currentStreak) 天**！\n")
                if currentStreak >= 14 {
                    lines.append("两周以上的坚持，运动已经成为你的习惯了！🏆")
                } else if currentStreak >= 7 {
                    lines.append("整整一周！坚持下去就是质变 💪")
                } else if currentStreak >= 3 {
                    lines.append("连续 \(currentStreak) 天，好习惯正在养成！")
                } else {
                    lines.append("好的开始！明天继续，让连续记录更长 🔥")
                }
                if longestStreak > currentStreak {
                    lines.append("\n📊 历史最长连续：\(longestStreak) 天，还差 \(longestStreak - currentStreak) 天打破记录！")
                } else if currentStreak == longestStreak && currentStreak >= 3 {
                    lines.append("\n🏅 这是你近 30 天的最长连续记录！")
                }
            }

            completion(lines.joined(separator: "\n"))
        }
    }

    // MARK: - Comparison

    private func respondComparison(context: SkillContext, completion: @escaping (String) -> Void) {
        context.healthService.fetchSummaries(days: 14) { summaries in
            let cal = Calendar.current
            let now = Date()
            let thisWeekStart = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? now
            let lastWeekStart = cal.date(byAdding: .weekOfYear, value: -1, to: thisWeekStart) ?? now
            let lastWeekEnd = thisWeekStart

            let thisWeek = summaries.filter { $0.date >= thisWeekStart && $0.date <= now }
            let lastWeek = summaries.filter { $0.date >= lastWeekStart && $0.date < lastWeekEnd }

            guard !thisWeek.isEmpty || !lastWeek.isEmpty else {
                completion("📊 暂无足够的健康数据进行对比。\n请开启健康权限以追踪每日数据。")
                return
            }

            var lines: [String] = ["📈 本周 vs 上周\n"]

            // Steps comparison
            let thisSteps = thisWeek.reduce(0) { $0 + $1.steps }
            let lastSteps = lastWeek.reduce(0) { $0 + $1.steps }
            lines.append(buildComparisonLine(
                icon: "👟", label: "步数",
                thisVal: thisSteps, lastVal: lastSteps,
                unit: "步", formatter: { Int($0).formatted() }
            ))

            // Exercise comparison
            let thisExercise = thisWeek.reduce(0) { $0 + $1.exerciseMinutes }
            let lastExercise = lastWeek.reduce(0) { $0 + $1.exerciseMinutes }
            if thisExercise > 0 || lastExercise > 0 {
                lines.append(buildComparisonLine(
                    icon: "⏱", label: "运动",
                    thisVal: thisExercise, lastVal: lastExercise,
                    unit: "分钟", formatter: { "\(Int($0))" }
                ))
            }

            // Sleep comparison
            let thisSleepDays = thisWeek.filter { $0.sleepHours > 0 }
            let lastSleepDays = lastWeek.filter { $0.sleepHours > 0 }
            let thisSleep = thisSleepDays.isEmpty ? 0 : thisSleepDays.reduce(0) { $0 + $1.sleepHours } / Double(thisSleepDays.count)
            let lastSleep = lastSleepDays.isEmpty ? 0 : lastSleepDays.reduce(0) { $0 + $1.sleepHours } / Double(lastSleepDays.count)
            if thisSleep > 0 || lastSleep > 0 {
                lines.append(buildComparisonLine(
                    icon: "😴", label: "日均睡眠",
                    thisVal: thisSleep, lastVal: lastSleep,
                    unit: "h", formatter: { String(format: "%.1f", $0) }
                ))
            }

            // Calories comparison
            let thisCal = thisWeek.reduce(0) { $0 + $1.activeCalories }
            let lastCal = lastWeek.reduce(0) { $0 + $1.activeCalories }
            if thisCal > 0 || lastCal > 0 {
                lines.append(buildComparisonLine(
                    icon: "🔥", label: "热量",
                    thisVal: thisCal, lastVal: lastCal,
                    unit: "千卡", formatter: { Int($0).formatted() }
                ))
            }

            // Distance comparison
            let thisDist = thisWeek.reduce(0) { $0 + $1.distanceKm }
            let lastDist = lastWeek.reduce(0) { $0 + $1.distanceKm }
            if thisDist > 0.1 || lastDist > 0.1 {
                lines.append(buildComparisonLine(
                    icon: "📏", label: "距离",
                    thisVal: thisDist, lastVal: lastDist,
                    unit: "km", formatter: { String(format: "%.1f", $0) }
                ))
            }

            // Flights climbed comparison
            let thisFlights = thisWeek.reduce(0) { $0 + $1.flightsClimbed }
            let lastFlights = lastWeek.reduce(0) { $0 + $1.flightsClimbed }
            if thisFlights > 0 || lastFlights > 0 {
                lines.append(buildComparisonLine(
                    icon: "🏢", label: "爬楼",
                    thisVal: thisFlights, lastVal: lastFlights,
                    unit: "层", formatter: { "\(Int($0))" }
                ))
            }

            // Overall verdict
            lines.append("")
            var better = 0
            var worse = 0
            if thisSteps > lastSteps * 1.05 { better += 1 } else if thisSteps < lastSteps * 0.95 { worse += 1 }
            if thisExercise > lastExercise * 1.05 { better += 1 } else if thisExercise < lastExercise * 0.95 { worse += 1 }
            if thisSleep > lastSleep * 1.05 && thisSleep <= 9 { better += 1 } else if thisSleep < lastSleep * 0.95 { worse += 1 }

            if better > worse {
                lines.append("💪 整体趋势向好，比上周更活跃了！")
            } else if worse > better {
                lines.append("💡 这周稍有松懈，下周找回节奏吧！")
            } else {
                lines.append("📊 和上周基本持平，保持稳定也是一种力量。")
            }

            completion(lines.joined(separator: "\n"))
        }
    }

    // MARK: - Helpers

    private func buildComparisonLine(
        icon: String, label: String,
        thisVal: Double, lastVal: Double,
        unit: String, formatter: (Double) -> String
    ) -> String {
        let arrow: String
        let change: String
        if lastVal > 0 {
            let pct = ((thisVal - lastVal) / lastVal) * 100
            arrow = pct >= 0 ? "↑" : "↓"
            change = "\(arrow)\(abs(Int(pct)))%"
        } else if thisVal > 0 {
            change = "新增"
        } else {
            change = "—"
        }
        return "\(icon) \(label)：\(formatter(thisVal))\(unit) vs \(formatter(lastVal))\(unit)  \(change)"
    }
}

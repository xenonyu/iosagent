import Foundation
import CoreData

/// Handles personal profile and identity queries.
/// Goes beyond static fields — builds a data-driven self-portrait from the user's
/// actual HealthKit, Location, Calendar, and Photo data to answer "who am I really?"
struct ProfileSkill: ClawSkill {

    let id = "profile"

    func canHandle(intent: QueryIntent) -> Bool {
        if case .profile = intent { return true }
        return false
    }

    func execute(intent: QueryIntent, context: SkillContext, completion: @escaping (String) -> Void) {
        let profile = context.profile

        // Fetch 14 days of health data for behavioral portrait
        context.healthService.fetchSummaries(days: 14) { summaries in
            let cal = Calendar.current
            let withData = summaries.filter { $0.hasData }

            var lines: [String] = []

            // ── Basic Identity ──
            if profile.name.isEmpty {
                lines.append("👤 个人画像\n")
                lines.append("⚙️ 基本信息未设置，前往「我」页面完善姓名等资料。")
            } else {
                lines.append("👤 \(profile.name) 的个人画像\n")

                // Core info
                var infoLine: [String] = []
                if let bd = profile.birthday {
                    let age = cal.dateComponents([.year], from: bd, to: Date()).year ?? 0
                    infoLine.append("\(age) 岁")
                }
                if !profile.occupation.isEmpty {
                    infoLine.append(profile.occupation)
                }
                if !infoLine.isEmpty {
                    lines.append("📋 " + infoLine.joined(separator: " · "))
                }
                if !profile.interests.isEmpty {
                    lines.append("🎯 兴趣：\(profile.interests.joined(separator: "、"))")
                }
                if !profile.familyMembers.isEmpty {
                    let familyStr = profile.familyMembers.prefix(4)
                        .map { "\($0.relation)\($0.name)" }
                        .joined(separator: "、")
                    lines.append("👨‍👩‍👧 家人：\(familyStr)")
                }
            }

            // ── Data Portrait (behavioral insights from real iOS data) ──
            let hasHealth = !withData.isEmpty
            let twoWeeksAgo = cal.date(byAdding: .day, value: -14, to: Date()) ?? Date()
            let locations = CDLocationRecord.fetch(from: twoWeeksAgo, to: Date(), in: context.coreDataContext)
            let lifeEvents = CDLifeEvent.fetch(from: twoWeeksAgo, to: Date(), in: context.coreDataContext)
            let calEvents = context.calendarService.fetchEvents(from: twoWeeksAgo, to: Date())
            let hasLocation = !locations.isEmpty
            let hasCalendar = !calEvents.isEmpty
            let hasLifeEvents = !lifeEvents.isEmpty

            guard hasHealth || hasLocation || hasCalendar || hasLifeEvents else {
                if lines.count <= 2 {
                    lines.append("\n📊 还没有积累足够的数据来描绘你的生活画像。")
                    lines.append("继续使用 iosclaw 几天后再问我「我是谁」，会看到不一样的回答 😊")
                }
                completion(lines.joined(separator: "\n"))
                return
            }

            lines.append("\n─── 数据画像（近 14 天）───\n")

            // ── Activity Level & Exercise Identity ──
            if hasHealth {
                let avgSteps = withData.reduce(0) { $0 + $1.steps } / Double(max(withData.count, 1))
                let exerciseDays = withData.filter { $0.exerciseMinutes >= 15 }
                let avgExercise = withData.reduce(0) { $0 + $1.exerciseMinutes } / Double(max(withData.count, 1))

                // Activity archetype — use combined score so gym-goers with moderate steps
                // AND high exercise time are properly recognized as "运动达人"
                let activityLabel: String
                let activityEmoji: String
                let stepScore = avgSteps / 8000.0    // 1.0 = daily goal
                let exerciseScore = avgExercise / 30.0 // 1.0 = daily goal
                let combinedScore = (stepScore + exerciseScore) / 2.0

                if combinedScore >= 1.4 || avgSteps >= 12000 || avgExercise >= 45 {
                    activityLabel = "运动达人"
                    activityEmoji = "🏃‍♂️"
                } else if combinedScore >= 0.9 || avgSteps >= 8000 || avgExercise >= 30 {
                    activityLabel = "积极活跃"
                    activityEmoji = "💪"
                } else if combinedScore >= 0.5 || avgSteps >= 5000 || avgExercise >= 15 {
                    activityLabel = "适度运动"
                    activityEmoji = "🚶"
                } else {
                    activityLabel = "偏静态生活"
                    activityEmoji = "🪑"
                }
                lines.append("\(activityEmoji) 活动水平：\(activityLabel)")
                lines.append("   日均 \(Int(avgSteps).formatted()) 步 · 运动 \(Int(avgExercise)) 分钟")
                if !exerciseDays.isEmpty {
                    lines.append("   过去 14 天中有 \(exerciseDays.count) 天运动超过 15 分钟")
                }

                // Workout type identity
                let allWorkouts = withData.flatMap { $0.workouts }
                if !allWorkouts.isEmpty {
                    var byType: [String: Int] = [:]
                    for w in allWorkouts {
                        byType[w.typeName, default: 0] += 1
                    }
                    let sorted = byType.sorted { $0.value > $1.value }
                    let topType = sorted.first
                    if let top = topType {
                        let typeList = sorted.prefix(3).map { "\($0.key)(\($0.value)次)" }.joined(separator: "、")
                        lines.append("   偏好运动：\(typeList)")
                        if top.value >= 5 {
                            lines.append("   你是一位热爱\(top.key)的运动者 🔥")
                        }
                    }
                }

                // ── Chronotype (sleep timing identity) ──
                let timingDays = withData.filter { $0.sleepOnset != nil }
                if timingDays.count >= 3 {
                    let onsetMinutes: [Double] = timingDays.compactMap { day in
                        guard let onset = day.sleepOnset else { return nil }
                        let h = Double(cal.component(.hour, from: onset))
                        let m = Double(cal.component(.minute, from: onset))
                        let raw = h * 60 + m
                        return raw < 18 * 60 ? raw + 24 * 60 : raw
                    }
                    let wakeMinutes: [Double] = timingDays.compactMap { day in
                        guard let wake = day.wakeTime else { return nil }
                        let h = Double(cal.component(.hour, from: wake))
                        let m = Double(cal.component(.minute, from: wake))
                        return h * 60 + m
                    }

                    if !onsetMinutes.isEmpty {
                        let avgOnset = onsetMinutes.reduce(0, +) / Double(onsetMinutes.count)
                        let normalizedOnset = avgOnset.truncatingRemainder(dividingBy: 1440)

                        let chronotype: String
                        let chronoEmoji: String
                        if normalizedOnset < 22.5 * 60 {
                            chronotype = "早睡型 (Early Sleeper)"
                            chronoEmoji = "🌅"
                        } else if normalizedOnset < 23.5 * 60 {
                            chronotype = "规律型"
                            chronoEmoji = "🌙"
                        } else if normalizedOnset < 1 * 60 {
                            chronotype = "轻度夜猫子"
                            chronoEmoji = "🦉"
                        } else {
                            chronotype = "夜猫子型 (Night Owl)"
                            chronoEmoji = "🌃"
                        }

                        let onsetH = Int(normalizedOnset) / 60
                        let onsetM = Int(normalizedOnset) % 60

                        lines.append("")
                        lines.append("\(chronoEmoji) 作息类型：\(chronotype)")
                        lines.append("   平均入睡 \(String(format: "%02d:%02d", onsetH, onsetM))")

                        if !wakeMinutes.isEmpty {
                            let avgWake = wakeMinutes.reduce(0, +) / Double(wakeMinutes.count)
                            let wakeH = Int(avgWake) / 60
                            let wakeM = Int(avgWake) % 60
                            lines.append("   平均醒来 \(String(format: "%02d:%02d", wakeH, wakeM))")
                        }
                    }
                }

                // ── Sleep quality trait ──
                let sleepDays = withData.filter { $0.sleepHours > 0 }
                if sleepDays.count >= 3 {
                    let avgSleep = sleepDays.reduce(0) { $0 + $1.sleepHours } / Double(sleepDays.count)
                    let sleepValues = sleepDays.map { $0.sleepHours }
                    let stdDev = self.standardDeviation(of: sleepValues)

                    let sleepLabel: String
                    if avgSleep >= 7 && avgSleep <= 9 && stdDev < 0.5 {
                        sleepLabel = "规律且充足 ✅"
                    } else if avgSleep >= 7 && avgSleep <= 9 {
                        sleepLabel = "时长达标，规律性可改善"
                    } else if avgSleep < 6.5 {
                        sleepLabel = "睡眠不足，需要关注 ⚠️"
                    } else if avgSleep > 9 {
                        sleepLabel = "睡眠偏多"
                    } else {
                        sleepLabel = "接近健康范围"
                    }
                    lines.append("   睡眠特征：均 \(String(format: "%.1f", avgSleep))h · \(sleepLabel)")
                }

                // ── Recovery & Stress profile ──
                let hrvDays = withData.filter { $0.hrv > 0 }
                let rhrDays = withData.filter { $0.restingHeartRate > 0 }
                if hrvDays.count >= 3 || rhrDays.count >= 3 {
                    var recoveryLabel: String = ""
                    if !hrvDays.isEmpty {
                        let avgHRV = hrvDays.reduce(0) { $0 + $1.hrv } / Double(hrvDays.count)
                        let hrvContext: String
                        if avgHRV >= 60 {
                            hrvContext = "恢复力佳"
                        } else if avgHRV >= 40 {
                            hrvContext = "正常水平"
                        } else if avgHRV >= 20 {
                            hrvContext = "偏低，注意休息"
                        } else {
                            hrvContext = "较低"
                        }
                        recoveryLabel += "HRV \(Int(avgHRV))ms（\(hrvContext)）"
                    }
                    if !rhrDays.isEmpty {
                        let avgRHR = rhrDays.reduce(0) { $0 + $1.restingHeartRate } / Double(rhrDays.count)
                        if !recoveryLabel.isEmpty { recoveryLabel += " · " }
                        recoveryLabel += "静息心率 \(Int(avgRHR))BPM"
                        if avgRHR < 60 {
                            recoveryLabel += "（心肺适能佳）"
                        } else if avgRHR <= 80 {
                            recoveryLabel += "（正常范围）"
                        } else {
                            recoveryLabel += "（偏高，关注压力和休息）"
                        }
                    }
                    lines.append("")
                    lines.append("💓 身体基线：\(recoveryLabel)")
                }

                // ── Weekday vs Weekend persona ──
                let weekdayData = withData.filter { !cal.isDateInWeekend($0.date) }
                let weekendData = withData.filter { cal.isDateInWeekend($0.date) }
                if weekdayData.count >= 3 && weekendData.count >= 2 {
                    let wdSteps = weekdayData.reduce(0) { $0 + $1.steps } / Double(weekdayData.count)
                    let weSteps = weekendData.reduce(0) { $0 + $1.steps } / Double(weekendData.count)
                    let wdExercise = weekdayData.reduce(0) { $0 + $1.exerciseMinutes } / Double(weekdayData.count)
                    let weExercise = weekendData.reduce(0) { $0 + $1.exerciseMinutes } / Double(weekendData.count)

                    let stepsDiff = wdSteps > 0 ? (weSteps - wdSteps) / wdSteps * 100 : 0
                    let exerciseDiff = wdExercise > 0 ? (weExercise - wdExercise) / wdExercise * 100 : 0

                    if abs(stepsDiff) >= 20 || abs(exerciseDiff) >= 30 {
                        let pattern: String
                        if weSteps > wdSteps * 1.2 && weExercise > wdExercise * 1.3 {
                            pattern = "周末战士型 — 工作日较静，周末集中运动"
                        } else if wdSteps > weSteps * 1.2 {
                            pattern = "通勤活跃型 — 工作日步行更多，周末偏宅"
                        } else if weExercise > wdExercise * 1.3 {
                            pattern = "周末运动型 — 周末是你的运动主战场"
                        } else {
                            pattern = "工作日更活跃"
                        }
                        lines.append("")
                        lines.append("🗓 生活节奏：\(pattern)")
                    }
                }
            }

            // ── Location Identity ──
            if hasLocation {
                let uniquePlaces = Set(locations.map { $0.displayName })
                    .filter { $0 != "未知地点" && !$0.isEmpty }
                let uniqueCount = uniquePlaces.count

                lines.append("")
                if uniqueCount >= 8 {
                    lines.append("🗺️ 出行画像：活跃探索者（14 天内到访 \(uniqueCount) 个不同地点）")
                } else if uniqueCount >= 4 {
                    lines.append("📍 出行画像：规律出行（\(uniqueCount) 个常去地点）")
                } else if uniqueCount >= 1 {
                    lines.append("🏠 出行画像：居家为主（\(uniqueCount) 个地点）")
                }

                // Top places
                var placeCount: [String: Int] = [:]
                for r in locations {
                    let name = r.displayName
                    if name != "未知地点" && !name.isEmpty {
                        placeCount[name, default: 0] += 1
                    }
                }
                let topPlaces = placeCount.sorted { $0.value > $1.value }.prefix(3)
                if !topPlaces.isEmpty {
                    let placeStr = topPlaces.map { "\($0.key)(\($0.value)次)" }.joined(separator: "、")
                    lines.append("   常去：\(placeStr)")
                }
            }

            // ── Schedule Identity ──
            if hasCalendar {
                let timedEvents = calEvents.filter { !$0.isAllDay }
                let totalMeetingMins = timedEvents.reduce(0.0) { $0 + $1.duration } / 60.0
                let daysInPeriod = max(1, cal.dateComponents([.day], from: twoWeeksAgo, to: Date()).day ?? 14)
                let avgEventsPerDay = Double(timedEvents.count) / Double(daysInPeriod)
                let avgMeetingMinsPerDay = totalMeetingMins / Double(daysInPeriod)

                lines.append("")
                let busyLabel: String
                if avgEventsPerDay >= 4 || avgMeetingMinsPerDay >= 240 {
                    busyLabel = "超高密度日程"
                } else if avgEventsPerDay >= 2 || avgMeetingMinsPerDay >= 120 {
                    busyLabel = "忙碌型"
                } else if avgEventsPerDay >= 0.5 {
                    busyLabel = "节奏适中"
                } else {
                    busyLabel = "日程宽松"
                }
                lines.append("📅 日程节奏：\(busyLabel)")
                lines.append("   日均 \(String(format: "%.1f", avgEventsPerDay)) 个事件 · \(Int(avgMeetingMinsPerDay)) 分钟有安排")
            }

            // ── Photo Identity ──
            if context.photoService.isAuthorized {
                let photoMeta = context.photoService.fetchMetadata(from: twoWeeksAgo, to: Date())
                if !photoMeta.isEmpty {
                    let favCount = photoMeta.filter { $0.isFavorite }.count
                    let dailyAvg = Double(photoMeta.count) / 14.0

                    lines.append("")
                    let photoLabel: String
                    if dailyAvg >= 10 {
                        photoLabel = "高产摄影师"
                    } else if dailyAvg >= 3 {
                        photoLabel = "日常记录者"
                    } else if dailyAvg >= 0.5 {
                        photoLabel = "偶尔拍照"
                    } else {
                        photoLabel = "很少拍照"
                    }
                    lines.append("📷 拍照习惯：\(photoLabel)（14 天 \(photoMeta.count) 张，日均 \(String(format: "%.1f", dailyAvg))）")
                    if favCount > 0 {
                        lines.append("   其中 \(favCount) 张被收藏 ❤️")
                    }
                }
            }

            // ── Mood & Life Events ──
            if hasLifeEvents {
                var moodDist: [MoodType: Int] = [:]
                lifeEvents.forEach { moodDist[$0.mood, default: 0] += 1 }
                let dominant = moodDist.max(by: { $0.value < $1.value })
                if let dom = dominant, lifeEvents.count >= 3 {
                    lines.append("")
                    lines.append("😊 情绪基调：\(dom.key.emoji) \(dom.key.label) 为主（\(lifeEvents.count) 条记录中 \(dom.value) 条）")
                }
            }

            // ── Closing insight ──
            lines.append("\n───")
            lines.append("💡 这是基于你近 14 天真实数据的画像。继续使用，画像会越来越精准。")

            completion(lines.joined(separator: "\n"))
        }
    }

    // MARK: - Helpers

    private func standardDeviation(of values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return sqrt(variance)
    }
}

import Foundation
import HealthKit

/// Reads health data from HealthKit — steps, exercise, sleep, heart rate.
/// All data stays on device; this only reads, never writes.
final class HealthService: ObservableObject {

    private let store = HKHealthStore()
    private var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// Whether HealthKit is available on this device (iPad doesn't support HealthKit).
    var isHealthDataAvailable: Bool { isAvailable }

    // MARK: - Types to read

    private var readTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>()
        let identifiers: [HKQuantityTypeIdentifier] = [
            .stepCount,
            .activeEnergyBurned,
            .basalEnergyBurned,
            .appleExerciseTime,
            .heartRate,
            .restingHeartRate,
            .heartRateVariabilitySDNN,
            .distanceWalkingRunning,
            .flightsClimbed,
            .bodyMass,
            .oxygenSaturation,
            .vo2Max
        ]
        identifiers.forEach {
            if let t = HKQuantityType.quantityType(forIdentifier: $0) { types.insert(t) }
        }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            types.insert(sleep)
        }
        // Workout sessions (running, cycling, yoga, etc.)
        types.insert(HKObjectType.workoutType())
        return types
    }

    // MARK: - Permission

    func requestPermission(completion: @escaping (Bool) -> Void) {
        guard isAvailable else { completion(false); return }
        store.requestAuthorization(toShare: [], read: readTypes) { success, _ in
            completion(success)
        }
    }

    // MARK: - Query helpers

    func fetchDailySummary(for date: Date, completion: @escaping (HealthSummary) -> Void) {
        guard isAvailable else { completion(HealthSummary(date: date)); return }

        let cal = Calendar.current
        let start = cal.startOfDay(for: date)
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)

        var summary = HealthSummary(date: date)
        let group = DispatchGroup()

        // Steps
        group.enter()
        fetchSum(.stepCount, unit: .count(), predicate: predicate) { val in
            summary.steps = val
            group.leave()
        }

        // Active calories
        group.enter()
        fetchSum(.activeEnergyBurned, unit: .kilocalorie(), predicate: predicate) { val in
            summary.activeCalories = val
            group.leave()
        }

        // Basal (resting) energy — metabolism at rest, the "always-on" calorie burn.
        // Combined with active calories gives total daily energy expenditure (TDEE),
        // which is what users typically mean when asking "今天消耗了多少卡路里".
        group.enter()
        fetchSum(.basalEnergyBurned, unit: .kilocalorie(), predicate: predicate) { val in
            summary.basalCalories = val
            group.leave()
        }

        // Exercise minutes
        group.enter()
        fetchSum(.appleExerciseTime, unit: .minute(), predicate: predicate) { val in
            summary.exerciseMinutes = val
            group.leave()
        }

        // Heart rate (average + min + max for range analysis)
        let hrUnit = HKUnit.count().unitDivided(by: .minute())
        group.enter()
        fetchAverage(.heartRate, unit: hrUnit, predicate: predicate) { val in
            summary.heartRate = val
            group.leave()
        }

        group.enter()
        fetchMinMax(.heartRate, unit: hrUnit, predicate: predicate) { minVal, maxVal in
            summary.heartRateMin = minVal
            summary.heartRateMax = maxVal
            group.leave()
        }

        // Resting heart rate (key fitness indicator)
        group.enter()
        fetchAverage(.restingHeartRate,
                     unit: HKUnit.count().unitDivided(by: .minute()),
                     predicate: predicate) { val in
            summary.restingHeartRate = val
            group.leave()
        }

        // Heart rate variability (SDNN in milliseconds)
        group.enter()
        fetchAverage(.heartRateVariabilitySDNN,
                     unit: .secondUnit(with: .milli),
                     predicate: predicate) { val in
            summary.hrv = val
            group.leave()
        }

        // Sleep (with phase breakdown + in-bed time + circadian timing)
        // Sleep spans across midnight (e.g. 23:00→07:00), so we must query from
        // the previous evening (18:00) to capture the full night's sleep cycle.
        // We use a strict 24-hour window [18:00(D-1), 18:00(D)] to avoid
        // double-counting the same sleep session in consecutive days' summaries.
        // (The old 30h window [18:00(D-1), 00:00(D+1)] overlapped with the next
        // day's window, inflating the weekly sleep trend.)
        let sleepQueryStart = cal.date(byAdding: .hour, value: -6, to: start) ?? start
        let sleepQueryEnd = cal.date(byAdding: .hour, value: 18, to: start) ?? end
        group.enter()
        fetchSleepPhases(start: sleepQueryStart, end: sleepQueryEnd) { total, deep, rem, core, inBed, onset, wake in
            summary.sleepHours = total
            summary.sleepDeepHours = deep
            summary.sleepREMHours = rem
            summary.sleepCoreHours = core
            summary.inBedHours = inBed
            summary.sleepOnset = onset
            summary.wakeTime = wake
            group.leave()
        }

        // Distance (walking + running)
        group.enter()
        fetchSum(.distanceWalkingRunning, unit: .meterUnit(with: .kilo), predicate: predicate) { val in
            summary.distanceKm = val
            group.leave()
        }

        // Flights climbed
        group.enter()
        fetchSum(.flightsClimbed, unit: .count(), predicate: predicate) { val in
            summary.flightsClimbed = val
            group.leave()
        }

        // Body mass (latest sample for this day — from smart scales or manual entry)
        group.enter()
        fetchLatest(.bodyMass, unit: .gramUnit(with: .kilo), predicate: predicate) { val in
            summary.bodyMassKg = val
            group.leave()
        }

        // Blood oxygen saturation (SpO2, percentage 0-1 from HealthKit → convert to 0-100)
        group.enter()
        fetchAverage(.oxygenSaturation, unit: .percent(), predicate: predicate) { val in
            summary.oxygenSaturation = val * 100  // HealthKit stores as 0-1 fraction
            group.leave()
        }

        // VO2 Max (latest sample — Apple Watch estimates from outdoor walk/run/hike workouts)
        group.enter()
        fetchLatest(.vo2Max,
                    unit: HKUnit(from: "ml/kg*min"),
                    predicate: predicate) { val in
            summary.vo2Max = val
            group.leave()
        }

        // Workouts (individual sessions)
        group.enter()
        fetchWorkouts(start: start, end: end) { workouts in
            summary.workouts = workouts
            group.leave()
        }

        group.notify(queue: .main) {
            completion(summary)
        }
    }

    func fetchWeeklySummaries(completion: @escaping ([HealthSummary]) -> Void) {
        fetchSummaries(days: 7, completion: completion)
    }

    /// Fetch daily summaries for the last N days (including today).
    func fetchSummaries(days: Int, completion: @escaping ([HealthSummary]) -> Void) {
        guard isAvailable else { completion([]); return }
        let cal = Calendar.current
        let today = Date()
        var summaries: [HealthSummary] = []
        let group = DispatchGroup()

        for i in 0..<days {
            let date = cal.date(byAdding: .day, value: -i, to: today)!
            group.enter()
            fetchDailySummary(for: date) { s in
                summaries.append(s)
                group.leave()
            }
        }

        group.notify(queue: .main) {
            completion(summaries.sorted { $0.date > $1.date })
        }
    }

    // MARK: - Private query helpers

    private func fetchSum(_ id: HKQuantityTypeIdentifier,
                          unit: HKUnit,
                          predicate: NSPredicate,
                          completion: @escaping (Double) -> Void) {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else {
            completion(0); return
        }
        let query = HKStatisticsQuery(
            quantityType: type,
            quantitySamplePredicate: predicate,
            options: .cumulativeSum
        ) { _, result, _ in
            completion(result?.sumQuantity()?.doubleValue(for: unit) ?? 0)
        }
        store.execute(query)
    }

    /// Fetches the most recent sample for a quantity type within the predicate window.
    /// Useful for metrics recorded once per day (e.g., body mass from smart scales).
    private func fetchLatest(_ id: HKQuantityTypeIdentifier,
                             unit: HKUnit,
                             predicate: NSPredicate,
                             completion: @escaping (Double) -> Void) {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else {
            completion(0); return
        }
        let sortDesc = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let query = HKSampleQuery(
            sampleType: type,
            predicate: predicate,
            limit: 1,
            sortDescriptors: [sortDesc]
        ) { _, samples, _ in
            let value = (samples?.first as? HKQuantitySample)?
                .quantity.doubleValue(for: unit) ?? 0
            completion(value)
        }
        store.execute(query)
    }

    /// Fetches the minimum and maximum values for a discrete quantity type.
    /// Useful for heart rate range — "avg 75bpm" is less informative than "52-145bpm range".
    private func fetchMinMax(_ id: HKQuantityTypeIdentifier,
                             unit: HKUnit,
                             predicate: NSPredicate,
                             completion: @escaping (Double, Double) -> Void) {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else {
            completion(0, 0); return
        }
        let query = HKStatisticsQuery(
            quantityType: type,
            quantitySamplePredicate: predicate,
            options: [.discreteMin, .discreteMax]
        ) { _, result, _ in
            let minVal = result?.minimumQuantity()?.doubleValue(for: unit) ?? 0
            let maxVal = result?.maximumQuantity()?.doubleValue(for: unit) ?? 0
            completion(minVal, maxVal)
        }
        store.execute(query)
    }

    private func fetchAverage(_ id: HKQuantityTypeIdentifier,
                              unit: HKUnit,
                              predicate: NSPredicate,
                              completion: @escaping (Double) -> Void) {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else {
            completion(0); return
        }
        let query = HKStatisticsQuery(
            quantityType: type,
            quantitySamplePredicate: predicate,
            options: .discreteAverage
        ) { _, result, _ in
            completion(result?.averageQuantity()?.doubleValue(for: unit) ?? 0)
        }
        store.execute(query)
    }

    /// Fetches the most recent workout sessions within the last N days.
    /// Useful for "last time I exercised" queries. Results are sorted newest-first.
    func fetchRecentWorkouts(days: Int, completion: @escaping ([WorkoutRecord]) -> Void) {
        guard isAvailable else { completion([]); return }
        let cal = Calendar.current
        let end = Date()
        let start = cal.date(byAdding: .day, value: -days, to: cal.startOfDay(for: end))!
        fetchWorkouts(start: start, end: end, completion: completion)
    }

    /// Fetches individual workout sessions (HKWorkout) for the given date range.
    private func fetchWorkouts(start: Date, end: Date,
                               completion: @escaping ([WorkoutRecord]) -> Void) {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let sortDesc = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let query = HKSampleQuery(
            sampleType: HKObjectType.workoutType(),
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: [sortDesc]
        ) { _, samples, _ in
            let records = (samples as? [HKWorkout])?.map { w -> WorkoutRecord in
                WorkoutRecord(
                    activityType: w.workoutActivityType.rawValue,
                    duration: w.duration,
                    totalCalories: w.totalEnergyBurned?.doubleValue(for: .kilocalorie()) ?? 0,
                    totalDistance: w.totalDistance?.doubleValue(for: .meter()) ?? 0,
                    startDate: w.startDate,
                    endDate: w.endDate
                )
            } ?? []
            completion(records)
        }
        store.execute(query)
    }

    /// Fetches sleep data with phase breakdown (deep, REM, core), in-bed time,
    /// and sleep timing (onset/wake) for circadian analysis.
    /// Returns (totalHours, deepHours, remHours, coreHours, inBedHours, sleepOnset, wakeTime).
    ///
    /// **Deduplication**: HealthKit often contains overlapping sleep samples from
    /// multiple sources (Apple Watch, iPhone Sleep schedule, third-party apps like
    /// AutoSleep/Pillow). Without deduplication, the same sleep period would be
    /// counted 2-3x, inflating reported hours (e.g. 15h instead of 7.5h).
    /// We merge overlapping time intervals per sleep category to get accurate totals.
    private func fetchSleepPhases(start: Date, end: Date,
                                  completion: @escaping (Double, Double, Double, Double, Double, Date?, Date?) -> Void) {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            completion(0, 0, 0, 0, 0, nil, nil); return
        }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let query = HKSampleQuery(sampleType: type, predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
            // Group intervals by sleep category for per-phase deduplication
            var deepIntervals: [(Date, Date)] = []
            var remIntervals: [(Date, Date)] = []
            var coreIntervals: [(Date, Date)] = []
            var unspecifiedIntervals: [(Date, Date)] = []
            var inBedIntervals: [(Date, Date)] = []

            // Track earliest sleep start and latest sleep end for circadian timing
            var earliestOnset: Date?
            var latestWake: Date?

            let asleepValues: Set<Int> = [
                HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                HKCategoryValueSleepAnalysis.asleepREM.rawValue,
                HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue
            ]

            (samples as? [HKCategorySample])?.forEach { s in
                let interval = (s.startDate, s.endDate)
                switch s.value {
                case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:
                    deepIntervals.append(interval)
                case HKCategoryValueSleepAnalysis.asleepREM.rawValue:
                    remIntervals.append(interval)
                case HKCategoryValueSleepAnalysis.asleepCore.rawValue:
                    coreIntervals.append(interval)
                case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue:
                    unspecifiedIntervals.append(interval)
                case HKCategoryValueSleepAnalysis.inBed.rawValue:
                    inBedIntervals.append(interval)
                default:
                    break // skip awake, etc.
                }
                // Only track timing for actual sleep samples (not inBed/awake)
                if asleepValues.contains(s.value) {
                    if earliestOnset == nil || s.startDate < earliestOnset! {
                        earliestOnset = s.startDate
                    }
                    if latestWake == nil || s.endDate > latestWake! {
                        latestWake = s.endDate
                    }
                }
            }

            // Merge overlapping intervals per category, then sum durations
            let deep = Self.mergedDurationHours(deepIntervals)
            let rem = Self.mergedDurationHours(remIntervals)
            let core = Self.mergedDurationHours(coreIntervals)
            let unspecified = Self.mergedDurationHours(unspecifiedIntervals)
            let inBed = Self.mergedDurationHours(inBedIntervals)

            let total = deep + rem + core + unspecified
            completion(total, deep, rem, core, inBed, earliestOnset, latestWake)
        }
        store.execute(query)
    }

    /// Merges overlapping time intervals and returns total non-overlapping duration in hours.
    /// E.g. [(22:00, 02:00), (22:30, 02:30)] → merged to (22:00, 02:30) → 4.5 hours,
    /// not the naive sum of 4.0 + 4.0 = 8.0 hours.
    private static func mergedDurationHours(_ intervals: [(Date, Date)]) -> Double {
        guard !intervals.isEmpty else { return 0 }
        // Sort by start date
        let sorted = intervals.sorted { $0.0 < $1.0 }
        var merged: [(Date, Date)] = [sorted[0]]
        for i in 1..<sorted.count {
            let current = sorted[i]
            let lastIdx = merged.count - 1
            if current.0 <= merged[lastIdx].1 {
                // Overlapping or adjacent — extend the end if needed
                if current.1 > merged[lastIdx].1 {
                    merged[lastIdx].1 = current.1
                }
            } else {
                // No overlap — add as new interval
                merged.append(current)
            }
        }
        // Sum durations of merged intervals
        return merged.reduce(0.0) { total, interval in
            total + interval.1.timeIntervalSince(interval.0) / 3600.0
        }
    }
}

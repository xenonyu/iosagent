import Foundation
import HealthKit

/// Reads health data from HealthKit — steps, exercise, sleep, heart rate.
/// All data stays on device; this only reads, never writes.
final class HealthService: ObservableObject {

    private let store = HKHealthStore()
    private var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    // MARK: - Types to read

    private var readTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>()
        let identifiers: [HKQuantityTypeIdentifier] = [
            .stepCount,
            .activeEnergyBurned,
            .appleExerciseTime,
            .heartRate,
            .distanceWalkingRunning,
            .flightsClimbed
        ]
        identifiers.forEach {
            if let t = HKQuantityType.quantityType(forIdentifier: $0) { types.insert(t) }
        }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            types.insert(sleep)
        }
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

        // Exercise minutes
        group.enter()
        fetchSum(.appleExerciseTime, unit: .minute(), predicate: predicate) { val in
            summary.exerciseMinutes = val
            group.leave()
        }

        // Heart rate (average)
        group.enter()
        fetchAverage(.heartRate,
                     unit: HKUnit.count().unitDivided(by: .minute()),
                     predicate: predicate) { val in
            summary.heartRate = val
            group.leave()
        }

        // Sleep (with phase breakdown)
        group.enter()
        fetchSleepPhases(start: start, end: end) { total, deep, rem, core in
            summary.sleepHours = total
            summary.sleepDeepHours = deep
            summary.sleepREMHours = rem
            summary.sleepCoreHours = core
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

    /// Fetches sleep data with phase breakdown (deep, REM, core).
    /// Returns (totalHours, deepHours, remHours, coreHours).
    private func fetchSleepPhases(start: Date, end: Date,
                                  completion: @escaping (Double, Double, Double, Double) -> Void) {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            completion(0, 0, 0, 0); return
        }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let query = HKSampleQuery(sampleType: type, predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
            var deep: Double = 0
            var rem: Double = 0
            var core: Double = 0
            var unspecified: Double = 0

            (samples as? [HKCategorySample])?.forEach { s in
                let hours = s.endDate.timeIntervalSince(s.startDate) / 3600
                switch s.value {
                case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:
                    deep += hours
                case HKCategoryValueSleepAnalysis.asleepREM.rawValue:
                    rem += hours
                case HKCategoryValueSleepAnalysis.asleepCore.rawValue:
                    core += hours
                case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue:
                    unspecified += hours
                default:
                    break // skip inBed, awake, etc.
                }
            }

            let total = deep + rem + core + unspecified
            completion(total, deep, rem, core)
        }
        store.execute(query)
    }
}

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

        // Sleep
        group.enter()
        fetchSleepHours(start: start, end: end) { hours in
            summary.sleepHours = hours
            group.leave()
        }

        group.notify(queue: .main) {
            completion(summary)
        }
    }

    func fetchWeeklySummaries(completion: @escaping ([HealthSummary]) -> Void) {
        let cal = Calendar.current
        let today = Date()
        var summaries: [HealthSummary] = []
        let group = DispatchGroup()

        for i in 0..<7 {
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

    private func fetchSleepHours(start: Date, end: Date, completion: @escaping (Double) -> Void) {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            completion(0); return
        }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
            let total = (samples as? [HKCategorySample])?.reduce(0.0) { acc, s in
                guard s.value == HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue ||
                      s.value == HKCategoryValueSleepAnalysis.asleepCore.rawValue ||
                      s.value == HKCategoryValueSleepAnalysis.asleepDeep.rawValue ||
                      s.value == HKCategoryValueSleepAnalysis.asleepREM.rawValue else { return acc }
                return acc + s.endDate.timeIntervalSince(s.startDate) / 3600
            } ?? 0
            completion(total)
        }
        store.execute(query)
    }
}

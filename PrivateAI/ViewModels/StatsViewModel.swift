import Foundation
import CoreData
import Combine

final class StatsViewModel: ObservableObject {

    // MARK: - Published

    @Published var healthSummaries: [HealthSummary] = []
    @Published var moodData: [MoodDataPoint] = []
    @Published var categoryData: [CategoryDataPoint] = []
    @Published var locationData: [LocationDataPoint] = []
    @Published var photoActivityData: [PhotoActivityPoint] = []
    @Published var calendarEvents: [CalendarEventItem] = []
    @Published var selectedRange: QueryTimeRange = .lastWeek
    @Published var isLoadingHealth: Bool = false

    private let context: NSManagedObjectContext
    private let healthService: HealthService
    private let calendarService: CalendarService
    private let photoService: PhotoMetadataService
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(context: NSManagedObjectContext,
         healthService: HealthService,
         calendarService: CalendarService,
         photoService: PhotoMetadataService) {
        self.context = context
        self.healthService = healthService
        self.calendarService = calendarService
        self.photoService = photoService

        $selectedRange
            .sink { [weak self] _ in self?.load() }
            .store(in: &cancellables)

        load()
    }

    // MARK: - Load

    func load() {
        let interval = selectedRange.interval
        loadMoodData(interval: interval)
        loadCategoryData(interval: interval)
        loadLocationData(interval: interval)
        loadCalendarEvents(interval: interval)
        loadPhotoActivity(interval: interval)
        loadHealth()
    }

    private func loadMoodData(interval: DateInterval) {
        let events = CDLifeEvent.fetch(from: interval.start, to: interval.end, in: context)
        let cal = Calendar.current

        var grouped: [Date: [MoodType: Int]] = [:]
        events.forEach {
            let day = cal.startOfDay(for: $0.timestamp)
            grouped[day, default: [:]][$0.mood, default: 0] += 1
        }

        moodData = grouped.flatMap { date, moods in
            moods.map { mood, count in
                MoodDataPoint(date: date, mood: mood, count: count)
            }
        }
        .sorted { $0.date < $1.date }
    }

    private func loadCategoryData(interval: DateInterval) {
        let events = CDLifeEvent.fetch(from: interval.start, to: interval.end, in: context)
        let grouped = Dictionary(grouping: events, by: { $0.category })
        categoryData = grouped.map { cat, evts in
            CategoryDataPoint(category: cat, count: evts.count)
        }
        .sorted { $0.count > $1.count }
    }

    private func loadLocationData(interval: DateInterval) {
        let records = CDLocationRecord.fetch(from: interval.start, to: interval.end, in: context)
        let grouped = Dictionary(grouping: records, by: { $0.displayName })
        locationData = grouped.map { name, records in
            LocationDataPoint(placeName: name, visitCount: records.count)
        }
        .sorted { $0.visitCount > $1.visitCount }
        .prefix(8)
        .map { $0 }
    }

    private func loadCalendarEvents(interval: DateInterval) {
        calendarEvents = calendarService.fetchEvents(from: interval.start, to: interval.end)
    }

    private func loadPhotoActivity(interval: DateInterval) {
        let counts = photoService.dailyPhotoCounts(from: interval.start, to: interval.end)
        photoActivityData = counts.map { date, count in
            PhotoActivityPoint(date: date, count: count)
        }
        .sorted { $0.date < $1.date }
    }

    private func loadHealth() {
        isLoadingHealth = true
        healthService.fetchWeeklySummaries { [weak self] summaries in
            self?.healthSummaries = summaries
            self?.isLoadingHealth = false
        }
    }

    // MARK: - Computed

    var totalSteps: Int { Int(healthSummaries.reduce(0) { $0 + $1.steps }) }
    var totalExerciseMinutes: Int { Int(healthSummaries.reduce(0) { $0 + $1.exerciseMinutes }) }
    var avgSleepHours: Double {
        let valid = healthSummaries.filter { $0.sleepHours > 0 }
        guard !valid.isEmpty else { return 0 }
        return valid.reduce(0) { $0 + $1.sleepHours } / Double(valid.count)
    }

    var dominantMood: MoodType? {
        let all = moodData
        guard !all.isEmpty else { return nil }
        var counts: [MoodType: Int] = [:]
        all.forEach { counts[$0.mood, default: 0] += $0.count }
        return counts.max(by: { $0.value < $1.value })?.key
    }
}

// MARK: - Data Point Models

struct MoodDataPoint: Identifiable {
    var id: String { "\(date.timeIntervalSince1970)-\(mood.rawValue)" }
    let date: Date
    let mood: MoodType
    let count: Int
}

struct CategoryDataPoint: Identifiable {
    var id: String { category.rawValue }
    let category: EventCategory
    let count: Int
}

struct LocationDataPoint: Identifiable {
    var id: String { placeName }
    let placeName: String
    let visitCount: Int
}

struct PhotoActivityPoint: Identifiable {
    var id: TimeInterval { date.timeIntervalSince1970 }
    let date: Date
    let count: Int
}

import Foundation
import CoreData
import Combine

final class TimelineViewModel: ObservableObject {

    @Published var events: [LifeEvent] = []
    @Published var selectedRange: QueryTimeRange = .lastWeek
    @Published var selectedCategory: EventCategory? = nil
    @Published var showAddEvent: Bool = false

    // New event form
    @Published var newEventTitle: String = ""
    @Published var newEventContent: String = ""
    @Published var newEventMood: MoodType = .neutral
    @Published var newEventCategory: EventCategory = .life

    private let context: NSManagedObjectContext
    private var cancellables = Set<AnyCancellable>()

    init(context: NSManagedObjectContext) {
        self.context = context

        $selectedRange
            .combineLatest($selectedCategory)
            .sink { [weak self] _, _ in self?.loadEvents() }
            .store(in: &cancellables)

        loadEvents()
    }

    func loadEvents() {
        let interval = selectedRange.interval
        var loaded = CDLifeEvent.fetch(from: interval.start, to: interval.end, in: context)

        if let cat = selectedCategory {
            loaded = loaded.filter { $0.category == cat }
        }

        events = loaded
    }

    func addEvent() {
        guard !newEventTitle.isEmpty else { return }
        let event = LifeEvent(
            title: newEventTitle,
            content: newEventContent,
            mood: newEventMood,
            category: newEventCategory
        )
        CDLifeEvent.create(from: event, context: context)
        PersistenceController.shared.save()
        resetForm()
        loadEvents()
    }

    func deleteEvent(_ event: LifeEvent) {
        let req = CDLifeEvent.fetchRequest()
        req.predicate = NSPredicate(format: "id == %@", event.id as CVarArg)
        if let cd = (try? context.fetch(req))?.first {
            context.delete(cd)
            PersistenceController.shared.save()
            loadEvents()
        }
    }

    private func resetForm() {
        newEventTitle = ""
        newEventContent = ""
        newEventMood = .neutral
        newEventCategory = .life
        showAddEvent = false
    }
}

import Foundation
import CoreData
import Combine

final class TimelineViewModel: ObservableObject {

    @Published var events: [LifeEvent] = []
    @Published var selectedRange: QueryTimeRange = .lastWeek
    @Published var selectedCategory: EventCategory? = nil
    @Published var showAddEvent: Bool = false
    @Published var searchText: String = ""
    @Published var editingEvent: LifeEvent? = nil
    @Published var showEditEvent: Bool = false

    var filteredEvents: [LifeEvent] {
        guard !searchText.isEmpty else { return events }
        return events.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.content.localizedCaseInsensitiveContains(searchText)
        }
    }

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

        $searchText
            .sink { [weak self] _ in self?.loadEvents() }
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

    func beginEdit(_ event: LifeEvent) {
        editingEvent = event
        newEventTitle = event.title
        newEventContent = event.content
        newEventMood = event.mood
        newEventCategory = event.category
        showEditEvent = true
    }

    func updateEvent() {
        guard let event = editingEvent else { return }
        let req = CDLifeEvent.fetchRequest()
        req.predicate = NSPredicate(format: "id == %@", event.id as CVarArg)
        guard let cd = (try? context.fetch(req))?.first else { return }
        cd.title = newEventTitle
        cd.content = newEventContent
        cd.mood = newEventMood.rawValue
        cd.category = newEventCategory.rawValue
        PersistenceController.shared.save()
        editingEvent = nil
        showEditEvent = false
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

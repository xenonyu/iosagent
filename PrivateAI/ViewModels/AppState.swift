import SwiftUI
import Combine
import CoreData

/// Central observable state shared across all views via EnvironmentObject.
final class AppState: ObservableObject {

    // MARK: - Permission toggles (persisted in UserDefaults)

    @AppStorage("perm_location")  var locationEnabled: Bool  = false
    @AppStorage("perm_health")    var healthEnabled: Bool    = false
    @AppStorage("perm_speech")    var speechEnabled: Bool    = true
    @AppStorage("perm_calendar")  var calendarEnabled: Bool  = false
    @AppStorage("ai_style")       var aiStyle: String        = "friendly"
    @AppStorage("memory_days")    var memoryRetentionDays: Int = 90
    @AppStorage("onboarding_done") var onboardingDone: Bool  = false

    // MARK: - Services

    let locationService = LocationService()
    let healthService   = HealthService()
    let speechService   = SpeechService()

    // MARK: - Init

    init() {
        // Start services according to saved preferences
        if locationEnabled {
            locationService.startTracking()
        }
    }

    // MARK: - Permission management

    func requestLocationPermission() {
        locationService.requestPermission { [weak self] granted in
            DispatchQueue.main.async {
                self?.locationEnabled = granted
                if granted { self?.locationService.startTracking() }
            }
        }
    }

    func requestHealthPermission() {
        healthService.requestPermission { [weak self] granted in
            DispatchQueue.main.async {
                self?.healthEnabled = granted
            }
        }
    }

    func requestSpeechPermission() {
        speechService.requestPermission { [weak self] granted in
            DispatchQueue.main.async {
                self?.speechEnabled = granted
            }
        }
    }

    func toggleLocation(_ enabled: Bool) {
        locationEnabled = enabled
        if enabled {
            requestLocationPermission()
        } else {
            locationService.stopTracking()
        }
    }

    func toggleHealth(_ enabled: Bool) {
        healthEnabled = enabled
        if enabled { requestHealthPermission() }
    }

    // MARK: - Data management

    func clearAllData(context: NSManagedObjectContext) {
        CDChatMessage.deleteAll(in: context)
        let eventReq = NSFetchRequest<NSFetchRequestResult>(entityName: "CDLifeEvent")
        let locationReq = NSFetchRequest<NSFetchRequestResult>(entityName: "CDLocationRecord")
        _ = try? context.execute(NSBatchDeleteRequest(fetchRequest: eventReq))
        _ = try? context.execute(NSBatchDeleteRequest(fetchRequest: locationReq))
        try? context.save()
    }
}

import SwiftUI
import Combine
import CoreData

/// Central observable state shared across all views via EnvironmentObject.
final class AppState: ObservableObject {

    // MARK: - Permission toggles (persisted in UserDefaults)

    @AppStorage("perm_location")       var locationEnabled: Bool    = false
    @AppStorage("perm_health")         var healthEnabled: Bool      = false
    @AppStorage("perm_speech")         var speechEnabled: Bool      = true
    @AppStorage("perm_calendar")       var calendarEnabled: Bool    = false
    @AppStorage("perm_photo")          var photoEnabled: Bool       = false
    @AppStorage("perm_notification")   var notificationEnabled: Bool = false
    @AppStorage("ai_style")            var aiStyle: String          = "friendly"
    @AppStorage("memory_days")         var memoryRetentionDays: Int = 90
    @AppStorage("onboarding_done")     var onboardingDone: Bool     = false
    @AppStorage("notif_hour")          var notifHour: Int           = 21
    @AppStorage("notif_minute")        var notifMinute: Int         = 0

    // MARK: - Services

    let locationService     = LocationService()
    let healthService       = HealthService()
    let speechService       = SpeechService()
    let calendarService     = CalendarService()
    let photoService        = PhotoMetadataService()
    let notificationService = NotificationService()

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

    func toggleCalendar(_ enabled: Bool) {
        calendarEnabled = enabled
        if enabled {
            calendarService.requestPermission { [weak self] granted in
                DispatchQueue.main.async { self?.calendarEnabled = granted }
            }
        }
    }

    func togglePhoto(_ enabled: Bool) {
        photoEnabled = enabled
        if enabled {
            photoService.requestPermission { [weak self] granted in
                DispatchQueue.main.async { self?.photoEnabled = granted }
            }
        }
    }

    func toggleNotifications(_ enabled: Bool, context: NSManagedObjectContext) {
        notificationEnabled = enabled
        if enabled {
            notificationService.requestPermission { [weak self] granted in
                guard let self, granted else { return }
                DispatchQueue.main.async {
                    self.notificationEnabled = true
                    self.notificationService.scheduleDailyReminder(hour: self.notifHour, minute: self.notifMinute)
                    self.notificationService.scheduleWeeklySummary(context: context)
                }
            }
        } else {
            notificationService.cancelAll()
        }
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

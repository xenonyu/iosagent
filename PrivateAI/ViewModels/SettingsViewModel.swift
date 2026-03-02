import Foundation
import CoreData
import Combine

final class SettingsViewModel: ObservableObject {

    @Published var showClearConfirm: Bool = false
    @Published var showExportAlert: Bool = false
    @Published var exportURL: URL? = nil

    private let context: NSManagedObjectContext
    private let appState: AppState

    init(context: NSManagedObjectContext, appState: AppState) {
        self.context = context
        self.appState = appState
    }

    func clearAllData() {
        appState.clearAllData(context: context)
    }

    func exportData() {
        let events = CDLifeEvent.fetchAll(in: context)
        let locations = CDLocationRecord.fetchAll(in: context)
        let profile = CDUserProfile.fetchOrCreate(in: context).toProfileData()

        var export: [String: Any] = [:]
        export["exportDate"] = ISO8601DateFormatter().string(from: Date())
        export["profile"] = [
            "name": profile.name,
            "occupation": profile.occupation,
            "interests": profile.interests
        ]
        export["events"] = events.map { e -> [String: Any] in
            return [
                "title": e.title,
                "content": e.content,
                "mood": e.mood.rawValue,
                "category": e.category.rawValue,
                "timestamp": ISO8601DateFormatter().string(from: e.timestamp)
            ]
        }
        export["locations"] = locations.map { l -> [String: Any] in
            return [
                "placeName": l.placeName,
                "address": l.address,
                "timestamp": ISO8601DateFormatter().string(from: l.timestamp)
            ]
        }

        if let data = try? JSONSerialization.data(withJSONObject: export, options: .prettyPrinted) {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("PrivateAI_Export_\(Date().timeIntervalSince1970).json")
            try? data.write(to: url)
            exportURL = url
            showExportAlert = true
        }
    }
}

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

    @Published var showImportPicker: Bool = false
    @Published var importResult: String? = nil

    func importData(from url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            importResult = "❌ 文件格式错误，请使用本应用导出的 JSON 文件"
            return
        }

        var importedCount = 0

        // Import events
        if let events = json["events"] as? [[String: Any]] {
            for e in events {
                guard let title = e["title"] as? String else { continue }
                let content = e["content"] as? String ?? ""
                let mood = MoodType(rawValue: e["mood"] as? String ?? "neutral") ?? .neutral
                let category = EventCategory(rawValue: e["category"] as? String ?? "life") ?? .life
                let timestamp: Date
                if let ts = e["timestamp"] as? String {
                    timestamp = ISO8601DateFormatter().date(from: ts) ?? Date()
                } else {
                    timestamp = Date()
                }
                let event = LifeEvent(title: title, content: content, mood: mood,
                                      category: category, timestamp: timestamp)
                CDLifeEvent.create(from: event, context: context)
                importedCount += 1
            }
            try? context.save()
        }

        importResult = "✅ 成功导入 \(importedCount) 条事件记录"
    }
}

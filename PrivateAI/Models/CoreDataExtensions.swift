import CoreData
import Foundation

// MARK: - CDChatMessage Helpers

extension CDChatMessage {
    func toModel() -> ChatMessage {
        ChatMessage(
            id: id ?? UUID(),
            content: content ?? "",
            isUser: isUser,
            timestamp: timestamp ?? Date()
        )
    }

    static func create(from message: ChatMessage, context: NSManagedObjectContext) {
        let cd = CDChatMessage(context: context)
        cd.id = message.id
        cd.content = message.content
        cd.isUser = message.isUser
        cd.timestamp = message.timestamp
    }

    static func fetchAll(in context: NSManagedObjectContext) -> [ChatMessage] {
        let request = CDChatMessage.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
        return (try? context.fetch(request))?.map { $0.toModel() } ?? []
    }

    static func deleteAll(in context: NSManagedObjectContext) {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "CDChatMessage")
        let deleteRequest = NSBatchDeleteRequest(fetchRequest: request)
        _ = try? context.execute(deleteRequest)
    }
}

// MARK: - CDLifeEvent Helpers

extension CDLifeEvent {
    func toModel() -> LifeEvent {
        let tagsArray = (tags ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        return LifeEvent(
            id: id ?? UUID(),
            title: title ?? "",
            content: content ?? "",
            mood: MoodType(rawValue: mood ?? "neutral") ?? .neutral,
            category: EventCategory(rawValue: category ?? "life") ?? .life,
            tags: tagsArray,
            timestamp: timestamp ?? Date()
        )
    }

    static func create(from event: LifeEvent, context: NSManagedObjectContext) {
        let cd = CDLifeEvent(context: context)
        cd.id = event.id
        cd.title = event.title
        cd.content = event.content
        cd.mood = event.mood.rawValue
        cd.category = event.category.rawValue
        cd.tags = event.tags.joined(separator: ",")
        cd.timestamp = event.timestamp
    }

    static func fetchAll(in context: NSManagedObjectContext) -> [LifeEvent] {
        let request = CDLifeEvent.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        return (try? context.fetch(request))?.map { $0.toModel() } ?? []
    }

    static func fetch(from: Date, to: Date, in context: NSManagedObjectContext) -> [LifeEvent] {
        let request = CDLifeEvent.fetchRequest()
        request.predicate = NSPredicate(format: "timestamp >= %@ AND timestamp <= %@", from as NSDate, to as NSDate)
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        return (try? context.fetch(request))?.map { $0.toModel() } ?? []
    }
}

// MARK: - CDLocationRecord Helpers

extension CDLocationRecord {
    func toModel() -> LocationRecord {
        LocationRecord(
            id: id ?? UUID(),
            latitude: latitude,
            longitude: longitude,
            altitude: altitude,
            address: address ?? "",
            placeName: placeName ?? "",
            duration: duration,
            timestamp: timestamp ?? Date()
        )
    }

    static func create(from record: LocationRecord, context: NSManagedObjectContext) {
        let cd = CDLocationRecord(context: context)
        cd.id = record.id
        cd.latitude = record.latitude
        cd.longitude = record.longitude
        cd.altitude = record.altitude
        cd.address = record.address
        cd.placeName = record.placeName
        cd.duration = record.duration
        cd.timestamp = record.timestamp
    }

    static func fetchAll(in context: NSManagedObjectContext) -> [LocationRecord] {
        let request = CDLocationRecord.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        return (try? context.fetch(request))?.map { $0.toModel() } ?? []
    }

    static func fetch(from: Date, to: Date, in context: NSManagedObjectContext) -> [LocationRecord] {
        let request = CDLocationRecord.fetchRequest()
        request.predicate = NSPredicate(format: "timestamp >= %@ AND timestamp <= %@", from as NSDate, to as NSDate)
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        return (try? context.fetch(request))?.map { $0.toModel() } ?? []
    }
}

// MARK: - CDUserProfile Helpers

extension CDUserProfile {
    func toProfileData() -> UserProfileData {
        var profile = UserProfileData()
        profile.name = name ?? ""
        profile.birthday = birthday
        profile.occupation = occupation ?? ""
        profile.notes = notes ?? ""
        profile.aiStyle = UserProfileData.AIStyle(rawValue: aiStyle ?? "friendly") ?? .friendly

        if let interestsStr = interests, !interestsStr.isEmpty,
           let data = interestsStr.data(using: .utf8),
           let array = try? JSONDecoder().decode([String].self, from: data) {
            profile.interests = array
        }

        if let familyStr = familyInfo, !familyStr.isEmpty,
           let data = familyStr.data(using: .utf8),
           let members = try? JSONDecoder().decode([FamilyMember].self, from: data) {
            profile.familyMembers = members
        }

        return profile
    }

    func update(from profile: UserProfileData) {
        name = profile.name
        birthday = profile.birthday
        occupation = profile.occupation
        notes = profile.notes
        aiStyle = profile.aiStyle.rawValue
        lastUpdated = Date()

        if let data = try? JSONEncoder().encode(profile.interests) {
            interests = String(data: data, encoding: .utf8)
        }

        if let data = try? JSONEncoder().encode(profile.familyMembers) {
            familyInfo = String(data: data, encoding: .utf8)
        }
    }

    static func fetchOrCreate(in context: NSManagedObjectContext) -> CDUserProfile {
        let request = CDUserProfile.fetchRequest()
        request.fetchLimit = 1
        if let existing = (try? context.fetch(request))?.first {
            return existing
        }
        let profile = CDUserProfile(context: context)
        profile.id = UUID()
        profile.lastUpdated = Date()
        return profile
    }
}

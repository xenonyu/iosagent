import Foundation
import CoreData
import Combine

final class ProfileViewModel: ObservableObject {

    @Published var profile: UserProfileData = UserProfileData()
    @Published var isSaved: Bool = false
    @Published var showAddFamily: Bool = false

    // New family member form
    @Published var newFamilyName: String = ""
    @Published var newFamilyRelation: String = ""
    @Published var newFamilyNotes: String = ""

    private let context: NSManagedObjectContext

    init(context: NSManagedObjectContext) {
        self.context = context
        load()
    }

    func load() {
        let cdProfile = CDUserProfile.fetchOrCreate(in: context)
        profile = cdProfile.toProfileData()
    }

    func save() {
        let cdProfile = CDUserProfile.fetchOrCreate(in: context)
        cdProfile.update(from: profile)
        PersistenceController.shared.save()
        withAnimation {
            isSaved = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.isSaved = false
        }
    }

    func addInterest(_ interest: String) {
        let trimmed = interest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !profile.interests.contains(trimmed) else { return }
        profile.interests.append(trimmed)
    }

    func removeInterest(_ interest: String) {
        profile.interests.removeAll { $0 == interest }
    }

    func addFamilyMember() {
        guard !newFamilyName.isEmpty, !newFamilyRelation.isEmpty else { return }
        let member = FamilyMember(
            name: newFamilyName,
            relation: newFamilyRelation,
            notes: newFamilyNotes
        )
        profile.familyMembers.append(member)
        newFamilyName = ""
        newFamilyRelation = ""
        newFamilyNotes = ""
        showAddFamily = false
    }

    func removeFamilyMember(_ member: FamilyMember) {
        profile.familyMembers.removeAll { $0.id == member.id }
    }
}

import Foundation

/// Handles personal profile and identity queries.
struct ProfileSkill: ClawSkill {

    let id = "profile"

    func canHandle(intent: QueryIntent) -> Bool {
        if case .profile = intent { return true }
        return false
    }

    func execute(intent: QueryIntent, context: SkillContext, completion: @escaping (String) -> Void) {
        completion(buildResponse(profile: context.profile))
    }

    private func buildResponse(profile: UserProfileData) -> String {
        guard !profile.name.isEmpty else {
            return "👤 您还没有填写个人信息。\n前往「我」页面完善您的资料，让我更了解您！"
        }

        var lines = ["👤 您的个人信息：\n"]
        lines.append("姓名：\(profile.name)")

        if let bd = profile.birthday {
            let age = Calendar.current.dateComponents([.year], from: bd, to: Date()).year ?? 0
            lines.append("年龄：\(age) 岁")
        }

        if !profile.occupation.isEmpty {
            lines.append("职业：\(profile.occupation)")
        }

        if !profile.interests.isEmpty {
            lines.append("兴趣：\(profile.interests.joined(separator: "、"))")
        }

        if !profile.familyMembers.isEmpty {
            lines.append("\n家人：")
            profile.familyMembers.forEach {
                lines.append("• \($0.relation)：\($0.name)")
            }
        }

        return lines.joined(separator: "\n")
    }
}

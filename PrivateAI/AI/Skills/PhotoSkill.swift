import Foundation

/// Handles photo statistics queries and photo search placeholders.
struct PhotoSkill: ClawSkill {

    let id = "photo"

    func canHandle(intent: QueryIntent) -> Bool {
        switch intent {
        case .photos, .photoSearch:
            return true
        default:
            return false
        }
    }

    func execute(intent: QueryIntent, context: SkillContext, completion: @escaping (String) -> Void) {
        switch intent {
        case .photos(let range):
            completion(buildPhotoStats(range: range, context: context))
        case .photoSearch:
            // Photo search UI is handled by ChatViewModel directly;
            // the engine returns a loading placeholder here.
            completion("📷 正在搜索照片...")
        default:
            break
        }
    }

    private func buildPhotoStats(range: QueryTimeRange, context: SkillContext) -> String {
        guard context.photoService.isAuthorized else {
            return "📷 相册权限未开启。\n请前往「设置 → iosclaw → 照片」，选择「所有照片」或「所选照片」。"
        }

        let interval = range.interval
        let photos = context.photoService.fetchMetadata(from: interval.start, to: interval.end)

        if photos.isEmpty {
            return "📷 \(range.label)没有找到照片。\n如果是有限访问权限，请在设置中选择更多照片，或者调整时间范围再试试。"
        }

        let withLocation = photos.filter { $0.hasLocation }.count
        let favorites = photos.filter { $0.isFavorite }.count

        let cal = Calendar.current
        var dayCount: [Date: Int] = [:]
        photos.forEach {
            let day = cal.startOfDay(for: $0.date)
            dayCount[day, default: 0] += 1
        }
        let mostActiveDay = dayCount.max(by: { $0.value < $1.value })

        var lines = ["📷 \(range.label)的照片活动：\n"]
        lines.append("总计拍了 \(photos.count) 张照片")
        if withLocation > 0 { lines.append("📍 其中 \(withLocation) 张有位置信息") }
        if favorites > 0 { lines.append("❤️ 标记了 \(favorites) 张收藏") }

        if let (day, count) = mostActiveDay {
            let df = DateFormatter()
            df.dateFormat = "M月d日"
            lines.append("\n🏆 最活跃的一天：\(df.string(from: day))（\(count) 张）")
        }

        return lines.joined(separator: "\n")
    }
}

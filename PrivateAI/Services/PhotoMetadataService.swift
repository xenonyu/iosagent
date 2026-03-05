import Foundation
import Photos

/// Reads only photo metadata (date + location). Never reads image content.
/// No photos are uploaded or stored — only date/coordinate summaries.
final class PhotoMetadataService: ObservableObject {

    // MARK: - Permission

    func requestPermission(completion: @escaping (Bool) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            DispatchQueue.main.async {
                completion(status == .authorized || status == .limited)
            }
        }
    }

    var isAuthorized: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .authorized || status == .limited
    }

    // MARK: - Fetch

    /// Fetches metadata for the most recent N photos.
    func fetchRecentMetadata(limit: Int = 100) -> [PhotoMetadataItem] {
        guard isAuthorized else { return [] }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = limit

        let results = PHAsset.fetchAssets(with: .image, options: options)
        var items: [PhotoMetadataItem] = []

        results.enumerateObjects { asset, _, _ in
            items.append(PhotoMetadataItem(
                id: asset.localIdentifier,
                date: asset.creationDate ?? Date(),
                latitude: asset.location?.coordinate.latitude,
                longitude: asset.location?.coordinate.longitude,
                isFavorite: asset.isFavorite
            ))
        }

        return items
    }

    /// Fetches photos within a date range.
    func fetchMetadata(from: Date, to: Date) -> [PhotoMetadataItem] {
        guard isAuthorized else { return [] }

        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate <= %@",
            from as NSDate, to as NSDate
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let results = PHAsset.fetchAssets(with: .image, options: options)
        var items: [PhotoMetadataItem] = []

        results.enumerateObjects { asset, _, _ in
            items.append(PhotoMetadataItem(
                id: asset.localIdentifier,
                date: asset.creationDate ?? Date(),
                latitude: asset.location?.coordinate.latitude,
                longitude: asset.location?.coordinate.longitude,
                isFavorite: asset.isFavorite
            ))
        }

        return items
    }

    /// Count of photos per day for a given range (for activity inference).
    func dailyPhotoCounts(from: Date, to: Date) -> [Date: Int] {
        let items = fetchMetadata(from: from, to: to)
        let cal = Calendar.current
        var counts: [Date: Int] = [:]
        items.forEach {
            let day = cal.startOfDay(for: $0.date)
            counts[day, default: 0] += 1
        }
        return counts
    }
}

// MARK: - Model

struct PhotoMetadataItem: Identifiable {
    let id: String
    let date: Date
    let latitude: Double?
    let longitude: Double?
    let isFavorite: Bool

    var hasLocation: Bool { latitude != nil && longitude != nil }
}

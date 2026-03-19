import Foundation
import Photos
import CoreLocation

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
        // Check both the new access-level API and the legacy API for robustness
        let newStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if newStatus == .authorized || newStatus == .limited { return true }
        let legacyStatus = PHPhotoLibrary.authorizationStatus()
        return legacyStatus == .authorized || legacyStatus == .limited
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

    // MARK: - Location-Based Search

    /// Fetches photos near a given coordinate within a radius (meters).
    func fetchNearby(latitude: Double, longitude: Double, radiusMeters: Double = 50_000,
                     from: Date? = nil, to: Date? = nil, limit: Int = 200) -> [PhotoMetadataItem] {
        guard isAuthorized else { return [] }

        let options = PHFetchOptions()
        var predicateFormat = "creationDate != nil"
        var args: [Any] = []

        if let from = from {
            predicateFormat += " AND creationDate >= %@"
            args.append(from as NSDate)
        }
        if let to = to {
            predicateFormat += " AND creationDate <= %@"
            args.append(to as NSDate)
        }

        options.predicate = NSPredicate(format: predicateFormat, argumentArray: args)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let results = PHAsset.fetchAssets(with: .image, options: options)
        var items: [PhotoMetadataItem] = []

        let center = CLLocation(latitude: latitude, longitude: longitude)

        results.enumerateObjects { asset, _, stop in
            guard let loc = asset.location else { return }
            let dist = loc.distance(from: center)
            if dist <= radiusMeters {
                items.append(PhotoMetadataItem(
                    id: asset.localIdentifier,
                    date: asset.creationDate ?? Date(),
                    latitude: loc.coordinate.latitude,
                    longitude: loc.coordinate.longitude,
                    isFavorite: asset.isFavorite
                ))
            }
            // Stop after scanning enough assets to avoid excessive enumeration
            if items.count >= limit { stop.pointee = true }
        }

        return items
    }

    /// Fetches only favorited photos in a date range.
    func fetchFavorites(from: Date? = nil, to: Date? = nil, limit: Int = 100) -> [PhotoMetadataItem] {
        guard isAuthorized else { return [] }

        let options = PHFetchOptions()
        var predicateFormat = "isFavorite == YES"
        var args: [Any] = []

        if let from = from {
            predicateFormat += " AND creationDate >= %@"
            args.append(from as NSDate)
        }
        if let to = to {
            predicateFormat += " AND creationDate <= %@"
            args.append(to as NSDate)
        }

        options.predicate = NSPredicate(format: predicateFormat, argumentArray: args)
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

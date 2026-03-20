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

    /// Fetches metadata for the most recent N photos (images only, excludes videos).
    func fetchRecentMetadata(limit: Int = 100) -> [PhotoMetadataItem] {
        guard isAuthorized else { return [] }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = limit

        let results = PHAsset.fetchAssets(with: .image, options: options)
        var items: [PhotoMetadataItem] = []

        results.enumerateObjects { asset, _, _ in
            items.append(Self.metadataItem(from: asset))
        }

        return items
    }

    /// Fetches photos within a date range (images only).
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
            items.append(Self.metadataItem(from: asset))
        }

        return items
    }

    // MARK: - Media Type Filtered Fetch

    /// Fetches assets matching a specific media kind, optionally within a date range.
    func fetchByMediaKind(_ kind: PhotoMediaKind, from: Date? = nil, to: Date? = nil,
                          limit: Int = 200) -> [PhotoMetadataItem] {
        guard isAuthorized else { return [] }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        // Video-based kinds need mediaType == .video
        let isVideoKind = kind == .video || kind == .sloMo || kind == .timelapse
        let mediaType: PHAssetMediaType = isVideoKind ? .video : .image

        var predicateParts: [String] = []
        var args: [Any] = []

        // Subtype filter via bitmask for non-video image kinds
        if !isVideoKind {
            switch kind {
            case .screenshot:
                predicateParts.append("(mediaSubtypes & %d) != 0")
                args.append(PHAssetMediaSubtype.photoScreenshot.rawValue)
            case .livePhoto:
                predicateParts.append("(mediaSubtypes & %d) != 0")
                args.append(PHAssetMediaSubtype.photoLive.rawValue)
            case .panorama:
                predicateParts.append("(mediaSubtypes & %d) != 0")
                args.append(PHAssetMediaSubtype.photoPanorama.rawValue)
            case .hdr:
                predicateParts.append("(mediaSubtypes & %d) != 0")
                args.append(PHAssetMediaSubtype.photoHDR.rawValue)
            case .depthEffect:
                predicateParts.append("(mediaSubtypes & %d) != 0")
                args.append(PHAssetMediaSubtype.photoDepthEffect.rawValue)
            case .burst:
                predicateParts.append("burstIdentifier != nil")
            default:
                break
            }
        } else {
            switch kind {
            case .sloMo:
                predicateParts.append("(mediaSubtypes & %d) != 0")
                args.append(PHAssetMediaSubtype.videoHighFrameRate.rawValue)
            case .timelapse:
                predicateParts.append("(mediaSubtypes & %d) != 0")
                args.append(PHAssetMediaSubtype.videoTimelapse.rawValue)
            default:
                break // plain .video — all video types
            }
        }

        if let from = from {
            predicateParts.append("creationDate >= %@")
            args.append(from as NSDate)
        }
        if let to = to {
            predicateParts.append("creationDate <= %@")
            args.append(to as NSDate)
        }

        if !predicateParts.isEmpty {
            options.predicate = NSPredicate(format: predicateParts.joined(separator: " AND "),
                                            argumentArray: args)
        }
        options.fetchLimit = limit

        let results = PHAsset.fetchAssets(with: mediaType, options: options)
        var items: [PhotoMetadataItem] = []

        results.enumerateObjects { asset, _, _ in
            items.append(Self.metadataItem(from: asset))
        }

        return items
    }

    /// Fetches all media types (images + videos) within a date range.
    func fetchAllMedia(from: Date, to: Date, limit: Int = 500) -> [PhotoMetadataItem] {
        guard isAuthorized else { return [] }

        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate <= %@",
            from as NSDate, to as NSDate
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = limit

        // Fetch without mediaType filter to include both images and videos
        let results = PHAsset.fetchAssets(with: options)
        var items: [PhotoMetadataItem] = []

        results.enumerateObjects { asset, _, _ in
            items.append(Self.metadataItem(from: asset))
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
                items.append(Self.metadataItem(from: asset))
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
            items.append(Self.metadataItem(from: asset))
        }

        return items
    }

    // MARK: - PHAsset → PhotoMetadataItem

    /// Classifies a PHAsset into a PhotoMediaKind based on its mediaType and mediaSubtypes.
    private static func classifyMediaKind(_ asset: PHAsset) -> PhotoMediaKind {
        if asset.mediaType == .video {
            if asset.mediaSubtypes.contains(.videoTimelapse) { return .timelapse }
            if asset.mediaSubtypes.contains(.videoHighFrameRate) { return .sloMo }
            return .video
        }
        // Image subtypes (order matters: most specific first)
        if asset.mediaSubtypes.contains(.photoScreenshot) { return .screenshot }
        if asset.mediaSubtypes.contains(.photoDepthEffect) { return .depthEffect }
        if asset.mediaSubtypes.contains(.photoPanorama) { return .panorama }
        if asset.mediaSubtypes.contains(.photoLive) { return .livePhoto }
        if asset.mediaSubtypes.contains(.photoHDR) { return .hdr }
        if asset.burstIdentifier != nil { return .burst }
        return .photo
    }

    /// Creates a PhotoMetadataItem from a PHAsset, extracting all available metadata.
    static func metadataItem(from asset: PHAsset) -> PhotoMetadataItem {
        PhotoMetadataItem(
            id: asset.localIdentifier,
            date: asset.creationDate ?? Date(),
            latitude: asset.location?.coordinate.latitude,
            longitude: asset.location?.coordinate.longitude,
            isFavorite: asset.isFavorite,
            mediaKind: classifyMediaKind(asset),
            duration: asset.duration,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight
        )
    }
}

// MARK: - Model

/// Media type classification for photo library assets.
enum PhotoMediaKind: String {
    case photo          // Standard photo
    case video          // Video clip
    case screenshot     // Screenshot capture
    case livePhoto      // Live Photo (image + short video)
    case panorama       // Panoramic photo
    case hdr            // HDR photo
    case burst          // Part of a burst sequence
    case depthEffect    // Portrait mode / depth effect
    case sloMo          // Slow-motion video
    case timelapse      // Time-lapse video

    var label: String {
        switch self {
        case .photo: return "照片"
        case .video: return "视频"
        case .screenshot: return "截图"
        case .livePhoto: return "实况照片"
        case .panorama: return "全景照片"
        case .hdr: return "HDR 照片"
        case .burst: return "连拍照片"
        case .depthEffect: return "人像照片"
        case .sloMo: return "慢动作视频"
        case .timelapse: return "延时摄影"
        }
    }

    var emoji: String {
        switch self {
        case .photo: return "📷"
        case .video: return "🎬"
        case .screenshot: return "📱"
        case .livePhoto: return "◉"
        case .panorama: return "🌅"
        case .hdr: return "🌈"
        case .burst: return "📸"
        case .depthEffect: return "🎭"
        case .sloMo: return "🐢"
        case .timelapse: return "⏱️"
        }
    }
}

struct PhotoMetadataItem: Identifiable {
    let id: String
    let date: Date
    let latitude: Double?
    let longitude: Double?
    let isFavorite: Bool
    let mediaKind: PhotoMediaKind
    let duration: TimeInterval   // > 0 for videos
    let pixelWidth: Int
    let pixelHeight: Int

    var hasLocation: Bool { latitude != nil && longitude != nil }
    var isVideo: Bool { mediaKind == .video || mediaKind == .sloMo || mediaKind == .timelapse }
    var isScreenshot: Bool { mediaKind == .screenshot }

    /// Convenience initializer for backward compatibility (defaults to .photo).
    init(id: String, date: Date, latitude: Double?, longitude: Double?,
         isFavorite: Bool, mediaKind: PhotoMediaKind = .photo,
         duration: TimeInterval = 0, pixelWidth: Int = 0, pixelHeight: Int = 0) {
        self.id = id
        self.date = date
        self.latitude = latitude
        self.longitude = longitude
        self.isFavorite = isFavorite
        self.mediaKind = mediaKind
        self.duration = duration
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

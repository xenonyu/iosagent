import Foundation
import CoreLocation
import CoreData

/// Tracks user location in background at low frequency to preserve battery.
/// Saves significant location changes only — no continuous GPS drain.
final class LocationService: NSObject, ObservableObject {

    // MARK: - Published

    @Published var currentLocation: CLLocation?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined

    /// Reverse-geocoded place name for the current live position.
    /// Updated whenever `currentLocation` changes. Used by GPTContextBuilder
    /// to show "📍 当前位置：南京西路" instead of raw coordinates.
    @Published var currentPlaceName: String?
    @Published var currentAddress: String?

    // MARK: - Private

    private let manager = CLLocationManager()
    private var permissionCallback: ((Bool) -> Void)?
    private var lastSavedLocation: CLLocation?
    private let minimumDistanceMeters: Double = 200  // Save if moved >200m
    private let minimumIntervalSeconds: Double = 300 // Save max once per 5 min
    private var lastSaveDate: Date?
    private let geocoder = CLGeocoder()

    // MARK: - Init

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 200 // CLLocationManager also filters at 200m
        manager.pausesLocationUpdatesAutomatically = true
        manager.activityType = .other
        authorizationStatus = manager.authorizationStatus
    }

    // MARK: - Public API

    func requestPermission(completion: @escaping (Bool) -> Void) {
        permissionCallback = completion
        manager.requestAlwaysAuthorization()
    }

    func startTracking() {
        guard manager.authorizationStatus == .authorizedAlways ||
              manager.authorizationStatus == .authorizedWhenInUse else { return }
        manager.startMonitoringSignificantLocationChanges()
        manager.allowsBackgroundLocationUpdates = true
    }

    func stopTracking() {
        manager.stopMonitoringSignificantLocationChanges()
        manager.allowsBackgroundLocationUpdates = false
    }

    // MARK: - Saving

    private func saveIfNeeded(_ location: CLLocation) {
        let now = Date()

        // Debounce: skip if too recent
        if let last = lastSaveDate, now.timeIntervalSince(last) < minimumIntervalSeconds {
            return
        }

        // Skip if barely moved
        if let prev = lastSavedLocation,
           location.distance(from: prev) < minimumDistanceMeters {
            return
        }

        lastSavedLocation = location
        lastSaveDate = now

        reverseGeocode(location) { placeName, address in
            let record = LocationRecord(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                altitude: location.altitude,
                address: address,
                placeName: placeName,
                timestamp: now
            )
            self.persistRecord(record)
        }
    }

    private func reverseGeocode(_ location: CLLocation, completion: @escaping (String, String) -> Void) {
        geocoder.reverseGeocodeLocation(location) { placemarks, _ in
            guard let placemark = placemarks?.first else {
                completion("", "")
                return
            }
            let placeName = placemark.name ?? placemark.locality ?? ""
            let address = [
                placemark.thoroughfare,
                placemark.locality,
                placemark.administrativeArea
            ].compactMap { $0 }.joined(separator: ", ")
            completion(placeName, address)
        }
    }

    private func persistRecord(_ record: LocationRecord) {
        let ctx = PersistenceController.shared.newBackgroundContext()
        ctx.perform {
            CDLocationRecord.create(from: record, context: ctx)
            try? ctx.save()
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationService: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        DispatchQueue.main.async { self.currentLocation = location }
        saveIfNeeded(location)
        geocodeCurrentLocation(location)
    }

    /// Reverse-geocodes the live position so GPTContextBuilder can show a
    /// human-readable name (e.g. "南京西路") instead of raw coordinates.
    /// Only fires on significant-change updates (≥200m), so geocoding is
    /// infrequent and Apple's rate limits are not a concern.
    private func geocodeCurrentLocation(_ location: CLLocation) {
        // Skip if we already have a geocoded name for a nearby position.
        // Prevents redundant geocoding when multiple updates arrive for
        // the same approximate spot (e.g. GPS drift within 100m).
        if let existing = currentLocation,
           let _ = currentPlaceName,
           location.distance(from: existing) < 100 {
            return
        }
        // Use a separate geocoder instance to avoid cancelling the save
        // geocoder if both fire at the same time. CLGeocoder only allows
        // one outstanding request per instance.
        let liveGeocoder = CLGeocoder()
        liveGeocoder.reverseGeocodeLocation(location) { [weak self] placemarks, _ in
            guard let self, let placemark = placemarks?.first else { return }
            let name = placemark.name ?? placemark.locality ?? ""
            let addr = [
                placemark.thoroughfare,
                placemark.locality,
                placemark.administrativeArea
            ].compactMap { $0 }.joined(separator: ", ")
            DispatchQueue.main.async {
                self.currentPlaceName = name.isEmpty ? nil : name
                self.currentAddress = addr.isEmpty ? nil : addr
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        DispatchQueue.main.async { self.authorizationStatus = status }
        let granted = status == .authorizedAlways || status == .authorizedWhenInUse
        permissionCallback?(granted)
        permissionCallback = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location error: \(error.localizedDescription)")
    }
}

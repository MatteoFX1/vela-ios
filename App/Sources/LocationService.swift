import CoreLocation
import Foundation
import UIKit

/** GPS for search bias and navigation. The map draws its own blue dot; this feeds the app. */
@MainActor
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var last: CLLocation?
    @Published private(set) var authorized = false
    /** Location is off for Kite (or for the whole phone): only Settings can turn it back on. */
    @Published private(set) var denied = false
    @Published private(set) var reducedAccuracy = false
    var onUpdate: (@MainActor (CLLocation) -> Void)?
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .automotiveNavigation
        reducedAccuracy = manager.accuracyAuthorization == .reducedAccuracy
    }

    func start() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.startUpdatingLocation()
    }

    /** Full-rate GPS that keeps running with the screen off, for a drive. */
    func setNavigating(_ on: Bool, mode: Int = 0) {
        manager.activityType = mode == 0 ? .automotiveNavigation : .fitness
        manager.distanceFilter = kCLDistanceFilterNone
        manager.desiredAccuracy = on ? kCLLocationAccuracyBestForNavigation : kCLLocationAccuracyBest
        manager.allowsBackgroundLocationUpdates = on
        manager.pausesLocationUpdatesAutomatically = !on
        manager.showsBackgroundLocationIndicator = on
        manager.startUpdatingLocation()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last, loc.horizontalAccuracy >= 0,
              abs(loc.timestamp.timeIntervalSinceNow) < 120 else { return }
        Task { @MainActor in
            self.last = loc
            self.onUpdate?(loc)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        let reduced = manager.accuracyAuthorization == .reducedAccuracy
        Task { @MainActor in
            self.authorized = s == .authorizedWhenInUse || s == .authorizedAlways
            self.denied = s == .denied || s == .restricted
            self.reducedAccuracy = reduced
            if self.authorized { self.manager.startUpdatingLocation() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    /** Kite's page in the Settings app, where location can be turned back on. */
    static func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}

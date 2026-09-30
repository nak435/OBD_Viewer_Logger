import CoreLocation
import Foundation

// CoreLocationによる緯度経度の取得。Tab5のGPSユニット(gpsTaskFunc)相当。
// ★バックグラウンドでも取得を続けるため、Info.plistの UIBackgroundModes に
//   "location" が必要（無い状態で allowsBackgroundLocationUpdates=true にするとクラッシュする）。
//   位置情報の更新自体がアプリを生かし続けるので、BLEのバックグラウンド動作の助けにもなる。
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var lastLocation: CLLocation?
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()
    private var wantsUpdates = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false // 信号待ち等で勝手に止めない
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        authorization = manager.authorizationStatus
    }

    func start() {
        RealmManager.logEvent("GPS", "start (authorization=\(authName(manager.authorizationStatus)))")
        wantsUpdates = true
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization() // 許可後に locationManagerDidChangeAuthorization が来る
        } else {
            manager.startUpdatingLocation()
        }
    }

    func stop() {
        RealmManager.logEvent("GPS", "stop")
        wantsUpdates = false
        manager.stopUpdatingLocation()
    }

    /// 直近 maxAge 秒以内に測位できた位置を返す（古い/無ければ nil）。
    /// Tab5の isGpsFixFresh(3秒) に相当。
    func currentFix(maxAge: TimeInterval = 5) -> CLLocation? {
        guard let loc = lastLocation, loc.horizontalAccuracy >= 0,
              Date().timeIntervalSince(loc.timestamp) <= maxAge else { return nil }
        return loc
    }

    private func authName(_ s: CLAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorizedAlways: return "always"
        case .authorizedWhenInUse: return "whenInUse"
        @unknown default: return "\(s.rawValue)"
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        RealmManager.logEvent("GPS", "authorization = \(authName(manager.authorizationStatus))")
        if wantsUpdates,
           manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let loc = locations.last { lastLocation = loc }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[Location] failed: \(error.localizedDescription)")
        RealmManager.logEvent("GPS", "failed: \(error.localizedDescription)")
    }
}

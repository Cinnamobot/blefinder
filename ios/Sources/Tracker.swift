import Foundation
import CoreMotion
import CoreLocation

/// A tracking session: records the user's own movement, pairs each position
/// with the target's RSSI-derived range, and multilaterates the target.
///
/// Position source: inertial dead reckoning first (pedometer step distance,
/// which is accelerometer-driven, plus the heading from CLLocationManager's
/// CLHeading — the documented, calibrated compass). GPS jitters by metres —
/// larger than the search area — so it is only a fallback for when the
/// pedometer cannot run at all.
/// Sensor problems are surfaced via `notice` instead of failing silently.
final class Tracker: NSObject, ObservableObject {
    @Published var isRunning = false
    @Published var posX = 0.0   // east of start, metres
    @Published var posY = 0.0   // north of start, metres
    @Published var headingDeg = 0.0
    @Published var track: [(x: Double, y: Double)] = []
    @Published var result: SolveResult?
    @Published var sampleCount = 0
    @Published var latestRange: Double?
    @Published var notice = ""
    @Published var gpsAccuracy: Double?
    @Published var usingGPS = false

    /// Calibration: RSSI expected at 1 m, and the path-loss exponent.
    var txPower = -59.0
    var pathLoss = 2.0

    private let pedometer = CMPedometer()
    private let locationManager = CLLocationManager()
    private var samples: [SamplePoint] = []
    private var lastPedometerDistance = 0.0
    private var lastSampleAt = Date.distantPast
    private var lastSamplePos: (x: Double, y: Double)?
    private var originLat: Double?
    private var originLon: Double?
    private var pedometerFailed = false
    private var pedometerErrorReported = false

    /// "慣性モード" while the pedometer drives the position, "GPSモード" in fallback.
    var modeText: String { pedometerFailed ? "GPSモード（予備）" : "慣性モード（歩数＋コンパス方位）" }

    /// Farthest any track point is from the start point (movement check).
    var maxSpreadFromStart: Double {
        track.map { hypot($0.x, $0.y) }.max() ?? 0
    }
    var distanceFromOrigin: Double { hypot(posX, posY) }

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.headingOrientation = .portrait
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = kCLDistanceFilterNone
    }

    func start() {
        pedometerFailed = !CMPedometer.isDistanceAvailable()
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()  // GPS fallback + authorization only
        if CLLocationManager.headingAvailable() {
            locationManager.startUpdatingHeading()  // primary heading source (CLHeading)
        }
        if CMPedometer.authorizationStatus() == .denied {
            pedometerFailed = true
            notice = "モーションの許可がありません（設定→プライバシーとセキュリティ→モーションとフィットネス）。GPSモードで代替します"
        }
        startPedometer()
        pedometerErrorReported = false
        isRunning = true
    }

    func stop() {
        pedometer.stopUpdates()
        locationManager.stopUpdatingHeading()
        locationManager.stopUpdatingLocation()
        isRunning = false
    }

    func reset() {
        samples = []
        track = []
        posX = 0; posY = 0
        result = nil
        sampleCount = 0
        latestRange = nil
        originLat = nil; originLon = nil
        lastSamplePos = nil
        usingGPS = false
        gpsAccuracy = nil
        lastPedometerDistance = 0
        if isRunning {
            pedometer.stopUpdates()
            startPedometer()
        }
    }

    private func startPedometer() {
        guard CMPedometer.isDistanceAvailable() else { return }
        pedometer.startUpdates(from: Date()) { [weak self] data, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async {
                    self.pedometerFailed = true
                    if !self.pedometerErrorReported {
                        self.pedometerErrorReported = true
                        self.notice = "歩行データを取得できませんでした（\(error.localizedDescription)）。GPSモードで代替します"
                    }
                }
                return
            }
            guard let data, let dist = data.distance else { return }
            DispatchQueue.main.async { self.handlePedometer(total: dist.doubleValue) }
        }
    }

    func addRSSI(_ rssi: Double) {
        guard isRunning else { return }
        let now = Date()
        guard now.timeIntervalSince(lastSampleAt) > 0.35 else { return }
        // Standing still piles every sample onto one point and poisons the
        // solve; require real movement (or a long pause) between samples.
        if let lp = lastSamplePos,
           hypot(posX - lp.x, posY - lp.y) < 0.15,
           now.timeIntervalSince(lastSampleAt) < 1.5 { return }
        lastSampleAt = now
        lastSamplePos = (posX, posY)
        let d = Multilateration.distance(rssi: rssi, txPower: txPower, pathLossExponent: pathLoss)
        latestRange = d
        samples.append(SamplePoint(x: posX, y: posY, distance: d))
        if samples.count > 400 { samples.removeFirst(samples.count - 400) }
        sampleCount = samples.count
        result = Multilateration.solve(samples: samples)
    }

    /// Distance to the estimate and its bearing relative to the way the
    /// phone is facing (0 = straight ahead, + = right).
    var guidance: (distance: Double, relativeBearing: Double)? {
        guard let r = result else { return nil }
        let dx = r.x - posX, dy = r.y - posY
        let dist = hypot(dx, dy)
        var bearing = atan2(dx, dy) * 180 / .pi
        if bearing < 0 { bearing += 360 }
        var rel = bearing - headingDeg
        while rel > 180 { rel -= 360 }
        while rel < -180 { rel += 360 }
        return (dist, rel)
    }

    private func setPosition(x: Double, y: Double) {
        posX = x; posY = y
        if let last = track.last {
            if hypot(x - last.x, y - last.y) > 0.5 {
                track.append((x, y))
                if track.count > 600 { track.removeFirst(track.count - 600) }
            }
        } else {
            track.append((x, y))
        }
    }

    private func handlePedometer(total: Double) {
        let delta = total - lastPedometerDistance
        lastPedometerDistance = total
        guard delta > 0.03, delta < 5 else { return }
        guard !pedometerFailed else { return }
        usingGPS = false
        let rad = headingDeg * .pi / 180
        setPosition(x: posX + delta * sin(rad), y: posY + delta * cos(rad))
    }

    private func handleLocation(_ location: CLLocation) {
        let acc = location.horizontalAccuracy
        gpsAccuracy = acc >= 0 ? acc : nil
        // GPS is jittery at this scale; use it only when inertial tracking
        // cannot run at all.
        guard pedometerFailed else { return }
        guard acc >= 0, acc <= 30 else { return }  // too rough to anchor on
        if originLat == nil {
            originLat = location.coordinate.latitude
            originLon = location.coordinate.longitude
            setPosition(x: 0, y: 0)
        }
        guard let lat0 = originLat, let lon0 = originLon else { return }
        let metersPerDegLon = 111_320.0 * cos(lat0 * .pi / 180)
        let metersPerDegLat = 110_574.0
        let x = (location.coordinate.longitude - lon0) * metersPerDegLon
        let y = (location.coordinate.latitude - lat0) * metersPerDegLat
        usingGPS = true
        setPosition(x: x, y: y)
    }
}

extension Tracker: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isRunning, let last = locations.last else { return }
        handleLocation(last)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        // CLHeading is the heading source: trueHeading is degrees clockwise
        // from true north (0 = north, 90 = east), already calibrated by iOS.
        let h = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        headingDeg = h
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .denied, .restricted:
            notice = "位置情報の許可がありません（設定→プライバシーとセキュリティ→位置情報サービス）。GPSと方位が使えません"
        default:
            break
        }
    }

    func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        true
    }
}

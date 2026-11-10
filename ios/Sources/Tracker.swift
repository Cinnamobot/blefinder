import Foundation
import CoreMotion
import CoreLocation

/// A tracking session: dead-reckons the user's own movement with the
/// pedometer (distance) + compass (heading), pairs each position with the
/// target's RSSI-derived range, and multilaterates the target's position.
final class Tracker: NSObject, ObservableObject {
    @Published var isRunning = false
    @Published var posX = 0.0   // east of start, metres
    @Published var posY = 0.0   // north of start, metres
    @Published var headingDeg = 0.0
    @Published var track: [(x: Double, y: Double)] = [(0, 0)]
    @Published var result: SolveResult?
    @Published var sampleCount = 0
    @Published var latestRange: Double?
    @Published var notice = ""

    /// Calibration: RSSI expected at 1 m, and the path-loss exponent.
    var txPower = -59.0
    var pathLoss = 2.0

    private let pedometer = CMPedometer()
    private let locationManager = CLLocationManager()
    private var samples: [SamplePoint] = []
    private var lastPedometerDistance = 0.0
    private var lastSampleAt = Date.distantPast
    private var sessionStart = Date()

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.headingOrientation = .portrait
    }

    func start() {
        sessionStart = Date()
        lastPedometerDistance = 0
        locationManager.requestWhenInUseAuthorization()
        if CLLocationManager.headingAvailable() {
            locationManager.startUpdatingHeading()
        } else {
            notice = "この端末ではコンパスが使えません"
        }
        guard CMPedometer.isDistanceAvailable() else {
            notice = "この端末では歩行距離が測れません"
            return
        }
        pedometer.startUpdates(from: sessionStart) { [weak self] data, _ in
            guard let self, let data, let dist = data.distance else { return }
            DispatchQueue.main.async { self.handlePedometer(total: dist.doubleValue) }
        }
        isRunning = true
        notice = ""
    }

    func stop() {
        pedometer.stopUpdates()
        locationManager.stopUpdatingHeading()
        isRunning = false
    }

    func reset() {
        let wasRunning = isRunning
        if wasRunning { stop() }
        samples = []
        track = [(0, 0)]
        posX = 0; posY = 0
        result = nil
        sampleCount = 0
        latestRange = nil
        lastPedometerDistance = 0
        if wasRunning { start() }
    }

    func addRSSI(_ rssi: Double) {
        guard isRunning else { return }
        let now = Date()
        guard now.timeIntervalSince(lastSampleAt) > 0.35 else { return }
        lastSampleAt = now
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

    private func handlePedometer(total: Double) {
        let delta = total - lastPedometerDistance
        lastPedometerDistance = total
        guard delta > 0.03, delta < 5 else { return }
        let rad = headingDeg * .pi / 180
        posX += delta * sin(rad)
        posY += delta * cos(rad)
        if let last = track.last, hypot(posX - last.x, posY - last.y) > 0.4 {
            track.append((posX, posY))
            if track.count > 600 { track.removeFirst(track.count - 600) }
        }
    }
}

extension Tracker: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let h = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        headingDeg = h
    }

    func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        true
    }
}

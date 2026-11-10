import Foundation

/// One RSSI observation converted to an estimated range, taken at a known
/// position relative to where tracking started (x = east, y = north, metres).
struct SamplePoint {
    var x: Double
    var y: Double
    var distance: Double
}

struct SolveResult {
    var x: Double
    var y: Double
    /// RMS of (measured range - fitted range); a rough accuracy indicator.
    var residualRMS: Double
    /// When the walked track is almost a straight line, the true position and
    /// its mirror image across the track fit the data equally well. The mirror
    /// candidate is reported until the user also moves sideways.
    var mirror: (x: Double, y: Double)?
    /// Spread of sample positions perpendicular to the dominant walk direction.
    var lateralSpread: Double
}

enum Multilateration {
    /// Log-distance path loss: d = 10 ^ ((txPower - rssi) / (10 * n))
    static func distance(rssi: Double, txPower: Double, pathLossExponent n: Double) -> Double {
        let d = pow(10.0, (txPower - rssi) / (10.0 * n))
        return min(max(d, 0.3), 80.0)
    }

    static func solve(samples input: [SamplePoint]) -> SolveResult? {
        guard input.count >= 3 else { return nil }
        // Two passes: solve once, drop gross outliers, solve again.
        var working = input
        if let first = gaussNewton(samples: working) {
            let kept = working.filter { s in
                let r = hypot(first.x - s.x, first.y - s.y)
                return abs(r - s.distance) <= max(2.5 * first.rms, 2.0)
            }
            if kept.count >= 3 { working = kept }
        }
        guard let fit = gaussNewton(samples: working) else { return nil }

        // Principal-axis analysis of the sample positions (collinearity check).
        let n = Double(working.count)
        let mx = working.reduce(0) { $0 + $1.x } / n
        let my = working.reduce(0) { $0 + $1.y } / n
        var cxx = 0.0, cyy = 0.0, cxy = 0.0
        for s in working {
            cxx += (s.x - mx) * (s.x - mx)
            cyy += (s.y - my) * (s.y - my)
            cxy += (s.x - mx) * (s.y - my)
        }
        let theta = 0.5 * atan2(2 * cxy, cxx - cyy)
        let cu = cos(theta), su = sin(theta)
        var varU = 0.0, varV = 0.0
        for s in working {
            let du = (s.x - mx) * cu + (s.y - my) * su
            let dv = -(s.x - mx) * su + (s.y - my) * cu
            varU += du * du; varV += dv * dv
        }
        let spreadU = (varU / n).squareRoot()
        let spreadV = (varV / n).squareRoot()

        var mirror: (x: Double, y: Double)? = nil
        if spreadV < 0.9 && spreadU > 1.5 {
            let du = (fit.x - mx) * cu + (fit.y - my) * su
            let dv = -(fit.x - mx) * su + (fit.y - my) * cu
            mirror = (x: mx + du * cu + dv * su, y: my + du * su - dv * cu)
        }
        return SolveResult(x: fit.x, y: fit.y, residualRMS: fit.rms,
                           mirror: mirror, lateralSpread: spreadV)
    }

    private static func gaussNewton(samples: [SamplePoint]) -> (x: Double, y: Double, rms: Double)? {
        guard !samples.isEmpty else { return nil }
        var wx = 0.0, wy = 0.0, wsum = 0.0
        for s in samples {
            let w = 1.0 / max(s.distance * s.distance, 0.09)
            wx += s.x * w; wy += s.y * w; wsum += w
        }
        var px = wx / wsum, py = wy / wsum
        for _ in 0..<60 {
            var a11 = 0.0, a12 = 0.0, a22 = 0.0, b1 = 0.0, b2 = 0.0
            for s in samples {
                let dx = px - s.x, dy = py - s.y
                let r = max(hypot(dx, dy), 0.05)
                let res = r - s.distance
                let ux = dx / r, uy = dy / r
                a11 += ux * ux; a12 += ux * uy; a22 += uy * uy
                b1 -= ux * res; b2 -= uy * res
            }
            let det = a11 * a22 - a12 * a12
            if abs(det) < 1e-9 { break }
            let stepX = (b1 * a22 - b2 * a12) / det
            let stepY = (a11 * b2 - a12 * b1) / det
            px += stepX; py += stepY
            if hypot(stepX, stepY) < 0.001 { break }
        }
        var ss = 0.0
        for s in samples {
            let r = hypot(px - s.x, py - s.y)
            ss += (r - s.distance) * (r - s.distance)
        }
        return (px, py, (ss / Double(samples.count)).squareRoot())
    }
}

import Foundation

/// WGS84 coordinate in decimal degrees.
struct LatLon: Codable, Hashable {
    var lat: Double
    var lon: Double
}

/// Local east/north plane (metres) around an origin. Accurate to centimetres
/// across a race track, which is all lap timing needs.
struct LocalProjection {
    let origin: LatLon
    private let mPerDegLat: Double
    private let mPerDegLon: Double

    init(origin: LatLon) {
        self.origin = origin
        let phi = origin.lat * .pi / 180
        mPerDegLat = 111_132.92 - 559.82 * cos(2 * phi) + 1.175 * cos(4 * phi)
        mPerDegLon = 111_412.84 * cos(phi) - 93.5 * cos(3 * phi)
    }

    func project(_ p: LatLon) -> Vec2 {
        Vec2(x: (p.lon - origin.lon) * mPerDegLon, y: (p.lat - origin.lat) * mPerDegLat)
    }

    func unproject(_ v: Vec2) -> LatLon {
        LatLon(lat: origin.lat + v.y / mPerDegLat, lon: origin.lon + v.x / mPerDegLon)
    }
}

struct Vec2: Hashable {
    var x: Double
    var y: Double
    static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: Vec2, s: Double) -> Vec2 { Vec2(x: a.x * s, y: a.y * s) }
    var length: Double { (x * x + y * y).squareRoot() }
    func cross(_ o: Vec2) -> Double { x * o.y - y * o.x }
    /// Compass bearing (0 = north, clockwise) of this vector, degrees.
    var bearing: Double { normalizeDegrees(atan2(x, y) * 180 / .pi) }
    /// Unit vector for a compass bearing.
    static func fromBearing(_ deg: Double) -> Vec2 {
        let r = deg * .pi / 180
        return Vec2(x: sin(r), y: cos(r))
    }
}

struct Vec3 {
    var x: Double, y: Double, z: Double
    static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
    static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z) }
    static func * (a: Vec3, s: Double) -> Vec3 { Vec3(x: a.x * s, y: a.y * s, z: a.z * s) }
    static let zero = Vec3(x: 0, y: 0, z: 0)
    func dot(_ o: Vec3) -> Double { x * o.x + y * o.y + z * o.z }
    func cross(_ o: Vec3) -> Vec3 { Vec3(x: y * o.z - z * o.y, y: z * o.x - x * o.z, z: x * o.y - y * o.x) }
    var length: Double { dot(self).squareRoot() }
    var normalized: Vec3 { let l = length; return l > 0 ? self * (1 / l) : self }
}

func normalizeDegrees(_ d: Double) -> Double {
    let r = d.truncatingRemainder(dividingBy: 360)
    return r < 0 ? r + 360 : r
}

/// Signed smallest difference b - a in degrees, in (-180, 180].
func angleDelta(_ a: Double, _ b: Double) -> Double {
    var d = normalizeDegrees(b - a)
    if d > 180 { d -= 360 }
    return d
}

/// Intersection of segment p0→p1 with segment q0→q1.
/// Returns the fraction along p (0...1) or nil.
func segmentIntersection(_ p0: Vec2, _ p1: Vec2, _ q0: Vec2, _ q1: Vec2) -> Double? {
    let r = p1 - p0, s = q1 - q0
    let denom = r.cross(s)
    guard abs(denom) > 1e-12 else { return nil }
    let qp = q0 - p0
    let t = qp.cross(s) / denom
    let u = qp.cross(r) / denom
    guard t >= 0, t <= 1, u >= 0, u <= 1 else { return nil }
    return t
}

func haversineMeters(_ a: LatLon, _ b: LatLon) -> Double {
    let R = 6_371_000.0
    let dLat = (b.lat - a.lat) * .pi / 180, dLon = (b.lon - a.lon) * .pi / 180
    let h = sin(dLat / 2) * sin(dLat / 2) + cos(a.lat * .pi / 180) * cos(b.lat * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
    return 2 * R * asin(min(1, h.squareRoot()))
}

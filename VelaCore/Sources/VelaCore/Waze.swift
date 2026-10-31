import Foundation

/**
 * A live report from Waze drivers: police, a crash, something on the road, a closure. From the
 * keyless feed behind waze.com/live-map, the one apps like Highway Radar read.
 */
public struct WazeAlert: Hashable, Sendable, Identifiable {
    /** What Kite groups the reports into; each kind has its own switch in Settings. */
    public enum Kind: String, CaseIterable, Sendable {
        case police, accident, hazard, weather, roadworks, closure, jam
    }

    public var id: String
    public var kind: Kind
    /** Waze's own detail, like "POLICE_HIDING" or "HAZARD_ON_ROAD_POT_HOLE". */
    public var subtype: String
    public var location: LatLng
    public var street: String?
    public var reportedAt: Date
    /** How many drivers confirmed it ("thumbs up"). */
    public var thumbsUp: Int
    /** Waze's 0-10 trust in the report. */
    public var reliability: Int
    /** Which way the reporting driver was heading, in degrees, when Waze has it. */
    public var heading: Double?

    public init(id: String, kind: Kind, subtype: String = "", location: LatLng, street: String? = nil,
                reportedAt: Date = Date(), thumbsUp: Int = 0, reliability: Int = 5, heading: Double? = nil) {
        self.id = id
        self.kind = kind
        self.subtype = subtype
        self.location = location
        self.street = street
        self.reportedAt = reportedAt
        self.thumbsUp = thumbsUp
        self.reliability = reliability
        self.heading = heading
    }

    /** A short name for the warning card and the voice: "Police", "Pothole", "Car stopped on the road". */
    public var title: String {
        switch subtype {
        case "POLICE_HIDING": return "Hidden police"
        case "POLICE_WITH_MOBILE_CAMERA", "POLICE_MOBILE_CAMERA": return "Mobile speed camera"
        case "ACCIDENT_MAJOR": return "Major crash"
        case "ACCIDENT_MINOR": return "Minor crash"
        case "HAZARD_ON_ROAD_POT_HOLE": return "Pothole"
        case "HAZARD_ON_ROAD_CAR_STOPPED": return "Car stopped on the road"
        case "HAZARD_ON_SHOULDER_CAR_STOPPED": return "Car stopped on the side"
        case "HAZARD_ON_ROAD_ROAD_KILL", "HAZARD_ON_SHOULDER_ANIMALS": return "Animal on the road"
        case "HAZARD_ON_ROAD_OBJECT": return "Object on the road"
        case "HAZARD_ON_ROAD_TRAFFIC_LIGHT_FAULT": return "Broken traffic light"
        case "HAZARD_ON_ROAD_LANE_CLOSED": return "Lane closed"
        case "HAZARD_ON_ROAD_OIL": return "Oil on the road"
        case "HAZARD_ON_ROAD_ICE", "HAZARD_WEATHER_FREEZING_RAIN": return "Ice on the road"
        case "HAZARD_WEATHER_FOG": return "Fog"
        case "HAZARD_WEATHER_HAIL": return "Hail"
        case "HAZARD_WEATHER_FLOOD", "HAZARD_WEATHER_HEAVY_RAIN": return "Flooding"
        case "HAZARD_WEATHER_HEAVY_SNOW": return "Heavy snow"
        case "HAZARD_ON_SHOULDER_MISSING_SIGN": return "Missing sign"
        case "JAM_STAND_STILL_TRAFFIC": return "Standstill traffic"
        case "JAM_HEAVY_TRAFFIC": return "Heavy traffic"
        default: break
        }
        switch kind {
        case .police: return "Police"
        case .accident: return "Crash"
        case .hazard: return "Hazard"
        case .weather: return "Bad weather"
        case .roadworks: return "Roadworks"
        case .closure: return "Road closed"
        case .jam: return "Traffic jam"
        }
    }

    /** "Police reported ahead." and the like, for the voice. */
    public var spoken: String {
        switch kind {
        case .closure: return "Road closed ahead."
        case .jam: return "Traffic jam ahead."
        default: return "\(title) reported ahead."
        }
    }
}

public enum Waze {
    /**
     * The kinds Kite can get. Since October 2026 Waze's live map shares only road closures; the
     * rest (police, crashes, hazards...) come from Waze's app servers (see
     * [WazeLive]). Settings shows a switch for each.
     */
    public static let shares = Set(WazeAlert.Kind.allCases)
    /** Waze keeps the Americas, Israel and the rest of the world on separate servers. */
    public static func env(for p: LatLng) -> String {
        if p.lat > 29, p.lat < 33.6, p.lng > 34, p.lng < 36 { return "il" }
        return p.lng < -25 ? "na" : "row"
    }

    /** Keeps the live map page's cookies between requests, the way a browser would. */
    public static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        // The live map's own page asks this way; Waze turns away requests that don't look like it.
        c.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            "Referer": "https://www.waze.com/live-map/",
            "Accept": "application/json, text/plain, */*",
        ]
        return URLSession(configuration: c)
    }()

    public static func url(south: Double, west: Double, north: Double, east: Double) -> URL {
        let env = env(for: LatLng((south + north) / 2, (west + east) / 2))
        let q = String(format: "top=%.5f&bottom=%.5f&left=%.5f&right=%.5f", north, south, west, east)
        return URL(string: "https://www.waze.com/live-map/api/georss?\(q)&env=\(env)&types=alerts")!
    }

    public static let pageURL = URL(string: "https://www.waze.com/live-map/")!

    /** How the last ask went, for the status line in Settings: when, the HTTP code (0 = no network), how many reports. */
    public struct Status: Sendable {
        public var at: Date
        public var code: Int
        public var count: Int
        /** Answered through the hidden web view rather than directly. */
        public var viaPage = false
        /** What the answer held, by Waze's own type: ["POLICE": 3, "ROAD_CLOSED": 140]. */
        public var types: [String: Int] = [:]

        public init(at: Date, code: Int, count: Int, viaPage: Bool = false, types: [String: Int] = [:]) {
            self.at = at
            self.code = code
            self.count = count
            self.viaPage = viaPage
            self.types = types
        }

        /** "3 police · 140 road closures", most first, for the status line. */
        public var summary: String {
            guard !types.isEmpty else { return "nothing" }
            return types.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .map { "\($0.value) \(Waze.typeName($0.key, $0.value))" }.joined(separator: " · ")
        }
    }

    /** Waze's type in plain words: "police", "crashes", "road closures". */
    public static func typeName(_ type: String, _ n: Int) -> String {
        switch type {
        case "POLICE", "POLICEMAN": return "police"
        case "ACCIDENT": return n == 1 ? "crash" : "crashes"
        case "HAZARD", "WEATHERHAZARD": return n == 1 ? "hazard" : "hazards"
        case "ROAD_CLOSED": return n == 1 ? "road closure" : "road closures"
        case "JAM": return n == 1 ? "jam" : "jams"
        case "CONSTRUCTION": return "roadworks"
        default: return type.lowercased()
        }
    }

    /** How many reports of each Waze type an answer holds, including types Kite doesn't show. */
    public static func types(_ data: Data) -> [String: Int] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var out: [String: Int] = [:]
        for a in root["alerts"] as? [[String: Any]] ?? [] { out[a["type"] as? String ?? "?", default: 0] += 1 }
        return out
    }
    /** Asks for [url] the way the live map page itself would, when Waze turns plain requests away. */
    nonisolated(unsafe) public static var fallback: (@Sendable (URL) async -> Data?)?
    nonisolated(unsafe) public private(set) static var lastStatus: Status?
    nonisolated(unsafe) private static var openedPage = false

    /**
     * Reports in a box. Nil when Waze didn't answer, so the caller can keep what it had. When the
     * feed turns us away, open the live map page first, as a browser would have, and ask once more;
     * then let [fallback] (a hidden web view in the app) ask from inside the page itself.
     */
    public static func alerts(south: Double, west: Double, north: Double, east: Double) async -> [WazeAlert]? {
        let u = url(south: south, west: west, north: north, east: east)
        // Once the page route has worked, go straight to it: the plain one will only be refused.
        if lastStatus?.viaPage == true, let fallback, let data = await fallback(u), let list = parse(data) {
            lastStatus = Status(at: Date(), code: 200, count: list.count, viaPage: true, types: types(data))
            return list
        }
        var status = 0
        for attempt in 0..<2 {
            if attempt == 1 {
                // Only once per launch: if Waze still says no, a page load each time won't change it.
                guard !openedPage else { break }
                openedPage = true
                _ = try? await session.data(from: pageURL)
            }
            guard let (data, resp) = try? await session.data(for: URLRequest(url: u)) else { status = 0; break }
            status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                let list = parse(data)
                lastStatus = Status(at: Date(), code: list == nil ? -1 : 200, count: list?.count ?? 0, types: types(data))
                return list
            }
            if status != 403 && status != 401 { break }
        }
        if status == 403 || status == 401, let fallback, let data = await fallback(u), let list = parse(data) {
            lastStatus = Status(at: Date(), code: 200, count: list.count, viaPage: true, types: types(data))
            return list
        }
        lastStatus = Status(at: Date(), code: status, count: 0)
        return nil
    }

    /**
     * Reports along a route: the line cut into pieces of about 15 km, one box each, since Waze
     * sends only so many reports per box. Nil when every box failed.
     */
    public static func alongRoute(_ line: [LatLng]) async -> [WazeAlert]? {
        guard line.count >= 2 else { return [] }
        var found: [String: WazeAlert] = [:]
        var answered = false
        for piece in Overpass.pieces(line, meters: 15_000) {
            let pad = 0.004
            let s = piece.map(\.lat).min()! - pad, n = piece.map(\.lat).max()! + pad
            let w = piece.map(\.lng).min()! - pad, e = piece.map(\.lng).max()! + pad
            guard let list = await alerts(south: s, west: w, north: n, east: e) else { continue }
            answered = true
            for a in list { found[a.id] = a }
        }
        return answered ? Array(found.values) : nil
    }

    public static func kind(type: String, subtype: String) -> WazeAlert.Kind? {
        switch type {
        case "POLICE", "POLICEMAN": return .police
        case "ACCIDENT": return .accident
        case "ROAD_CLOSED": return .closure
        case "JAM": return .jam
        case "CONSTRUCTION": return .roadworks
        case "WEATHERHAZARD", "HAZARD":
            if subtype == "HAZARD_ON_ROAD_CONSTRUCTION" { return .roadworks }
            if subtype.hasPrefix("HAZARD_WEATHER") || subtype == "HAZARD_ON_ROAD_ICE" { return .weather }
            return .hazard
        default: return nil
        }
    }

    public static func parse(_ data: Data) -> [WazeAlert]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let items = root["alerts"] as? [[String: Any]] ?? []
        return items.compactMap { a in
            guard let loc = a["location"] as? [String: Any],
                  let x = (loc["x"] as? NSNumber)?.doubleValue, let y = (loc["y"] as? NSNumber)?.doubleValue,
                  let type = a["type"] as? String else { return nil }
            let sub = a["subtype"] as? String ?? ""
            guard let kind = kind(type: type, subtype: sub) else { return nil }
            let id = a["uuid"] as? String ?? a["id"] as? String ?? "\(type)\(x),\(y)"
            let ms = (a["pubMillis"] as? NSNumber)?.doubleValue
            let street = (a["street"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return WazeAlert(id: id, kind: kind, subtype: sub, location: LatLng(y, x), street: street,
                             reportedAt: ms.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date(),
                             thumbsUp: (a["nThumbsUp"] as? NSNumber)?.intValue ?? 0,
                             reliability: (a["reliability"] as? NSNumber)?.intValue ?? 5,
                             heading: (a["magvar"] as? NSNumber)?.doubleValue)
        }
    }

    /**
     * Where each report sits along [line]: close to the road, and for one with a heading, made by
     * someone driving the same way (police on the other carriageway isn't ahead of you).
     */
    public static func project(_ alerts: [WazeAlert], on line: [LatLng], maxOffset: Double = 40) -> [(alert: WazeAlert, along: Double)] {
        guard line.count >= 2 else { return [] }
        let cum = Geo.cumulative(line)
        var out: [(WazeAlert, Double)] = []
        for a in alerts {
            let p = Geo.project(a.location, on: line, cumulative: cum)
            guard p.offset <= maxOffset else { continue }
            if let h = a.heading, a.kind != .closure {
                let ahead = Geo.point(along: line, meters: p.along + 30, cumulative: cum)
                let behind = Geo.point(along: line, meters: max(p.along - 30, 0), cumulative: cum)
                let road = Geo.bearing(behind, ahead)
                let diff = abs((h - road + 540).truncatingRemainder(dividingBy: 360) - 180)
                if diff > 110 { continue }
            }
            out.append((a, p.along))
        }
        return out.sorted { $0.1 < $1.1 }
    }
}

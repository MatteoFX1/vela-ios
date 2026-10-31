import Foundation

/** A mapped camera from OpenStreetMap: a fixed speed camera, or a license plate reader (DeFlock). */
public struct RoadCamera: Hashable, Codable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case speed, plate }
    public var id: Int64
    public var kind: Kind
    public var location: LatLng
    /** Who runs a plate reader ("Flock Safety"), when mapped. */
    public var operatorName: String?
    /** The limit a speed camera checks, when mapped on it. */
    public var maxspeedKmh: Double?
    /** One of a pair or chain timing average speed (how Britain usually maps them). */
    public var average = false
    /**
     * The way traffic is going when this camera checks it, as compass bearings (0 north, 90 east),
     * from OSM's `direction`. Nil when the map doesn't say, so it counts for both ways.
     */
    public var directions: [Double]? = nil
    /**
     * Set along a route for a camera that looks like the other side's (see [CameraAlerts.otherWay]):
     * it still shows, but without a chime or voice, since the map can be wrong.
     */
    public var quiet = false

    /** Saved in the road cache without [quiet], which only means something along one route. */
    enum CodingKeys: String, CodingKey { case id, kind, location, operatorName, maxspeedKmh, average, directions }

    /** OSM `direction` as compass bearings: "90", "NE", "45;225", "0-90" (its middle). Nil for "both", "forward" and the like. */
    public static func bearings(_ raw: String?) -> [Double]? {
        guard let raw else { return nil }
        let points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        var out: [Double] = []
        for part in raw.split(whereSeparator: { $0 == ";" || $0 == "," }) {
            let p = part.trimmingCharacters(in: .whitespaces).uppercased()
            if p.isEmpty { continue }
            if let i = points.firstIndex(of: p) { out.append(Double(i) * 22.5); continue }
            if let n = Double(p) { out.append(n.truncatingRemainder(dividingBy: 360)); continue }
            // A range, "315-45": its middle.
            let ends = p.split(separator: "-").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard ends.count == 2 else { return nil }
            let span = (ends[1] - ends[0] + 360).truncatingRemainder(dividingBy: 360)
            out.append((ends[0] + span / 2).truncatingRemainder(dividingBy: 360))
        }
        return out.isEmpty ? nil : out.map { $0 < 0 ? $0 + 360 : $0 }
    }

    /**
     * Whether the map says this camera checks traffic going [heading] (a compass bearing): false only
     * for a camera mapped clearly the other way (more than 100 degrees off); one with no direction counts.
     */
    public func checks(heading: Double) -> Bool {
        guard let directions, !directions.isEmpty else { return true }
        return directions.contains { d in
            let off = abs((d - heading + 540).truncatingRemainder(dividingBy: 360) - 180)
            return off <= 100
        }
    }
}

/** A stretch of road where average speed is checked between cameras (common in Britain). */
public struct AverageSpeedZone: Hashable, Sendable {
    public var startMeters: Double
    public var endMeters: Double
    public var kmh: Double?
}

/**
 * Speed and plate cameras from Overpass, the way Vela gets them: keyless, failing over across the
 * public mirrors. Fixed installations only; coverage is OSM's.
 */
public enum Overpass {
    public static let endpoints = [
        "https://overpass-api.de/api/interpreter",
        "https://overpass.kumi.systems/api/interpreter",
        "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
        "https://overpass.private.coffee/api/interpreter",
    ]

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 45
        c.httpAdditionalHeaders = ["User-Agent": "Vela-iOS (https://github.com/matteofx1/vela-ios)"]
        return URLSession(configuration: c)
    }()

    /** Cameras in a box. Nil when every mirror failed, so the caller can retry later. */
    public static func cameras(south: Double, west: Double, north: Double, east: Double,
                               speed: Bool, plate: Bool) async -> [RoadCamera]? {
        let box = String(format: "(%.5f,%.5f,%.5f,%.5f)", south, west, north, east)
        return await cameras(filter: box, speed: speed, plate: plate)
    }

    /** Cameras within [radius] meters of a route, one query per route. */
    public static func cameras(along line: [LatLng], radius: Int = 150, speed: Bool, plate: Bool) async -> [RoadCamera]? {
        guard line.count >= 2 else { return [] }
        let maxPts = 250
        let pts = line.count <= maxPts ? line : (0..<maxPts).map {
            line[min(line.count - 1, Int((Double($0) * Double(line.count - 1) / Double(maxPts - 1)).rounded()))]
        }
        let coords = pts.map { String(format: "%.5f,%.5f", $0.lat, $0.lng) }.joined(separator: ",")
        return await cameras(filter: "(around:\(radius),\(coords))", speed: speed, plate: plate)
    }

    /** A mapped road with a posted limit (OSM `maxspeed`), in km/h, and its shape. */
    public struct LimitWay: Codable, Sendable {
        /** OSM's way id, so the same road seen twice is kept once. */
        public var id: Int64 = 0
        public var kmh: Double?
        public var line: [LatLng]

        public init(id: Int64 = 0, kmh: Double?, line: [LatLng]) {
            self.id = id
            self.kmh = kmh
            self.line = line
        }
    }

    /**
     * Cameras, posted speed limits and traffic lights along a route in one query: cameras within
     * 150 m, roads with a `maxspeed` within 12 m, traffic lights within 50 m. Nil when every mirror failed.
     */
    /// [limits] false leaves the roads' speed limits out (the road matcher has them): the question is
    /// then far lighter, and a busy server that turns the full one away still answers it.
    public static func alongRoute(_ line: [LatLng], speed: Bool, plate: Bool, limits: Bool = true) async
        -> (cameras: [RoadCamera], ways: [LimitWay], zones: [AverageSpeedZone], signals: [LatLng])? {
        guard line.count >= 2 else { return ([], [], [], []) }
        // Long drives go in pieces of about 40 km: one query for a whole motorway trip is often
        // too much for the public servers.
        var cams: [Int64: RoadCamera] = [:]
        var ways: [LimitWay] = []
        var zones: [AverageSpeedZone] = []
        var signals: [LatLng] = []
        var answered = false
        for piece in pieces(line, meters: 40_000) {
            guard let data = await alongQuery(piece, speed: speed, plate: plate, limits: limits) else { continue }
            answered = true
            let found = parse(data) ?? [], w = parseWays(data), lights = parseSignalNodes(data)
            for c in found { cams[c.id] = c }
            ways += w
            zones += averageZones(data, on: line)
            signals += lights.map(\.at)
            RoadCache.shared.add(ways: w, cameras: found, signals: lights)
        }
        guard answered else { return nil }
        return (Array(cams.values), ways, CameraAlerts.merge(zones, []), signalsOnRoute(signals, line: line))
    }

    /** [line] cut into runs of about [meters], each sharing its first point with the last run's end. */
    static func pieces(_ line: [LatLng], meters: Double) -> [[LatLng]] {
        var out: [[LatLng]] = []
        var cur: [LatLng] = [line[0]]
        var len = 0.0
        for p in line.dropFirst() {
            len += cur.last!.distance(to: p)
            cur.append(p)
            if len >= meters {
                out.append(cur)
                cur = [p]
                len = 0
            }
        }
        if cur.count >= 2 { out.append(cur) }
        return out
    }

    private static func alongQuery(_ line: [LatLng], speed: Bool, plate: Bool, limits: Bool) async -> Data? {
        // About one point every 100 m: the query's line cuts corners between points, and traffic
        // lights stand right by the road.
        let maxPts = 400
        let pts = line.count <= maxPts ? line : (0..<maxPts).map {
            line[min(line.count - 1, Int((Double($0) * Double(line.count - 1) / Double(maxPts - 1)).rounded()))]
        }
        let coords = pts.map { String(format: "%.5f,%.5f", $0.lat, $0.lng) }.joined(separator: ",")
        var parts: [String] = []
        if speed { parts.append("node[\"highway\"=\"speed_camera\"](around:150,\(coords));") }
        if plate { parts.append("node[\"surveillance:type\"=\"ALPR\"](around:150,\(coords));") }
        if limits { parts.append("way[\"highway\"][\"maxspeed\"](around:12,\(coords));") }
        if speed { parts.append("relation[\"enforcement\"=\"average_speed\"](around:200,\(coords));") }
        parts.append("node[\"highway\"=\"traffic_signals\"](around:50,\(coords));")
        let q = "[out:json][timeout:40];(" + parts.joined() + ");out body geom 8000;"
        return await firstAnswer(q) { parse($0) != nil }
    }

    /**
     * Asks the mirrors one after another, but without waiting out a slow one: each next mirror is
     * asked [stagger] seconds after the last, and the first good answer wins. A busy main server
     * used to hold a drive's speed limits back by two minutes or more.
     */
    static func firstAnswer(_ q: String, stagger: Double = 8, valid: @escaping @Sendable (Data) -> Bool) async -> Data? {
        await withTaskGroup(of: Data?.self) { group in
            for (i, ep) in endpoints.enumerated() {
                group.addTask {
                    if i > 0 { try? await Task.sleep(nanoseconds: UInt64(Double(i) * stagger * 1e9)) }
                    guard !Task.isCancelled, let (data, status) = await fetch(ep, query: q), status == 200,
                          !timedOut(data), valid(data) else { return nil }
                    return data
                }
            }
            for await answer in group {
                if let answer {
                    group.cancelAll()
                    return answer
                }
            }
            return nil
        }
    }

    /**
     * Average speed check zones along [line]: each enforcement relation's mapped points (its
     * cameras, its start and end) that lie on the route, from the first to the last.
     */
    public static func averageZones(_ data: Data, on line: [LatLng]) -> [AverageSpeedZone] {
        guard line.count >= 2, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = root["elements"] as? [[String: Any]] else { return [] }
        let cum = Geo.cumulative(line)
        var out: [AverageSpeedZone] = []
        for e in elements where e["type"] as? String == "relation" {
            let tags = e["tags"] as? [String: String] ?? [:]
            guard tags["enforcement"] == "average_speed" else { continue }
            var pts: [LatLng] = []
            for m in e["members"] as? [[String: Any]] ?? [] {
                if let lat = m["lat"] as? Double, let lon = m["lon"] as? Double { pts.append(LatLng(lat, lon)) }
                for g in m["geometry"] as? [[String: Any]] ?? [] {
                    if let lat = g["lat"] as? Double, let lon = g["lon"] as? Double { pts.append(LatLng(lat, lon)) }
                }
            }
            let along = pts.map { Geo.project($0, on: line, cumulative: cum) }.filter { $0.offset < 60 }.map(\.along)
            guard let a = along.min(), let b = along.max(), b - a > 300 else { continue }
            out.append(AverageSpeedZone(startMeters: a, endMeters: b, kmh: maxspeedKmh(tags["maxspeed"])))
        }
        return out.sorted { $0.startMeters < $1.startMeters }
    }

    /** Traffic light nodes in an answer (OSM `highway=traffic_signals`). */
    static func parseSignals(_ data: Data) -> [LatLng] { parseSignalNodes(data).map(\.at) }

    static func parseSignalNodes(_ data: Data) -> [(id: Int64, at: LatLng)] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = root["elements"] as? [[String: Any]] else { return [] }
        return elements.compactMap { e in
            guard (e["tags"] as? [String: String])?["highway"] == "traffic_signals",
                  let lat = e["lat"] as? Double, let lon = e["lon"] as? Double else { return nil }
            return ((e["id"] as? NSNumber)?.int64Value ?? 0, LatLng(lat, lon))
        }
    }

    /**
     * The traffic lights on the route itself, one per junction: a junction's lights are often mapped
     * once per road into it, so lights within 40 m of each other along the route are drawn once.
     */
    public static func signalsOnRoute(_ signals: [LatLng], line: [LatLng]) -> [LatLng] {
        guard line.count >= 2 else { return [] }
        let cum = Geo.cumulative(line)
        let on = signals.map { ($0, Geo.project($0, on: line, cumulative: cum)) }
            .filter { $0.1.offset < 20 }
            .sorted { $0.1.along < $1.1.along }
        var out: [(LatLng, Double)] = []
        for (p, at) in on where out.last.map({ at.along - $0.1 >= 40 }) ?? true { out.append((p, at.along)) }
        return out.map(\.0)
    }

    static func parseWays(_ data: Data) -> [LimitWay] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = root["elements"] as? [[String: Any]] else { return [] }
        return elements.compactMap { e in
            guard e["type"] as? String == "way", let geom = e["geometry"] as? [[String: Any]] else { return nil }
            let tags = e["tags"] as? [String: String] ?? [:]
            let line = geom.compactMap { g -> LatLng? in
                guard let lat = g["lat"] as? Double, let lon = g["lon"] as? Double else { return nil }
                return LatLng(lat, lon)
            }
            return line.count >= 2 ? LimitWay(id: (e["id"] as? NSNumber)?.int64Value ?? 0,
                                              kmh: britishLimit(maxspeedKmh(tags["maxspeed"]), at: line[0]), line: line) : nil
        }
    }

    /**
     * In Great Britain limits are signed in mph, but some roads are mapped "maxspeed=30" with no
     * unit, which by the map's rules means 30 km/h and showed as a "19" sign (the roundabout at
     * Chestnut Avenue / Passfield Avenue, Eastleigh). No British limit is a round 10 to 70 km/h,
     * so there those are read as the mph the sign says.
     */
    public static func britishLimit(_ kmh: Double?, at p: LatLng) -> Double? {
        guard let kmh, inGreatBritain(p) else { return kmh }
        let n = kmh.rounded()
        return abs(kmh - n) < 0.01 && Int(n) % 10 == 0 && (10...70).contains(n) ? n * 1.609344 : kmh
    }

    /** England, Wales and Scotland, roughly (Ireland, north and south, left out). */
    static func inGreatBritain(_ p: LatLng) -> Bool {
        (49.8...61).contains(p.lat) && (-8...2).contains(p.lng) && !(p.lat < 55.4 && p.lng < -5.4)
    }

    /** OSM `maxspeed` to km/h, as Vela reads it: "50", "30 mph", "50 km/h", Britain's "national"; nil for "none", "DE:urban" and the like. */
    public static func maxspeedKmh(_ raw: String?) -> Double? {
        guard let s = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !s.isEmpty else { return nil }
        if s == "walk" { return 7 }
        // Britain's implied limits, as they are mapped: national single and dual carriageway, motorway, built-up.
        switch s {
        case "national", "gb:nsl_single", "uk:nsl_single": return 60 * 1.609344
        case "gb:nsl_dual", "uk:nsl_dual", "gb:motorway", "uk:motorway": return 70 * 1.609344
        case "gb:nsl_restricted", "uk:nsl_restricted", "gb:urban": return 30 * 1.609344
        default: break
        }
        guard let r = s.range(of: #"^\d+(\.\d+)?"#, options: .regularExpression), let n = Double(s[r]) else { return nil }
        let kmh = s.contains("mph") ? n * 1.609344 : n
        return (1...200).contains(kmh) ? kmh : nil
    }

    /**
     * Turn the roads into limit changes along [line]: each road covers the stretch of the route
     * its points lie on. A crossing street touches the route at one point and is skipped.
     */
    public static func speedLimits(_ ways: [LimitWay], on line: [LatLng]) -> [SpeedLimit] {
        guard line.count >= 2 else { return [] }
        let cum = Geo.cumulative(line)
        var spans: [(from: Double, to: Double, kmh: Double?)] = []
        for w in ways {
            let hits = w.line.map { Geo.project($0, on: line, cumulative: cum) }.filter { $0.offset < 12 }.map(\.along)
            guard let lo = hits.min(), let hi = hits.max(), hi - lo > 20 else { continue }
            // Roads remembered from earlier drives may still hold the unit-less reading.
            spans.append((lo, hi, britishLimit(w.kmh, at: w.line[0])))
        }
        guard !spans.isEmpty else { return [] }
        // Sample every 25 m; where roads overlap, the shorter (more specific) one wins.
        var out: [SpeedLimit] = []
        let total = cum.last ?? 0
        var m = 0.0
        while m <= total {
            let here = spans.filter { $0.from - 15 <= m && m <= $0.to + 15 }.min { ($0.to - $0.from) < ($1.to - $1.from) }
            let kmh = here?.kmh
            if out.last.map({ $0.kmh != kmh }) ?? true { out.append(SpeedLimit(startMeters: m, kmh: kmh)) }
            m += 25
        }
        return out
    }

    public static func query(filter: String, speed: Bool, plate: Bool) -> String {
        var parts: [String] = []
        if speed { parts.append("node[\"highway\"=\"speed_camera\"]\(filter);") }
        if plate { parts.append("node[\"surveillance:type\"=\"ALPR\"]\(filter);") }
        return "[out:json][timeout:25];(" + parts.joined() + ");out body 4000;"
    }

    private static func cameras(filter: String, speed: Bool, plate: Bool) async -> [RoadCamera]? {
        guard speed || plate else { return [] }
        let q = query(filter: filter, speed: speed, plate: plate)
        return await firstAnswer(q) { parse($0) != nil }.flatMap(parse)
    }

    /** One request to one mirror. A POST, since a route's query is too long for a URL. Nil on a network error. */
    public static func fetch(_ endpoint: String, query: String) async -> (Data, Int)? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let url = URL(string: endpoint) else { return nil }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.httpBody = ("data=" + (query.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")).data(using: .utf8)
        guard let (data, resp) = try? await session.data(for: r) else { return nil }
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /** Any query, failing over across the mirrors; nil when none answered with data. */
    public static func query(_ q: String) async -> Data? {
        await firstAnswer(q) { (try? JSONSerialization.jsonObject(with: $0)) != nil }
    }

    /** A busy server can answer 200 with a "remark" that the query ran out of time, and no data. */
    static func timedOut(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let remark = root["remark"] as? String else { return false }
        return remark.contains("runtime error") || remark.contains("timed out") || remark.contains("out of memory")
    }

    static func parse(_ data: Data) -> [RoadCamera]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = root["elements"] as? [[String: Any]] else { return nil }
        return elements.compactMap { e in
            guard let lat = e["lat"] as? Double, let lon = e["lon"] as? Double else { return nil }
            let tags = e["tags"] as? [String: String] ?? [:]
            // The same answer holds traffic lights: only cameras are cameras.
            if tags["highway"] == "traffic_signals" { return nil }
            let id = (e["id"] as? NSNumber)?.int64Value ?? 0
            let plate = tags["surveillance:type"] == "ALPR"
            return RoadCamera(id: id, kind: plate ? .plate : .speed, location: LatLng(lat, lon),
                              operatorName: plate ? (tags["operator"] ?? tags["manufacturer"]) : nil,
                              maxspeedKmh: plate ? nil : britishLimit(maxspeedKmh(tags["maxspeed"]), at: LatLng(lat, lon)),
                              average: !plate && tags["enforcement"] == "average_speed",
                              // Speed cameras only: a plate reader's direction is where its lens points, which
                              // can be either way along the road.
                              directions: plate ? nil : RoadCamera.bearings(tags["direction"]))
        }
    }
}

/**
 * When to warn about a camera ahead (ported from Vela's CameraAlerts): about twelve seconds out,
 * once per camera, never for one already passed and never while stopped.
 */
public enum CameraAlerts {
    public static let leadSeconds = 12.0
    public static let minLead = 150.0
    public static let maxLead = 600.0
    public static let movingFloor = 2.0

    public static func leadDistance(speedMps: Double) -> Double {
        min(max(speedMps * leadSeconds, minLead), maxLead)
    }

    /** The index of the camera to announce now, or nil. [cameraMeters] are along the route. */
    public static func due(cameraMeters: [Double], traveled: Double, speedMps: Double, spoken: Set<Int>) -> Int? {
        guard speedMps >= movingFloor else { return nil }
        let lead = leadDistance(speedMps: speedMps)
        var best: Int?
        var bestAhead = Double.greatestFiniteMagnitude
        for (i, m) in cameraMeters.enumerated() where !spoken.contains(i) {
            let ahead = m - traveled
            if ahead <= 0 || ahead > lead { continue }
            if ahead < bestAhead { bestAhead = ahead; best = i }
        }
        return best
    }

    /**
     * Average speed checks from the cameras themselves: a run of average speed cameras along the
     * route, each within [maxGap] of the last, is one check from the first to the last.
     */
    public static func averageZones(_ cams: [(camera: RoadCamera, along: Double)], maxGap: Double = 15_000) -> [AverageSpeedZone] {
        var out: [AverageSpeedZone] = []
        var run: [(camera: RoadCamera, along: Double)] = []
        func close() {
            if let a = run.first, let b = run.last, b.along - a.along > 300 {
                out.append(AverageSpeedZone(startMeters: a.along, endMeters: b.along,
                                            kmh: run.compactMap(\.camera.maxspeedKmh).first))
            }
            run = []
        }
        for c in cams where c.camera.average && !c.camera.quiet {
            if let last = run.last, c.along - last.along > maxGap { close() }
            run.append(c)
        }
        close()
        return out
    }

    /** Zones from both sources, dropping any that overlap one already kept. */
    public static func merge(_ a: [AverageSpeedZone], _ b: [AverageSpeedZone]) -> [AverageSpeedZone] {
        var out: [AverageSpeedZone] = []
        for z in (a + b).sorted(by: { $0.startMeters < $1.startMeters }) {
            if let last = out.last, z.startMeters <= last.endMeters {
                out[out.count - 1].endMeters = max(last.endMeters, z.endMeters)
                if out[out.count - 1].kmh == nil { out[out.count - 1].kmh = z.kmh }
            } else {
                out.append(z)
            }
        }
        return out
    }

    /**
     * Where each camera sits along [line], dropping any farther than [maxOffset] from it
     * (a camera on a parallel street isn't on the route).
     */
    public static func project(_ cams: [RoadCamera], on line: [LatLng], maxOffset: Double = 35) -> [(camera: RoadCamera, along: Double)] {
        guard line.count >= 2 else { return [] }
        let cum = Geo.cumulative(line)
        var out: [(RoadCamera, Double)] = []
        for c in cams {
            let p = Geo.project(c.location, on: line, cumulative: cum)
            guard p.offset <= maxOffset else { continue }
            var cam = c
            cam.quiet = otherWay(c, along: p.along, offset: p.offset, on: line, cumulative: cum)
            out.append((cam, p.along))
        }
        return out.sorted { $0.1 < $1.1 }
    }

    /**
     * Likely a camera for the traffic coming the other way: the map says it checks the other way AND
     * it stands on the far side of the road. Even both together can be wrong (in Britain the map's
     * direction is reversed for 12 of 71 cameras on one-way roads, and the side disagrees with it
     * for 198 of 773), so such a camera is shown quietly rather than left out.
     */
    static func otherWay(_ c: RoadCamera, along: Double, offset: Double, on line: [LatLng], cumulative cum: [Double]) -> Bool {
        let h = heading(of: line, at: along, cumulative: cum)
        guard !c.checks(heading: h), offset >= farSideMeters else { return false }
        let at = Geo.point(along: line, meters: along, cumulative: cum)
        // Which side of the route it stands on: negative is to the left.
        let rel = (Geo.bearing(at, c.location) - h + 540).truncatingRemainder(dividingBy: 360) - 180
        let onLeft = rel < 0
        // Traffic keeps left in Britain, so a camera on the right checks the other carriageway.
        return Geo.drivesOnLeft(at) ? !onLeft : onLeft
    }

    /** How far off the route's line a camera must stand to count as on one side of the road. */
    static let farSideMeters = 5.0

    /** Which way the route is going [meters] along it, from the stretch 20 m either side. */
    static func heading(of line: [LatLng], at meters: Double, cumulative cum: [Double]) -> Double {
        let total = cum.last ?? 0
        let a = Geo.point(along: line, meters: max(min(meters - 20, total - 40), 0), cumulative: cum)
        let b = Geo.point(along: line, meters: min(max(meters + 20, 40), total), cumulative: cum)
        return Geo.bearing(a, b)
    }
}

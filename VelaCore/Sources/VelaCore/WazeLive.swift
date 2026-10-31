import Foundation

/**
 * Live Waze reports (police, crashes, hazards...) the way the Waze app itself gets them: its
 * "RT" protocol, with an anonymous account Waze hands out (no name, email or phone). Waze's live
 * map website stopped sharing drivers' reports in October 2026; this is how Highway Radar's
 * SABRE Plus plugin carries on.
 *
 * Ported from SABRE Plus for Highway Radar (github.com/nicglazkov/highway-radar-sabre-plus),
 * Copyright (c) 2026 highway-radar-sabre-plus contributors, MIT licence (see
 * licenses/SABRE-Plus-LICENSE.txt). Only the fetch path: Kite never reports to Waze.
 *
 * Gentle on Waze: one account kept on the phone (at most 3 new ones a day), one session reused,
 * a handful of boxes per ask: along the route every 90 seconds while navigating, and otherwise
 * for the map on screen at most every 2 minutes (or when it moves well away).
 */
public actor WazeLive {
    public static let shared = WazeLive()

    /** How the last ask went, for Settings: when, the HTTP code (0 = no network, -1 = refused in the answer), how many reports. */
    nonisolated(unsafe) public private(set) static var lastStatus: Waze.Status?
    /** Bytes sent and received since launch, to keep an eye on data use. */
    nonisolated(unsafe) public private(set) static var bytes = 0
    /** Another server instead of Waze's, for testing what Kite does when Waze is unreachable. */
    nonisolated(unsafe) public static var hostOverride: String?

    static let protocolVersion = 234
    static let appVersion = "5.17.1.0"

    private struct Account: Codable {
        var user: String
        var pass: String
        var device: Int
        var installation: String
    }

    struct Session {
        var id: Int64
        var secret: String
    }

    private enum Failure: Error {
        /** The account is no good any more: make a new one. */
        case rejected(String)
        /** The session ended: log in again with the same account. */
        case expired(String)
        case other(String)
    }

    private var account: Account?
    private var session: Session?
    private var seq = 1
    private var lastAsk = Date.distantPast
    private var handshaken: Int64 = 0
    private var http = WazeLive.makeSession()
    private var region = "row"
    private var backoffUntil = Date.distantPast
    /** Failed asks in a row: each one waits twice as long before the next, up to 10 minutes. */
    private var failures = 0
    /** Reports from this session, by Waze's id; Waze sends each once per session, then "RmAlert" when it clears. */
    private var cache: [String: WazeAlert] = [:]

    private let defaults = UserDefaults.standard

    init() {
        if let data = defaults.data(forKey: "wazeLiveAccount") {
            account = try? JSONDecoder().decode(Account.self, from: data)
        }
    }

    /**
     * Reports in [boxes] (south, west, north, east), plus what Waze already sent this session.
     * Nil when Waze couldn't be asked.
     */
    public func alerts(boxes: [(s: Double, w: Double, n: Double, e: Double)], near: LatLng) async -> [WazeAlert]? {
        guard !boxes.isEmpty, Date() >= backoffUntil else { return nil }
        do {
            try await refresh(boxes, near: near)
        } catch Failure.expired {
            session = nil
            do { try await refresh(boxes, near: near) } catch { return failed(error) }
        } catch Failure.rejected(let why) {
            // A purged account: make a new one, but only a few a day.
            guard canRegister() else { return failed(Failure.rejected(why)) }
            account = nil
            session = nil
            defaults.removeObject(forKey: "wazeLiveAccount")
            do { try await refresh(boxes, near: near) } catch { return failed(error) }
        } catch {
            return failed(error)
        }
        // Only what's in the boxes asked about (the session also remembers reports from earlier asks).
        let list = cache.values.filter { a in
            boxes.contains { a.location.lat >= $0.s - 0.01 && a.location.lat <= $0.n + 0.01
                && a.location.lng >= $0.w - 0.015 && a.location.lng <= $0.e + 0.015 }
        }
        var types: [String: Int] = [:]
        for a in list { types[Self.typeKey(a.kind), default: 0] += 1 }
        Self.lastStatus = Waze.Status(at: Date(), code: 200, count: list.count, types: types)
        failures = 0
        return list
    }

    /** Reports along a route: the line cut into pieces of about 10 km, one box each, plus a small box around [here]. */
    public func alongRoute(_ line: [LatLng], here: LatLng) async -> [WazeAlert]? {
        guard line.count >= 2 else { return [] }
        var boxes: [(s: Double, w: Double, n: Double, e: Double)] = []
        let d = 0.012
        boxes.append((here.lat - d, here.lng - d * 1.6, here.lat + d, here.lng + d * 1.6))
        for piece in Overpass.pieces(line, meters: 10_000).prefix(4) {
            let pad = 0.004
            boxes.append((piece.map(\.lat).min()! - pad, piece.map(\.lng).min()! - pad,
                          piece.map(\.lat).max()! + pad, piece.map(\.lng).max()! + pad))
        }
        return await alerts(boxes: boxes, near: here)
    }

    private func failed(_ error: Error) -> [WazeAlert]? {
        failures += 1
        backoffUntil = Date().addingTimeInterval(min(30 * pow(2, Double(failures - 1)), 600))
        let offline: Set<URLError.Code> = [.notConnectedToInternet, .timedOut, .networkConnectionLost, .cannotFindHost,
                                           .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff]
        let code: Int
        switch error {
        case Failure.rejected: code = 401
        case Failure.expired: code = 440
        case let e as URLError where offline.contains(e.code): code = 0
        default: code = -1
        }
        Self.lastStatus = Waze.Status(at: Date(), code: code, count: 0)
        return nil
    }

    private func refresh(_ boxes: [(s: Double, w: Double, n: Double, e: Double)], near: LatLng) async throws {
        let r = Self.region(near)
        if r != region {
            // Another of Waze's server regions: start over there.
            region = r
            session = nil
            cache = [:]
        }
        if account == nil { try await register(near) }
        if session == nil || Date().timeIntervalSince(lastAsk) > 95 { try await login(near) }
        if let s = session, s.id != handshaken {
            // Once per login, like the app: say where we are; its answer is a real map query.
            cache = [:]
            let b = Self.box(around: near, meters: 1_800)
            merge(try await command([Self.seeMe(), "SetMood,1", "Location,\(near.lng),\(near.lat)",
                                     Self.mapDisplayed(b)].joined(separator: "\n")))
            handshaken = s.id
        }
        for b in boxes {
            // Shrunk to three quarters, as the app does for its viewport.
            let cx = (b.w + b.e) / 2, cy = (b.s + b.n) / 2
            let hx = (b.e - b.w) / 2 * 0.75, hy = (b.n - b.s) / 2 * 0.75
            merge(try await command(Self.mapDisplayed((cy - hy, cx - hx, cy + hy, cx + hx))))
        }
    }

    private func merge(_ batch: [Element]) {
        for el in batch {
            if let old = el.oldCommand?.trimmingCharacters(in: .whitespaces), old.hasPrefix("RmAlert,") {
                cache[String(old.dropFirst("RmAlert,".count)).trimmingCharacters(in: .whitespaces)] = nil
            }
            if let a = el.alert { cache[a.id] = a }
        }
    }

    // MARK: Register, log in, ask

    private func url(_ path: String) -> URL {
        if let h = Self.hostOverride { return URL(string: "https://\(h)/rtserver/distrib/\(path)")! }
        let host = region == "na" ? "rt-xlb-am.waze.com" : region == "il" ? "rt-xlb-il.waze.com" : "rt-xlb-row.waze.com"
        return URL(string: "https://\(host)/rtserver/distrib/\(path)")!
    }

    private func register(_ near: LatLng) async throws {
        guard canRegister() else { throw Failure.other("no new accounts today") }
        let device = Int.random(in: 0..<Self.devices.count)
        let install = UUID().uuidString.lowercased()
        let body = [Self.clientInfo(device: device, installation: install, near), Self.line(element: 2219, Data())]
            .joined(separator: "\n")
        let (data, code) = try await post("static", body, ["User-Agent": Self.appVersion, "x-waze-network-version": "3"])
        guard code < 400, !data.isEmpty else { throw Failure.other("register HTTP \(code)") }
        let batch = try Self.check(Self.parseBatch(data))
        guard let ok = batch.first(where: { $0.registered != nil })?.registered, !ok.user.isEmpty, !ok.pass.isEmpty else {
            throw Failure.other("register: no account in the answer")
        }
        account = Account(user: ok.user, pass: ok.pass, device: device, installation: install)
        if let saved = try? JSONEncoder().encode(account) { defaults.set(saved, forKey: "wazeLiveAccount") }
        noteRegistration()
    }

    private func login(_ near: LatLng) async throws {
        guard let account else { throw Failure.other("login before register") }
        http = Self.makeSession()   // fresh cookies, as the app does
        var cred = ProtoWriter()
        cred.string(1, account.user)
        cred.string(2, account.pass)
        var req = ProtoWriter()
        req.message(1, cred.data)
        req.varint(3, 0)
        let body = [Self.clientInfo(device: account.device, installation: account.installation, near),
                    Self.line(element: 2744, req.data), Self.line(element: 2108, Data())].joined(separator: "\n")
        seq = 1
        let (data, code) = try await post("login", body, ["User-Agent": "waze/\(Self.appVersion)", "cache-control": "no-cache",
                                                         "x-waze-network-version": "3", "x-waze-wait-timeout": "8500"])
        if (400..<500).contains(code) { throw Failure.rejected("login HTTP \(code)") }
        guard code < 400, !data.isEmpty else { throw Failure.other("login HTTP \(code)") }
        let batch = try Self.check(Self.parseBatch(data))
        for el in batch {
            if let err = el.loginErrorType { throw Self.loginFailure(err) }
            if let s = el.loginSuccess {
                guard s.id != 0, !s.secret.isEmpty else { throw Failure.other("login: empty session") }
                session = s
                seq = 2
                lastAsk = Date()
                return
            }
        }
        throw Failure.rejected("login: no session in the answer")
    }

    private func command(_ body: String) async throws -> [Element] {
        guard let session else { throw Failure.expired("ask before login") }
        var uid = ProtoWriter()
        uid.varint(1, UInt64(bitPattern: session.id))
        uid.string(2, session.secret)
        let (data, code) = try await post("command", body, ["User-Agent": Self.appVersion, "cache-control": "no-cache",
                                                           "x-waze-network-version": "3", "x-waze-wait-timeout": "10500",
                                                           "uid": uid.data.base64EncodedString()])
        if (400..<500).contains(code) { throw Failure.expired("command HTTP \(code)") }
        guard code < 400, !data.isEmpty else { throw Failure.other("command HTTP \(code)") }
        let batch = try Self.check(Self.parseBatch(data))
        lastAsk = Date()
        return batch
    }

    private func post(_ path: String, _ body: String, _ headers: [String: String]) async throws -> (Data, Int) {
        var req = URLRequest(url: url(path))
        req.httpMethod = "POST"
        req.httpBody = Data(body.utf8)
        req.setValue("binary/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue(String(seq), forHTTPHeaderField: "sequence-number")
        seq += 1
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await http.data(for: req)
        Self.bytes += body.utf8.count + data.count
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private static func makeSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        // Asks are held open by Waze for up to 10.5 s.
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 30
        c.httpCookieAcceptPolicy = .always
        return URLSession(configuration: c)
    }

    /** At most 3 new accounts a day, so a run of refusals can't use up Waze's daily allowance. */
    private func canRegister() -> Bool {
        let start = defaults.double(forKey: "wazeLiveRegDay")
        if Date().timeIntervalSince1970 - start > 86_400 { return true }
        return defaults.integer(forKey: "wazeLiveRegCount") < 3
    }

    private func noteRegistration() {
        let now = Date().timeIntervalSince1970
        if now - defaults.double(forKey: "wazeLiveRegDay") > 86_400 {
            defaults.set(now, forKey: "wazeLiveRegDay")
            defaults.set(0, forKey: "wazeLiveRegCount")
        }
        defaults.set(defaults.integer(forKey: "wazeLiveRegCount") + 1, forKey: "wazeLiveRegCount")
    }

    // MARK: The wire format

    /** Waze's servers: the Americas, Israel, and the rest of the world (the UK). */
    public static func region(_ p: LatLng) -> String {
        if p.lng >= -170, p.lng <= -52, p.lat >= -15, p.lat <= 73 { return "na" }
        if p.lng >= 34, p.lng <= 36, p.lat >= 29.5, p.lat <= 33.5 { return "il" }
        return "row"
    }

    public static func box(around p: LatLng, meters: Double) -> (s: Double, w: Double, n: Double, e: Double) {
        let dLat = meters / 110_574, dLng = meters / (cos(p.lat * .pi / 180) * 111_320)
        return (p.lat - dLat, p.lng - dLng, p.lat + dLat, p.lng + dLng)
    }

    static func seeMe() -> String { "SeeMe,1,2,T,T,T,1,-1,1,7" }

    /** "MapDisplayed,": the box's corners, its middle, a constant, the corners again. */
    public static func mapDisplayed(_ b: (s: Double, w: Double, n: Double, e: Double)) -> String {
        func f(_ v: Double) -> String { String(format: "%.6f", v) }
        let corners = [f(b.w), f(b.n), f(b.e), f(b.n), f(b.e), f(b.s), f(b.w), f(b.s)].joined(separator: ",")
        return "MapDisplayed,\(corners),\(f((b.w + b.e) / 2)),\(f((b.s + b.n) / 2)),67186,\(corners)"
    }

    /** One line of a body: "ProtoBase64," + a Batch holding one element. */
    static func line(element field: Int, _ payload: Data) -> String {
        var el = ProtoWriter()
        el.message(field, payload)
        var batch = ProtoWriter()
        batch.message(1001, el.data)
        return "ProtoBase64," + batch.data.base64EncodedString()
    }

    /** The phones SABRE Plus describes itself as; one is picked per account. */
    static let devices: [(make: String, model: String, os: String, w: Int, h: Int)] = [
        ("samsung", "SM-S928B", "16-SDK36", 1440, 3088),
        ("samsung", "SM-A546B", "15-SDK35", 1080, 2340),
        ("Google", "Pixel 9 Pro", "16-SDK36", 1280, 2856),
        ("Google", "Pixel 8", "15-SDK35", 1080, 2400),
        ("OnePlus", "CPH2451", "15-SDK35", 1240, 2772),
        ("Xiaomi", "2201117TG", "14-SDK34", 1220, 2712),
        ("motorola", "moto g84", "15-SDK35", 1080, 2400),
        ("Nothing", "A065", "15-SDK35", 1080, 2412),
    ]

    static func clientInfo(device: Int, installation: String, _ near: LatLng) -> String {
        let d = devices[device % devices.count]
        // Moved up to 500 m at random, as the app does.
        let lng = near.lng + Double.random(in: -500...500) / (cos(near.lat * .pi / 180) * 111_320)
        let lat = near.lat + Double.random(in: -500...500) / 110_574
        var pos = ProtoWriter()
        pos.int32(101, Int32((lng * 1_000_000).rounded()))
        pos.int32(102, Int32((lat * 1_000_000).rounded()))
        var display = ProtoWriter()
        display.varint(1, 2)
        display.varint(2, UInt64(d.w))
        display.varint(3, UInt64(d.h))
        var ci = ProtoWriter()
        ci.varint(1, UInt64(protocolVersion))
        ci.string(3, appVersion)
        ci.message(4, pos.data)
        ci.string(5, d.make)
        ci.string(6, d.model)
        ci.string(11, d.os)
        ci.string(16, "en")
        ci.string(17, installation)
        ci.varint(18, 50)
        ci.varint(19, 1)
        ci.message(24, display.data)
        ci.string(25, "en")
        ci.string(26, UUID().uuidString.lowercased())
        ci.varint(28, UInt64(Date().timeIntervalSince1970 * 1000))
        ci.varint(31, 5)
        return line(element: 2184, ci.data)
    }

    /** What Kite reads from an answer's elements. */
    struct Element {
        var oldCommand: String?
        var errorCode: Int?
        var errorText: String?
        var registered: (user: String, pass: String)?
        var loginSuccess: Session?
        var loginErrorType: Int?
        var alert: WazeAlert?
    }

    static func parseBatch(_ data: Data) throws -> [Element] {
        guard let fields = ProtoReader.fields(data) else { throw Failure.other("unreadable answer") }
        return fields.filter { $0.number == 1001 }.compactMap { $0.bytes.flatMap(element) }
    }

    static func element(_ data: Data) -> Element? {
        guard let fields = ProtoReader.fields(data) else { return nil }
        var el = Element()
        for f in fields {
            switch f.number {
            case 2001: el.oldCommand = f.string
            case 2003:
                let sub = f.bytes.flatMap(ProtoReader.fields) ?? []
                el.errorCode = sub.first { $0.number == 10101 }.map { Int(Int32(truncatingIfNeeded: $0.value)) } ?? 0
                el.errorText = sub.first { $0.number == 10102 }?.string ?? ""
            case 2220:
                let sub = f.bytes.flatMap(ProtoReader.fields) ?? []
                el.registered = (sub.first { $0.number == 1 }?.string ?? "", sub.first { $0.number == 2 }?.string ?? "")
            case 2224:
                let sub = f.bytes.flatMap(ProtoReader.fields) ?? []
                el.loginErrorType = Int(sub.first { $0.number == 2 }?.value ?? 0)
            case 2745:
                let sub = f.bytes.flatMap(ProtoReader.fields) ?? []
                for r in sub {
                    let inner = r.bytes.flatMap(ProtoReader.fields) ?? []
                    if r.number == 1 {
                        el.loginSuccess = Session(id: Int64(bitPattern: inner.first { $0.number == 1 }?.value ?? 0),
                                                  secret: inner.first { $0.number == 3 }?.string ?? "")
                    } else if r.number == 2 {
                        el.loginErrorType = Int(inner.first { $0.number == 2 }?.value ?? 0)
                    }
                }
            case 2708:
                if let rt = f.bytes.flatMap(ProtoReader.fields)?.first(where: { $0.number == 1 })?.bytes {
                    el.alert = alert(rt)
                }
            default: break
            }
        }
        return el
    }

    /** A RealtimeAlert: its kind, place, heading, time, street and thumbs up. */
    static func alert(_ data: Data) -> WazeAlert? {
        guard let f = ProtoReader.fields(data),
              let info = f.first(where: { $0.number == 2 })?.bytes.flatMap(ProtoReader.fields),
              let pos = info.first(where: { $0.number == 3 })?.bytes.flatMap(ProtoReader.fields),
              let lngRaw = pos.first(where: { $0.number == 101 })?.value,
              let latRaw = pos.first(where: { $0.number == 102 })?.value else { return nil }
        let type = typeNames[Int(info.first { $0.number == 1 }?.value ?? 0)] ?? ""
        let sub = subtypeNames[Int(info.first { $0.number == 2 }?.value ?? 0)] ?? ""
        guard let kind = Waze.kind(type: type, subtype: sub) else { return nil }
        let lng = Double(Int32(truncatingIfNeeded: lngRaw)) / 1_000_000
        let lat = Double(Int32(truncatingIfNeeded: latRaw)) / 1_000_000
        let report = f.first { $0.number == 3 }?.bytes.flatMap(ProtoReader.fields) ?? []
        let seconds = report.first { $0.number == 4 }?.value ?? 0
        let address = report.first { $0.number == 8 }?.bytes.flatMap(ProtoReader.fields) ?? []
        let street = address.first { $0.number == 2 }?.string.flatMap { $0.isEmpty ? nil : $0 }
        let heading = info.first { $0.number == 6 }.map { Double(Int32(truncatingIfNeeded: $0.value)) }
        let numeric = f.first { $0.number == 1 }?.value ?? 0
        let id = f.first { $0.number == 6 }?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "rt\(numeric)"
        return WazeAlert(id: id, kind: kind, subtype: sub, location: LatLng(lat, lng), street: street,
                         reportedAt: seconds > 0 ? Date(timeIntervalSince1970: Double(seconds)) : Date(),
                         thumbsUp: Int(report.first { $0.number == 9 }?.value ?? 0),
                         heading: heading.flatMap { $0 >= 0 && $0 < 360 ? $0 : nil })
    }

    /** Errors Waze sends inside a 200 answer. */
    private static func check(_ batch: [Element]) throws -> [Element] {
        for el in batch {
            if let code = el.errorCode {
                let text = (el.errorText ?? "").lowercased()
                if text.contains("relogin") || text.contains("unknown userid") || text.contains("secretkey missing")
                    || text.contains("secret key missing") { throw Failure.expired(text) }
                if (400..<500).contains(code) { throw Failure.rejected("\(code) \(text)") }
                if code >= 500 { throw Failure.other("\(code) \(text)") }
            }
            if let t = el.loginErrorType, el.loginSuccess == nil { throw loginFailure(t) }
        }
        return batch
    }

    /** Waze's own trouble (internal issues, unknown) isn't the account's fault: don't throw it away. */
    private static func loginFailure(_ type: Int) -> Failure {
        type == 0 || type == 2 ? .other("login error \(type)") : .rejected("login error \(type)")
    }

    static func typeKey(_ k: WazeAlert.Kind) -> String {
        switch k {
        case .police: return "POLICE"
        case .accident: return "ACCIDENT"
        case .hazard: return "HAZARD"
        case .weather: return "WEATHERHAZARD"
        case .roadworks: return "CONSTRUCTION"
        case .closure: return "ROAD_CLOSED"
        case .jam: return "JAM"
        }
    }

    static let typeNames: [Int: String] = [
        2: "POLICE", 3: "ACCIDENT", 4: "JAM", 6: "HAZARD", 8: "CONSTRUCTION", 13: "ROAD_CLOSED",
        14: "ROAD_CLOSED", 100: "WEATHERHAZARD", 101: "HAZARD",
    ]

    static let subtypeNames: [Int: String] = [
        201: "POLICE_VISIBLE", 202: "POLICE_HIDING", 203: "POLICE_WITH_MOBILE_CAMERA",
        301: "ACCIDENT_MINOR", 302: "ACCIDENT_MAJOR",
        401: "JAM_MODERATE_TRAFFIC", 402: "JAM_HEAVY_TRAFFIC", 403: "JAM_STAND_STILL_TRAFFIC", 404: "JAM_LIGHT_TRAFFIC",
        601: "HAZARD_ON_ROAD", 602: "HAZARD_ON_SHOULDER", 603: "HAZARD_WEATHER", 604: "HAZARD_ON_ROAD_OBJECT",
        605: "HAZARD_ON_ROAD_POT_HOLE", 606: "HAZARD_ON_ROAD_ROAD_KILL", 607: "HAZARD_ON_SHOULDER_CAR_STOPPED",
        608: "HAZARD_ON_SHOULDER_ANIMALS", 609: "HAZARD_ON_SHOULDER_MISSING_SIGN", 610: "HAZARD_WEATHER_FOG",
        611: "HAZARD_WEATHER_HAIL", 612: "HAZARD_WEATHER_HEAVY_RAIN", 613: "HAZARD_WEATHER_HEAVY_SNOW",
        614: "HAZARD_WEATHER_FLOOD", 619: "HAZARD_WEATHER_FREEZING_RAIN", 620: "HAZARD_ON_ROAD_LANE_CLOSED",
        621: "HAZARD_ON_ROAD_OIL", 622: "HAZARD_ON_ROAD_ICE", 623: "HAZARD_ON_ROAD_CONSTRUCTION",
        624: "HAZARD_ON_ROAD_CAR_STOPPED", 625: "HAZARD_ON_ROAD_TRAFFIC_LIGHT_FAULT", 626: "HAZARD_ON_ROAD_EMERGENCY_VEHICLE",
        1301: "ROAD_CLOSED_HAZARD", 1302: "ROAD_CLOSED_CONSTRUCTION", 1303: "ROAD_CLOSED_EVENT",
        2001: "HAZARD_ON_ROAD_ICE", 2002: "HAZARD_ON_ROAD_LANE_CLOSED", 2003: "HAZARD_ON_ROAD_LANE_CLOSED",
        2004: "HAZARD_ON_ROAD_LANE_CLOSED", 2005: "HAZARD_ON_ROAD_LANE_CLOSED",
    ]
}

/** Just enough protobuf to write Waze's requests: varints and length-delimited fields. */
struct ProtoWriter {
    private(set) var data = Data()

    mutating func raw(_ v: UInt64) {
        var v = v
        while v >= 0x80 {
            data.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }

    mutating func varint(_ field: Int, _ v: UInt64) {
        raw(UInt64(field << 3))
        raw(v)
    }

    /** int32 as protobuf writes it: a negative one sign-extended to 64 bits. */
    mutating func int32(_ field: Int, _ v: Int32) { varint(field, UInt64(bitPattern: Int64(v))) }

    mutating func message(_ field: Int, _ bytes: Data) {
        raw(UInt64(field << 3 | 2))
        raw(UInt64(bytes.count))
        data.append(bytes)
    }

    mutating func string(_ field: Int, _ s: String) { message(field, Data(s.utf8)) }
}

/** Reads a message's top-level fields; nil when the bytes aren't protobuf. */
enum ProtoReader {
    struct Field {
        var number: Int
        /** A varint's value (fixed 32/64-bit ones too). */
        var value: UInt64
        /** A length-delimited field's bytes. */
        var bytes: Data?
        var string: String? { bytes.flatMap { String(data: $0, encoding: .utf8) } }
    }

    static func fields(_ data: Data) -> [Field]? {
        let b = [UInt8](data)
        var i = 0
        var out: [Field] = []
        func varint() -> UInt64? {
            var v: UInt64 = 0, shift: UInt64 = 0
            while i < b.count, shift < 64 {
                let byte = b[i]
                i += 1
                v |= UInt64(byte & 0x7F) << shift
                if byte < 0x80 { return v }
                shift += 7
            }
            return nil
        }
        while i < b.count {
            guard let key = varint() else { return nil }
            let number = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard let v = varint() else { return nil }
                out.append(Field(number: number, value: v))
            case 1:
                guard i + 8 <= b.count else { return nil }
                var v: UInt64 = 0
                for k in 0..<8 { v |= UInt64(b[i + k]) << (8 * UInt64(k)) }
                i += 8
                out.append(Field(number: number, value: v))
            case 2:
                guard let len = varint(), len <= UInt64(b.count - i) else { return nil }
                out.append(Field(number: number, value: 0, bytes: Data(b[i..<i + Int(len)])))
                i += Int(len)
            case 5:
                guard i + 4 <= b.count else { return nil }
                var v: UInt64 = 0
                for k in 0..<4 { v |= UInt64(b[i + k]) << (8 * UInt64(k)) }
                i += 4
                out.append(Field(number: number, value: v))
            default:
                return nil
            }
        }
        return out
    }
}

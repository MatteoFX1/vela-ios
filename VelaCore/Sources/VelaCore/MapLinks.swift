import Foundation

/**
 * Map links pasted into the search bar: Google Maps (full and maps.app.goo.gl short links), Waze,
 * Apple Maps, geo: links and plain "51.5, -0.12" coordinates. Short links are followed to the full
 * link first.
 */
public enum MapLinks {
    /** What a link points at: a spot (with the place's name when the link has one) or a search. */
    public enum Target: Equatable, Sendable {
        case spot(LatLng, name: String?)
        case search(String, near: LatLng?)
    }

    /** The first link in [text] (share text often has the place's name before it), or nil. */
    public static func link(in text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasPrefix("geo:") { return URL(string: t) }
        guard let r = t.range(of: #"(https?://)?[A-Za-z0-9.-]*(google\.[a-z.]+/maps|maps\.google\.[a-z.]+|goo\.gl|share\.google|waze\.com|maps\.apple\.com)[^\s]*"#,
                              options: [.regularExpression, .caseInsensitive]) else { return nil }
        var s = String(t[r])
        if !s.lowercased().hasPrefix("http") { s = "https://" + s }
        return URL(string: s)
    }

    /** True when [text] looks like something this can open, so it shouldn't go to place search. */
    public static func looksLikeLink(_ text: String) -> Bool {
        link(in: text) != nil || coordinates(text) != nil
    }

    /** Plain coordinates typed or pasted: "51.50072, -0.12462" or "51.5 -0.12". */
    public static func coordinates(_ text: String) -> LatLng? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = t.split(whereSeparator: { $0 == "," || $0 == " " }).filter { !$0.isEmpty }
        guard parts.count == 2, let lat = Double(parts[0]), let lng = Double(parts[1]),
              parts.allSatisfy({ $0.contains(".") }) else { return nil }
        return valid(lat, lng)
    }

    /** Where [text] points, following short links over the network. */
    public static func resolve(_ text: String) async -> Target? {
        if let c = coordinates(text) { return .spot(c, name: nil) }
        guard let url = link(in: text) else { return nil }
        if let t = parse(url) { return t }
        for next in await redirects(from: url) {
            if let t = parse(next) { return t }
        }
        return nil
    }

    /** Where a long link points, with no network. */
    public static func parse(_ url: URL) -> Target? {
        if url.scheme?.lowercased() == "geo" { return parseGeo(url.absoluteString) }
        let host = url.host?.lowercased() ?? ""
        let q = query(url)
        // A consent page or a redirector carries the real link in a parameter.
        for key in ["continue", "link", "url"] {
            if let inner = q[key], let u = URL(string: inner), u.host != nil, u != url, let t = parse(u) { return t }
        }
        if host.contains("waze.com") { return parseWaze(url, q) }
        if host.contains("maps.apple.com") { return parseApple(q) }
        if host.contains("google.") { return parseGoogle(url, q) }
        return nil
    }

    // MARK: Google

    static func parseGoogle(_ url: URL, _ q: [String: String]) -> Target? {
        let path = url.path.removingPercentEncoding ?? url.path
        let full = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        let segments = path.split(separator: "/").map(String.init)
        var name: String?
        if let i = segments.firstIndex(of: "place"), i + 1 < segments.count, !segments[i + 1].hasPrefix("@") {
            name = segments[i + 1].replacingOccurrences(of: "+", with: " ")
        }
        // The pin itself (!3d lat !4d lng) beats the map's middle (@lat,lng).
        if let m = match(full, #"!3d(-?\d+(?:\.\d+)?)!4d(-?\d+(?:\.\d+)?)"#), let p = valid(m.0, m.1) {
            return .spot(p, name: name.flatMap(nameIfNotCoordinates))
        }
        let at = match(path, #"@(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)"#).flatMap { valid($0.0, $0.1) }
        for key in ["q", "query", "daddr", "destination"] {
            guard let v = q[key]?.replacingOccurrences(of: "+", with: " "), !v.isEmpty else { continue }
            if let c = coordinates(v) ?? latLngPair(v) { return .spot(c, name: nil) }
            return .search(v, near: at ?? q["ll"].flatMap(latLngPair) ?? q["center"].flatMap(latLngPair))
        }
        if let i = segments.firstIndex(of: "search"), i + 1 < segments.count, !segments[i + 1].hasPrefix("@") {
            let v = segments[i + 1].replacingOccurrences(of: "+", with: " ")
            if let c = coordinates(v) ?? latLngPair(v) { return .spot(c, name: nil) }
            return .search(v, near: at)
        }
        if let i = segments.firstIndex(of: "dir"), let last = segments[(i + 1)...].last(where: { !$0.hasPrefix("@") && !$0.hasPrefix("data=") && !$0.isEmpty }) {
            let v = last.replacingOccurrences(of: "+", with: " ")
            if let c = coordinates(v) ?? latLngPair(v) { return .spot(c, name: nil) }
            return .search(v, near: at)
        }
        if let n = name, let at { return .spot(at, name: nameIfNotCoordinates(n)) }
        if let c = q["ll"].flatMap(latLngPair) ?? q["center"].flatMap(latLngPair) ?? at { return .spot(c, name: nil) }
        return nil
    }

    // MARK: Waze

    static func parseWaze(_ url: URL, _ q: [String: String]) -> Target? {
        for key in ["ll", "latlng"] {
            if let c = q[key].flatMap(latLngPair) { return .spot(c, name: q["q"]) }
        }
        if let to = q["to"] ?? q["from"], to.hasPrefix("ll."), let c = latLngPair(String(to.dropFirst(3))) {
            return .spot(c, name: nil)
        }
        // Share links: waze.com/ul/h + a geohash of the spot.
        let parts = url.path.split(separator: "/")
        if parts.count >= 2, parts[parts.count - 2] == "ul", parts.last?.first == "h",
           let c = geohash(String(parts.last!.dropFirst())) {
            return .spot(c, name: nil)
        }
        if let v = q["q"], !v.isEmpty { return .search(v, near: nil) }
        return nil
    }

    // MARK: Apple and geo:

    static func parseApple(_ q: [String: String]) -> Target? {
        let near = q["ll"].flatMap(latLngPair) ?? q["sll"].flatMap(latLngPair)
        if let c = q["coordinate"].flatMap(latLngPair) ?? near {
            return .spot(c, name: q["q"] ?? q["name"])
        }
        if let v = q["q"] ?? q["address"] ?? q["daddr"], !v.isEmpty {
            if let c = latLngPair(v) { return .spot(c, name: nil) }
            return .search(v, near: nil)
        }
        return nil
    }

    static func parseGeo(_ s: String) -> Target? {
        // geo:51.5,-0.12?q=51.5,-0.12(Label)  or  geo:0,0?q=Some+Place
        let body = String(s.dropFirst(4)).removingPercentEncoding ?? String(s.dropFirst(4))
        let parts = body.split(separator: "?", maxSplits: 1).map(String.init)
        let head = parts.first.flatMap { latLngPair($0.split(separator: ";").first.map(String.init) ?? $0) }
        if parts.count > 1, let qv = parts[1].split(separator: "&").first(where: { $0.hasPrefix("q=") }) {
            var v = String(qv.dropFirst(2)).replacingOccurrences(of: "+", with: " ")
            var label: String?
            if let open = v.firstIndex(of: "("), v.hasSuffix(")") {
                label = String(v[v.index(after: open)..<v.index(before: v.endIndex)])
                v = String(v[..<open])
            }
            if let c = latLngPair(v) { return .spot(c, name: label) }
            if !v.isEmpty { return .search(v, near: head.flatMap { $0.lat == 0 && $0.lng == 0 ? nil : $0 }) }
        }
        if let head, !(head.lat == 0 && head.lng == 0) { return .spot(head, name: nil) }
        return nil
    }

    // MARK: Helpers

    /** Decodes a geohash ("gcpvj0d6") to the middle of its box. */
    public static func geohash(_ s: String) -> LatLng? {
        let alphabet = Array("0123456789bcdefghjkmnpqrstuvwxyz")
        var lat = (-90.0, 90.0), lng = (-180.0, 180.0)
        var even = true
        guard s.count >= 4 else { return nil }
        for ch in s.lowercased() {
            guard let v = alphabet.firstIndex(of: ch) else { return nil }
            for bit in (0..<5).reversed() {
                let on = (v >> bit) & 1 == 1
                if even {
                    let mid = (lng.0 + lng.1) / 2
                    if on { lng.0 = mid } else { lng.1 = mid }
                } else {
                    let mid = (lat.0 + lat.1) / 2
                    if on { lat.0 = mid } else { lat.1 = mid }
                }
                even.toggle()
            }
        }
        return LatLng((lat.0 + lat.1) / 2, (lng.0 + lng.1) / 2)
    }

    static func query(_ url: URL) -> [String: String] {
        var out: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            if out[item.name] == nil, let v = item.value { out[item.name] = v }
        }
        return out
    }

    static func latLngPair(_ s: String) -> LatLng? {
        let parts = s.replacingOccurrences(of: "%2C", with: ",").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let lat = Double(parts[0]), let lng = Double(parts[1]) else { return nil }
        return valid(lat, lng)
    }

    static func match(_ s: String, _ pattern: String) -> (Double, Double)? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let a = Range(m.range(at: 1), in: s), let b = Range(m.range(at: 2), in: s),
              let x = Double(s[a]), let y = Double(s[b]) else { return nil }
        return (x, y)
    }

    static func valid(_ lat: Double, _ lng: Double) -> LatLng? {
        guard (-90...90).contains(lat), (-180...180).contains(lng), !(lat == 0 && lng == 0) else { return nil }
        return LatLng(lat, lng)
    }

    static func nameIfNotCoordinates(_ n: String) -> String? {
        latLngPair(n) == nil && !n.isEmpty ? n : nil
    }

    // MARK: Short links

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    /** Each place a short link redirects to, in order, up to six hops. */
    static func redirects(from start: URL) async -> [URL] {
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var out: [URL] = []
        var url = start
        for _ in 0..<6 {
            var r = URLRequest(url: url)
            r.timeoutInterval = 10
            r.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
                        forHTTPHeaderField: "User-Agent")
            guard let (data, resp) = try? await session.data(for: r), let http = resp as? HTTPURLResponse else { break }
            if let loc = http.value(forHTTPHeaderField: "Location"), let next = URL(string: loc, relativeTo: url)?.absoluteURL {
                out.append(next)
                if parse(next) != nil { break }
                url = next
                continue
            }
            // Some short links answer with a page that holds the real link.
            let html = String(decoding: data.prefix(200_000), as: UTF8.self)
            if let r = html.range(of: #"https://www\.google\.[a-z.]+/maps/[^"'\s<>\\]+"#, options: .regularExpression),
               let u = URL(string: String(html[r]).replacingOccurrences(of: "&amp;", with: "&")) {
                out.append(u)
            }
            break
        }
        return out
    }
}

import Combine
import CoreLocation
import Foundation
import MapLibre
import SwiftUI
import UIKit
import VelaCore

/** The dock's pages. */
enum AppTab: Equatable {
    case map, saved, settings
}

/** Which of your places the "pick a place" sheet is choosing. */
enum PickKind: String, Identifiable {
    case home, work
    var id: String { rawValue }
}

enum SheetDetent: Equatable {
    case peek, half, full
}

enum SortMode: String, CaseIterable, Identifiable {
    case relevance = "Relevance", distance = "Distance", rating = "Rating"
    var id: String { rawValue }
}

struct Category: Identifiable, Hashable {
    let label: String
    let icon: String
    let query: String
    var id: String { label }

    /** British words where units are British: petrol, supermarkets, chemists, cash machines. */
    static var all: [Category] { Fmt.yards ? british : american }

    static let british = [
        Category(label: "Restaurants", icon: "fork.knife", query: "restaurants"),
        Category(label: "Coffee", icon: "cup.and.saucer.fill", query: "coffee"),
        Category(label: "Petrol", icon: "fuelpump.fill", query: "petrol station"),
        Category(label: "Supermarkets", icon: "cart.fill", query: "supermarket"),
        Category(label: "Pubs", icon: "mug.fill", query: "pub"),
        Category(label: "Hotels", icon: "bed.double.fill", query: "hotels"),
        Category(label: "Parking", icon: "parkingsign", query: "car park"),
        Category(label: "EV charging", icon: "bolt.car.fill", query: "ev charging station"),
        Category(label: "Chemists", icon: "cross.case.fill", query: "pharmacy"),
        Category(label: "Cash machines", icon: "banknote.fill", query: "atm"),
    ]

    static let american = [
        Category(label: "Restaurants", icon: "fork.knife", query: "restaurants"),
        Category(label: "Coffee", icon: "cup.and.saucer.fill", query: "coffee"),
        Category(label: "Gas", icon: "fuelpump.fill", query: "gas stations"),
        Category(label: "Groceries", icon: "cart.fill", query: "grocery stores"),
        Category(label: "Hotels", icon: "bed.double.fill", query: "hotels"),
        Category(label: "Parking", icon: "parkingsign", query: "parking"),
        Category(label: "Pharmacies", icon: "cross.case.fill", query: "pharmacy"),
        Category(label: "ATMs", icon: "banknote.fill", query: "atm"),
    ]
}

/** Directions to one place: routes for every mode, the one picked, and where from. */
struct DirectionsState {
    var destination: Place
    /** True when the trip goes from the place back to you. */
    var reversed = false
    var mode: TravelMode
    var routes: [TravelMode: [Route]] = [:]
    var loading: Set<TravelMode> = []
    var errors: [TravelMode: String] = [:]
    var selected = 0
    /** The Transit tab is showing (its trips come from Transitous, not the road routers). */
    /** Places to stop at on the way, in order. */
    var stops: [Place] = []
    var transit = false
    var trips: [TransitTrip]?
    var tripsError: String?
    /** Nil for "leave now". */
    var transitTime: Date?
    var arriveBy = false
    var trip = 0

    var current: [Route] { transit ? [] : routes[mode] ?? [] }
    var route: Route? { current.indices.contains(selected) ? current[selected] : current.first }
    var pickedTrip: TransitTrip? { transit ? trips.flatMap { $0.indices.contains(trip) ? $0[trip] : $0.first } : nil }
}

/** The whole app's state; the map and every sheet read it. */
@MainActor
final class AppModel: ObservableObject {
    let settings = AppSettings.shared
    let location: LocationService

    @Published var query = ""
    /** Autocomplete while typing: Google's, or OpenStreetMap's without Google. */
    @Published var suggestions = SuggestParser.Result()
    private var suggestTask: Task<Void, Never>?
    @Published var results: [Place] = []
    @Published var resultsTitle = ""
    @Published var selected: Place?
    @Published var searching = false
    @Published var notice: String?
    @Published var detent: SheetDetent = .half
    @Published var openNowOnly = false
    @Published var rating4Only = false
    @Published var sort: SortMode = .relevance
    @Published var directions: DirectionsState?
    @Published var nav: Navigator?
    @Published var showLayers = false
    /** Which page of the dock is open. */
    @Published var tab: AppTab = .map
    /** Live Waze reports in view, for the "Live from Waze" chip; nil until Waze answers. */
    @Published var wazeLiveCount: Int?
    /** The police risk around you (0 to 100), for the chip on the map. */
    @Published var areaRisk: Int?
    @Published var showSettings = false
    /** A Waze report tapped on the map, shown in a small card. */
    @Published var wazeInfo: WazeAlert?
    @Published var surveillanceInfo: SurveillanceCamera?
    /** The "Add stop" search sheet. */
    @Published var addingStop = false
    @Published var showSaved = false
    /** The sheet for choosing home or work by searching for it. */
    @Published var picking: PickKind?
    @Published var showSteps = false
    /** "Start" on a place: begin the drive as soon as its route arrives. */
    @Published var autoStart = false
    /** Bumped when the map should redraw overlays that don't come from a published value. */
    @Published var mapTick = 0
    /** Which way the map faces, for the compass button. */
    @Published var mapHeading: Double = 0

    weak var map: MLNMapView? { didSet { glide.map = map } }
    /** How wide the side panel is on a big screen (the open iPhone Duo), so the map centres
     *  things in the part you can see; 0 on a phone. */
    var sideInset: CGFloat = 0 { didSet { glide.leftInset = sideInset } }
    /** Moves the nav arrow and camera every frame between GPS fixes. */
    let glide = NavGlide()
    /** Bumped on every new route or transit request, so answers to an older one (before a
     *  reverse, a new stop or another time) are dropped instead of replacing the new ones. */
    private var routesRequest = 0
    private var transitRequest = 0
    private var searchTask: Task<Void, Never>?
    private var navSub: AnyCancellable?

    init() {
        location = LocationService()
        location.onUpdate = { [weak self] loc in self?.locationChanged(loc) }
    }

    var userLatLng: LatLng? {
        location.last.map { LatLng($0.coordinate.latitude, $0.coordinate.longitude) }
            ?? map?.userLocation?.location.map { LatLng($0.coordinate.latitude, $0.coordinate.longitude) }
    }

    // MARK: Search

    var visibleResults: [Place] {
        var r = results
        if openNowOnly { r = r.filter { $0.openNow == true } }
        if rating4Only { r = r.filter { ($0.rating ?? 0) >= 4 } }
        switch sort {
        case .relevance: break
        case .distance: r.sort { ($0.distanceMeters ?? .infinity) < ($1.distanceMeters ?? .infinity) }
        case .rating: r.sort { ($0.rating ?? 0) > ($1.rating ?? 0) }
        }
        return r
    }

    var viewport: (center: LatLng, span: Double?) {
        guard let map, map.bounds.width > 0 else { return (userLatLng ?? LatLng(40.7484, -73.9857), nil) }
        let c = map.centerCoordinate
        let b = map.visibleCoordinateBounds
        let span = LatLng(b.sw.latitude, b.sw.longitude).distance(to: LatLng(b.ne.latitude, b.ne.longitude)) / 1.4
        return (LatLng(c.latitude, c.longitude), span.isFinite && span > 0 ? span : nil)
    }

    func search(_ text: String? = nil, title: String? = nil) {
        let q = (text ?? query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        if title == nil, MapLinks.looksLikeLink(q) {
            openLink(q)
            return
        }
        query = title ?? q
        settings.addRecent(title ?? q)
        searchTask?.cancel()
        selected = nil
        directions = nil
        searching = true
        notice = nil
        openNowOnly = false
        rating4Only = false
        sort = .relevance
        let vp = viewport
        let useGoogle = !settings.noGoogle
        let user = userLatLng
        searchTask = Task {
            var r = await PlaceSearch.search(q, center: vp.center, spanMeters: vp.span, useGoogle: useGoogle)
            guard !Task.isCancelled else { return }
            // Distances read from you, not from the middle of the map.
            if let user {
                r.places = r.places.map { var p = $0; p.distanceMeters = user.distance(to: p.location); return p }
            }
            searching = false
            resultsTitle = title ?? q
            results = r.places
            if r.places.isEmpty {
                notice = Connectivity.explain("No results for \"\(q)\" here. Try another word, or move the map.")
            } else if r.googleError != nil && useGoogle {
                notice = "Google didn't answer, so these results are from OpenStreetMap."
            }
            if r.places.count == 1 {
                select(r.places[0])
            } else {
                detent = .half
                frame(r.places.map(\.location))
            }
        }
    }

    func typed(_ text: String) {
        suggestTask?.cancel()
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2, !MapLinks.looksLikeLink(q) else { suggestions = SuggestParser.Result(); return }
        let vp = viewport
        let useGoogle = !settings.noGoogle
        let user = userLatLng
        suggestTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            var r = SuggestParser.Result()
            if useGoogle {
                r = (try? await GoogleClient.shared.suggest(q, near: vp.center, spanMeters: vp.span ?? 20_000)) ?? r
            }
            if r.places.isEmpty && r.queries.isEmpty, let pc = await Postcodes.lookup(q) {
                // A UK postcode, like the Set home box finds: the open geocoder often misses them.
                r.places = [pc]
            }
            if r.places.isEmpty && r.queries.isEmpty {
                r.places = (try? await Photon.search(q, near: vp.center, limit: 8)) ?? []
            }
            guard !Task.isCancelled else { return }
            if let user {
                r.places = r.places.map { var p = $0; p.distanceMeters = user.distance(to: p.location); return p }
            }
            suggestions = r
        }
    }

    /** A pasted Google Maps, Waze or Apple Maps link (or coordinates): show the spot it points at. */
    func openLink(_ text: String) {
        searchTask?.cancel()
        suggestTask?.cancel()
        suggestions = SuggestParser.Result()
        selected = nil
        directions = nil
        results = []
        notice = nil
        searching = true
        query = "Opening link…"
        searchTask = Task {
            let target = await MapLinks.resolve(text)
            guard !Task.isCancelled else { return }
            searching = false
            switch target {
            case let .spot(point, name?)?:
                query = name
                resolve(Place(id: "link:\(point.lat),\(point.lng)", name: name, location: point, source: "osm"))
            case let .spot(point, nil)?:
                query = ""
                dropPin(at: point, name: "Shared location")
            case let .search(q, near)?:
                if let near, let map {
                    map.setCenter(CLLocationCoordinate2D(latitude: near.lat, longitude: near.lng), zoomLevel: 14, animated: false)
                }
                search(q)
            case nil:
                query = ""
                notice = Connectivity.explain("Couldn't find a location in that link.")
            }
        }
    }

    /** A place picked from the suggestions: show it now, then fill in its details from Google. */
    func openSuggestion(_ place: Place) {
        suggestTask?.cancel()
        // A search still loading would otherwise land afterwards and replace this place.
        searchTask?.cancel()
        searching = false
        notice = nil
        settings.addRecent(place.name)
        query = place.name
        results = []
        directions = nil
        resolve(place)
    }

    func clearSearch() {
        searchTask?.cancel()
        query = ""
        results = []
        resultsTitle = ""
        selected = nil
        searching = false
        notice = nil
    }

    func select(_ place: Place, focus: Bool = true) {
        var p = place
        if !DemoScript.active { settings.addRecentPlace(place) }
        if p.distanceMeters == nil, let u = userLatLng { p.distanceMeters = u.distance(to: p.location) }
        selected = p
        detent = .half
        guard focus, let map else { return }
        let target = CLLocationCoordinate2D(latitude: p.location.lat, longitude: p.location.lng)
        let pad = sideInset > 0 ? UIEdgeInsets(top: 0, left: sideInset, bottom: 0, right: 0)
                                : UIEdgeInsets(top: 120, left: 0, bottom: map.bounds.height * 0.45, right: 0)
        let cam = MLNMapCamera(lookingAtCenter: target, acrossDistance: 900, pitch: 0, heading: 0)
        if map.zoomLevel > 16 { cam.altitude = map.camera.altitude }
        map.setCamera(cam, withDuration: 0.6, animationTimingFunction: CAMediaTimingFunction(name: .easeInEaseOut),
                      edgePadding: pad, completionHandler: nil)
    }

    func closePlace() {
        selected = nil
        if !results.isEmpty { detent = .half }
    }

    /** A tap on a place the basemap draws: look it up on Google by name at that spot. */
    func resolveTapped(name: String, at point: LatLng) {
        resolve(Place(id: "tap:\(point.lat),\(point.lng)", name: name, location: point, source: "osm"))
    }

    /** Show [placeholder] right away, then swap in Google's full place found at the same spot. */
    private func resolve(_ placeholder: Place) {
        var placeholder = placeholder
        let name = placeholder.name, point = placeholder.location
        placeholder.distanceMeters = userLatLng?.distance(to: point)
        select(placeholder, focus: !placeholder.id.hasPrefix("tap:"))
        guard !settings.noGoogle else { return }
        let q = [name, placeholder.address].compactMap { $0 }.joined(separator: " ")
        let pid = placeholder.id
        Task {
            let found = (try? await GoogleClient.shared.search(q, center: point, spanMeters: 1_000, pages: 1)) ?? []
            guard selected?.id == pid else { return }
            if let best = found.filter({ $0.location.distance(to: point) < 150 })
                .min(by: { $0.location.distance(to: point) < $1.location.distance(to: point) }) {
                var b = best
                // Enrich a tapped map feature without moving its pin to a nearby search result.
                if pid.hasPrefix("tap:") { b.location = point }
                b.distanceMeters = userLatLng?.distance(to: b.location)
                selected = b
                if !DemoScript.active { settings.addRecentPlace(b) }
            }
        }
    }

    static let locationOffText = "Location is off for Kite. Turn it on in Settings to get directions from where you are."

    // MARK: My places

    /** A Siri or Shortcuts request: directions home or to work, or back to the car. */
    func perform(_ kind: LaunchAction.Kind) async {
        // At a cold start, give location a few seconds to come in first.
        for _ in 0..<20 where userLatLng == nil { try? await Task.sleep(nanoseconds: 250_000_000) }
        if nav != nil { endNavigation() }
        let target: Place?
        switch kind {
        case .home: target = settings.home
        case .work: target = settings.work
        case .car: target = settings.parking
        }
        guard let target else {
            if kind == .car { notice = "No parking spot saved yet. Tap P on the map when you park." }
            else { picking = kind == .home ? .home : .work }
            return
        }
        openDirections(to: target)
        if kind == .car { directions?.mode = .walk }
    }

    /** Home, work, the parked car or a saved place, by id, for a tap on its map icon. */
    func myPlace(_ id: String) -> Place? {
        [settings.home, settings.work, settings.parking].compactMap { $0 }.first { $0.id == id }
            ?? settings.saved.first { $0.id == id }
    }

    func setHome(_ p: Place?) {
        settings.home = p.map { var h = $0; h.distanceMeters = nil; return h }
        if p != nil { notice = "Saved as your home." }
    }

    func setWork(_ p: Place?) {
        settings.work = p.map { var w = $0; w.distanceMeters = nil; return w }
        if p != nil { notice = "Saved as your work." }
    }

    /** Remember where the car is: here, now, with the street name when one is found. */
    func saveParking() {
        guard let me = userLatLng else {
            notice = location.denied ? "Location is off for Kite. Turn it on in Settings to save where you parked." : "Still finding your location. Try again in a moment."
            return
        }
        var p = Place(id: "parking:\(Int(Date().timeIntervalSince1970))", name: "Parked car", location: me, source: "osm")
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        p.category = "Parked at \(f.string(from: Date()))"
        settings.parking = p
        notice = "Parking spot saved. Tap the P button to find your car."
        let pid = p.id
        Task {
            guard let found = await Photon.reverse(me), settings.parking?.id == pid else { return }
            settings.parking?.address = [found.name, found.address].compactMap { $0 }.joined(separator: ", ")
        }
    }

    func clearParking() {
        if selected?.id == settings.parking?.id { selected = nil }
        settings.parking = nil
    }

    /** Long press: a dropped pin with the address there. */
    func dropPin(at point: LatLng, name: String = "Dropped pin") {
        var pin = Place(id: "pin:\(point.lat),\(point.lng)", name: name, location: point, source: "osm")
        pin.category = String(format: "%.5f, %.5f", point.lat, point.lng)
        select(pin)
        Task {
            guard let found = await Photon.reverse(point), selected?.id == pin.id else { return }
            var p = pin
            p.address = [found.name, found.address].compactMap { $0 }.joined(separator: ", ")
            selected = p
        }
    }

    // MARK: Directions

    func openDirections(to place: Place) {
        autoStart = false
        directions = DirectionsState(destination: place, mode: settings.defaultMode)
        detent = .half
        loadAllModes()
    }

    func closeDirections() {
        autoStart = false
        directions = nil
        showSteps = false
        if let p = selected { select(p) }
    }

    func reverseDirections() {
        directions?.reversed.toggle()
        directions?.routes = [:]
        directions?.selected = 0
        directions?.trips = nil
        directions?.trip = 0
        loadAllModes()
    }

    func setMode(_ m: TravelMode) {
        directions?.transit = false
        directions?.mode = m
        directions?.selected = 0
        settings.defaultMode = m
        frameRoute()
    }

    func addStop(_ p: Place) {
        guard directions != nil, (directions?.stops.count ?? 0) < 8 else { return }
        directions?.stops.append(p)
        reloadRoutes()
    }

    func removeStop(_ i: Int) {
        guard let d = directions, d.stops.indices.contains(i) else { return }
        directions?.stops.remove(at: i)
        reloadRoutes()
    }

    /** 0 leave now, 1 depart at, 2 arrive by. */
    func setTransitTime(kind: Int, at date: Date) {
        directions?.transitTime = kind == 0 ? nil : date
        directions?.arriveBy = kind == 2
        loadTransit()
    }

    func showTransit() {
        directions?.transit = true
        frameRoute()
    }

    func selectTrip(_ i: Int) {
        directions?.trip = i
        frameRoute()
    }

    func selectRoute(_ i: Int) {
        directions?.selected = i
        mapTick += 1
    }

    func reloadRoutes() {
        guard directions != nil else { return }
        directions?.routes = [:]
        directions?.errors = [:]
        directions?.selected = 0
        loadAllModes()
    }

    private func loadAllModes() {
        guard let d = directions else { return }
        guard let me = userLatLng else {
            // Say so on the trip card itself, not just in passing.
            let why = location.denied ? Self.locationOffText : "Waiting for your location…"
            for m in TravelMode.allCases { directions?.errors[m] = why }
            directions?.tripsError = why
            directions?.trips = []
            if !location.denied {
                // GPS is on but hasn't answered yet: try again once it does.
                location.start()
                Task {
                    for _ in 0..<40 where userLatLng == nil { try? await Task.sleep(nanoseconds: 250_000_000) }
                    if userLatLng != nil, directions?.destination.id == d.destination.id, directions?.routes.isEmpty == true { reloadRoutes() }
                }
            }
            return
        }
        let (from, to) = d.reversed ? (d.destination.location, me) : (me, d.destination.location)
        let via = (d.reversed ? d.stops.reversed() : d.stops).map(\.location)
        routesRequest += 1
        let req = routesRequest
        let hw = settings.avoidHighways, tolls = settings.avoidTolls, google = !settings.noGoogle
        // Already driving (asked at a red light, say): no route that starts with a U-turn.
        let moving = location.last.flatMap { l in l.speed >= 4 && l.course >= 0 && l.courseAccuracy >= 0 && l.courseAccuracy < 45 ? l.course : nil }
        let heading = d.reversed ? nil : moving
        for m in TravelMode.allCases {
            directions?.loading.insert(m)
            Task {
                let r = await Directions.routes(from: from, to: to, mode: m, avoidHighways: hw, avoidTolls: tolls, useGoogle: google, via: via,
                                                heading: m == .drive ? heading : nil, alternatives: true)
                guard directions?.destination.id == d.destination.id, routesRequest == req else { return }
                directions?.loading.remove(m)
                directions?.routes[m] = r.routes
                if r.routes.isEmpty {
                    directions?.errors[m] = Connectivity.explain(r.error == "No route found." ? "No route found." : "Couldn't get a route just now. Try again in a moment.")
                }
                if m == directions?.mode {
                    frameRoute()
                    if autoStart, !r.routes.isEmpty {
                        autoStart = false
                        startNavigation()
                    }
                }
            }
        }
        loadTransit()
    }

    /** Transit trips for the current trip, leaving now or at the picked time. */
    func loadTransit() {
        guard let d = directions, let me = userLatLng else { return }
        let (from, to) = d.reversed ? (d.destination.location, me) : (me, d.destination.location)
        let destId = d.destination.id
        let time = d.transitTime, arriveBy = d.arriveBy
        transitRequest += 1
        let req = transitRequest
        directions?.trips = nil
        directions?.tripsError = nil
        directions?.trip = 0
        Task {
            do {
                let trips = try await Transitous.plan(from: from, to: to, time: time, arriveBy: arriveBy)
                guard directions?.destination.id == destId, transitRequest == req else { return }
                directions?.trips = trips
                if trips.isEmpty { directions?.tripsError = "No transit trips found here." }
            } catch {
                guard directions?.destination.id == destId, transitRequest == req else { return }
                directions?.trips = []
                directions?.tripsError = Connectivity.explain("Couldn't reach the transit planner.")
            }
            if directions?.transit == true { frameRoute() }
        }
    }

    func frameRoute() {
        if let t = directions?.pickedTrip {
            if t.path.count >= 2 { frame(t.path, bottomFraction: 0.42) }
            mapTick += 1
            return
        }
        guard let r = directions?.route else { mapTick += 1; return }
        frame(r.polyline, bottomFraction: 0.42, top: 170 + CGFloat(directions?.stops.count ?? 0) * 42)
    }

    /** Police risk within about a kilometre of you, from remembered and live Waze police reports. */
    func updateAreaRisk(live: [WazeAlert]) {
        guard settings.wazeOn, settings.policeRisk, settings.wazePolice,
              !location.reducedAccuracy, let fix = location.last,
              fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= 200,
              abs(fix.timestamp.timeIntervalSinceNow) < 120 else { areaRisk = nil; return }
        let here = LatLng(fix.coordinate.latitude, fix.coordinate.longitude)
        let d = 0.0096 / max(cos(here.lat * .pi / 180), 0.2) * 0.62
        let line = [LatLng(here.lat, here.lng - d), LatLng(here.lat, here.lng + d)]
        let near = live.filter { $0.kind == .police && $0.location.distance(to: here) < 1_500 }.count
        areaRisk = PoliceRisk.score(ahead: line, past: WazeHistory.shared.reports, live: near, radius: 900)
    }

    // MARK: Navigation

    func startNavigation() {
        guard let d = directions, let route = d.route, !d.reversed else { return }
        let n = Navigator(route: route, destination: d.destination, stops: d.stops, settings: settings)
        nav = n
        navSub = n.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        n.onFinished = { [weak self, weak n] in
            guard let self, let n, self.nav === n else { return }
            self.endNavigation()
        }
        location.setNavigating(true, mode: route.mode.rawValue)
        map?.showsUserLocation = false
        if let loc = location.last { n.handle(loc); followCamera(n, loc, animated: false) }
    }

    func endNavigation() {
        nav?.stop()
        glide.stop()
        nav = nil
        navSub = nil
        location.setNavigating(false)
        map?.showsUserLocation = true
        directions = nil
        showSteps = false
        resetCamera()
    }

    func recenterNav() {
        guard let n = nav else { return }
        n.following = true
        if let loc = location.last { followCamera(n, loc, animated: true) }
    }

    /** Show the whole remaining trip; the camera stops following until re-centered. */
    func overviewNav() {
        guard let n = nav else { return }
        n.following = false
        let line = n.progress.map { Geo.slice(n.route.polyline, from: $0.alongMeters, to: Geo.length(n.route.polyline)) } ?? n.route.polyline
        frame(line, bottomFraction: 0.25, top: 200)
    }

    private func locationChanged(_ loc: CLLocation) {
        if location.reducedAccuracy || loc.horizontalAccuracy > 200 { areaRisk = nil }
        guard let n = nav else { return }
        n.handle(loc)
        followCamera(n, loc, animated: true)
        mapTick += 1
    }

    private func followCamera(_ n: Navigator, _ loc: CLLocation, animated: Bool) {
        let p = n.progress
        let speed = max(0, loc.speed)
        var across = n.route.mode == .drive ? min(1400, max(450, 300 + speed * 30)) : 300
        // Close to a roundabout, zoom in so the whole of it and its exits fill the view.
        if n.nextManeuver?.type == .roundabout, let d = p?.distanceToNext, d < 350 { across = min(across, 380) }
        glide.fix(n, loc, across: across, jump: !animated)
    }

    // MARK: Map

    func centerOnUser() {
        guard let map, let loc = location.last ?? map.userLocation?.location else {
            if location.denied { LocationService.openSettings() } else { location.start() }
            return
        }
        let cam = MLNMapCamera(lookingAtCenter: loc.coordinate, acrossDistance: 1200, pitch: 0, heading: 0)
        map.setCamera(cam, withDuration: 0.5, animationTimingFunction: CAMediaTimingFunction(name: .easeInEaseOut),
                      edgePadding: UIEdgeInsets(top: 0, left: sideInset, bottom: 0, right: 0), completionHandler: nil)
    }

    private func resetCamera() {
        guard let map else { return }
        let cam = map.camera
        cam.pitch = 0
        cam.heading = 0
        map.setCamera(cam, withDuration: 0.5, animationTimingFunction: nil, edgePadding: .zero, completionHandler: nil)
    }

    func frame(_ points: [LatLng], bottomFraction: CGFloat = 0.45, top: CGFloat = 130) {
        guard let map, !points.isEmpty else { return }
        if points.count == 1 {
            let c = CLLocationCoordinate2D(latitude: points[0].lat, longitude: points[0].lng)
            map.setCamera(MLNMapCamera(lookingAtCenter: c, acrossDistance: 1200, pitch: 0, heading: 0), withDuration: 0.3,
                          animationTimingFunction: nil, edgePadding: UIEdgeInsets(top: 0, left: sideInset, bottom: 0, right: 0),
                          completionHandler: nil)
            return
        }
        let lats = points.map(\.lat), lngs = points.map(\.lng)
        let bounds = MLNCoordinateBounds(
            sw: CLLocationCoordinate2D(latitude: lats.min()!, longitude: lngs.min()!),
            ne: CLLocationCoordinate2D(latitude: lats.max()!, longitude: lngs.max()!))
        // With a side panel the cards are on the left, not at the bottom.
        let pad = sideInset > 0 ? UIEdgeInsets(top: 60, left: sideInset + 40, bottom: 60, right: 40)
                                : UIEdgeInsets(top: top, left: 40, bottom: map.bounds.height * bottomFraction + 20, right: 40)
        let cam = map.cameraThatFitsCoordinateBounds(bounds, edgePadding: pad)
        cam.pitch = 0
        cam.heading = 0
        if cam.altitude < 500 { cam.altitude = 500 }
        map.setCamera(cam, withDuration: 0.6, animationTimingFunction: CAMediaTimingFunction(name: .easeInEaseOut))
    }
}

import Combine
import CoreLocation
import Foundation
import MapLibre
import SwiftUI
import UIKit
import VelaCore

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
    @Published var showSettings = false
    /** The "Add stop" search sheet. */
    @Published var addingStop = false
    @Published var showSaved = false
    @Published var showSteps = false
    /** "Start" on a place: begin the drive as soon as its route arrives. */
    @Published var autoStart = false
    /** Bumped when the map should redraw overlays that don't come from a published value. */
    @Published var mapTick = 0
    /** Which way the map faces, for the compass button. */
    @Published var mapHeading: Double = 0

    weak var map: MLNMapView?
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
                notice = "No results for \"\(q)\" here."
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
                notice = "Couldn't find a location in that link."
            }
        }
    }

    /** A place picked from the suggestions: show it now, then fill in its details from Google. */
    func openSuggestion(_ place: Place) {
        suggestTask?.cancel()
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

    func select(_ place: Place) {
        var p = place
        if !DemoScript.active { settings.addRecentPlace(place) }
        if p.distanceMeters == nil, let u = userLatLng { p.distanceMeters = u.distance(to: p.location) }
        selected = p
        detent = .half
        guard let map else { return }
        let target = CLLocationCoordinate2D(latitude: p.location.lat, longitude: p.location.lng)
        let pad = UIEdgeInsets(top: 120, left: 0, bottom: map.bounds.height * 0.45, right: 0)
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
        select(placeholder)
        guard !settings.noGoogle else { return }
        let q = [name, placeholder.address].compactMap { $0 }.joined(separator: " ")
        let pid = placeholder.id
        Task {
            let found = (try? await GoogleClient.shared.search(q, center: point, spanMeters: 1_000, pages: 1)) ?? []
            guard selected?.id == pid else { return }
            if let best = found.filter({ $0.location.distance(to: point) < 150 })
                .min(by: { $0.location.distance(to: point) < $1.location.distance(to: point) }) {
                var b = best
                b.distanceMeters = userLatLng?.distance(to: b.location)
                selected = b
                if !DemoScript.active { settings.addRecentPlace(b) }
            }
        }
    }

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
            notice = kind == .car ? "No parking spot saved yet. Tap P on the map when you park."
                : "Set your \(kind == .home ? "home" : "work") first: open a place, tap More, then Set as \(kind == .home ? "home" : "work")."
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
            notice = "Turn on location to save where you parked."
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
            notice = "Turn on location to get directions from where you are."
            return
        }
        let (from, to) = d.reversed ? (d.destination.location, me) : (me, d.destination.location)
        let via = (d.reversed ? d.stops.reversed() : d.stops).map(\.location)
        let destId = d.destination.id
        let hw = settings.avoidHighways, tolls = settings.avoidTolls, google = !settings.noGoogle
        for m in TravelMode.allCases {
            directions?.loading.insert(m)
            Task {
                let r = await Directions.routes(from: from, to: to, mode: m, avoidHighways: hw, avoidTolls: tolls, useGoogle: google, via: via)
                guard directions?.destination.id == destId else { return }
                directions?.loading.remove(m)
                directions?.routes[m] = r.routes
                if r.routes.isEmpty { directions?.errors[m] = r.error ?? "No route" }
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
        directions?.trips = nil
        directions?.tripsError = nil
        directions?.trip = 0
        Task {
            do {
                let trips = try await Transitous.plan(from: from, to: to, time: time, arriveBy: arriveBy)
                guard directions?.destination.id == destId, directions?.transitTime == time, directions?.arriveBy == arriveBy else { return }
                directions?.trips = trips
                if trips.isEmpty { directions?.tripsError = "No transit trips found here." }
            } catch {
                guard directions?.destination.id == destId else { return }
                directions?.trips = []
                directions?.tripsError = "Couldn't reach the transit planner."
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

    // MARK: Navigation

    func startNavigation() {
        guard let d = directions, let route = d.route, !d.reversed else { return }
        let n = Navigator(route: route, destination: d.destination, stops: d.stops, settings: settings)
        nav = n
        navSub = n.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        location.setNavigating(true, mode: route.mode.rawValue)
        map?.showsUserLocation = false
        if let loc = location.last { n.handle(loc); followCamera(n, loc, animated: false) }
    }

    func endNavigation() {
        nav?.stop()
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
        guard let n = nav else { return }
        n.handle(loc)
        if n.following { followCamera(n, loc, animated: true) }
        mapTick += 1
    }

    private func followCamera(_ n: Navigator, _ loc: CLLocation, animated: Bool) {
        guard let map else { return }
        let p = n.progress
        let onRoute = p.map { !$0.offRoute && $0.offsetMeters < 40 } ?? false
        let center = onRoute ? CLLocationCoordinate2D(latitude: p!.snapped.lat, longitude: p!.snapped.lng) : loc.coordinate
        let heading = loc.course >= 0 && loc.speed > 2 ? loc.course : (p?.routeBearing ?? map.direction)
        let speed = max(0, loc.speed)
        let across = n.route.mode == .drive ? min(1400, max(450, 300 + speed * 30)) : 300
        let cam = MLNMapCamera(lookingAtCenter: center, acrossDistance: across, pitch: 50, heading: heading)
        let pad = UIEdgeInsets(top: map.bounds.height * 0.45, left: 0, bottom: 120, right: 0)
        map.setCamera(cam, withDuration: animated ? 1.0 : 0, animationTimingFunction: CAMediaTimingFunction(name: .linear),
                      edgePadding: pad, completionHandler: nil)
    }

    // MARK: Map

    func centerOnUser() {
        guard let map, let loc = location.last ?? map.userLocation?.location else {
            location.start()
            return
        }
        let cam = MLNMapCamera(lookingAtCenter: loc.coordinate, acrossDistance: 1200, pitch: 0, heading: 0)
        map.setCamera(cam, withDuration: 0.5, animationTimingFunction: CAMediaTimingFunction(name: .easeInEaseOut))
    }

    func resetNorth() {
        guard let map else { return }
        map.setDirection(0, animated: true)
        let cam = map.camera
        cam.pitch = 0
        cam.heading = 0
        map.setCamera(cam, animated: true)
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
            map.setCamera(MLNMapCamera(lookingAtCenter: c, acrossDistance: 1200, pitch: 0, heading: 0), animated: true)
            return
        }
        let lats = points.map(\.lat), lngs = points.map(\.lng)
        let bounds = MLNCoordinateBounds(
            sw: CLLocationCoordinate2D(latitude: lats.min()!, longitude: lngs.min()!),
            ne: CLLocationCoordinate2D(latitude: lats.max()!, longitude: lngs.max()!))
        let pad = UIEdgeInsets(top: top, left: 40, bottom: map.bounds.height * bottomFraction + 20, right: 40)
        let cam = map.cameraThatFitsCoordinateBounds(bounds, edgePadding: pad)
        cam.pitch = 0
        cam.heading = 0
        if cam.altitude < 500 { cam.altitude = 500 }
        map.setCamera(cam, withDuration: 0.6, animationTimingFunction: CAMediaTimingFunction(name: .easeInEaseOut))
    }
}

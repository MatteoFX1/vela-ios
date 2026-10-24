import MapLibre
import SwiftUI
import UIKit
import VelaCore

/** The full-screen map: OpenFreeMap Liberty painted in Vela's colors, plus Vela's own layers
 *  (result pins, routes with traffic, the navigation puck, live traffic, satellite). */
struct VelaMapView: UIViewRepresentable {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    let dark: Bool

    static let styleURL = URL(string: "https://tiles.openfreemap.org/styles/liberty")!

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero, styleURL: Self.styleURL)
        let c = context.coordinator
        map.delegate = c
        map.showsUserLocation = true
        map.compassView.isHidden = true
        map.logoView.isHidden = true
        map.attributionButtonPosition = .bottomLeft
        map.attributionButtonMargins = CGPoint(x: 8, y: 8)
        map.setCenter(CLLocationCoordinate2D(latitude: 40.7484, longitude: -73.9857), zoomLevel: 12, animated: false)

        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tapped(_:)))
        for r in map.gestureRecognizers ?? [] {
            if let t = r as? UITapGestureRecognizer, t.numberOfTapsRequired == 2 { tap.require(toFail: t) }
        }
        let press = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.pressed(_:)))
        press.delegate = c
        map.addGestureRecognizer(press)
        // A long press must never also count as a tap, or the tap closes the pin it just dropped.
        tap.require(toFail: press)
        tap.delegate = c
        map.addGestureRecognizer(tap)

        c.dark = dark
        model.map = map
        model.location.start()
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        let c = context.coordinator
        if c.dark != dark {
            c.dark = dark
            c.repaint(map)
        }
        c.render(map)
        c.loadCameras(map)
    }

    @MainActor
    final class Coordinator: NSObject, MLNMapViewDelegate, UIGestureRecognizerDelegate {
        let model: AppModel
        var dark = false
        private var styleReady = false
        private var movedToUser = false
        private var pinDroppedAt = Date.distantPast
        private var originalLabels: [String: (NSExpression?, NSExpression?, NSExpression?)] = [:]
        private var lastResultsKey = ""
        private var lastRouteKey = ""
        private var lastMineKey = ""
        private var lastPuckKey = ""
        private var lastCameraKey = ""
        /** Cameras fetched so far, and the 0.1° cells already asked for (cameras don't move). */
        private var cameras: [Int64: RoadCamera] = [:]
        private var cameraCells: Set<String> = []
        private var cameraFetch: Task<Void, Never>?
        private var railFetch: Task<Void, Never>?
        /** The box the drawn rail lines cover, so panning inside it asks nothing. */
        private var railBox: (s: Double, w: Double, n: Double, e: Double, z: Int)?

        init(model: AppModel) { self.model = model }

        // MARK: Style

        nonisolated func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            MainActor.assumeIsolated { styleLoaded(mapView, style) }
        }

        private func styleLoaded(_ mapView: MLNMapView, _ style: MLNStyle) {
            for case let s as MLNSymbolStyleLayer in style.layers {
                originalLabels[s.identifier] = (s.textColor, s.textHaloColor, s.textHaloWidth)
            }
            MapIcons.register(in: style)
            addVelaLayers(style)
            styleReady = true
            repaint(mapView)
            lastResultsKey = ""; lastRouteKey = ""; lastMineKey = ""; lastPuckKey = ""; lastCameraKey = ""
            render(mapView)
        }

        func repaint(_ map: MLNMapView) {
            guard let style = map.style, styleReady else { return }
            if !dark {
                for case let s as MLNSymbolStyleLayer in style.layers {
                    if let o = originalLabels[s.identifier] {
                        s.textColor = o.0 ?? s.textColor
                        s.textHaloColor = o.1 ?? s.textHaloColor
                        s.textHaloWidth = o.2 ?? s.textHaloWidth
                    }
                }
            }
            MapStyler.apply(style, dark: dark)
            (style.layer(withIdentifier: "vela-rail-case") as? MLNLineStyleLayer)?.lineColor =
                NSExpression(forConstantValue: UIColor(white: dark ? 0 : 1, alpha: 0.9))
            // Names next to our pins: dark text on a white halo by day, light text on navy at night.
            let text = dark ? UIColor(hex: 0xE8EAED) : UIColor(hex: 0x202124)
            let halo = dark ? UIColor(hex: 0x0B1526) : UIColor.white
            for id in ["vela-results", "vela-selected"] {
                guard let l = style.layer(withIdentifier: id) as? MLNSymbolStyleLayer else { continue }
                l.textColor = NSExpression(forConstantValue: text)
                l.textHaloColor = NSExpression(forConstantValue: halo)
                l.textHaloWidth = NSExpression(forConstantValue: 1.5)
            }
            lastResultsKey = ""
            lastRouteKey = ""
        }

        private func firstSymbolLayer(_ style: MLNStyle) -> MLNStyleLayer? {
            style.layers.first { $0 is MLNSymbolStyleLayer }
        }

        private func addVelaLayers(_ style: MLNStyle) {
            // Satellite (Esri World Imagery) under the roads, off unless picked in Layers.
            let sat = MLNRasterTileSource(identifier: "vela-sat", tileURLTemplates: [
                "https://services.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}",
            ], options: [.tileSize: 256, .maximumZoomLevel: 19,
                         .attributionHTMLString: "Imagery © Esri"])
            style.addSource(sat)
            let satLayer = MLNRasterStyleLayer(identifier: "vela-sat", source: sat)
            satLayer.isVisible = false
            if let below = style.layers.first(where: { $0.identifier.hasPrefix("tunnel_") }) {
                style.insertLayer(satLayer, below: below)
            } else {
                style.addLayer(satLayer)
            }

            // Terrain shading (Esri World Hillshade), blended over the land, off unless picked.
            let hill = MLNRasterTileSource(identifier: "vela-terrain", tileURLTemplates: [
                "https://services.arcgisonline.com/ArcGIS/rest/services/Elevation/World_Hillshade/MapServer/tile/{z}/{y}/{x}",
            ], options: [.tileSize: 256, .maximumZoomLevel: 16, .attributionHTMLString: "Hillshade © Esri"])
            style.addSource(hill)
            let hillLayer = MLNRasterStyleLayer(identifier: "vela-terrain", source: hill)
            hillLayer.rasterOpacity = NSExpression(forConstantValue: dark ? 0.22 : 0.32)
            hillLayer.isVisible = false
            if let below = style.layers.first(where: { $0.identifier.hasPrefix("tunnel_") || $0.identifier.hasPrefix("road_") }) {
                style.insertLayer(hillLayer, below: below)
            } else {
                style.addLayer(hillLayer)
            }

            // Google's live traffic tiles, the same keyless overlay Vela draws.
            let trafficURL = "https://www.google.com/maps/vt/pb=!1m4!1m3!1i{z}!2i{x}!3i{y}!2m9!1e2!2straffic!3i999999" +
                "!4m2!1sincidents!2s1!4m2!1sincidents_text!2s1!3m8!2sen!3sus!5e1105!12m4!1e68!2m2!1sset!2sRoadmap!4e0!5m1!1e0"
            let traffic = MLNRasterTileSource(identifier: "vela-traffic", tileURLTemplates: [trafficURL],
                                              options: [.tileSize: 256, .maximumZoomLevel: 16])
            style.addSource(traffic)
            let trafficLayer = MLNRasterStyleLayer(identifier: "vela-traffic", source: traffic)
            trafficLayer.rasterOpacity = NSExpression(forConstantValue: 0.6)
            trafficLayer.rasterFadeDuration = NSExpression(forConstantValue: 0.9)
            trafficLayer.isVisible = false
            if let above = style.layer(withIdentifier: "building-3d") ?? style.layer(withIdentifier: "building") {
                style.insertLayer(trafficLayer, above: above)
            } else {
                style.addLayer(trafficLayer)
            }

            // Routes: alternates, then the picked route, then its traffic, all under the labels.
            let labels = firstSymbolLayer(style)
            func insert(_ l: MLNStyleLayer) {
                if let labels { style.insertLayer(l, below: labels) } else { style.addLayer(l) }
            }
            let altSrc = MLNShapeSource(identifier: "vela-route-alt", shape: nil, options: nil)
            let routeSrc = MLNShapeSource(identifier: "vela-route", shape: nil, options: nil)
            let spanSrc = MLNShapeSource(identifier: "vela-route-traffic", shape: nil, options: nil)
            [altSrc, routeSrc, spanSrc].forEach(style.addSource)

            let altEdge = line("vela-route-alt-edge", altSrc, UIColor(hex: 0x3566C4), width: 11)
            let altFill = line("vela-route-alt", altSrc, UIColor(hex: 0xA9C4F5), width: 7)
            let edge = line("vela-route-edge", routeSrc, UIColor(hex: 0x0B4FB8), width: 12)
            let fill = line("vela-route-line", routeSrc, UIColor(hex: 0x1F6FEB), width: 8)
            [altEdge, altFill, edge, fill].forEach(insert)
            // A transit trip: each ride in its line's color, walks dotted.
            let transitSrc = MLNShapeSource(identifier: "vela-transit", shape: nil, options: nil)
            style.addSource(transitSrc)
            let walk = line("vela-transit-walk", transitSrc, UIColor(hex: 0x5F6368), width: 5)
            walk.predicate = NSPredicate(format: "walk == 1")
            walk.lineDashPattern = NSExpression(forConstantValue: [0.1, 1.8])
            let rideEdge = line("vela-transit-edge", transitSrc, UIColor(white: 0.1, alpha: 0.55), width: 10)
            rideEdge.predicate = NSPredicate(format: "walk == 0")
            let ride = line("vela-transit-ride", transitSrc, UIColor(hex: 0x1F6FEB), width: 7)
            ride.predicate = NSPredicate(format: "walk == 0")
            ride.lineColor = NSExpression(mglJSONObject: ["to-color", ["get", "color"]])
            [walk, rideEdge, ride].forEach(insert)
            for (level, color) in [(1, 0xF2A65A), (2, 0xE8453C), (3, 0x9E1C1C)] {
                let l = line("vela-route-traffic-\(level)", spanSrc, UIColor(hex: UInt32(color)), width: 8)
                l.predicate = NSPredicate(format: "level == %d", level)
                insert(l)
            }

            // Metro, tram and rail lines in their own colors, from zoom 10 in (Transitous).
            let railSrc = MLNShapeSource(identifier: "vela-rail", shape: nil, options: nil)
            style.addSource(railSrc)
            let railCase = line("vela-rail-case", railSrc, UIColor(white: dark ? 0 : 1, alpha: 0.9), width: 5.5)
            let rail = line("vela-rail", railSrc, .gray, width: 3.2)
            rail.lineColor = NSExpression(format: "CAST(color, 'UIColor')")
            for l in [railCase, rail] {
                l.minimumZoomLevel = 10
                l.isVisible = false
                insert(l)
            }

            // Speed cameras and plate readers, from zoom 12 in.
            let camSrc = MLNShapeSource(identifier: "vela-cameras", shape: nil, options: nil)
            style.addSource(camSrc)
            let cams = MLNSymbolStyleLayer(identifier: "vela-cameras", source: camSrc)
            cams.iconImageName = NSExpression(forKeyPath: "icon")
            cams.iconAllowsOverlap = NSExpression(forConstantValue: true)
            cams.minimumZoomLevel = 12
            style.addLayer(cams)

            // My places: home, work, the parked car and saved places, under the result pins.
            let mineSrc = MLNShapeSource(identifier: "vela-mine", shape: nil, options: nil)
            style.addSource(mineSrc)
            let mine = MLNSymbolStyleLayer(identifier: "vela-mine", source: mineSrc)
            mine.iconImageName = NSExpression(forKeyPath: "icon")
            mine.iconAllowsOverlap = NSExpression(forConstantValue: true)
            mine.text = NSExpression(forKeyPath: "label")
            mine.textFontNames = NSExpression(forConstantValue: ["Noto Sans Bold"])
            mine.textFontSize = NSExpression(forConstantValue: 11)
            mine.textAnchor = NSExpression(forConstantValue: "top")
            mine.textOffset = NSExpression(forConstantValue: NSValue(cgVector: CGVector(dx: 0, dy: 1.1)))
            mine.textOptional = NSExpression(forConstantValue: true)
            mine.maximumTextWidth = NSExpression(forConstantValue: 8)
            mine.minimumZoomLevel = 9
            style.addLayer(mine)

            // Result pins with names, the picked place's red pin, the time bubbles and the puck.
            let results = MLNShapeSource(identifier: "vela-results", shape: nil, options: nil)
            style.addSource(results)
            let pins = MLNSymbolStyleLayer(identifier: "vela-results", source: results)
            pins.iconImageName = NSExpression(forKeyPath: "icon")
            pins.iconAllowsOverlap = NSExpression(forConstantValue: true)
            pins.text = NSExpression(forKeyPath: "label")
            pins.textFontNames = NSExpression(forConstantValue: ["Noto Sans Bold"])
            pins.textFontSize = NSExpression(forConstantValue: 12)
            pins.textAnchor = NSExpression(forConstantValue: "left")
            pins.textOffset = NSExpression(forConstantValue: NSValue(cgVector: CGVector(dx: 1.4, dy: 0)))
            pins.textOptional = NSExpression(forConstantValue: true)
            pins.maximumTextWidth = NSExpression(forConstantValue: 8)
            pins.textJustification = NSExpression(forConstantValue: "left")
            pins.symbolSortKey = NSExpression(forKeyPath: "rank")
            style.addLayer(pins)

            let selSrc = MLNShapeSource(identifier: "vela-selected", shape: nil, options: nil)
            style.addSource(selSrc)
            let sel = MLNSymbolStyleLayer(identifier: "vela-selected", source: selSrc)
            sel.iconImageName = NSExpression(forKeyPath: "icon")
            sel.iconAnchor = NSExpression(forKeyPath: "anchor")
            sel.iconAllowsOverlap = NSExpression(forConstantValue: true)
            sel.textAllowsOverlap = NSExpression(forConstantValue: false)
            sel.text = NSExpression(forKeyPath: "label")
            sel.textFontNames = NSExpression(forConstantValue: ["Noto Sans Bold"])
            sel.textFontSize = NSExpression(forConstantValue: 13)
            sel.textAnchor = NSExpression(forConstantValue: "top")
            sel.textOffset = NSExpression(forConstantValue: NSValue(cgVector: CGVector(dx: 0, dy: 0.4)))
            sel.textOptional = NSExpression(forConstantValue: true)
            style.addLayer(sel)

            let bubbleSrc = MLNShapeSource(identifier: "vela-route-bubbles", shape: nil, options: nil)
            style.addSource(bubbleSrc)
            for selected in [false, true] {
                let b = MLNSymbolStyleLayer(identifier: "vela-route-bubble-\(selected ? 1 : 0)", source: bubbleSrc)
                b.predicate = NSPredicate(format: "sel == %d", selected ? 1 : 0)
                b.iconImageName = NSExpression(forConstantValue: selected ? "bubble-sel" : "bubble-alt")
                b.iconTextFit = NSExpression(forConstantValue: "both")
                b.iconTextFitPadding = NSExpression(forConstantValue: NSValue(uiEdgeInsets: UIEdgeInsets(top: 5, left: 9, bottom: 5, right: 9)))
                b.text = NSExpression(forKeyPath: "label")
                b.textFontNames = NSExpression(forConstantValue: ["Noto Sans Bold"])
                b.textFontSize = NSExpression(forConstantValue: 13)
                b.textColor = NSExpression(forConstantValue: selected ? UIColor.white : UIColor(hex: 0x202124))
                b.iconAllowsOverlap = NSExpression(forConstantValue: true)
                b.textAllowsOverlap = NSExpression(forConstantValue: true)
                style.addLayer(b)
            }

            // The next turn drawn on the road while navigating, like Vela's turn arrows.
            let arrowSrc = MLNShapeSource(identifier: "vela-turn-arrow", shape: nil, options: nil)
            style.addSource(arrowSrc)
            let arrowEdge = line("vela-turn-arrow-edge", arrowSrc, UIColor(hex: 0x0B3D91), width: 11)
            arrowEdge.predicate = NSPredicate(format: "part == 'shaft'")
            arrowEdge.lineCap = NSExpression(forConstantValue: "butt")
            let arrowLine = line("vela-turn-arrow", arrowSrc, .white, width: 7)
            arrowLine.predicate = NSPredicate(format: "part == 'shaft'")
            arrowLine.lineCap = NSExpression(forConstantValue: "butt")
            let head = MLNSymbolStyleLayer(identifier: "vela-turn-arrow-head", source: arrowSrc)
            head.predicate = NSPredicate(format: "part == 'head'")
            head.iconImageName = NSExpression(forConstantValue: "turn-head")
            head.iconRotation = NSExpression(forKeyPath: "bearing")
            head.iconRotationAlignment = NSExpression(forConstantValue: "map")
            head.iconAllowsOverlap = NSExpression(forConstantValue: true)
            head.iconIgnoresPlacement = NSExpression(forConstantValue: true)
            for l in [arrowEdge, arrowLine] as [MLNStyleLayer] { style.addLayer(l) }
            style.addLayer(head)

            let puckSrc = MLNShapeSource(identifier: "vela-puck", shape: nil, options: nil)
            style.addSource(puckSrc)
            let puck = MLNSymbolStyleLayer(identifier: "vela-puck", source: puckSrc)
            puck.iconImageName = NSExpression(forConstantValue: "puck")
            puck.iconRotation = NSExpression(forKeyPath: "bearing")
            puck.iconRotationAlignment = NSExpression(forConstantValue: "map")
            puck.iconPitchAlignment = NSExpression(forConstantValue: "map")
            puck.iconAllowsOverlap = NSExpression(forConstantValue: true)
            puck.iconIgnoresPlacement = NSExpression(forConstantValue: true)
            style.addLayer(puck)
        }

        private func line(_ id: String, _ src: MLNSource, _ color: UIColor, width: Double) -> MLNLineStyleLayer {
            let l = MLNLineStyleLayer(identifier: id, source: src)
            l.lineColor = NSExpression(forConstantValue: color)
            l.lineWidth = NSExpression(forConstantValue: width)
            l.lineCap = NSExpression(forConstantValue: "round")
            l.lineJoin = NSExpression(forConstantValue: "round")
            return l
        }

        // MARK: Render

        func render(_ map: MLNMapView) {
            guard styleReady, let style = map.style else { return }
            let s = model.settings
            let navigating = model.nav != nil
            // The navigation arrow replaces the blue dot.
            if map.showsUserLocation == navigating { map.showsUserLocation = !navigating }
            style.layer(withIdentifier: "vela-traffic")?.isVisible = s.traffic && !navigating && !s.noGoogle
            style.layer(withIdentifier: "vela-sat")?.isVisible = s.satellite
            style.layer(withIdentifier: "vela-terrain")?.isVisible = s.terrain && !s.satellite
            for id in ["vela-rail", "vela-rail-case"] { style.layer(withIdentifier: id)?.isVisible = s.transitLines && !navigating }
            for id in ["building", "building-3d"] { style.layer(withIdentifier: id)?.isVisible = !s.satellite }
            renderResults(style)
            renderRoutes(style)
            renderPuck(style)
            renderCameras(style)
            renderMine(style)
            if s.transitLines { loadRail(map) }
        }

        private func renderMine(_ style: MLNStyle) {
            let s = model.settings
            let hidden = model.nav != nil || model.directions != nil
            var items: [(Place, String, String)] = []
            if !hidden {
                if let h = s.home { items.append((h, "mine-home", "Home")) }
                if let w = s.work { items.append((w, "mine-work", "Work")) }
                if let p = s.parking { items.append((p, "mine-parking", "Parked car")) }
                for p in s.saved.prefix(200) where !items.contains(where: { $0.0.id == p.id }) { items.append((p, "mine-saved", p.name)) }
            }
            let sel = model.selected?.id
            let key = items.map { $0.0.id + $0.1 }.joined(separator: ",") + "|" + (sel ?? "")
            guard key != lastMineKey else { return }
            lastMineKey = key
            let features: [MLNPointFeature] = items.compactMap { p, icon, label in
                guard p.id != sel else { return nil }
                let f = MLNPointFeature()
                f.coordinate = CLLocationCoordinate2D(latitude: p.location.lat, longitude: p.location.lng)
                f.attributes = ["id": p.id, "icon": icon, "label": label]
                return f
            }
            (style.source(withIdentifier: "vela-mine") as? MLNShapeSource)?.shape = MLNShapeCollectionFeature(shapes: features)
        }

        private func renderCameras(_ style: MLNStyle) {
            let s = model.settings
            let key = "\(s.speedCameras)\(s.plateCameras)\(cameras.count)"
            guard key != lastCameraKey else { return }
            lastCameraKey = key
            let shown = cameras.values.filter { $0.kind == .speed ? s.speedCameras : s.plateCameras }
            let features: [MLNPointFeature] = shown.map { c in
                let f = MLNPointFeature()
                f.coordinate = CLLocationCoordinate2D(latitude: c.location.lat, longitude: c.location.lng)
                f.attributes = ["icon": c.kind == .speed ? "cam-speed" : "cam-plate"]
                return f
            }
            (style.source(withIdentifier: "vela-cameras") as? MLNShapeSource)?.shape = MLNShapeCollectionFeature(shapes: features)
        }

        /** Transit lines for the view and a margin around it, when the layer is on. */
        func loadRail(_ map: MLNMapView) {
            guard model.settings.transitLines, map.zoomLevel >= 10, railFetch == nil, model.nav == nil else { return }
            let b = map.visibleCoordinateBounds
            let z = Int(map.zoomLevel)
            if let r = railBox, b.sw.latitude >= r.s, b.sw.longitude >= r.w, b.ne.latitude <= r.n, b.ne.longitude <= r.e,
               abs(z - r.z) <= 2 { return }
            let dLat = (b.ne.latitude - b.sw.latitude) * 0.5, dLng = (b.ne.longitude - b.sw.longitude) * 0.5
            let box = (s: b.sw.latitude - dLat, w: b.sw.longitude - dLng, n: b.ne.latitude + dLat, e: b.ne.longitude + dLng, z: z)
            railFetch = Task { [weak self, weak map] in
                let lines = await Transitous.lines(south: box.s, west: box.w, north: box.n, east: box.e, zoom: min(z, 14))
                guard let self else { return }
                self.railFetch = nil
                if let lines {
                    self.railBox = box
                    let shapes = lines.map { l in
                        self.polyline(l.points, ["color": String(format: "#%06X", l.color)])
                    }
                    (map?.style?.source(withIdentifier: "vela-rail") as? MLNShapeSource)?.shape = MLNShapeCollectionFeature(shapes: shapes)
                }
                // The map may have moved on while this was loading.
                if lines != nil, let map { self.loadRail(map) }
            }
        }

        /** Ask Overpass for the cameras in view, a few 0.1° cells at a time, each cell once. */
        func loadCameras(_ map: MLNMapView) {
            let s = model.settings
            guard s.speedCameras || s.plateCameras, map.zoomLevel >= 12, cameraFetch == nil else { return }
            let b = map.visibleCoordinateBounds
            let cell = 0.1
            let y0 = Int(floor(b.sw.latitude / cell)), y1 = Int(floor(b.ne.latitude / cell))
            let x0 = Int(floor(b.sw.longitude / cell)), x1 = Int(floor(b.ne.longitude / cell))
            guard (y1 - y0 + 1) * (x1 - x0 + 1) <= 12 else { return }
            var missing: [(Int, Int)] = []
            for y in y0...y1 { for x in x0...x1 where !cameraCells.contains("\(y),\(x)") { missing.append((y, x)) } }
            guard !missing.isEmpty else { return }
            let ys = missing.map(\.0), xs = missing.map(\.1)
            let south = Double(ys.min()!) * cell, north = Double(ys.max()! + 1) * cell
            let west = Double(xs.min()!) * cell, east = Double(xs.max()! + 1) * cell
            cameraFetch = Task { [weak self] in
                // Both kinds every time, so turning one on later needs no new fetch.
                let found = await Overpass.cameras(south: south, west: west, north: north, east: east, speed: true, plate: true)
                guard let self else { return }
                self.cameraFetch = nil
                guard let found else { return }
                for (y, x) in missing { self.cameraCells.insert("\(y),\(x)") }
                for c in found { self.cameras[c.id] = c }
                self.render(map)
                // The map may have moved on while this one was loading.
                self.loadCameras(map)
            }
        }

        private func renderResults(_ style: MLNStyle) {
            let showList = model.directions == nil && model.nav == nil
            let list = showList ? model.visibleResults : []
            let target = model.nav?.destination ?? model.directions?.destination ?? model.selected
            let stops: [Place] = model.nav?.stops ?? model.directions?.stops ?? []
            let ids: String = list.map(\.id).joined(separator: ",")
            let stopIds: String = stops.map(\.id).joined(separator: ",")
            let key = "\(ids)|\(target?.id ?? "")|\(model.directions?.reversed ?? false)|\(model.nav == nil)|\(stopIds)"
            guard key != lastResultsKey else { return }
            lastResultsKey = key
            let features: [MLNPointFeature] = list.enumerated().compactMap { i, p in
                guard p.id != target?.id else { return nil }
                let f = MLNPointFeature()
                f.coordinate = CLLocationCoordinate2D(latitude: p.location.lat, longitude: p.location.lng)
                let rating = p.rating.map { String(format: "%.1f", $0) }
                f.attributes = [
                    "id": p.id,
                    "icon": MapIcons.iconName(for: p),
                    "label": [p.name, rating].compactMap { $0 }.joined(separator: "\n"),
                    "rank": i,
                ]
                return f
            }
            (style.source(withIdentifier: "vela-results") as? MLNShapeSource)?.shape = MLNShapeCollectionFeature(shapes: features)

            var sel: [MLNPointFeature] = []
            if let t = target {
                let f = MLNPointFeature()
                f.coordinate = CLLocationCoordinate2D(latitude: t.location.lat, longitude: t.location.lng)
                f.attributes = ["id": t.id, "icon": "pin-selected", "anchor": "bottom", "label": t.name]
                sel.append(f)
                for (i, stop) in stops.enumerated() {
                    let f = MLNPointFeature()
                    f.coordinate = CLLocationCoordinate2D(latitude: stop.location.lat, longitude: stop.location.lng)
                    f.attributes = ["id": "stop\(i)", "icon": "pin-stop", "anchor": "center", "label": stop.name]
                    sel.append(f)
                }
                if let d = model.directions, d.reversed == false, model.nav == nil, let me = model.userLatLng {
                    let o = MLNPointFeature()
                    o.coordinate = CLLocationCoordinate2D(latitude: me.lat, longitude: me.lng)
                    o.attributes = ["id": "origin", "icon": "pin-origin", "anchor": "center", "label": ""]
                    sel.append(o)
                }
            }
            (style.source(withIdentifier: "vela-selected") as? MLNShapeSource)?.shape = MLNShapeCollectionFeature(shapes: sel)
        }

        func polyline(_ pts: [LatLng], _ attrs: [String: Any] = [:]) -> MLNPolylineFeature {
            var coords = pts.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) }
            let f = MLNPolylineFeature(coordinates: &coords, count: UInt(coords.count))
            f.attributes = attrs
            return f
        }

        private func renderRoutes(_ style: MLNStyle) {
            var alts: [Route] = []
            var main: Route?
            var from = 0.0
            if let n = model.nav {
                main = n.route
                from = n.progress?.alongMeters ?? 0
            } else if let d = model.directions {
                main = d.route
                alts = d.current.filter { $0.id != main?.id }
            }
            let trip = model.nav == nil ? model.directions?.pickedTrip : nil
            let key = (model.nav == nil ? "" : "nav") + (trip?.id.uuidString ?? "") + (main?.id.uuidString ?? "") + alts.map(\.id.uuidString).joined() + "\(Int(from / 5))"
            guard key != lastRouteKey else { return }
            lastRouteKey = key

            let altSrc = style.source(withIdentifier: "vela-route-alt") as? MLNShapeSource
            let routeSrc = style.source(withIdentifier: "vela-route") as? MLNShapeSource
            let spanSrc = style.source(withIdentifier: "vela-route-traffic") as? MLNShapeSource
            let bubbleSrc = style.source(withIdentifier: "vela-route-bubbles") as? MLNShapeSource

            altSrc?.shape = MLNShapeCollectionFeature(shapes: alts.map { polyline($0.polyline) })
            let transitSrc = style.source(withIdentifier: "vela-transit") as? MLNShapeSource
            transitSrc?.shape = trip.map { t in
                MLNShapeCollectionFeature(shapes: t.legs.filter { $0.path.count >= 2 }.map { leg in
                    polyline(leg.path, ["walk": leg.isWalk ? 1 : 0, "color": String(format: "#%06X", leg.color ?? 0x1F6FEB)])
                })
            }
            guard let r = main else {
                routeSrc?.shape = nil; spanSrc?.shape = nil; bubbleSrc?.shape = nil
                return
            }
            let cum = Geo.cumulative(r.polyline)
            let total = cum.last ?? 0
            let ahead = from > 1 ? Geo.slice(r.polyline, from: from, to: total, cumulative: cum) : r.polyline
            routeSrc?.shape = ahead.count >= 2 ? polyline(ahead) : nil
            let spans: [MLNPolylineFeature] = r.trafficSpans.compactMap { s in
                let a = max(s.startMeters, from), b = min(s.startMeters + s.lengthMeters, total)
                guard b > a else { return nil }
                let piece = Geo.slice(r.polyline, from: a, to: b, cumulative: cum)
                return piece.count >= 2 ? polyline(piece, ["level": min(s.level, 3)]) : nil
            }
            spanSrc?.shape = MLNShapeCollectionFeature(shapes: spans)

            // Turn arrow: 35 m of road before the next turn and 22 m after it, from 14 m away.
            let arrowSrc = style.source(withIdentifier: "vela-turn-arrow") as? MLNShapeSource
            if let n = model.nav, let m = n.nextManeuver, m.type != .arrive, m.type != .depart, m.type != .straight,
               let p = n.progress, m.alongMeters - p.alongMeters < 600 {
                let a = max(m.alongMeters - 35, from), b = min(m.alongMeters + 22, total)
                let shaft = Geo.slice(r.polyline, from: a, to: b, cumulative: cum)
                if shaft.count >= 2 {
                    let tip = shaft[shaft.count - 1], prev = Geo.point(along: r.polyline, meters: max(a, b - 4), cumulative: cum)
                    let head = MLNPointFeature()
                    head.coordinate = CLLocationCoordinate2D(latitude: tip.lat, longitude: tip.lng)
                    head.attributes = ["part": "head", "bearing": Geo.bearing(prev, tip)]
                    arrowSrc?.shape = MLNShapeCollectionFeature(shapes: [polyline(shaft, ["part": "shaft"]), head])
                } else {
                    arrowSrc?.shape = nil
                }
            } else {
                arrowSrc?.shape = nil
            }

            // Time bubbles: on each route, at a point the others don't share.
            guard model.nav == nil, let d = model.directions else { bubbleSrc?.shape = nil; return }
            var bubbles: [MLNPointFeature] = []
            for (i, route) in d.current.enumerated() {
                let others = d.current.enumerated().filter { $0.offset != i }.map(\.element.polyline)
                let c = Geo.cumulative(route.polyline)
                let len = c.last ?? 0
                var spot = Geo.point(along: route.polyline, meters: len * 0.5, cumulative: c)
                for f in stride(from: 0.5, through: 0.9, by: 0.1) {
                    let p = Geo.point(along: route.polyline, meters: len * f, cumulative: c)
                    let shared = others.contains { o in o.contains { $0.distance(to: p) < 120 } }
                    if !shared { spot = p; break }
                }
                let f = MLNPointFeature()
                f.coordinate = CLLocationCoordinate2D(latitude: spot.lat, longitude: spot.lng)
                f.attributes = ["label": Fmt.duration(route.durationSeconds), "sel": route.id == r.id ? 1 : 0, "idx": i]
                bubbles.append(f)
            }
            bubbleSrc?.shape = MLNShapeCollectionFeature(shapes: bubbles)
        }

        private func renderPuck(_ style: MLNStyle) {
            let src = style.source(withIdentifier: "vela-puck") as? MLNShapeSource
            guard let n = model.nav, let fix = n.lastFix else {
                if lastPuckKey != "" { src?.shape = nil; lastPuckKey = "" }
                return
            }
            let p = n.progress
            let onRoute = p.map { !$0.offRoute && $0.offsetMeters < 40 } ?? false
            let at = onRoute ? CLLocationCoordinate2D(latitude: p!.snapped.lat, longitude: p!.snapped.lng) : fix.coordinate
            let bearing = fix.course >= 0 && fix.speed > 1 ? fix.course : (p?.routeBearing ?? 0)
            let key = "\(at.latitude),\(at.longitude),\(Int(bearing))"
            guard key != lastPuckKey else { return }
            lastPuckKey = key
            let f = MLNPointFeature()
            f.coordinate = at
            f.attributes = ["bearing": bearing]
            src?.shape = f
        }

        // MARK: Gestures

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        @objc func tapped(_ g: UITapGestureRecognizer) {
            guard let map = g.view as? MLNMapView, model.nav == nil,
                  Date().timeIntervalSince(pinDroppedAt) > 1 else { return }
            let pt = g.location(in: map)
            let box = CGRect(x: pt.x - 22, y: pt.y - 22, width: 44, height: 44)
            Task { @MainActor in
                if self.model.directions != nil {
                    let hits = map.visibleFeatures(in: box, styleLayerIdentifiers: ["vela-route-bubble-0", "vela-route-alt", "vela-route-alt-edge"])
                    if let idx = hits.first?.attribute(forKey: "idx") as? Int {
                        self.model.selectRoute(idx)
                        return
                    }
                    if let line = hits.first(where: { $0 is MLNPolylineFeature }) as? MLNPolylineFeature,
                       let d = self.model.directions {
                        let c = line.coordinate
                        let tapped = LatLng(c.latitude, c.longitude)
                        if let i = d.current.firstIndex(where: { r in r.id != d.route?.id && r.polyline.contains { $0.distance(to: tapped) < 300 } }) {
                            self.model.selectRoute(i)
                        }
                    }
                    return
                }
                let mine = map.visibleFeatures(in: box, styleLayerIdentifiers: ["vela-mine"])
                if let id = mine.first?.attribute(forKey: "id") as? String, let place = self.model.myPlace(id) {
                    self.model.select(place)
                    return
                }
                let pins = map.visibleFeatures(in: box, styleLayerIdentifiers: ["vela-results"])
                if let id = pins.first?.attribute(forKey: "id") as? String,
                   let place = self.model.results.first(where: { $0.id == id }) {
                    self.model.select(place)
                    return
                }
                let pois = map.visibleFeatures(in: box, styleLayerIdentifiers: ["poi_r1", "poi_r7", "poi_r20", "poi_transit", "airport"])
                if let poi = pois.first, let name = (poi.attribute(forKey: "name:en") ?? poi.attribute(forKey: "name")) as? String {
                    let c = poi.coordinate
                    self.model.resolveTapped(name: name, at: LatLng(c.latitude, c.longitude))
                    return
                }
                if self.model.selected != nil {
                    self.model.closePlace()
                } else if !self.model.results.isEmpty {
                    self.model.detent = .peek
                }
            }
        }

        @objc func pressed(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began, let map = g.view as? MLNMapView else { return }
            pinDroppedAt = Date()
            let c = map.convert(g.location(in: map), toCoordinateFrom: map)
            Task { @MainActor in
                guard self.model.nav == nil, self.model.directions == nil else { return }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                self.model.dropPin(at: LatLng(c.latitude, c.longitude))
            }
        }

        // MARK: Camera

        nonisolated func mapView(_ mapView: MLNMapView, regionWillChangeWith reason: MLNCameraChangeReason, animated: Bool) {
            let gesture: MLNCameraChangeReason = [.gesturePan, .gesturePinch, .gestureRotate, .gestureZoomIn,
                                                  .gestureZoomOut, .gestureOneFingerZoom, .gestureTilt]
            guard !reason.intersection(gesture).isEmpty else { return }
            Task { @MainActor in
                if let n = self.model.nav, n.following { n.following = false }
            }
        }

        nonisolated func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            MainActor.assumeIsolated {
                loadCameras(mapView)
                loadRail(mapView)
                noteHeading(mapView)
            }
        }

        nonisolated func mapViewRegionIsChanging(_ mapView: MLNMapView) {
            MainActor.assumeIsolated { noteHeading(mapView) }
        }

        /** The compass button shows while the map isn't facing north. */
        private func noteHeading(_ map: MLNMapView) {
            let h = map.direction
            if abs(h - model.mapHeading) > 2 || (h.truncatingRemainder(dividingBy: 360) == 0) != (model.mapHeading == 0) {
                model.mapHeading = h.truncatingRemainder(dividingBy: 360) == 0 ? 0 : h
            }
        }

        nonisolated func mapView(_ mapView: MLNMapView, didUpdate userLocation: MLNUserLocation?) {
            guard let loc = userLocation?.location else { return }
            MainActor.assumeIsolated {
                guard !movedToUser else { return }
                movedToUser = true
                guard model.results.isEmpty, model.selected == nil else { return }
                mapView.setCenter(loc.coordinate, zoomLevel: 15, animated: false)
            }
        }
    }
}

import CoreLocation
import MapLibre
import SwiftUI
import UIKit
import VelaCore

struct ContentView: View {
    @StateObject private var model = AppModel()
    @ObservedObject private var launch = LaunchAction.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.horizontalSizeClass) private var hClass
    @Environment(\.verticalSizeClass) private var vClass
    @State private var screen: CGSize = .zero
    /** The side panel's width on a big screen held sideways (the open iPhone Duo), 0 on a phone. */
    private var panel: CGFloat { SidePanel.width(for: screen, h: hClass, v: vClass) }

    private var dark: Bool { settings.colorScheme.map { $0 == .dark } ?? (systemScheme == .dark) }

    var body: some View {
        ZStack {
            VelaMapView(model: model, settings: settings, dark: dark)
                .ignoresSafeArea()
            if let nav = model.nav {
                NavigationOverlay(model: model, nav: nav)
            } else if model.directions != nil {
                DirectionsOverlay(model: model).inSidePanel(panel)
            } else {
                switch model.tab {
                case .map: BrowseOverlay(model: model)
                case .saved: SavedPage(model: model).sidePage(panel).transition(.opacity)
                case .settings: SettingsPage(model: model).sidePage(panel).transition(.opacity)
                }
            }
            if let info = model.wazeInfo, model.nav == nil, model.tab == .map {
                VStack {
                    WazeInfoCard(alert: info) { withAnimation { model.wazeInfo = nil } }
                        .padding(.top, 64)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    Spacer()
                }
                .inSidePanel(panel)
                .task(id: info.id) {
                    // Out of the way by itself after a while, like a toast.
                    guard !DemoScript.active else { return }
                    try? await Task.sleep(nanoseconds: 9_000_000_000)
                    if model.wazeInfo?.id == info.id { withAnimation { model.wazeInfo = nil } }
                }
            }
        }
        .alert(item: $model.surveillanceInfo) { camera in
            let details = [camera.operatorName.map { "Operator: \($0)" }, camera.manufacturer.map { "Manufacturer: \($0)" },
                           camera.surveillance.map { "Watches: \($0)" }, camera.mount.map { "Mount: \($0)" },
                           camera.direction.map { "Direction: \($0)" }].compactMap { $0 }.joined(separator: "\n")
            return Alert(title: Text(camera.isALPR ? "Plate reader" : "Surveillance camera"),
                         message: Text(details.isEmpty ? "Details not mapped in OpenStreetMap." : details), dismissButton: .default(Text("OK")))
        }
        .overlay(alignment: .bottom) {
            if DemoScript.step == "wazemap" || DemoScript.step == "wazeuk" || DemoScript.step == "wazesizes" {
                // Screenshot run only: what Waze answered, since the build's computers can't be trusted to get through.
                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    Text((Waze.lastStatus.map { "Waze: HTTP \($0.code), \($0.count) reports\($0.viaPage ? " via page" : ""): \($0.summary)" } ?? "Waze: not asked yet")
                         + "\n" + WazeWeb.shared.note + (DemoScript.wazeProbe.isEmpty ? "" : "\n" + DemoScript.wazeProbe))
                        .font(.caption.monospaced()).padding(6).background(Color.red).foregroundColor(.white)
                        .padding(.bottom, 120)
                }
            }
        }
        .background(GeometryReader { g in
            Color.clear
                .onAppear { screen = g.size }
                .onChange(of: g.size) { screen = $0 }
        })
        .environment(\.sidePanel, panel)
        .onAppear { model.sideInset = panel }
        .onChange(of: panel) { model.sideInset = $0 }
        .animation(.easeOut(duration: 0.25), value: model.wazeInfo?.id)
        .animation(.easeOut(duration: 0.2), value: model.tab)
        .kiteType()
        .preferredColorScheme(settings.colorScheme)
        .task { await DemoScript.run(model) }
        .onReceive(launch.$pending) { kind in
            guard let kind else { return }
            launch.pending = nil
            Task { await model.perform(kind) }
        }
        .onChange(of: model.showSettings) { on in
            // Older ways in (a shortcut, the demo) open the Settings page of the dock.
            guard on else { return }
            model.showSettings = false
            model.tab = .settings
        }
        .onChange(of: model.showSaved) { on in
            guard on else { return }
            model.showSaved = false
            model.tab = .saved
        }
        .sheet(isPresented: $model.showLayers) {
            LayersSheet(settings: settings).kiteType()
        }
        .fullScreenCover(isPresented: .constant(DemoScript.step?.hasPrefix("svtest") == true)) {
            // Screenshot run only: the viewer on a test pattern, turned right by the step's number.
            GoogleStreetViewScreen(name: "Test pattern", pano: StreetView.Panorama(id: PanoramaViewer.testID, location: LatLng(0, 0)),
                                   heading: Double(DemoScript.step?.dropFirst(6) ?? "") ?? 0)
        }
        .fullScreenCover(isPresented: Binding(get: {
            (!settings.welcomed || settings.needsWazeChoice)
                && (!DemoScript.active || DemoScript.step == "welcome" || DemoScript.step == "wazeintro")
        }, set: { _ in })) {
            // First the Google choice, then (also once for people updating) the Waze one.
            Group {
                if settings.welcomed { WazeIntroView(settings: settings) } else { WelcomeView(settings: settings) }
            }
            .kiteType()
        }
        .sheet(isPresented: $model.addingStop) {
            StopPicker(model: model).kiteType()
        }
        .sheet(item: $model.picking) { kind in
            PlacePicker(model: model, kind: kind).kiteType()
        }
        .onChange(of: settings.welcomed && !settings.needsWazeChoice) { ready in
            if ready { model.location.start() }
        }
    }
}

/** The map page: a big "Where to?" bar, Home and Work one tap away, and the results or place sheet. */
struct BrowseOverlay: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var voice = VoiceSearch()
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.sidePanel) private var panel

    private var hasSheet: Bool { model.selected != nil || !model.results.isEmpty }
    /** Only the map and the dock when nothing is open. */
    private var idle: Bool { !hasSheet && !searchFocused && !voice.listening }

    var body: some View {
        GeometryReader { geo in
            let full = geo.size.height + geo.safeAreaInsets.bottom
            let sheetH = hasSheet ? BottomSheet<EmptyView, EmptyView>.height(model.detent, container: full, peek: 230) : 0
            // Room the dock takes at the bottom, from the screen's edge.
            let dockTop = KiteDock.height + KiteDock.bottomGap(geo.safeAreaInsets.bottom)
            ZStack(alignment: .top) {
                // Map buttons: layers and the compass on the right, under the top cards.
                VStack {
                    HStack(alignment: .top) {
                        Spacer()
                        VStack(spacing: 12) {
                            MapFab(icon: "square.3.layers.3d", size: 56) { model.showLayers = true }
                                .accessibilityLabel("Map layers")
                            if settings.parkingButton || settings.parking != nil {
                                MapFab(icon: "parkingsign", tint: settings.parking != nil ? Vela.routeBlue : .primary, size: 56) {
                                    if let p = settings.parking { model.select(p) } else { model.saveParking() }
                                }
                            }
                            if model.mapHeading > 1 && model.mapHeading < 359 {
                                Button { model.map?.setDirection(0, animated: true) } label: {
                                    CompassNeedle()
                                        .rotationEffect(.degrees(-model.mapHeading))
                                        .frame(width: 56, height: 56)
                                        .glass(Circle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Face north")
                                .transition(.scale.combined(with: .opacity))
                            }
                        }
                    }
                    // With a side panel the search box isn't above them: they go to the top right.
                    .padding(.top, panel > 0 ? 10 : idle ? 176 : 86)
                    Spacer()
                    if sheetH < full * 0.6 || panel > 0 {
                        HStack(alignment: .bottom) {
                            if idle { WazeMapChips(model: model) }
                            Spacer()
                            MapFab(icon: "location.fill", tint: Vela.accentText(scheme), size: 64) { model.centerOnUser() }
                                .accessibilityLabel("Centre on me")
                                .contextMenu {
                                    if let u = model.userLatLng {
                                        ShareLink(item: URL(string: "https://maps.google.com/?q=\(u.lat),\(u.lng)")!) {
                                            Label("Share my location", systemImage: "square.and.arrow.up")
                                        }
                                        Button { UIPasteboard.general.string = String(format: "%.6f, %.6f", u.lat, u.lng) } label: {
                                            Label("Copy my coordinates", systemImage: "doc.on.doc")
                                        }
                                    }
                                    Button { model.saveParking() } label: { Label("I parked here", systemImage: "parkingsign") }
                                }
                        }
                        .padding(.bottom, panel > 0 ? 16
                                 : hasSheet ? max(sheetH - geo.safeAreaInsets.bottom, 0) + 14
                                 : max(dockTop - geo.safeAreaInsets.bottom, 0) + 16)
                        .padding(.leading, panel)
                    }
                }
                .padding(.horizontal, 16)

                if hasSheet {
                    VStack {
                        Spacer()
                        sheet(full: full)
                    }
                    .ignoresSafeArea(edges: .bottom)
                    .inSidePanel(panel)
                    .transition(.move(edge: .bottom))
                }

                if idle {
                    VStack {
                        Spacer()
                        KiteDock(model: model, bottomInset: geo.safeAreaInsets.bottom)
                    }
                    .ignoresSafeArea(edges: .bottom)
                    .inSidePanel(panel)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                VStack(spacing: 12) {
                    SearchBar(model: model, voice: voice, focused: $searchFocused)
                    if voice.listening { ListeningCard(voice: voice) }
                    // Home, Work and recents are one tap away under "Where to?", so the map itself stays clear.
                    if searchFocused {
                        SuggestionsPanel(model: model) { searchFocused = false }
                    }
                    if let n = model.notice, !searchFocused {
                        NoticeBanner(text: n) { model.notice = nil }
                    }
                    if !searchFocused { StatusCards(location: model.location) }
                }
                .padding(.top, 6)
                .inSidePanel(panel)
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: hasSheet)
            .animation(.easeOut(duration: 0.2), value: idle)
        }
        .task {
            // Screenshot run only: the search box open, to check nothing sits on its panel.
            guard DemoScript.step == "searchfocus" else { return }
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            searchFocused = true
        }
    }

    @ViewBuilder
    private func sheet(full: CGFloat) -> some View {
        if let place = model.selected {
            BottomSheet(detent: $model.detent, containerHeight: full, peekHeight: 230) {
                PlaceHeader(model: model, place: place)
            } content: {
                PlaceBody(model: model, place: place)
            }
            .id(place.id)
        } else {
            BottomSheet(detent: $model.detent, containerHeight: full, peekHeight: 230) {
                ResultsHeader(model: model)
            } content: {
                ResultsList(model: model)
            }
        }
    }
}

/** "Where to?": the one way into search, big enough to hit from a phone holder. */
struct SearchBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var voice: VoiceSearch
    var focused: FocusState<Bool>.Binding
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 14) {
            if focused.wrappedValue || !model.results.isEmpty || model.selected != nil {
                Button {
                    if focused.wrappedValue { focused.wrappedValue = false } else { model.clearSearch() }
                } label: {
                    Image(systemName: "arrow.left").font(.system(size: 22, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            } else {
                Image(systemName: "magnifyingglass").font(.system(size: 22, weight: .semibold))
                    .foregroundColor(Vela.muted(scheme))
                    .padding(.leading, 8)
            }
            TextField("Where to?", text: $model.query)
                .font(.system(size: 21, weight: .medium))
                .focused(focused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { model.search() }
                .onChange(of: model.query) { q in
                    if focused.wrappedValue { model.typed(q) }
                }
            if model.searching {
                ProgressView().frame(width: 48, height: 48)
            } else if !model.query.isEmpty || !model.results.isEmpty || model.selected != nil {
                Button {
                    model.clearSearch()
                    focused.wrappedValue = false
                } label: {
                    Image(systemName: "xmark").font(.system(size: 19, weight: .bold))
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(Vela.chip(scheme)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            } else {
                Button {
                    focused.wrappedValue = false
                    voice.start(onDone: { text in
                        model.query = text
                        model.search(text)
                    }, onError: { model.notice = $0 })
                } label: {
                    Image(systemName: "mic.fill").font(.system(size: 21, weight: .semibold))
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(Vela.chip(scheme)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Search by voice")
            }
        }
        .foregroundColor(.primary)
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 64)
        .glass(Capsule())
        .padding(.horizontal, 16)
    }
}

struct SuggestionsPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings = AppSettings.shared
    let done: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var copiedLink = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !model.query.isEmpty && !(model.suggestions.places.isEmpty && model.suggestions.queries.isEmpty) {
                    ForEach(model.suggestions.places.prefix(6)) { p in
                        Button { done(); model.openSuggestion(p) } label: {
                            HStack(spacing: 16) {
                                Image(systemName: "mappin.circle.fill").font(.system(size: 20)).frame(width: 22).foregroundColor(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.name).foregroundColor(.primary).lineLimit(1)
                                    if let a = p.address { Text(a).font(.caption).foregroundColor(.secondary).lineLimit(1) }
                                }
                                Spacer()
                                if let d = p.distanceMeters { Text(Fmt.distance(d)).font(.caption).foregroundColor(.secondary) }
                            }
                            .padding(.horizontal, 18)
                            .frame(minHeight: 54)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(model.suggestions.queries.prefix(5), id: \.self) { q in
                        row(icon: "magnifyingglass", text: q) { done(); model.search(q) }
                    }
                } else {
                    if copiedLink {
                        // The system Paste button reads the clipboard without iOS asking first.
                        HStack(spacing: 16) {
                            Image(systemName: "link").frame(width: 22).foregroundColor(.secondary)
                            Text("Open a copied map link").foregroundColor(.primary)
                            Spacer()
                            PasteButton(payloadType: String.self) { strings in
                                guard let text = strings.first else { return }
                                Task { @MainActor in
                                    done()
                                    model.openLink(text)
                                }
                            }
                            .labelStyle(.titleOnly)
                            .buttonBorderShape(.capsule)
                            .tint(Vela.routeBlue)
                        }
                        .padding(.horizontal, 18)
                        .frame(height: 50)
                    }
                    Shortcuts(model: model, done: done)
                    if !settings.recentPlaces.isEmpty || !settings.recents.isEmpty {
                        HStack {
                            Text("Recent").font(.subheadline.weight(.semibold)).foregroundColor(.secondary)
                            Spacer()
                            Button("Clear") { settings.recents = []; settings.recentPlaces = [] }
                                .font(.subheadline).foregroundColor(Vela.routeBlue)
                        }
                        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 4)
                        ForEach(settings.recentPlaces.prefix(5)) { p in
                            Button { done(); model.openSuggestion(p) } label: {
                                HStack(spacing: 16) {
                                    Image(systemName: "clock").frame(width: 22).foregroundColor(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(p.name).foregroundColor(.primary).lineLimit(1)
                                        if let a = p.address ?? p.category { Text(a).font(.caption).foregroundColor(.secondary).lineLimit(1) }
                                    }
                                    Spacer()
                                    if let d = model.userLatLng?.distance(to: p.location) {
                                        Text(Fmt.distance(d)).font(.caption).foregroundColor(.secondary)
                                    }
                                }
                                .padding(.horizontal, 18)
                                .frame(minHeight: 52)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) { settings.recentPlaces.removeAll { $0.id == p.id } } label: {
                                    Label("Remove from recents", systemImage: "trash")
                                }
                            }
                        }
                        ForEach(settings.recents.filter { q in !settings.recentPlaces.prefix(5).contains { $0.name == q } }.prefix(6), id: \.self) { q in
                            row(icon: "magnifyingglass", text: q) { done(); model.search(q) }
                                .contextMenu {
                                    Button(role: .destructive) { settings.recents.removeAll { $0 == q } } label: {
                                        Label("Remove from recents", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    // Recents first, like every maps app: most searches are for somewhere you've been.
                    Text("Nearby").font(.subheadline.weight(.semibold)).foregroundColor(.secondary)
                        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 4)
                    ForEach(Category.all) { c in
                        row(icon: c.icon, text: c.label) { done(); model.search(c.query, title: c.label) }
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .glass(RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 12)
        .frame(maxHeight: 460)
        .task {
            // Only checks whether the clipboard looks like a link; it doesn't read it.
            guard UIPasteboard.general.hasStrings || UIPasteboard.general.hasURLs else { return }
            UIPasteboard.general.detectPatterns(for: [.probableWebURL]) { result in
                let found = (try? result.get())?.contains(.probableWebURL) ?? false
                Task { @MainActor in copiedLink = found }
            }
        }
    }

    private func row(icon: String, text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon).frame(width: 22).foregroundColor(.secondary)
                Text(text).foregroundColor(.primary)
                Spacer()
            }
            .padding(.horizontal, 18)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct NoticeBanner: View {
    let text: String
    let dismiss: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle").foregroundColor(.secondary)
            Text(text).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) { Image(systemName: "xmark").font(.footnote) }.buttonStyle(.plain)
        }
        .padding(12)
        .glass(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 12)
    }
}

/** Drives the app into one screen for the build's screenshots: `-demo search|place|directions|nav`. */
enum DemoScript {
    static let scrollResults = Notification.Name("demo-scroll-results")
    /** Made-up Waze reports are on screen, so live ones mustn't replace them. */
    static var fakeWaze = false
    /** The wazesizes step's findings, shown on screen. */
    static var wazeProbe = ""
    static var active: Bool { ProcessInfo.processInfo.arguments.contains("-demo") }
    static var step: String? {
        let a = ProcessInfo.processInfo.arguments
        return a.firstIndex(of: "-demo").flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil }
    }

    @MainActor
    static func run(_ model: AppModel) async {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-demo"), i + 1 < args.count else { return }
        let step = args[i + 1]
        func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }
        await wait(6)
        if step == "browse" { return }
        if step == "cameras" {
            // Central Munich, where many fixed speed cameras are mapped.
            model.map?.setCenter(CLLocationCoordinate2D(latitude: 48.137, longitude: 11.575), zoomLevel: 12.5, animated: false)
            return
        }
        if step == "layers" { model.showLayers = true; return }
        if step == "pickhome" { model.picking = .home; return }
        if step == "rail" {
            // Lower Manhattan with the subway lines and hill shading on.
            model.settings.transitLines = true
            model.settings.terrain = true
            model.map?.setCenter(CLLocationCoordinate2D(latitude: 40.722, longitude: -73.99), zoomLevel: 12.6, animated: false)
            return
        }
        if step == "welcome" { model.settings.welcomed = false; return }
        if step == "wazeintro" {
            model.settings.welcomed = true
            model.settings.noGoogle = false
            model.settings.wazeAsked = false
            return
        }
        if step == "wazemap" {
            // Live Waze reports and the police glow over central London.
            model.settings.waze = true
            model.settings.wazeOnMap = true
            model.settings.wazeHeatmap = true
            model.settings.wazeKinds = Set(WazeAlert.Kind.allCases)
            model.map?.setCenter(CLLocationCoordinate2D(latitude: 51.507, longitude: -0.12), zoomLevel: 12.3, animated: false)
            return
        }
        if step == "wazesizes" {
            // Does Waze send less for a bigger box? The same spot in Southampton, five box sizes.
            model.settings.waze = true
            model.map?.setCenter(CLLocationCoordinate2D(latitude: 50.92, longitude: -1.40), zoomLevel: 12, animated: false)
            Task {
                for d in [0.01, 0.03, 0.06, 0.12, 0.25] {
                    let found = await Waze.alerts(south: 50.92 - d, west: -1.40 - d * 1.6, north: 50.92 + d, east: -1.40 + d * 1.6)
                    wazeProbe += String(format: "±%.2f°: ", d) + (found == nil ? "failed" : (Waze.lastStatus?.summary ?? "?")) + "\n"
                }
                // Busy places where Waze always has police and crash reports, and a thin box along the
                // M27 like the ones Kite asks for while navigating: closures only there too means Waze is
                // holding drivers' reports back, not that there are none.
                let busy: [(String, Double, Double, Double, Double)] = [
                    ("Los Angeles", 33.95, -118.45, 34.10, -118.20), ("New York", 40.70, -74.02, 40.80, -73.93),
                    ("Paris", 48.83, 2.28, 48.89, 2.40), ("M27 strip", 50.905, -1.45, 50.925, -1.20)]
                for (name, s, w, n, e) in busy {
                    let found = await Waze.alerts(south: s, west: w, north: n, east: e)
                    wazeProbe += name + ": " + (found == nil ? "failed" : (Waze.lastStatus?.summary ?? "?")) + "\n"
                }
                // Other doors into the same data: does any of them still hand out drivers' reports?
                let q = "top=50.98&bottom=50.86&left=-1.50&right=-1.30"
                let others = ["https://embed.waze.com/live-map/api/georss?\(q)&env=row&types=alerts",
                              "https://www.waze.com/live-map/api/georss?\(q)&env=row&types=alerts,traffic,users",
                              "https://www.waze.com/row-rtserver/web/TGeoRSS?\(q)&ma=200&mj=0&mu=0&types=alerts",
                              "https://www.waze.com/rtserver/web/TGeoRSS?\(q)&ma=200&mj=0&mu=0&types=alerts"]
                for u in others.compactMap(URL.init(string:)) {
                    let name = (u.host ?? "") + u.path.replacingOccurrences(of: "/live-map/api", with: "") + (u.query?.contains("users") == true ? "+users" : "")
                    var line = name + ": "
                    if let (data, resp) = try? await Waze.session.data(from: u) {
                        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                        line += "direct \(code) \(code == 200 ? Waze.Status(at: Date(), code: 200, count: 0, types: Waze.types(data)).summary : "")"
                    } else { line += "direct failed" }
                    if let fallback = Waze.fallback {
                        let data = await fallback(u)
                        line += data.map { " · page " + Waze.Status(at: Date(), code: 200, count: 0, types: Waze.types($0)).summary } ?? " · page failed"
                    }
                    wazeProbe += line + "\n"
                }
                wazeProbe += "done"
            }
            return
        }
        if step == "wazeuk" {
            // The same over Southampton and the M27, to see what Waze sends for the UK outside London.
            model.settings.waze = true
            model.settings.wazeOnMap = true
            model.settings.wazeHeatmap = true
            model.settings.wazeKinds = Set(WazeAlert.Kind.allCases)
            model.map?.setCenter(CLLocationCoordinate2D(latitude: 50.92, longitude: -1.40), zoomLevel: 10.6, animated: false)
            return
        }
        if step == "wazesettings" {
            model.settings.waze = true
            model.tab = .settings
            return
        }
        if step == "wazedemo" || step == "wazetap" {
            // Made-up reports around Davis, so the badges and the heat map show even if Waze is down.
            fakeWaze = true
            model.settings.waze = true
            model.settings.wazeHeatmap = true
            model.settings.wazeKinds = Set(WazeAlert.Kind.allCases)
            model.settings.wazeMaxAge = 0
            let c = LatLng(38.5449, -121.7405)
            var list: [WazeAlert] = []
            var seed: UInt64 = 7
            func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
            for i in 0..<60 {
                // Most police around two hot spots, a few anywhere.
                let spot = i % 3 == 0 ? LatLng(38.5530, -121.7600) : i % 3 == 1 ? LatLng(38.5390, -121.7280) : c
                list.append(WazeAlert(id: "demo-p\(i)", kind: .police, location: LatLng(spot.lat + (rnd() - 0.5) * 0.012, spot.lng + (rnd() - 0.5) * 0.016),
                                      reportedAt: Date().addingTimeInterval(-rnd() * 7200)))
            }
            for (i, k) in WazeAlert.Kind.allCases.enumerated() where k != .police {
                list.append(WazeAlert(id: "demo-k\(i)", kind: k, location: LatLng(c.lat + Double(i - 3) * 0.004, c.lng + 0.008 * Double(i % 2 == 0 ? 1 : -1))))
            }
            model.map?.setCenter(CLLocationCoordinate2D(latitude: c.lat, longitude: c.lng), zoomLevel: 13.6, animated: false)
            await wait(2)
            if let map = model.map { (map.delegate as? VelaMapView.Coordinator)?.showDemoWaze(list, map: map) }
            if step == "wazetap" {
                await wait(1)
                var picked = list[list.count - 6]
                picked.subtype = "ACCIDENT_MAJOR"
                picked.street = "Russell Blvd"
                picked.thumbsUp = 4
                picked.reliability = 9
                picked.reportedAt = Date().addingTimeInterval(-18 * 60)
                model.wazeInfo = picked
            }
            return
        }
        if step == "settings" { model.tab = .settings; return }
        if step == "saved" {
            // A few saved places, one with a long name, in the bookmarks list.
            var pub = Place(id: "demo-pub", name: "The Old Bell Traditional Pub, Restaurant and Rooms by the River", location: LatLng(38.5460, -121.7420), source: "demo")
            pub.address = "123 Long Address Road, Somewhere Quite Far Away, Davis, CA 95616"
            pub.category = "Pub"
            let cafe = Place(id: "demo-cafe", name: "Temple Coffee", location: LatLng(38.5440, -121.7400), source: "demo")
            model.settings.saved = [pub, cafe]
            var home = Place(id: "demo-home", name: "Home", location: LatLng(38.5480, -121.7445), source: "demo")
            home.address = "Home"
            model.settings.home = home
            model.tab = .saved
            return
        }
        if step == "longname" || step == "longdir" {
            // A place with a very long name, its sheet and then directions to it.
            var pub = Place(id: "demo-pub", name: "The Old Bell Traditional Pub, Restaurant and Rooms by the River", location: LatLng(38.5460, -121.7420), source: "demo")
            pub.address = "123 Long Address Road, Somewhere Quite Far Away, Davis, CA 95616"
            pub.category = "Traditional British pub and restaurant"
            model.select(pub)
            guard step == "longdir" else { return }
            await wait(2)
            model.openDirections(to: pub)
            return
        }
        if step == "searchfocus" {
            // The search box open with home set and the police heat map on: the legend must hide.
            model.settings.waze = true
            model.settings.wazeHeatmap = true
            var home = Place(id: "demo-home", name: "Home", location: LatLng(38.5480, -121.7445), source: "demo")
            home.address = "Home"
            model.settings.home = home
            return
        }
        if step == "transituk" {
            // A long trip with many changes (the build sets the phone in Reading): a real
            // Transitous plan to central London, whose rows used to push the screen off its right edge.
            let to = Place(id: "demo-london", name: "London", location: LatLng(51.5072, -0.1276), source: "demo")
            model.select(to)
            await wait(2)
            model.openDirections(to: to)
            model.showTransit()
            model.detent = .full
            return
        }
        if step == "wazelink" {
            // A Waze share link pasted into search: a geohash by Westminster Bridge.
            model.search("https://waze.com/ul/hgcpuvpk4")
            return
        }
        if step == "googlelink" {
            model.search("Big Ben https://www.google.com/maps/place/Big+Ben/@51.5007292,-0.1272003,17z/data=!3m1!4b1!4m6!3m5!1s0x487604c38c8cd1d9:0xb78f2474b9a45aa9!8m2!3d51.5007292!4d-0.1246254!16zL20vMGNrcA")
            return
        }
        if step == "mine" {
            // Home, work and a parked car around downtown Davis, as icons on the map.
            var home = Place(id: "demo-home", name: "Home", location: LatLng(38.5480, -121.7445), source: "demo")
            home.address = "Home"
            model.settings.home = home
            model.settings.work = Place(id: "demo-work", name: "UC Davis", location: LatLng(38.5402, -121.7500), source: "demo")
            var car = Place(id: "parking:demo", name: "Parked car", location: LatLng(38.5446, -121.7392), source: "osm")
            car.category = "Parked at 9:41 AM"
            model.settings.parking = car
            model.map?.setCenter(CLLocationCoordinate2D(latitude: 38.5445, longitude: -121.7440), zoomLevel: 14.6, animated: false)
            model.map?.setDirection(35, animated: false)
            return
        }
        if step == "board" {
            var station = Place(id: "demo-davis", name: "Davis Station", location: LatLng(38.5435, -121.7377), source: "demo")
            station.category = "Train station"
            model.select(station)
            return
        }
        if step == "roundabout" {
            // Matteo's M27 roundabout drawn in the banner, in miles and yards, with the camera alert.
            model.settings.units = .yards
            let to = Place(id: "demo-pitlochry", name: "Pitlochry", location: LatLng(56.7030, -3.7340), source: "demo")
            model.select(to)
            await wait(2)
            model.openDirections(to: to)
            await wait(10)
            model.startNavigation()
            await wait(5)
            model.nav?.showDemoRoundabout()
            model.nav?.showDemoAlerts()
            return
        }
        if step == "uk" {
            // Driving north out of Perth on the A9, in miles and yards, with camera alerts up.
            model.settings.units = .yards
            let to = Place(id: "demo-pitlochry", name: "Pitlochry", location: LatLng(56.7030, -3.7340), source: "demo")
            model.select(to)
            await wait(2)
            model.openDirections(to: to)
            await wait(10)
            model.startNavigation()
            await wait(5)
            model.nav?.showDemoAlerts()
            // Under the limit here: the speed sign stays plain.
            model.nav?.showDemoSpeed(limitKmh: 96.6, mph: 57)
            return
        }
        if step == "transit" {
            // Davis to Sacramento Valley Station: buses and Amtrak.
            let station = Place(id: "demo-sac", name: "Sacramento Valley Station", location: LatLng(38.5843, -121.5006), source: "demo")
            model.select(station)
            await wait(2)
            model.openDirections(to: station)
            model.showTransit()
            return
        }
        if step == "streetview" {
            // A fixed place with Google imagery 34 m away, so every run looks the same way.
            var pier = Place(id: "demo-pier50", name: "Pier 50 Sushi", location: LatLng(38.54436, -121.74073), source: "demo")
            pier.category = "Sushi restaurant"
            model.select(pier)
            return
        }
        model.search("restaurants", title: "Restaurants")
        await wait(8)
        if step == "listscroll" {
            // The results sheet open full height and its list scrolled: the red label must say
            // "list scrolled", so a pull down scrolls the list instead of closing the sheet.
            model.detent = .full
            await wait(2)
            NotificationCenter.default.post(name: scrollResults, object: nil)
            return
        }
        guard step != "search", let first = model.visibleResults.first else { return }
        if step == "copy" { CopyOnHold.demoText = first.address }
        model.select(first)
        await wait(5)
        guard !["place", "lookaround", "copy"].contains(step) else { return }
        if step == "wazeroute" { RouteWazeSummary.demo = [(.police, 2), (.accident, 1), (.hazard, 3)] }
        model.openDirections(to: first)
        if step == "stops", let second = model.visibleResults.dropFirst().first { model.addStop(second) }
        await wait(8)
        if step == "addstop" { model.addingStop = true; return }
        guard ["nav", "camalert", "wazealert", "allalerts", "endtrip"].contains(step) else { return }
        model.startNavigation()
        if step == "camalert" {
            await wait(4)
            model.nav?.showDemoAlerts()
        }
        if step == "wazealert" {
            await wait(4)
            model.nav?.showDemoWaze()
        }
        if step == "allalerts" {
            // Everything at once: camera, Waze police, helicopter and an average speed check.
            await wait(4)
            model.nav?.showDemoAlerts()
            model.nav?.showDemoWaze()
        }
    }
}

/** Home, Work and the parked car at the top of the search panel. */
struct Shortcuts: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings = AppSettings.shared
    let done: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            PlaceTile(model: model, icon: "house.fill", color: Vela.routeBlue, title: "Home", place: settings.home) {
                done()
                model.picking = .home
            } go: { done() }
            PlaceTile(model: model, icon: "briefcase.fill", color: Color(hex: 0x8B5CF6), title: "Work", place: settings.work) {
                done()
                model.picking = .work
            } go: { done() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

struct PlaceTile: View {
    @ObservedObject var model: AppModel
    let icon: String
    let color: Color
    let title: String
    let place: Place?
    let unset: () -> Void
    var go: () -> Void = {}
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button {
            if let p = place { go(); model.openDirections(to: p) } else { unset() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 19, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(place == nil ? Color.gray : color))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 19, weight: .bold)).lineLimit(1)
                    Text(place.flatMap { p in model.userLatLng.map { $0.distance(to: p.location) } }.map(Fmt.distance) ?? (place == nil ? "Tap to set" : "Tap to go"))
                        .font(.system(size: 15, weight: .medium)).foregroundColor(Vela.muted(scheme)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 74)
            .glass(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .foregroundColor(.primary)
        .contextMenu {
            if place != nil, title == "Home" || title == "Work" {
                Button { model.picking = title == "Home" ? .home : .work } label: { Label("Change \(title.lowercased())", systemImage: "pencil") }
            }
        }
        .accessibilityLabel(place == nil ? "\(title), not set" : "Go to \(title)")
    }
}

/** Red-and-gray needle pointing north, like Vela's compass. */
struct CompassNeedle: View {
    var body: some View {
        ZStack {
            Triangle().fill(Color(hex: 0xEA4335)).frame(width: 10, height: 14).offset(y: -7)
            Triangle().fill(Color.secondary).frame(width: 10, height: 14).rotationEffect(.degrees(180)).offset(y: 7)
        }
    }
}

struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/** Why the map can't do its job right now: location turned off, or no internet. */
struct StatusCards: View {
    @ObservedObject var location: LocationService
    @ObservedObject private var net = Connectivity.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if location.denied || DemoScript.step == "locationoff" {
            card(icon: "location.slash.fill", color: Vela.closed, title: "Location is off",
                 detail: "Kite needs it to show where you are and to guide you.", button: "Turn on") { LocationService.openSettings() }
        } else if location.authorized && location.reducedAccuracy {
            card(icon: "location.circle.fill", color: Color(hex: 0xF59E0B), title: "Precise location is off",
                 detail: "Turn on Precise Location for Kite in Settings to improve your position.", button: "Settings") { LocationService.openSettings() }
        } else if location.authorized, let fix = location.last, fix.horizontalAccuracy > 200 {
            card(icon: "location.circle.fill", color: Color(hex: 0xF59E0B), title: "Location is uncertain",
                 detail: "GPS accuracy is about \(Int(fix.horizontalAccuracy)) m. Move outdoors for a better fix.", button: nil) {}
        } else if !net.online {
            card(icon: "wifi.slash", color: Color(hex: 0xF59E0B), title: "No internet connection",
                 detail: "Search, routes and live traffic need one. The map you've already seen still works.", button: nil) {}
        }
    }

    private func card(icon: String, color: Color, title: String, detail: String, button: String?, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 20, weight: .bold)).foregroundColor(.white)
                .frame(width: 44, height: 44).background(Circle().fill(color))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 18, weight: .bold))
                Text(detail).font(.system(size: 15)).foregroundColor(Vela.muted(scheme)).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let button {
                Button(action: action) {
                    Text(button).font(.system(size: 17, weight: .bold)).foregroundColor(Vela.onAccent(scheme))
                        .padding(.horizontal, 16).frame(height: 44).background(Capsule().fill(Vela.accent(scheme)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .glass(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
    }
}

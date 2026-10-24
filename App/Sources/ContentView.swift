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

    private var dark: Bool { settings.colorScheme.map { $0 == .dark } ?? (systemScheme == .dark) }

    var body: some View {
        ZStack {
            VelaMapView(model: model, settings: settings, dark: dark)
                .ignoresSafeArea()
            if let nav = model.nav {
                NavigationOverlay(model: model, nav: nav)
            } else if model.directions != nil {
                DirectionsOverlay(model: model)
            } else {
                BrowseOverlay(model: model)
            }
        }
        .preferredColorScheme(settings.colorScheme)
        .task { await DemoScript.run(model) }
        .onReceive(launch.$pending) { kind in
            guard let kind else { return }
            launch.pending = nil
            Task { await model.perform(kind) }
        }
        .sheet(isPresented: $model.showLayers) {
            LayersSheet(settings: settings)
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsView(settings: settings, onChange: { model.reloadRoutes() })
        }
        .fullScreenCover(isPresented: .constant(DemoScript.step?.hasPrefix("svtest") == true)) {
            // Screenshot run only: the viewer on a test pattern, turned right by the step's number.
            GoogleStreetViewScreen(name: "Test pattern", pano: StreetView.Panorama(id: PanoramaViewer.testID, location: LatLng(0, 0)),
                                   heading: Double(DemoScript.step?.dropFirst(6) ?? "") ?? 0)
        }
        .fullScreenCover(isPresented: Binding(get: { !settings.welcomed && (!DemoScript.active || DemoScript.step == "welcome") }, set: { _ in })) {
            WelcomeView(settings: settings)
        }
        .sheet(isPresented: $model.addingStop) {
            StopPicker(model: model)
        }
        .sheet(isPresented: $model.showSaved) {
            SavedView(settings: settings) { p in
                model.showSaved = false
                model.select(p)
            }
        }
    }
}

/** The normal map screen: search bar, category chips, map buttons and the results or place sheet. */
struct BrowseOverlay: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var voice = VoiceSearch()
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var scheme

    private var hasSheet: Bool { model.selected != nil || !model.results.isEmpty }

    var body: some View {
        GeometryReader { geo in
            let full = geo.size.height + geo.safeAreaInsets.bottom
            let sheetH = hasSheet ? BottomSheet<EmptyView, EmptyView>.height(model.detent, container: full, peek: 150) : 0
            ZStack(alignment: .top) {
                // Map buttons on the right: layers up top, location just above the sheet.
                VStack {
                    HStack(alignment: .top) {
                        Spacer()
                        VStack(spacing: 10) {
                            MapFab(icon: "square.3.layers.3d", size: 44) { model.showLayers = true }
                            if settings.parkingButton || settings.parking != nil {
                                MapFab(icon: "parkingsign", tint: settings.parking != nil ? Vela.routeBlue : .primary, size: 44) {
                                    if let p = settings.parking { model.select(p) } else { model.saveParking() }
                                }
                            }
                            if model.mapHeading > 1 && model.mapHeading < 359 {
                                Button { model.map?.setDirection(0, animated: true) } label: {
                                    CompassNeedle()
                                        .rotationEffect(.degrees(-model.mapHeading))
                                        .frame(width: 44, height: 44)
                                        .glass(Circle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Face north")
                                .transition(.scale.combined(with: .opacity))
                            }
                        }
                    }
                    .padding(.top, model.results.isEmpty && model.selected == nil ? 118 : 70)
                    Spacer()
                    if sheetH < full * 0.6 {
                        HStack {
                            Spacer()
                            MapFab(icon: "location.fill", tint: Vela.routeBlue) { model.centerOnUser() }
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
                        .padding(.bottom, max(sheetH - geo.safeAreaInsets.bottom, 0) + 14)
                    }
                }
                .padding(.horizontal, 14)

                if hasSheet {
                    VStack {
                        Spacer()
                        sheet(full: full)
                    }
                    .ignoresSafeArea(edges: .bottom)
                    .transition(.move(edge: .bottom))
                }

                VStack(spacing: 10) {
                    SearchBar(model: model, voice: voice, focused: $searchFocused)
                    if voice.listening { ListeningCard(voice: voice) }
                    if searchFocused {
                        SuggestionsPanel(model: model) { searchFocused = false }
                    } else if model.results.isEmpty && model.selected == nil {
                        CategoryChips { c in
                            searchFocused = false
                            model.search(c.query, title: c.label)
                        }
                    }
                    if let n = model.notice, !searchFocused {
                        NoticeBanner(text: n) { model.notice = nil }
                    }
                }
                .padding(.top, 6)
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: hasSheet)
        }
    }

    @ViewBuilder
    private func sheet(full: CGFloat) -> some View {
        if let place = model.selected {
            BottomSheet(detent: $model.detent, containerHeight: full, peekHeight: 150) {
                PlaceHeader(model: model, place: place)
            } content: {
                PlaceBody(model: model, place: place)
            }
            .id(place.id)
        } else {
            BottomSheet(detent: $model.detent, containerHeight: full, peekHeight: 150) {
                ResultsHeader(model: model)
            } content: {
                ResultsList(model: model)
            }
        }
    }
}

struct SearchBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var voice: VoiceSearch
    var focused: FocusState<Bool>.Binding
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 12) {
            if focused.wrappedValue {
                Button { focused.wrappedValue = false } label: {
                    Image(systemName: "arrow.left").font(.system(size: 18, weight: .medium))
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "magnifyingglass").font(.system(size: 18, weight: .medium))
            }
            TextField("Search", text: $model.query)
                .focused(focused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { model.search() }
                .onChange(of: model.query) { q in
                    if focused.wrappedValue { model.typed(q) }
                }
            if model.searching {
                ProgressView()
            } else if !model.query.isEmpty || !model.results.isEmpty || model.selected != nil {
                Button {
                    model.clearSearch()
                    focused.wrappedValue = false
                } label: {
                    Image(systemName: "xmark").font(.system(size: 17, weight: .medium))
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    focused.wrappedValue = false
                    voice.start(onDone: { text in
                        model.query = text
                        model.search(text)
                    }, onError: { model.notice = $0 })
                } label: {
                    Image(systemName: "mic").font(.system(size: 18))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Search by voice")
                Button { model.showSaved = true } label: {
                    Image(systemName: "bookmark").font(.system(size: 18))
                }
                .buttonStyle(.plain)
            }
            Button { model.showSettings = true } label: {
                Image(systemName: "gearshape").font(.system(size: 18))
            }
            .buttonStyle(.plain)
        }
        .foregroundColor(.primary)
        .padding(.horizontal, 18)
        .frame(height: 52)
        .glass(Capsule())
        .padding(.horizontal, 12)
    }
}

struct CategoryChips: View {
    let onPick: (Category) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Category.all) { c in
                    Button { onPick(c) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: c.icon).font(.system(size: 13))
                            Text(c.label).font(.subheadline.weight(.medium))
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .glass(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
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
                    ForEach(Category.all) { c in
                        row(icon: c.icon, text: c.label) { done(); model.search(c.query, title: c.label) }
                    }
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
            .frame(height: 46)
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
        if step == "rail" {
            // Lower Manhattan with the subway lines and hill shading on.
            model.settings.transitLines = true
            model.settings.terrain = true
            model.map?.setCenter(CLLocationCoordinate2D(latitude: 40.722, longitude: -73.99), zoomLevel: 12.6, animated: false)
            return
        }
        if step == "welcome" { model.settings.welcomed = false; return }
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
        guard step != "search", let first = model.visibleResults.first else { return }
        if step == "copy" { CopyOnHold.demoText = first.address }
        model.select(first)
        await wait(5)
        guard !["place", "lookaround", "copy"].contains(step) else { return }
        model.openDirections(to: first)
        if step == "stops", let second = model.visibleResults.dropFirst().first { model.addStop(second) }
        await wait(8)
        guard step == "nav" || step == "camalert" else { return }
        model.startNavigation()
        if step == "camalert" {
            await wait(4)
            model.nav?.showDemoAlerts()
        }
    }
}

/** Home, Work and the parked car, one tap from the search box. */
struct Shortcuts: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings = AppSettings.shared
    let done: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("house.fill", "Home", settings.home) {
                    model.notice = "Open any place and tap More, then Set as home."
                }
                chip("briefcase.fill", "Work", settings.work) {
                    model.notice = "Open any place and tap More, then Set as work."
                }
                if let p = settings.parking {
                    chip("parkingsign", "Parked car", p) {}
                }
            }
            .padding(.horizontal, 14)
        }
        .padding(.vertical, 6)
    }

    private func chip(_ icon: String, _ title: String, _ place: Place?, unset: @escaping () -> Void) -> some View {
        Button {
            done()
            if let p = place { model.openDirections(to: p) } else { unset() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(place == nil ? Color.secondary : Vela.routeBlue))
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(place.flatMap { p in p.distanceMeters ?? model.userLatLng.map { $0.distance(to: p.location) } }.map(Fmt.distance) ?? (place == nil ? "Set" : ""))
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .padding(.leading, 6).padding(.trailing, 14)
            .frame(height: 44)
            .background(Capsule().stroke(Color.secondary.opacity(0.35)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundColor(.primary)
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

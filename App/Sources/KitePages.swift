import SwiftUI
import VelaCore

/** The bar along the bottom: Map, Saved and Settings, each a big target. */
struct KiteDock: View {
    @ObservedObject var model: AppModel
    let bottomInset: CGFloat
    @Environment(\.colorScheme) private var scheme

    static let height: CGFloat = 80
    /** How far the dock sits above the screen's bottom edge. */
    static func bottomGap(_ inset: CGFloat) -> CGFloat { max(inset - 14, 10) }

    var body: some View {
        HStack(spacing: 0) {
            item(.map, "map.fill", "Map")
            item(.saved, "bookmark.fill", "Saved")
            item(.settings, "gearshape.fill", "Settings")
        }
        .frame(height: Self.height)
        .glass(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, Self.bottomGap(bottomInset))
    }

    private func item(_ tab: AppTab, _ icon: String, _ title: String) -> some View {
        let on = model.tab == tab
        return Button {
            if tab != model.tab, model.tab == .settings { model.reloadRoutes() }
            model.tab = tab
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 25, weight: .semibold))
                Text(title).font(.system(size: 14, weight: on ? .bold : .semibold))
            }
            .foregroundColor(on ? Vela.accentText(scheme) : Vela.muted(scheme))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/** Bottom left of the map, with Waze on: the heat map's key, the police risk here and how many live reports are in view. */
struct WazeMapChips: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if settings.wazeOn {
            VStack(alignment: .leading, spacing: 8) {
                if settings.wazeHeatmap, settings.wazePolice { HeatLegend() }
                if settings.policeRisk, let risk = model.areaRisk {
                    let level = PoliceRisk.level(risk)
                    HStack(spacing: 8) {
                        Image(systemName: "shield.lefthalf.filled").font(.system(size: 17, weight: .bold))
                        Text("Local report activity: \(level.rawValue.capitalized)").font(.system(size: 16, weight: .bold))
                    }
                    .foregroundColor(level == .medium ? Color(hex: 0x1F1300) : .white)
                    .padding(.horizontal, 14).frame(height: 44)
                    .background(Capsule().fill(PoliceRiskChip.color(level)))
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                    .accessibilityElement(children: .combine)
                }
                if let n = model.wazeLiveCount, settings.wazeOnMap || settings.wazeHeatmap {
                    HStack(spacing: 8) {
                        Circle().fill(Color(hex: 0x22C55E)).frame(width: 10, height: 10)
                        Text("Live from Waze · \(n) report\(n == 1 ? "" : "s")").font(.system(size: 14, weight: .semibold))
                    }
                    .padding(.horizontal, 12).frame(height: 34)
                    .glass(Capsule())
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

/** The Saved page of the dock: Home and Work as big tiles, then every saved place with its own Go. */
struct SavedPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var scheme
    @State private var renaming: Place?
    @State private var newName = ""

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Vela.ground(scheme).ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Saved").font(.system(size: 36, weight: .heavy)).padding(.horizontal, 4)
                        HStack(spacing: 12) {
                            mineTile("house.fill", Vela.routeBlue, "Home", settings.home)
                            mineTile("briefcase.fill", Color(hex: 0x8B5CF6), "Work", settings.work)
                        }
                        if let car = settings.parking {
                            row(car, icon: "parkingsign", color: Vela.routeBlue, editable: false)
                                .background(card)
                        }
                        if settings.saved.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "bookmark").font(.system(size: 40, weight: .semibold)).foregroundColor(Vela.muted(scheme))
                                Text("No saved places yet").font(.title3.weight(.bold))
                                Text("Open any place and tap Save to keep it here.").font(.body).foregroundColor(Vela.muted(scheme))
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(settings.saved.enumerated()), id: \.element.id) { i, p in
                                    if i > 0 { Divider().padding(.leading, 78) }
                                    row(p, icon: "bookmark.fill", color: Color(hex: 0xF59E0B), editable: true)
                                }
                            }
                            .background(card)
                            Text("Hold a place to rename or remove it.").font(.subheadline).foregroundColor(Vela.muted(scheme))
                                .padding(.horizontal, 4)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, KiteDock.height + 40)
                }
                KiteDock(model: model, bottomInset: geo.safeAreaInsets.bottom)
                    .ignoresSafeArea(edges: .bottom)
                    .offset(y: geo.safeAreaInsets.bottom)
            }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") {
                if let p = renaming { settings.renameSaved(p.id, to: newName) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Vela.surface(scheme))
    }

    private func distance(_ p: Place) -> String? {
        model.userLatLng.map { Fmt.distance($0.distance(to: p.location)) }
    }

    private func mineTile(_ icon: String, _ color: Color, _ title: String, _ place: Place?) -> some View {
        Button {
            if let p = place { go(p) } else {
                model.picking = title == "Home" ? .home : .work
            }
        } label: {
            VStack(alignment: .leading) {
                Image(systemName: icon).font(.system(size: 21, weight: .bold)).foregroundColor(.white)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(place == nil ? Color.gray : color))
                Spacer(minLength: 8)
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.system(size: 21, weight: .bold))
                    Spacer()
                    Text(place.flatMap(distance) ?? (place == nil ? "Set" : "")).font(.system(size: 16, weight: .medium))
                        .foregroundColor(Vela.muted(scheme))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 118, alignment: .leading)
            .background(card)
            .contentShape(RoundedRectangle(cornerRadius: 24))
        }
        .buttonStyle(.plain)
        .foregroundColor(.primary)
        .contextMenu {
            if place != nil {
                Button { model.picking = title == "Home" ? .home : .work } label: { Label("Change \(title.lowercased())", systemImage: "pencil") }
            }
        }
        .accessibilityLabel(place == nil ? "\(title), not set" : "Go \(title)")
    }

    private func row(_ p: Place, icon: String, color: Color, editable: Bool) -> some View {
        HStack(spacing: 14) {
            Button { show(p) } label: {
                HStack(spacing: 14) {
                    Image(systemName: icon).font(.system(size: 20, weight: .bold)).foregroundColor(.white)
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(color))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name).font(.system(size: 20, weight: .bold)).lineLimit(2)
                        if let line = [distance(p), p.address ?? p.category].compactMap({ $0 }).first {
                            Text(line).font(.system(size: 16)).foregroundColor(Vela.muted(scheme)).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { go(p) } label: {
                Image(systemName: "location.north.fill").font(.system(size: 24, weight: .bold))
                    .foregroundColor(Vela.onAccent(scheme))
                    .frame(width: 60, height: 60)
                    .background(Circle().fill(Vela.accent(scheme)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Go to \(p.name)")
        }
        .foregroundColor(.primary)
        .padding(.leading, 14).padding(.trailing, 12)
        .frame(minHeight: 88)
        .contextMenu {
            if editable {
                Button { newName = p.name; renaming = p } label: { Label("Rename", systemImage: "pencil") }
                Button(role: .destructive) { settings.saved.removeAll { $0.id == p.id } } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
        }
    }

    private func go(_ p: Place) {
        model.tab = .map
        model.openDirections(to: p)
    }

    private func show(_ p: Place) {
        model.tab = .map
        model.select(p)
    }
}

/** The Settings page of the dock. */
struct SettingsPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Vela.ground(scheme).ignoresSafeArea()
                SettingsView(settings: settings, model: model, inTab: true, pick: { model.picking = $0 }, onChange: { model.reloadRoutes() })
                    .safeAreaInset(edge: .bottom) { Color.clear.frame(height: KiteDock.height + 10) }
                KiteDock(model: model, bottomInset: geo.safeAreaInsets.bottom)
                    .ignoresSafeArea(edges: .bottom)
                    .offset(y: geo.safeAreaInsets.bottom)
            }
        }
    }
}

/** Choosing home or work: type an address or postcode, or use where you are now. */
struct PlacePicker: View {
    @ObservedObject var model: AppModel
    let kind: PickKind
    @ObservedObject private var settings = AppSettings.shared
    @State private var query = ""
    @State private var found: [Place] = []
    @State private var searching = false
    @State private var task: Task<Void, Never>?
    @State private var locating = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    private var title: String { kind == .home ? "Home" : "Work" }
    private var current: Place? { kind == .home ? settings.home : settings.work }

    var body: some View {
        NavigationView {
            List {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Section {
                        Button { useHere() } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "location.fill").font(.system(size: 18, weight: .bold))
                                    .foregroundColor(.white).frame(width: 40, height: 40)
                                    .background(Circle().fill(Vela.routeBlue))
                                Text("Use where I am now").font(.system(size: 19, weight: .semibold)).foregroundColor(.primary)
                                Spacer()
                                if locating { ProgressView() }
                            }
                        }
                        .disabled(model.userLatLng == nil || locating)
                    } footer: {
                        Text(model.location.denied ? "Location is off for Kite, so type the address instead."
                             : "Or type the address or postcode above.")
                    }
                    if let p = current {
                        Section("Now set to") {
                            row(p)
                            Button(role: .destructive) {
                                if kind == .home { model.setHome(nil) } else { model.setWork(nil) }
                                dismiss()
                            } label: { Label("Remove \(title.lowercased())", systemImage: "trash") }
                        }
                    }
                } else if !found.isEmpty {
                    Section { ForEach(found) { row($0) } }
                } else if searching {
                    HStack(spacing: 10) { ProgressView(); Text("Searching…").foregroundColor(.secondary) }
                } else {
                    Text(Connectivity.explain("Nothing found yet. Keep typing, or try the postcode."))
                        .foregroundColor(.secondary)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Address or postcode")
            .onChange(of: query) { q in lookUp(q, full: false) }
            .onSubmit(of: .search) { lookUp(query, full: true) }
            .kiteList()
            .navigationTitle("Set \(title.lowercased())")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func row(_ p: Place) -> some View {
        Button { pick(p) } label: {
            HStack(spacing: 14) {
                Image(systemName: "mappin.circle.fill").font(.system(size: 26)).foregroundColor(Vela.closed)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name).font(.system(size: 18, weight: .semibold)).foregroundColor(.primary).lineLimit(2)
                    if let a = p.address, a != p.name {
                        Text(a).font(.system(size: 15)).foregroundColor(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                if let d = model.userLatLng?.distance(to: p.location) {
                    Text(Fmt.distance(d)).font(.system(size: 15)).foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func pick(_ p: Place) {
        if kind == .home { model.setHome(p) } else { model.setWork(p) }
        dismiss()
    }

    private func useHere() {
        guard let me = model.userLatLng else { return }
        locating = true
        Task {
            let near = await Photon.reverse(me)
            var p = Place(id: "\(kind.rawValue):\(me.lat),\(me.lng)", name: near?.name ?? title, location: me, source: "osm")
            p.address = near?.address
            locating = false
            pick(p)
        }
    }

    /** As you type: quick suggestions. On Search: a full search, postcodes included. */
    private func lookUp(_ text: String, full: Bool) {
        task?.cancel()
        let q = text.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { found = []; searching = false; return }
        searching = true
        let center = model.userLatLng ?? model.viewport.center
        let useGoogle = !settings.noGoogle
        task = Task {
            if !full { try? await Task.sleep(nanoseconds: 300_000_000) }
            guard !Task.isCancelled else { return }
            var places: [Place] = []
            if full {
                places = await PlaceSearch.search(q, center: center, spanMeters: 50_000, useGoogle: useGoogle).places
            } else {
                if let pc = await Postcodes.lookup(q) { places = [pc] }
                if places.isEmpty, useGoogle {
                    places = (try? await GoogleClient.shared.suggest(q, near: center, spanMeters: 50_000))?.places ?? []
                }
                if places.isEmpty { places = (try? await Photon.search(q, near: center, limit: 10)) ?? [] }
            }
            guard !Task.isCancelled else { return }
            found = Array(places.prefix(20))
            searching = false
        }
    }
}

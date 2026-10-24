import SwiftUI
import UIKit
import VelaCore

struct PlaceHeader: View {
    @ObservedObject var model: AppModel
    let place: Place
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Text(place.name)
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                    .copyable(place.name, below: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                CircleIconButton(icon: settings.isSaved(place) ? "bookmark.fill" : "bookmark") { settings.toggleSaved(place) }
                if let url = place.shareURL {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.primary)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Color.secondary.opacity(0.18)))
                    }
                    .buttonStyle(.plain)
                }
                CircleIconButton(icon: "xmark") { withAnimation { model.closePlace() } }
            }
            PlaceMetaLine(place: place)
            StatusText(place: place).font(.subheadline)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }
}

struct PlaceBody: View {
    @ObservedObject var model: AppModel
    let place: Place
    @State private var tab = 0
    @State private var hoursOpen = false
    /** Driving time from here, shown on the Directions button like Google Maps. */
    @State private var driveSeconds: Double?
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            SheetTopMarker()
            VStack(alignment: .leading, spacing: 14) {
                actions
                PhotoStrip(urls: place.photoUrls, height: 140, opensViewer: true, streetView: place)
                if hasAbout {
                    Picker("", selection: $tab) {
                        Text("Overview").tag(0)
                        Text("About").tag(1)
                    }
                    .pickerStyle(.segmented)
                }
                if tab == 0 { overview } else { about }
                Text(place.source == "google" ? "Place details from Google Maps" : "Map data © OpenStreetMap contributors")
                    .font(.caption).foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 80)
        }
        .task(id: place.id) { await loadDriveTime() }
    }

    private func loadDriveTime() async {
        driveSeconds = nil
        guard let from = model.userLatLng, from.distance(to: place.location) > 300,
              from.distance(to: place.location) < 300_000 else { return }
        let r = try? await OSRM.route(from: from, to: place.location, mode: .drive)
        if let s = r?.first?.durationSeconds { withAnimation { driveSeconds = s } }
    }

    private var hasAbout: Bool { !place.about.isEmpty }

    /** A bus stop or a station, which gets a live departure board. */
    private var isStop: Bool {
        let text = ((place.category ?? "") + " " + place.name).lowercased()
        return ["station", "bus stop", "stop ", "transit", "subway", "metro", "tram", "light rail", "terminal", "depot"]
            .contains { text.contains($0) }
    }

    private var actions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                PillButton(title: driveSeconds.map { "Directions · \(Fmt.duration($0))" } ?? "Directions",
                           icon: "arrow.triangle.turn.up.right.diamond.fill", filled: true) {
                    model.openDirections(to: place)
                }
                PillButton(title: "Start", icon: "location.north.fill") {
                    model.openDirections(to: place)
                    model.autoStart = true
                }
                if let tel = telURL(place.phone) {
                    PillButton(title: "Call", icon: "phone.fill") { openURL(tel) }
                }
                if let web = webURL(place.website) {
                    PillButton(title: "Website", icon: "globe") { openURL(web) }
                }
                if place.id == model.settings.parking?.id {
                    PillButton(title: "Clear spot", icon: "xmark.circle") { model.clearParking() }
                }
                Menu {
                    if model.settings.home?.id == place.id {
                        Button(role: .destructive) { model.setHome(nil) } label: { Label("Remove home", systemImage: "house.slash") }
                    } else {
                        Button { model.setHome(place) } label: { Label("Set as home", systemImage: "house") }
                    }
                    if model.settings.work?.id == place.id {
                        Button(role: .destructive) { model.setWork(nil) } label: { Label("Remove work", systemImage: "briefcase") }
                    } else {
                        Button { model.setWork(place) } label: { Label("Set as work", systemImage: "briefcase") }
                    }
                    Button { UIPasteboard.general.string = String(format: "%.6f, %.6f", place.location.lat, place.location.lng) } label: {
                        Label("Copy coordinates", systemImage: "doc.on.doc")
                    }
                    if let a = place.address {
                        Button { UIPasteboard.general.string = [place.name, a].joined(separator: ", ") } label: {
                            Label("Copy address", systemImage: "doc.on.clipboard")
                        }
                    }
                    Section("Open in") {
                        ForEach(OtherApp.allCases, id: \.self) { app in
                            Button { openURL(app.url(for: place)) } label: { Label(app.rawValue, systemImage: app.icon) }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold))
                        Text("More").font(.subheadline.weight(.semibold))
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .foregroundColor(Vela.onTonal(scheme))
                    .background(Capsule().fill(Vela.tonal(scheme)))
                }
            }
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let s = place.editorialSummary { Text(s).font(.body).copyable(s) }
            if let a = place.address { InfoRow(icon: "mappin.and.ellipse", text: a).copyable(a) }
            if isStop { DepartureBoard(place: place) }
            if !place.hours.isEmpty { hours.copyable(place.hours.joined(separator: "\n")) }
            if let phone = place.phone {
                InfoRow(icon: "phone", text: phone)
                    .onTapGesture { if let u = telURL(phone) { openURL(u) } }
                    .copyable(phone)
            }
            if let site = place.website {
                InfoRow(icon: "globe", text: site.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: ""))
                    .onTapGesture { if let u = webURL(site) { openURL(u) } }
                    .copyable(site)
            }
            let coords = String(format: "%.6f, %.6f", place.location.lat, place.location.lng)
            InfoRow(icon: "scope", text: coords).copyable(coords)
            if let r = place.featuredReview {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Review").font(.headline)
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "person.crop.circle.fill").font(.title2).foregroundColor(.secondary)
                        Text("“\(r)”").font(.subheadline)
                    }
                }
            }
        }
    }

    private var hours: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "clock").frame(width: 22).foregroundColor(.secondary)
                VStack(alignment: .leading) {
                    StatusText(place: place).font(.subheadline)
                    if !hoursOpen, let today = place.hours.first {
                        Text(today).font(.subheadline).foregroundColor(.secondary)
                    }
                }
                Spacer()
                Image(systemName: hoursOpen ? "chevron.up" : "chevron.down").foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation { hoursOpen.toggle() } }
            if hoursOpen {
                ForEach(place.hours, id: \.self) { h in
                    let parts = h.split(separator: ":", maxSplits: 1).map(String.init)
                    HStack(alignment: .top) {
                        Text(parts.first ?? h).font(.subheadline).frame(width: 100, alignment: .leading)
                        Text(parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : "").font(.subheadline)
                    }
                    .padding(.leading, 36)
                }
            }
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(place.about, id: \.self) { section in
                VStack(alignment: .leading, spacing: 6) {
                    Text(section.title).font(.headline)
                    ForEach(section.items, id: \.self) { item in
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark").font(.caption).foregroundColor(.secondary)
                            Text(item).font(.subheadline)
                        }
                    }
                }
            }
        }
    }
}

struct InfoRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).frame(width: 22).foregroundColor(.secondary)
            Text(text).font(.subheadline).foregroundColor(.primary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SavedView: View {
    @ObservedObject var settings: AppSettings
    let onPick: (Place) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: Place?
    @State private var newName = ""

    var body: some View {
        NavigationView {
            Group {
                if settings.saved.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "bookmark").font(.largeTitle).foregroundColor(.secondary)
                        Text("No saved places yet").font(.headline)
                        Text("Tap the bookmark on a place to save it here.").font(.subheadline).foregroundColor(.secondary)
                    }
                } else {
                    List {
                        ForEach(settings.saved) { p in
                            Button { onPick(p) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.name).foregroundColor(.primary)
                                    if let a = p.address { Text(a).font(.caption).foregroundColor(.secondary) }
                                }
                            }
                            .contextMenu {
                                Button { startRename(p) } label: { Label("Rename", systemImage: "pencil") }
                                Button(role: .destructive) { settings.saved.removeAll { $0.id == p.id } } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button { startRename(p) } label: { Label("Rename", systemImage: "pencil") }.tint(Vela.routeBlue)
                            }
                        }
                        .onDelete { settings.saved.remove(atOffsets: $0) }
                    }
                }
            }
            .navigationTitle("Saved")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Save") {
                    if let p = renaming { settings.renameSaved(p.id, to: newName) }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private extension SavedView {
    func startRename(_ p: Place) {
        newName = p.name
        renaming = p
    }
}

/** Next departures at a stop from Transitous, refreshed every 30 seconds while it's open. */
struct DepartureBoard: View {
    let place: Place
    @State private var board: (stop: String, departures: [Transitous.Departure])?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Departures").font(.headline)
            if let b = board {
                ForEach(Array(b.departures.prefix(8).enumerated()), id: \.offset) { _, d in
                    HStack(spacing: 10) {
                        LineChip(leg: TransitLeg(isWalk: false, mode: d.mode, line: d.line, color: d.color, textColor: d.textColor))
                        Text(d.headsign).font(.subheadline).lineLimit(1)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(countdown(d.time)).font(.subheadline.weight(.semibold))
                                .foregroundColor(d.delayMinutes != nil ? Vela.open : .primary)
                            if let late = d.delayMinutes, late != 0 {
                                Text(late > 0 ? "\(late) min late" : "\(-late) min early").font(.caption2)
                                    .foregroundColor(late > 0 ? Vela.closed : Vela.open)
                            }
                        }
                    }
                }
                Text("Live times in green · from Transitous").font(.caption).foregroundColor(.secondary)
            } else if loaded {
                Text("No departures found here.").font(.subheadline).foregroundColor(.secondary)
            } else {
                HStack { ProgressView(); Text("Loading departures…").foregroundColor(.secondary) }
            }
        }
        .task(id: place.id) {
            while !Task.isCancelled {
                let b = await Transitous.departures(near: place.location)
                if Task.isCancelled { return }
                if b != nil || !loaded { board = b }
                loaded = true
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    private func countdown(_ t: Date) -> String {
        let mins = Int((t.timeIntervalSinceNow / 60).rounded())
        if mins <= 0 { return "Now" }
        if mins < 60 { return "\(mins) min" }
        let f = DateFormatter()
        f.timeStyle = .short
        return f.string(from: t)
    }
}

/** Other map apps a place can be handed to, by their web links (no app list permission needed). */
enum OtherApp: String, CaseIterable {
    case google = "Google Maps"
    case waze = "Waze"
    case apple = "Apple Maps"

    var icon: String {
        switch self {
        case .google: return "map"
        case .waze: return "car"
        case .apple: return "applelogo"
        }
    }

    func url(for p: Place) -> URL {
        let ll = "\(p.location.lat),\(p.location.lng)"
        let name = p.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        switch self {
        case .google: return p.shareURL ?? URL(string: "https://www.google.com/maps/search/?api=1&query=\(ll)")!
        case .waze: return URL(string: "https://waze.com/ul?ll=\(ll)&navigate=yes")!
        case .apple: return URL(string: "https://maps.apple.com/?ll=\(ll)&q=\(name)")!
        }
    }
}

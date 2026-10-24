import Foundation
import SwiftUI
import VelaCore

enum ThemeMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum UnitsMode: String, CaseIterable, Identifiable {
    case auto, metric, imperial, yards
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Automatic"
        case .metric: return "Kilometers"
        case .imperial: return "Miles and feet"
        case .yards: return "Miles and yards (UK)"
        }
    }
}

/** Everything in Settings, kept between launches. */
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var theme: ThemeMode { didSet { d.set(theme.rawValue, forKey: "theme") } }
    @Published var units: UnitsMode { didSet { d.set(units.rawValue, forKey: "units") } }
    @Published var voice: Bool { didSet { d.set(voice, forKey: "voice") } }
    @Published var traffic: Bool { didSet { d.set(traffic, forKey: "traffic") } }
    @Published var satellite: Bool { didSet { d.set(satellite, forKey: "satellite") } }
    /** Hill shading, and metro/rail lines in their colors. */
    @Published var terrain: Bool { didSet { d.set(terrain, forKey: "terrain") } }
    @Published var transitLines: Bool { didSet { d.set(transitLines, forKey: "transitLines") } }
    @Published var avoidTolls: Bool { didSet { d.set(avoidTolls, forKey: "avoidTolls") } }
    @Published var avoidHighways: Bool { didSet { d.set(avoidHighways, forKey: "avoidHighways") } }
    /** "Use Vela without Google": search and routes from open data only. */
    @Published var noGoogle: Bool { didSet { d.set(noGoogle, forKey: "noGoogle") } }
    /** Fixed speed cameras on the map, and plate readers (DeFlock), from OpenStreetMap. */
    @Published var speedCameras: Bool { didSet { d.set(speedCameras, forKey: "speedCameras") } }
    @Published var plateCameras: Bool { didSet { d.set(plateCameras, forKey: "plateCameras") } }
    /** Say "Speed camera ahead" while navigating. Off by default: some countries restrict it. */
    @Published var cameraWarnings: Bool { didSet { d.set(cameraWarnings, forKey: "cameraWarnings") } }
    /** Say so when driving over the posted limit. Off by default, like Vela. */
    @Published var speedingAlert: Bool { didSet { d.set(speedingAlert, forKey: "speedingAlert") } }
    /** The map's "P" button: save where you parked, and find the way back. */
    @Published var parkingButton: Bool { didSet { d.set(parkingButton, forKey: "parkingButton") } }
    @Published var home: Place? { didSet { save(home, "home") } }
    @Published var work: Place? { didSet { save(work, "work") } }
    /** Where the car is parked, with when in `statusText`. */
    @Published var parking: Place? { didSet { save(parking, "parking") } }
    /** The first-run choice between Google's data and open data only has been made. */
    @Published var welcomed: Bool { didSet { d.set(welcomed, forKey: "welcomed") } }
    @Published var defaultMode: TravelMode { didSet { d.set(defaultMode.rawValue, forKey: "defaultMode") } }
    @Published var saved: [Place] { didSet { save(saved, "saved") } }
    @Published var recents: [String] { didSet { d.set(recents, forKey: "recents") } }
    /** Places you opened lately, newest first. */
    @Published var recentPlaces: [Place] { didSet { save(recentPlaces, "recentPlaces") } }

    private init() {
        theme = ThemeMode(rawValue: d.string(forKey: "theme") ?? "") ?? .system
        units = UnitsMode(rawValue: d.string(forKey: "units") ?? "") ?? .auto
        voice = d.object(forKey: "voice") as? Bool ?? true
        traffic = d.object(forKey: "traffic") as? Bool ?? false
        satellite = d.bool(forKey: "satellite")
        terrain = d.bool(forKey: "terrain")
        transitLines = d.bool(forKey: "transitLines")
        avoidTolls = d.bool(forKey: "avoidTolls")
        avoidHighways = d.bool(forKey: "avoidHighways")
        noGoogle = d.bool(forKey: "noGoogle")
        speedCameras = d.object(forKey: "speedCameras") as? Bool ?? true
        plateCameras = d.object(forKey: "plateCameras") as? Bool ?? true
        cameraWarnings = d.bool(forKey: "cameraWarnings")
        speedingAlert = d.bool(forKey: "speedingAlert")
        parkingButton = d.object(forKey: "parkingButton") as? Bool ?? true
        home = d.data(forKey: "home").flatMap { try? JSONDecoder().decode(Place.self, from: $0) }
        work = d.data(forKey: "work").flatMap { try? JSONDecoder().decode(Place.self, from: $0) }
        parking = d.data(forKey: "parking").flatMap { try? JSONDecoder().decode(Place.self, from: $0) }
        welcomed = d.bool(forKey: "welcomed") || d.object(forKey: "saved") != nil
        defaultMode = TravelMode(rawValue: d.integer(forKey: "defaultMode")) ?? .drive
        saved = (d.data(forKey: "saved")).flatMap { try? JSONDecoder().decode([Place].self, from: $0) } ?? []
        recents = d.stringArray(forKey: "recents") ?? []
        recentPlaces = d.data(forKey: "recentPlaces").flatMap { try? JSONDecoder().decode([Place].self, from: $0) } ?? []
    }

    private func save<T: Encodable>(_ v: T, _ key: String) {
        if let data = try? JSONEncoder().encode(v) { d.set(data, forKey: key) }
    }

    var colorScheme: ColorScheme? {
        switch theme {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    func isSaved(_ p: Place) -> Bool { saved.contains { $0.id == p.id } }

    func toggleSaved(_ p: Place) {
        if let i = saved.firstIndex(where: { $0.id == p.id }) { saved.remove(at: i) } else { saved.insert(p, at: 0) }
    }

    func renameSaved(_ id: String, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let i = saved.firstIndex(where: { $0.id == id }) else { return }
        saved[i].name = n
    }

    func addRecentPlace(_ p: Place) {
        guard !p.id.hasPrefix("pin:"), !p.id.hasPrefix("link:"), !p.id.hasPrefix("parking"), !p.id.hasPrefix("tap:"), !p.id.hasPrefix("demo") else { return }
        var slim = p
        slim.distanceMeters = nil
        slim.photoUrls = Array(p.photoUrls.prefix(1))
        slim.about = []
        slim.featuredReview = nil
        var r = recentPlaces.filter { $0.id != p.id && $0.name != p.name }
        r.insert(slim, at: 0)
        recentPlaces = Array(r.prefix(15))
    }

    func addRecent(_ q: String) {
        var r = recents.filter { $0.caseInsensitiveCompare(q) != .orderedSame }
        r.insert(q, at: 0)
        recents = Array(r.prefix(12))
    }
}

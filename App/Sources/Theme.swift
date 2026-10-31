import SwiftUI
import UIKit
import VelaCore

/**
 * Kite's colors: a deep navy night look with one bright teal for "go" (the Android app's
 * names are kept so older code reads the same). Sized and colored for a phone in a car holder.
 */
enum Vela {
    static let teal = Color(hex: 0x0F766E)
    static let tealLight = Color(hex: 0x2DD4BF)
    static let routeBlue = Color(hex: 0x2F7BFF)
    /** The driving banner: deep teal, with a darker band for the lanes. */
    static let navGreen = Color(hex: 0x0F766E)
    static let navBand = Color(hex: 0x0B4F49)
    static let open = Color(hex: 0x16A34A)
    static let openDark = Color(hex: 0x4ADE80)
    static let closed = Color(hex: 0xDC2626)
    static let closedDark = Color(hex: 0xF87171)
    static let star = Color(hex: 0xF9AB00)
    /** Speed cameras: loud orange, so a glance is enough. */
    static let camera = Color(hex: 0xFF8A00)
    static let police = Color(hex: 0x2F7BFF)

    /** The filled "Go" color: bright teal with dark text, day and night. */
    static func accent(_ scheme: ColorScheme) -> Color { scheme == .dark ? tealLight : Color(hex: 0x14B8A6) }
    static func onAccent(_ scheme: ColorScheme) -> Color { Color(hex: 0x04241F) }
    /** Teal for text and icons on the page (darker by day so it reads on white). */
    static func accentText(_ scheme: ColorScheme) -> Color { scheme == .dark ? tealLight : teal }
    static func sheet(_ scheme: ColorScheme) -> Color { scheme == .dark ? Color(hex: 0x151F30) : .white }
    /** Cards, buttons and tiles floating on the map. */
    static func surface(_ scheme: ColorScheme) -> Color { scheme == .dark ? Color(hex: 0x1A2638) : .white }
    /** Behind whole pages (Saved, Settings). */
    static func ground(_ scheme: ColorScheme) -> Color { scheme == .dark ? Color(hex: 0x0E1726) : Color(hex: 0xF2F5F9) }
    static func chip(_ scheme: ColorScheme) -> Color { scheme == .dark ? Color(hex: 0x243349) : Color(hex: 0xEDF1F6) }
    static func tonal(_ scheme: ColorScheme) -> Color { scheme == .dark ? Color(hex: 0x12403C) : Color(hex: 0xCCFBF1) }
    static func onTonal(_ scheme: ColorScheme) -> Color { scheme == .dark ? Color(hex: 0x99F6E4) : Color(hex: 0x134E4A) }
    static func muted(_ scheme: ColorScheme) -> Color { scheme == .dark ? Color(hex: 0x94A3B8) : Color(hex: 0x64748B) }
}

/** Kite's type: rounded, and never smaller than a size that reads from a phone holder. */
struct KiteType: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.1, *) {
            content.fontDesign(.rounded).dynamicTypeSize(.xLarge...)
        } else {
            content.dynamicTypeSize(.xLarge...)
        }
    }
}

/** A settings-style list on Kite's own ground colour, with the taller rows. */
struct KiteList: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(Vela.ground(scheme))
            .environment(\.defaultMinListRowHeight, 56)
            .tint(Vela.accentText(scheme))
    }
}

extension View {
    func kiteType() -> some View { modifier(KiteType()) }
    func kiteList() -> some View { modifier(KiteList()) }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

enum Fmt {
    static var metric: Bool {
        switch AppSettings.shared.units {
        case .metric: return true
        case .imperial, .yards: return false
        case .auto: return Locale.current.measurementSystem == .metric
        }
    }

    /** Short distances in yards, the British way. */
    static var yards: Bool {
        switch AppSettings.shared.units {
        case .yards: return true
        case .auto: return Locale.current.measurementSystem == .uk
        default: return false
        }
    }

    static func distance(_ m: Double) -> String {
        if metric {
            if m < 950 { return "\(Int((m / 10).rounded()) * 10) m" }
            return m < 9_950 ? String(format: "%.1f km", m / 1000) : "\(Int((m / 1000).rounded())) km"
        }
        if yards {
            let yd = m * 1.09361
            if yd < 500 { return "\(max(Int((yd / 10).rounded()) * 10, 10)) yd" }
        } else {
            let ft = m * 3.28084
            if ft < 1000 { return "\(max(Int((ft / 50).rounded()) * 50, 50)) ft" }
        }
        let mi = m / 1609.344
        return mi < 9.95 ? String(format: "%.1f mi", mi) : "\(Int(mi.rounded())) mi"
    }

    /** Words for the voice: "400 feet", "1.2 miles". */
    static func spokenDistance(_ m: Double) -> String {
        if metric {
            if m < 950 { return "\(Int((m / 50).rounded()) * 50) meters" }
            let km = m / 1000
            return km < 1.05 ? "1 kilometer" : String(format: "%.1f kilometers", km)
        }
        if yards {
            let yd = m * 1.09361
            if yd < 500 { return "\(max(Int((yd / 50).rounded()) * 50, 50)) yards" }
        } else {
            let ft = m * 3.28084
            if ft < 1000 { return "\(max(Int((ft / 100).rounded()) * 100, 100)) feet" }
        }
        let mi = m / 1609.344
        // The way people say it: "a quarter of a mile" in Britain, "a quarter mile" in America.
        if mi < 0.3 { return yards ? "a quarter of a mile" : "a quarter mile" }
        if mi < 0.6 { return "half a mile" }
        if mi < 0.9 { return "three quarters of a mile" }
        return mi < 1.05 ? "1 mile" : String(format: "%.1f miles", mi)
    }

    /** A limit for the voice: "30 miles per hour" (to the posted 5), "50 kilometers per hour". */
    static func spokenSpeed(_ kmh: Double) -> String {
        if metric { return "\(Int((kmh / 5).rounded()) * 5) kilometers per hour" }
        return "\(Int((kmh / 1.609344 / 5).rounded()) * 5) miles per hour"
    }

    /** A speed in the user's units, without the unit. */
    static func speed(_ kmh: Double) -> Int {
        Int((metric ? kmh : kmh / 1.609344).rounded())
    }

    static var speedUnit: String { metric ? "km/h" : "mph" }

    static func duration(_ s: Double) -> String {
        let mins = max(1, Int((s / 60).rounded()))
        if mins < 60 { return "\(mins) min" }
        let h = mins / 60, m = mins % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    /** "2h 18m": the same, shorter, for the travel mode tabs where four have to fit side by side. */
    static func shortDuration(_ s: Double) -> String {
        let mins = max(1, Int((s / 60).rounded()))
        if mins < 60 { return "\(mins) min" }
        let h = mins / 60, m = mins % 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    static func arrival(_ s: Double) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        return f.string(from: Date().addingTimeInterval(s))
    }
}

func statusColor(_ p: Place, _ scheme: ColorScheme) -> Color {
    if p.permanentlyClosed { return scheme == .dark ? Vela.closedDark : Vela.closed }
    switch p.openNow {
    case true?: return scheme == .dark ? Vela.openDark : Vela.open
    case false?: return scheme == .dark ? Vela.closedDark : Vela.closed
    default: return .secondary
    }
}

/** "Open" in green, then "· Closes 9:30 PM" in gray, the way Vela splits Google's status. */
struct StatusText: View {
    let place: Place
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if place.permanentlyClosed {
            Text("Permanently closed").foregroundColor(statusColor(place, scheme))
        } else if let s = place.statusText {
            let parts = s.components(separatedBy: " · ")
            (Text(parts[0]).foregroundColor(statusColor(place, scheme))
                + Text(parts.count > 1 ? " · " + parts.dropFirst().joined(separator: " · ") : "").foregroundColor(.secondary))
        }
    }
}

struct Stars: View {
    let rating: Double

    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<5, id: \.self) { i in
                let fill = rating - Double(i)
                Image(systemName: fill >= 0.75 ? "star.fill" : (fill >= 0.25 ? "star.leadinghalf.filled" : "star"))
                    .font(.system(size: 11))
                    .foregroundColor(Vela.star)
            }
        }
    }
}

/** "4.7 ★★★★★ (1,341) · 0.2 mi · Sushi restaurant · $10–20" */
struct PlaceMetaLine: View {
    let place: Place
    var showStars = true
    /** Where the user is now: the distance is worked out from here, not from where the search was made. */
    var here: LatLng? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let r = place.rating {
                Text(String(format: "%.1f", r)).foregroundColor(.primary)
                if showStars { Stars(rating: r) } else {
                    Image(systemName: "star.fill").font(.system(size: 10)).foregroundColor(Vela.star)
                }
                if let n = place.reviewCount { Text("(\(n.formatted()))") }
            }
            // After driving there, the search's "11 mi" would be stale.
            let meters = here.map { $0.distance(to: place.location) } ?? place.distanceMeters
            let rest = [meters.map(Fmt.distance), place.category, place.priceText].compactMap { $0 }
            if !rest.isEmpty {
                Text((place.rating != nil ? "· " : "") + rest.joined(separator: " · ")).lineLimit(1)
            }
        }
        .font(.subheadline)
        .foregroundColor(.secondary)
    }
}

/** Arrow for a maneuver, from SF Symbols. */
func maneuverSymbol(_ t: ManeuverType) -> String {
    switch t {
    case .depart, .straight, .unknown: return "arrow.up"
    case .arrive: return "mappin.circle.fill"
    case .turnLeft: return "arrow.turn.up.left"
    case .turnRight: return "arrow.turn.up.right"
    case .slightLeft, .keepLeft, .rampLeft, .forkLeft: return "arrow.up.left"
    case .slightRight, .keepRight, .rampRight, .forkRight: return "arrow.up.right"
    case .sharpLeft: return "arrow.down.left"
    case .sharpRight: return "arrow.down.right"
    case .uturn: return "arrow.uturn.down"
    case .merge: return "arrow.triangle.merge"
    case .roundabout: return "arrow.triangle.2.circlepath"
    }
}

/**
 * Frosted glass for everything that floats over the map (buttons, the search bar, cards): the
 * map shows through, blurred, with a thin bright edge and a soft shadow, like iOS 26.
 */
struct Glass<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background(
                shape.fill(.ultraThinMaterial)
                    .overlay(shape.fill(Vela.surface(scheme).opacity(scheme == .dark ? 0.86 : 0.88)))
                    .overlay(shape.stroke(Color.white.opacity(scheme == .dark ? 0.08 : 0.5), lineWidth: 0.75))
                    .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.16), radius: 12, y: 5)
            )
    }
}

extension View {
    func glass<S: Shape>(_ shape: S) -> some View { modifier(Glass(shape: shape)) }
}

/** Round buttons floating on the map (layers, location, compass). */
struct MapFab: View {
    let icon: String
    var tint: Color = .primary
    var size: CGFloat = 56
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: size, height: size)
                .glass(Circle())
        }
        .buttonStyle(.plain)
    }
}

/** Pill buttons in sheets: filled teal for the main one, tonal for the rest. */
struct PillButton: View {
    let title: String
    let icon: String
    var filled = false
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 17, weight: .bold))
                Text(title).font(.body.weight(.bold))
            }
            .padding(.horizontal, 20)
            .frame(height: 52)
            .foregroundColor(filled ? Vela.onAccent(scheme) : Vela.onTonal(scheme))
            .background(Capsule().fill(filled ? Vela.accent(scheme) : Vela.tonal(scheme)))
        }
        .buttonStyle(.plain)
    }
}

struct CircleIconButton: View {
    let icon: String
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(.primary)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Vela.chip(scheme)))
        }
        .buttonStyle(.plain)
    }
}

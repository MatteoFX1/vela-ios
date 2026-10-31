import MapLibre
import UIKit
import VelaCore

/** The images Vela's map layers draw: category pins, the red picked pin, the puck, route bubbles. */
enum MapIcons {
    struct Kind {
        let name: String
        let symbol: String
        let color: UInt32
        let words: [String]
    }

    static let kinds: [Kind] = [
        Kind(name: "cat-coffee", symbol: "cup.and.saucer.fill", color: 0xE8710A, words: ["coffee", "cafe", "café", "bakery", "tea", "donut"]),
        Kind(name: "cat-food", symbol: "fork.knife", color: 0xE8453C, words: ["restaurant", "food", "pizza", "sushi", "burger", "grill", "bar", "pub", "diner", "taco", "bistro", "steak", "ramen", "noodle", "kitchen", "eatery", "sandwich", "chicken"]),
        Kind(name: "cat-gas", symbol: "fuelpump.fill", color: 0x1A73E8, words: ["gas", "fuel", "petrol", "charging"]),
        Kind(name: "cat-shop", symbol: "cart.fill", color: 0x1A73E8, words: ["grocery", "supermarket", "store", "shop", "market", "mall", "pharmacy", "drugstore"]),
        Kind(name: "cat-hotel", symbol: "bed.double.fill", color: 0xD01884, words: ["hotel", "motel", "inn", "lodging", "hostel", "resort"]),
        Kind(name: "cat-park", symbol: "leaf.fill", color: 0x188038, words: ["park", "garden", "trail", "playground", "beach"]),
        Kind(name: "cat-health", symbol: "cross.case.fill", color: 0xC5221F, words: ["hospital", "clinic", "doctor", "dentist", "medical", "urgent"]),
        Kind(name: "cat-transit", symbol: "tram.fill", color: 0x12B5A5, words: ["station", "bus", "subway", "metro", "train", "airport"]),
        Kind(name: "cat-money", symbol: "banknote.fill", color: 0x5F6368, words: ["atm", "bank"]),
        Kind(name: "cat-parking", symbol: "parkingsign", color: 0x1A73E8, words: ["parking", "garage"]),
    ]

    static func iconName(for p: Place) -> String {
        let c = (p.category ?? "").lowercased()
        return kinds.first { k in k.words.contains { c.contains($0) } }?.name ?? "cat-default"
    }

    static func register(in style: MLNStyle) {
        for k in kinds { style.setImage(dot(k.symbol, UIColor(hex: k.color)), forName: k.name) }
        style.setImage(dot("mappin", UIColor(hex: 0xE8453C)), forName: "cat-default")
        style.setImage(selectedPin(), forName: "pin-selected")
        style.setImage(originDot(), forName: "pin-origin")
        style.setImage(puck(dark: true), forName: "puck")
        style.setImage(bubble(fill: UIColor(hex: 0x0F766E), stroke: .white), forName: "bubble-sel")
        style.setImage(bubble(fill: .white, stroke: UIColor(hex: 0xBDC1C6)), forName: "bubble-alt")
        style.setImage(speedCamera(), forName: "cam-speed")
        style.setImage(plateCamera(), forName: "cam-plate")
        style.setImage(surveillanceCamera(), forName: "cam-surveillance")
        style.setImage(trafficLight(), forName: "traffic-light")
        for k in WazeAlert.Kind.allCases { style.setImage(waze(k), forName: "waze-\(k.rawValue)") }
        style.setImage(turnHead(), forName: "turn-head")
        style.setImage(routeChevron(), forName: "route-chevron")
        style.setImage(dot("smallcircle.filled.circle", UIColor(hex: 0x5F6368)), forName: "pin-stop")
        // My places: home, work, the parked car and saved places.
        style.setImage(dot("house.fill", UIColor(hex: 0x1A73E8)), forName: "mine-home")
        style.setImage(dot("briefcase.fill", UIColor(hex: 0x8D6E63)), forName: "mine-work")
        style.setImage(dot("parkingsign", UIColor(hex: 0x1967D2)), forName: "mine-parking")
        style.setImage(dot("bookmark.fill", UIColor(hex: 0x0F9D58)), forName: "mine-saved")
    }

    /** Vela's speed camera badge: amber rounded square, head-on camera with a big lens and flash slit. */
    /** The head of the turn arrow drawn on the road: chunky white with a dark teal edge and a soft shadow, pointing up. */
    static func turnHead() -> UIImage {
        let size = CGSize(width: 44, height: 40)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let p = UIBezierPath()
            p.move(to: CGPoint(x: 22, y: 6))
            p.addLine(to: CGPoint(x: 38, y: 32))
            p.addLine(to: CGPoint(x: 6, y: 32))
            p.close()
            p.lineJoinStyle = .round
            ctx.cgContext.setShadow(offset: CGSize(width: 0, height: 2), blur: 3, color: UIColor.black.withAlphaComponent(0.4).cgColor)
            UIColor(hex: 0x0F766E).setStroke()
            p.lineWidth = 8
            p.stroke()
            ctx.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
            UIColor.white.setFill()
            UIColor.white.setStroke()
            p.lineWidth = 2.5
            p.fill()
            p.stroke()
        }
    }

    static func speedCamera() -> UIImage {
        badge(UIColor(hex: 0xEF6C00)) { amber in
            UIColor.white.setFill()
            UIBezierPath(roundedRect: CGRect(x: 15, y: 12, width: 16, height: 20), cornerRadius: 3).fill()
            amber.setFill()
            UIBezierPath(ovalIn: CGRect(x: 23 - 4.6, y: 20 - 4.6, width: 9.2, height: 9.2)).fill()
            UIColor.white.setFill()
            UIBezierPath(ovalIn: CGRect(x: 21, y: 18, width: 4, height: 4)).fill()
            amber.setFill()
            UIBezierPath(rect: CGRect(x: 18, y: 26.5, width: 10, height: 3)).fill()
        }
    }

    /** A small traffic light, like Waze's: a dark upright box with red, amber and green lamps. */
    static func trafficLight() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 14, height: 30)).image { _ in
            UIColor.white.setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: 14, height: 30), cornerRadius: 5).fill()
            UIColor(hex: 0x263238).setFill()
            UIBezierPath(roundedRect: CGRect(x: 1.5, y: 1.5, width: 11, height: 27), cornerRadius: 4).fill()
            for (i, c) in [0xFF3B30, 0xFFB300, 0x34C759].enumerated() {
                UIColor(hex: UInt32(c)).setFill()
                UIBezierPath(ovalIn: CGRect(x: 3.5, y: 3.5 + CGFloat(i) * 8, width: 7, height: 7)).fill()
            }
        }
    }

    /** Vela's plate reader badge: purple rounded square with a CCTV camera on a mount. */
    static func plateCamera() -> UIImage {
        badge(UIColor(hex: 0x7B1FA2)) { purple in
            UIColor.white.setFill()
            UIBezierPath(roundedRect: CGRect(x: 12, y: 18, width: 18, height: 9), cornerRadius: 2).fill()
            UIBezierPath(ovalIn: CGRect(x: 31 - 4.2, y: 22.5 - 4.2, width: 8.4, height: 8.4)).fill()
            purple.setFill()
            UIBezierPath(ovalIn: CGRect(x: 29, y: 20.5, width: 4, height: 4)).fill()
            let arm = UIBezierPath()
            arm.move(to: CGPoint(x: 17, y: 18)); arm.addLine(to: CGPoint(x: 17, y: 12))
            arm.move(to: CGPoint(x: 12, y: 12)); arm.addLine(to: CGPoint(x: 24, y: 12))
            arm.lineWidth = 2.4
            UIColor.white.setStroke()
            arm.stroke()
        }
    }

    static func surveillanceCamera() -> UIImage {
        badge(UIColor(hex: 0x22863A)) { _ in
            draw("video.fill", in: CGRect(x: 12, y: 12, width: 22, height: 22), color: .white)
        }
    }

    /** Waze report badges, in Waze's own colors: blue police, red crashes, amber hazards… */
    static func waze(_ k: WazeAlert.Kind) -> UIImage {
        let symbol: String
        switch k {
        case .police: symbol = "shield.fill"
        case .accident: symbol = "burst.fill"
        case .hazard: symbol = "exclamationmark.triangle.fill"
        case .weather: symbol = "cloud.fog.fill"
        case .roadworks: symbol = "wrench.and.screwdriver.fill"
        case .closure: symbol = "nosign"
        case .jam: symbol = "car.2.fill"
        }
        return badge(wazeColor(k)) { _ in
            draw(symbol, in: CGRect(x: 12, y: 12, width: 22, height: 22), color: .white)
        }
    }

    static func wazeColor(_ k: WazeAlert.Kind) -> UIColor {
        switch k {
        case .police: return UIColor(hex: 0x1E88E5)
        case .accident, .jam: return UIColor(hex: 0xD93025)
        case .hazard: return UIColor(hex: 0xF29900)
        case .weather: return UIColor(hex: 0x00897B)
        case .roadworks: return UIColor(hex: 0xE8710A)
        case .closure: return UIColor(hex: 0xB71C1C)
        }
    }

    /** A 46-unit badge drawn at 34 points (sharp when the map scales it up): white rim, colored field, then the glyph. */
    private static func badge(_ color: UIColor, glyph: (UIColor) -> Void) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 34.5, height: 34.5)).image { ctx in
            ctx.cgContext.scaleBy(x: 0.75, y: 0.75)
            UIColor.white.setFill()
            UIBezierPath(roundedRect: CGRect(x: 2, y: 2, width: 42, height: 42), cornerRadius: 11).fill()
            color.setFill()
            UIBezierPath(roundedRect: CGRect(x: 4.5, y: 4.5, width: 37, height: 37), cornerRadius: 9).fill()
            glyph(color)
        }
    }

    private static func dot(_ symbol: String, _ color: UIColor) -> UIImage {
        let size = CGSize(width: 28, height: 28)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let r = CGRect(origin: .zero, size: size).insetBy(dx: 1.5, dy: 1.5)
            color.setFill()
            UIColor.white.setStroke()
            let path = UIBezierPath(ovalIn: r)
            path.lineWidth = 2
            path.fill()
            path.stroke()
            draw(symbol, in: r.insetBy(dx: 6, dy: 6), color: .white)
            _ = ctx
        }
    }

    private static func draw(_ symbol: String, in r: CGRect, color: UIColor) {
        let cfg = UIImage.SymbolConfiguration(pointSize: r.height, weight: .semibold)
        guard let img = UIImage(systemName: symbol, withConfiguration: cfg)?.withTintColor(color, renderingMode: .alwaysOriginal) else { return }
        let s = img.size
        let scale = min(r.width / s.width, r.height / s.height)
        let w = s.width * scale, h = s.height * scale
        img.draw(in: CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h))
    }

    private static func selectedPin() -> UIImage {
        let size = CGSize(width: 34, height: 46)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let red = UIColor(hex: 0xEA4335)
            let head = CGRect(x: 2, y: 2, width: 30, height: 30)
            let p = UIBezierPath()
            p.move(to: CGPoint(x: 17, y: 44))
            p.addCurve(to: CGPoint(x: 3.5, y: 23), controlPoint1: CGPoint(x: 13, y: 37), controlPoint2: CGPoint(x: 6, y: 29))
            p.addArc(withCenter: CGPoint(x: head.midX, y: head.midY), radius: 15, startAngle: .pi * 0.86, endAngle: .pi * 0.14, clockwise: true)
            p.addCurve(to: CGPoint(x: 17, y: 44), controlPoint1: CGPoint(x: 28, y: 29), controlPoint2: CGPoint(x: 21, y: 37))
            p.close()
            red.setFill()
            UIColor(hex: 0xA50E0E).setStroke()
            p.lineWidth = 1.5
            p.fill()
            p.stroke()
            UIColor(hex: 0x7A0B0B).setFill()
            UIBezierPath(ovalIn: CGRect(x: 12, y: 12, width: 10, height: 10)).fill()
        }
    }

    private static func originDot() -> UIImage {
        let size = CGSize(width: 22, height: 22)
        return UIGraphicsImageRenderer(size: size).image { _ in
            UIColor.white.setFill()
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)).fill()
            UIColor(hex: 0x14B8A6).setStroke()
            let ring = UIBezierPath(ovalIn: CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4))
            ring.lineWidth = 4
            ring.stroke()
        }
    }

    /**
     * The car while navigating, Waze-style in Kite's teal: a chunky teal arrow with a white rim and a
     * darker right half so it reads as raised, sitting on a disc with a teal ring (navy at night,
     * white by day).
     */
    static func puck(dark: Bool) -> UIImage {
        let size = CGSize(width: 76, height: 76)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let g = ctx.cgContext
            let disc = UIBezierPath(ovalIn: CGRect(x: 6, y: 6, width: 64, height: 64))
            (dark ? UIColor(hex: 0x0F172A, alpha: 0.6) : UIColor(white: 1, alpha: 0.75)).setFill()
            disc.fill()
            UIColor(hex: 0x2DD4BF, alpha: 0.75).setStroke()
            disc.lineWidth = 2.5
            disc.stroke()
            let tip = CGPoint(x: 38, y: 13), left = CGPoint(x: 18, y: 60), right = CGPoint(x: 58, y: 60), notch = CGPoint(x: 38, y: 50)
            let outline = UIBezierPath()
            outline.move(to: tip); outline.addLine(to: right); outline.addLine(to: notch); outline.addLine(to: left); outline.close()
            outline.lineJoinStyle = .round
            g.setShadow(offset: CGSize(width: 0, height: 2), blur: 4, color: UIColor.black.withAlphaComponent(0.45).cgColor)
            UIColor.white.setStroke()
            outline.lineWidth = 5
            outline.stroke()
            g.setShadow(offset: .zero, blur: 0, color: nil)
            g.saveGState()
            outline.addClip()
            let space = CGColorSpaceCreateDeviceRGB()
            if let grad = CGGradient(colorsSpace: space, colors: [UIColor(hex: 0x99F6E4).cgColor, UIColor(hex: 0x0D9488).cgColor] as CFArray, locations: [0, 1]) {
                g.drawLinearGradient(grad, start: tip, end: CGPoint(x: 52, y: 60), options: [])
            }
            // The right half a shade darker.
            UIColor(hex: 0x064E3B, alpha: 0.3).setFill()
            let shade = UIBezierPath()
            shade.move(to: tip); shade.addLine(to: right); shade.addLine(to: notch); shade.close()
            shade.fill()
            g.restoreGState()
        }
    }

    /** A chevron along the route line, pointing the way you go (right, along the line). */
    static func routeChevron() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 14, height: 16)).image { _ in
            let p = UIBezierPath()
            p.move(to: CGPoint(x: 4, y: 3)); p.addLine(to: CGPoint(x: 10, y: 8)); p.addLine(to: CGPoint(x: 4, y: 13))
            p.lineWidth = 3
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            UIColor(hex: 0x0B3B36).setStroke()
            p.stroke()
        }
    }

    private static func bubble(fill: UIColor, stroke: UIColor) -> UIImage {
        // A pill, like the rest of Kite's chips.
        let size = CGSize(width: 30, height: 26)
        let img = UIGraphicsImageRenderer(size: size).image { _ in
            let p = UIBezierPath(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1), cornerRadius: 12)
            fill.setFill()
            stroke.setStroke()
            p.lineWidth = 1.5
            p.fill()
            p.stroke()
        }
        return img.resizableImage(withCapInsets: UIEdgeInsets(top: 12, left: 13, bottom: 12, right: 13), resizingMode: .stretch)
    }
}

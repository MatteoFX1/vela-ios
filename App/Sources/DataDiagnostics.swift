import Foundation
import SwiftUI
import UIKit
import VelaCore

/**
 * "Share diagnostics": checks that the services Kite leans on answer, and packs the results
 * (plus, if you choose, a picture of the map) into a ZIP you can send with a bug report.
 * Adapted from Ausbloke's Kite fork (github.com/NotDiscordOfficial/kite-maps), GPL-3.0.
 * Tests use a fixed spot in central London, never your position.
 */
@MainActor
final class DataDiagnostics: ObservableObject {
    @Published var running = false
    @Published var status = "Ready"
    @Published var report: URL?

    func run(model: AppModel, includeMap: Bool) {
        guard !running else { return }
        running = true; report = nil; status = "Testing…"
        let mapImage: Data? = {
            guard includeMap, let map = model.map, map.bounds.width > 0, map.bounds.height > 0 else { return nil }
            return UIGraphicsImageRenderer(bounds: map.bounds).image { _ in
                map.drawHierarchy(in: map.bounds, afterScreenUpdates: true)
            }.pngData()
        }()
        let s = model.settings
        let info = Bundle.main.infoDictionary
        Task {
            var entries: [DiagnosticZip.Entry] = []
            var lines = [
                "Kite diagnostics",
                "Created (UTC): \(ISO8601DateFormatter().string(from: Date()))",
                "Kite: \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))",
                "App ID: \(Bundle.main.bundleIdentifier ?? "?")",
                "iOS: \(UIDevice.current.systemVersion), \(Self.deviceModel())",
                "Location allowed: \(model.location.authorized), precise: \(!model.location.reducedAccuracy)",
                "GPS accuracy now: \(model.location.last.map { "\(Int($0.horizontalAccuracy)) m" } ?? "no fix")",
                "Road alerts: \(s.wazeOn), on map: \(s.wazeOnMap), heat map: \(s.wazeHeatmap), no Google: \(s.noGoogle)",
                "Speed cameras: \(s.speedCameras), plate cameras: \(s.plateCameras), surveillance: \(s.surveillanceCameras)",
                "Navigating: \(model.nav != nil)",
                "Map picture included: \(mapImage != nil) (it can show where you are).",
                "No GPS position, searches, saved places or accounts are in this file.",
                "",
                "Service tests (fixed box in central London):",
            ]
            if let mapImage { entries.append(.init(name: "map.png", data: mapImage)) }

            func timed<T>(_ name: String, _ work: () async -> T?, describe: (T) -> String) async {
                status = "Testing \(name)…"
                let t0 = Date()
                let result = await work()
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                lines.append("\(name): " + (result.map(describe) ?? "FAILED") + ", \(ms) ms")
            }
            await timed("Waze live map", { await Waze.alerts(south: 51.49, west: -0.15, north: 51.53, east: -0.08) }) {
                "\($0.count) reports"
            }
            await timed("Speed cameras (OpenStreetMap)", {
                await Overpass.cameras(south: 51.49, west: -0.15, north: 51.53, east: -0.08, speed: true, plate: true)
            }) { "\($0.count) cameras" }

            entries.insert(.init(name: "diagnostics.txt", data: Data(lines.joined(separator: "\n").utf8)), at: 0)
            do {
                let zip = try DiagnosticZip.archive(entries)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("Kite-diagnostics.zip")
                try zip.write(to: url, options: .atomic)
                report = url
                status = "Ready to share."
            } catch {
                status = "Couldn't make the file: \(error.localizedDescription)"
            }
            running = false
        }
    }

    private static func deviceModel() -> String {
        var sys = utsname()
        uname(&sys)
        return withUnsafeBytes(of: &sys.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

struct DataDiagnosticsView: View {
    @ObservedObject var model: AppModel
    @StateObject private var diagnostics = DataDiagnostics()
    @State private var includeMap = false

    var body: some View {
        Form {
            Section {
                Toggle("Include a picture of the map", isOn: $includeMap)
                Button(diagnostics.running ? "Testing…" : "Run tests") {
                    diagnostics.run(model: model, includeMap: includeMap)
                }
                .disabled(diagnostics.running)
                Text(diagnostics.status).font(.footnote).foregroundColor(.secondary)
                if let report = diagnostics.report {
                    ShareLink(item: report) { Label("Share diagnostics", systemImage: "square.and.arrow.up") }
                }
            } footer: {
                Text("Checks that Waze and OpenStreetMap answer, and puts that with your Kite version, iPhone model and settings into a small file to send with a bug report. Nothing is sent until you share it. The map picture can show where you are, so leave it off unless it helps.")
            }
        }
        .kiteList()
        .navigationTitle("Diagnostics")
    }
}

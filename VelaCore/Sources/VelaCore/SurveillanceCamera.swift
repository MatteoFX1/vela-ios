import Foundation

/// OpenStreetMap surveillance cameras. Generic CCTV is not necessarily an ALPR.
public struct SurveillanceCamera: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let location: LatLng
    public let isALPR: Bool
    public let operatorName: String?
    public let manufacturer: String?
    public let direction: String?
    public let surveillance: String?
    public let mount: String?
}

public enum SurveillanceCameras {
    public static func query(south: Double, west: Double, north: Double, east: Double) -> String {
        let box = String(format: "(%.5f,%.5f,%.5f,%.5f)", south, west, north, east)
        return "[out:json][timeout:25];(node[\"man_made\"=\"surveillance\"]\(box);node[\"surveillance:type\"=\"ALPR\"]\(box););out body 4000;"
    }

    public static func parse(_ data: Data) -> [SurveillanceCamera]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = root["elements"] as? [[String: Any]] else { return nil }
        var seen = Set<Int64>()
        return elements.compactMap { element in
            guard let id = (element["id"] as? NSNumber)?.int64Value,
                  let lat = element["lat"] as? Double, let lon = element["lon"] as? Double,
                  (-90...90).contains(lat), (-180...180).contains(lon), seen.insert(id).inserted else { return nil }
            let tags = element["tags"] as? [String: String] ?? [:]
            let alpr = tags["surveillance:type"]?.uppercased() == "ALPR"
            guard alpr || tags["man_made"] == "surveillance" else { return nil }
            return SurveillanceCamera(id: id, location: LatLng(lat, lon), isALPR: alpr,
                                      operatorName: tags["operator"], manufacturer: tags["manufacturer"],
                                      direction: tags["camera:direction"], surveillance: tags["surveillance"], mount: tags["camera:mount"])
        }
    }

    public static func inBox(south: Double, west: Double, north: Double, east: Double) async -> [SurveillanceCamera]? {
        let q = query(south: south, west: west, north: north, east: east)
        return await Overpass.firstAnswer(q) { parse($0) != nil }.flatMap(parse)
    }
}

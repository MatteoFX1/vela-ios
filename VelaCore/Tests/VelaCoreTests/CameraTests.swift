import XCTest
@testable import VelaCore

final class CameraTests: XCTestCase {
    func testParse() {
        let json = #"{"elements":[{"type":"node","id":1,"lat":48.1,"lon":11.5,"tags":{"highway":"speed_camera"}},{"type":"node","id":2,"lat":38.5,"lon":-121.7,"tags":{"surveillance:type":"ALPR","manufacturer":"Flock Safety"}},{"type":"node","id":3}]}"#
        let cams = Overpass.parse(Data(json.utf8))
        XCTAssertEqual(cams?.count, 2)
        XCTAssertEqual(cams?[0].kind, .speed)
        XCTAssertEqual(cams?[1].kind, .plate)
        XCTAssertEqual(cams?[1].operatorName, "Flock Safety")
    }

    func testTrafficLights() {
        // A junction's lights mapped on two roads into it, one by the route's other end, and one off to the side.
        let json = #"{"elements":[{"type":"node","id":1,"lat":0.0050,"lon":0.0001,"tags":{"highway":"traffic_signals"}},{"type":"node","id":2,"lat":0.0052,"lon":0,"tags":{"highway":"traffic_signals"}},{"type":"node","id":3,"lat":0.0095,"lon":0,"tags":{"highway":"traffic_signals"}},{"type":"node","id":4,"lat":0.003,"lon":0.002,"tags":{"highway":"traffic_signals"}},{"type":"node","id":5,"lat":0.004,"lon":0,"tags":{"highway":"speed_camera"}}]}"#
        let data = Data(json.utf8)
        // Lights are never taken for cameras.
        XCTAssertEqual(Overpass.parse(data)?.map(\.id), [5])
        let lights = Overpass.parseSignals(data)
        XCTAssertEqual(lights.count, 4)
        let line = [LatLng(0, 0), LatLng(0.01, 0)]
        let on = Overpass.signalsOnRoute(lights, line: line)
        XCTAssertEqual(on, [LatLng(0.0050, 0.0001), LatLng(0.0095, 0)])
    }

    func testQuery() {
        let q = Overpass.query(filter: "(1,2,3,4)", speed: true, plate: false)
        XCTAssertEqual(q, "[out:json][timeout:25];(node[\"highway\"=\"speed_camera\"](1,2,3,4););out body 4000;")
    }

    func testDue() {
        // At 20 m/s the lead is 240 m: the camera 200 m ahead is due, the one 400 m ahead is not yet.
        XCTAssertEqual(CameraAlerts.due(cameraMeters: [500, 700], traveled: 300, speedMps: 20, spoken: []), 0)
        XCTAssertNil(CameraAlerts.due(cameraMeters: [500, 700], traveled: 300, speedMps: 20, spoken: [0]))
        XCTAssertNil(CameraAlerts.due(cameraMeters: [500], traveled: 300, speedMps: 1, spoken: []))
        XCTAssertNil(CameraAlerts.due(cameraMeters: [200], traveled: 300, speedMps: 20, spoken: []))
    }

    func testProject() {
        let line = [LatLng(0, 0), LatLng(0.01, 0)]
        let on = RoadCamera(id: 1, kind: .speed, location: LatLng(0.005, 0.0001))
        let off = RoadCamera(id: 2, kind: .speed, location: LatLng(0.005, 0.01))
        let p = CameraAlerts.project([off, on], on: line)
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p[0].camera.id, 1)
        XCTAssertEqual(p[0].along, Geo.length(line) / 2, accuracy: 2)
    }

    func testMaxspeed() {
        XCTAssertEqual(Overpass.maxspeedKmh("50"), 50)
        XCTAssertEqual(Overpass.maxspeedKmh("30 mph") ?? 0, 48.28, accuracy: 0.01)
        XCTAssertNil(Overpass.maxspeedKmh("DE:urban"))
        XCTAssertNil(Overpass.maxspeedKmh("none"))
    }

    func testSpeedLimitsAlongRoute() {
        // Route north ~1,113 m; a 50 road covers the first half, a 30 road the rest, and a
        // crossing 80 road touches it at one point only.
        let route = [LatLng(0, 0), LatLng(0.01, 0)]
        let ways = [
            Overpass.LimitWay(kmh: 50, line: [LatLng(0, 0), LatLng(0.005, 0)]),
            Overpass.LimitWay(kmh: 30, line: [LatLng(0.005, 0), LatLng(0.01, 0)]),
            Overpass.LimitWay(kmh: 80, line: [LatLng(0.003, -0.01), LatLng(0.003, 0), LatLng(0.003, 0.01)]),
        ]
        let limits = Overpass.speedLimits(ways, on: route)
        XCTAssertEqual(limits.first?.kmh, 50)
        XCTAssertFalse(limits.contains { $0.kmh == 80 })
        var r = Route(mode: .drive, polyline: route, distanceMeters: 1113, typicalSeconds: 60, trafficSeconds: nil,
                      summary: nil, maneuvers: [], source: "osm")
        r.speedLimits = limits
        XCTAssertEqual(r.speedLimit(at: 200), 50)
        XCTAssertEqual(r.speedLimit(at: 900), 30)
    }

    func testBritishLimits() {
        XCTAssertEqual(Overpass.maxspeedKmh("national") ?? 0, 96.56, accuracy: 0.1)
        XCTAssertEqual(Overpass.maxspeedKmh("GB:nsl_dual") ?? 0, 112.65, accuracy: 0.1)
        XCTAssertEqual(Overpass.maxspeedKmh("20 mph") ?? 0, 32.19, accuracy: 0.1)
        XCTAssertTrue(Geo.drivesOnLeft(LatLng(51.5074, -0.1278)), "London")
        XCTAssertTrue(Geo.drivesOnLeft(LatLng(55.95, -3.19)), "Edinburgh")
        XCTAssertTrue(Geo.drivesOnLeft(LatLng(51.48, -3.18)), "Cardiff")
        XCTAssertFalse(Geo.drivesOnLeft(LatLng(48.85, 2.35)), "Paris")
        XCTAssertFalse(Geo.drivesOnLeft(LatLng(38.54, -121.74)), "Davis")
    }

    func testAverageZones() {
        // A straight road north; a relation whose start and end nodes sit 0.9 km apart on it.
        let line = [LatLng(51.0, -1.0), LatLng(51.02, -1.0)]
        let json = """
        {"elements":[{"type":"relation","tags":{"enforcement":"average_speed","maxspeed":"50 mph"},
          "members":[{"type":"node","lat":51.002,"lon":-1.0},{"type":"node","lat":51.0101,"lon":-1.0},
                     {"type":"node","lat":51.05,"lon":-1.2}]}]}
        """
        let z = Overpass.averageZones(Data(json.utf8), on: line)
        XCTAssertEqual(z.count, 1)
        XCTAssertEqual(z.first?.startMeters ?? 0, 222, accuracy: 5)
        XCTAssertEqual(z.first?.endMeters ?? 0, 1123, accuracy: 5)
        XCTAssertEqual(z.first?.kmh ?? 0, 80.47, accuracy: 0.1)
    }
}

final class AverageCameraTests: XCTestCase {
    func testZonesFromCameras() {
        func cam(_ id: Int64, avg: Bool) -> RoadCamera {
            RoadCamera(id: id, kind: .speed, location: LatLng(0, 0), maxspeedKmh: 96.56, average: avg)
        }
        let z = CameraAlerts.averageZones([(cam(1, avg: true), 1000), (cam(2, avg: false), 2000),
                                           (cam(3, avg: true), 6000), (cam(4, avg: true), 40000)])
        XCTAssertEqual(z.count, 1, "the far one is a lone camera, not a check")
        XCTAssertEqual(z.first?.startMeters, 1000)
        XCTAssertEqual(z.first?.endMeters, 6000)
        let m = CameraAlerts.merge(z, [AverageSpeedZone(startMeters: 5000, endMeters: 9000, kmh: nil)])
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m.first?.endMeters, 9000)
    }
}

final class PiecesTests: XCTestCase {
    func testLongRoutesAreCut() {
        // About 111 km due north in 1 km steps: three pieces of ~40 km, joined end to start.
        let line = (0...100).map { LatLng(Double($0) * 0.01, 0) }
        let p = Overpass.pieces(line, meters: 40_000)
        XCTAssertEqual(p.count, 3)
        XCTAssertEqual(p[0].last, p[1].first)
        XCTAssertEqual(p.last?.last, line.last)
    }
}

final class PostcodeTests: XCTestCase {
    func testPostcodes() {
        XCTAssertEqual(Postcodes.normalize("sw1a1aa"), "SW1A 1AA")
        XCTAssertEqual(Postcodes.normalize(" CF10 1NS "), "CF10 1NS")
        XCTAssertEqual(Postcodes.normalize("EH1 1YZ"), "EH1 1YZ")
        XCTAssertNil(Postcodes.normalize("pizza"))
        XCTAssertNil(Postcodes.normalize("12345"))
        let json = #"{"status":200,"result":{"postcode":"CF10 1NS","latitude":51.48,"longitude":-3.18,"admin_district":"Cardiff","admin_ward":"Cathays","country":"Wales"}}"#
        let p = Postcodes.parse(Data(json.utf8), code: "CF10 1NS")
        XCTAssertEqual(p?.name, "CF10 1NS")
        XCTAssertEqual(p?.address, "Cathays, Cardiff, Wales")
    }
}

final class StreetViewTests: XCTestCase {
    func testParse() {
        let reply = #"[[0],[[1],[2,"AbCdEfGhIjKlMnOpQrStUv"],[2,2,[6656,13312],[[1]]],[[null,null,38.544912,-121.740501],[15.2],[201.5,90.1,0.3]]]]"#
        let p = StreetView.parse(reply)
        XCTAssertEqual(p?.id, "AbCdEfGhIjKlMnOpQrStUv")
        XCTAssertEqual(p?.location.lat ?? 0, 38.544912, accuracy: 1e-6)
        XCTAssertEqual(p?.location.lng ?? 0, -121.740501, accuracy: 1e-6)
        XCTAssertEqual(p?.width, 13312)
        XCTAssertEqual(p?.height, 6656)
        XCTAssertEqual(p?.heading ?? 0, 201.5, accuracy: 0.01)
        XCTAssertEqual(p?.size(zoom: 3).width, 3328)
        XCTAssertNil(StreetView.parse(#"[[5,"search returned no images"]]"#))
    }
}

final class RoadCacheTests: XCTestCase {
    func testKnownRoadsComeBackForARouteNearby() {
        let cache = RoadCache(file: nil)
        let road = Overpass.LimitWay(id: 7, kmh: 48.3, line: [LatLng(50.900, -1.400), LatLng(50.905, -1.400)])
        let far = Overpass.LimitWay(id: 8, kmh: 112, line: [LatLng(51.500, -0.100), LatLng(51.505, -0.100)])
        cache.add(ways: [road, far], cameras: [RoadCamera(id: 3, kind: .speed, location: LatLng(50.902, -1.4001))],
                  signals: [(id: 9, at: LatLng(50.903, -1.400))])
        // The same road seen again is kept once.
        cache.add(ways: [road], cameras: [], signals: [])
        let line = [LatLng(50.899, -1.400), LatLng(50.906, -1.400)]
        let known = cache.along(line)
        XCTAssertEqual(known.ways.map(\.id), [7])
        XCTAssertEqual(known.cameras.map(\.id), [3])
        XCTAssertEqual(known.signals.count, 1)
        XCTAssertEqual(Overpass.speedLimits(known.ways, on: line).compactMap(\.kmh), [48.3])
    }

    func testNothingKnownFarAway() {
        let cache = RoadCache(file: nil)
        cache.add(ways: [Overpass.LimitWay(id: 1, kmh: 50, line: [LatLng(0, 0), LatLng(0.005, 0)])], cameras: [], signals: [])
        XCTAssertTrue(cache.along([LatLng(10, 10), LatLng(10.01, 10)]).ways.isEmpty)
    }
}

final class ValhallaTests: XCTestCase {
    func testLimitsFromMatchedRoads() throws {
        // Two roads at 30 mph (48 km/h), one at 60 (97), one not known.
        let json = """
        {"shape":"_ibE_ibE_ibE?_ibE?_ibE?","edges":[
         {"speed_limit":48,"way_id":11,"length":0.1,"begin_shape_index":0,"end_shape_index":1},
         {"speed_limit":48,"way_id":12,"length":0.1,"begin_shape_index":1,"end_shape_index":2},
         {"speed_limit":97,"way_id":13,"length":0.3,"begin_shape_index":2,"end_shape_index":3},
         {"way_id":14,"length":0.1,"begin_shape_index":3,"end_shape_index":4}]}
        """
        let p = try XCTUnwrap(Valhalla.parse(Data(json.utf8)))
        XCTAssertEqual(p.limits.map(\.kmh), [48, 97, nil])
        XCTAssertEqual(p.limits.map { $0.startMeters.rounded() }, [0, 200, 500])
        XCTAssertEqual(p.meters, 600, accuracy: 0.01)
        XCTAssertEqual(p.ways.map(\.id), [11, 12, 13])
    }

    /** A British road mapped "maxspeed=30" with no unit is 30 mph, not 19; elsewhere 30 stays km/h. */
    func testBritishUnitlessLimitIsMph() {
        let eastleigh = LatLng(50.9613, -1.3705), paris = LatLng(48.85, 2.35), dublin = LatLng(53.35, -6.26)
        XCTAssertEqual(Overpass.britishLimit(30, at: eastleigh) ?? 0, 48.28, accuracy: 0.01)
        XCTAssertEqual(Overpass.britishLimit(30, at: paris), 30)
        XCTAssertEqual(Overpass.britishLimit(30, at: dublin), 30)
        // Already mph (30 mph is 48.28 km/h) or not a round number: left alone.
        XCTAssertEqual(Overpass.britishLimit(48.28032, at: eastleigh) ?? 0, 48.28, accuracy: 0.01)
        XCTAssertEqual(Overpass.britishLimit(80, at: eastleigh), 80)
        XCTAssertNil(Overpass.britishLimit(nil, at: eastleigh))
    }

    /** Normandy Way, Marchwood (2026-10-27): 40 mph mapped by the roundabout, nothing for the next mile, then another road. */
    func testLimitCarriesAlongTheSameRoad() throws {
        let json = """
        {"shape":"_ibE_ibE_ibE?_ibE?_ibE?","edges":[
         {"speed_limit":64,"way_id":1,"names":["Normandy Way"],"length":0.1,"begin_shape_index":0,"end_shape_index":1},
         {"way_id":2,"names":["Normandy Way"],"length":1.5,"begin_shape_index":1,"end_shape_index":2},
         {"way_id":3,"names":["Cracknore Hard Lane"],"length":0.4,"begin_shape_index":2,"end_shape_index":3},
         {"way_id":4,"names":["Normandy Way"],"length":0.1,"begin_shape_index":3,"end_shape_index":4}]}
        """
        let p = try XCTUnwrap(Valhalla.parse(Data(json.utf8)))
        // On along Normandy Way the 40 still holds; turning onto another road it's not known (and stays so).
        XCTAssertEqual(p.limits.map(\.kmh), [64, nil])
        XCTAssertEqual(p.limits.map { $0.startMeters.rounded() }, [0, 1600])
        // Only what's mapped is remembered with the roads.
        XCTAssertEqual(p.ways.map(\.kmh), [64, nil, nil])
    }

    func testDirectionTag() {
        XCTAssertEqual(RoadCamera.bearings("90"), [90])
        XCTAssertEqual(RoadCamera.bearings("NE"), [45])
        XCTAssertEqual(RoadCamera.bearings("wsw"), [247.5])
        XCTAssertEqual(RoadCamera.bearings("45;225"), [45, 225])
        XCTAssertEqual(RoadCamera.bearings("315-45"), [0])
        XCTAssertEqual(RoadCamera.bearings("-90"), [270])
        XCTAssertNil(RoadCamera.bearings("both"))
        XCTAssertNil(RoadCamera.bearings("forward"))
        XCTAssertNil(RoadCamera.bearings(nil))
        // Read from the map for speed cameras, never for plate readers.
        let json = #"{"elements":[{"type":"node","id":1,"lat":51,"lon":-1,"tags":{"highway":"speed_camera","direction":"180"}},{"type":"node","id":2,"lat":51,"lon":-1,"tags":{"surveillance:type":"ALPR","direction":"180"}}]}"#
        let cams = Overpass.parse(Data(json.utf8))
        XCTAssertEqual(cams?[0].directions, [180])
        XCTAssertNil(cams?[1].directions)
    }

    func testOnlyCamerasFacingOurWay() {
        // Driving north up a straight road in England: traffic keeps left, so northbound cameras
        // stand on the west (left) side, about 8 m off the middle, and southbound ones on the east.
        let line = [LatLng(51.0, -1.0), LatLng(51.02, -1.0)]
        let west = -1.000115, east = -0.999885, middle = -1.0
        func cam(_ id: Int64, _ lat: Double, _ lng: Double, _ dir: [Double]?) -> RoadCamera {
            RoadCamera(id: id, kind: .speed, location: LatLng(lat, lng), directions: dir)
        }
        let cams = [
            cam(1, 51.002, west, [0]),      // ours, mapped right
            cam(2, 51.004, east, [180]),    // the other way's: skipped
            cam(3, 51.006, east, nil),      // no direction: warns
            cam(4, 51.008, west, [180]),    // on our side but mapped the other way: warns, to be safe
            cam(5, 51.010, middle, [180]),  // on the road itself, mapped the other way: warns
            cam(6, 51.012, east, [0]),      // far side but mapped our way: warns
            cam(7, 51.014, east, [90]),     // sideways: warns
            cam(8, 51.016, east, [200]),    // the other way's: skipped
        ]
        // All still shown; the other way's are quiet.
        let north = CameraAlerts.project(cams, on: line)
        XCTAssertEqual(north.count, 8)
        XCTAssertEqual(north.filter(\.camera.quiet).map(\.camera.id), [2, 8])
        // Driving south, the other way round.
        let south = CameraAlerts.project(cams, on: line.reversed())
        XCTAssertEqual(south.filter(\.camera.quiet).map(\.camera.id), [1])
    }
}

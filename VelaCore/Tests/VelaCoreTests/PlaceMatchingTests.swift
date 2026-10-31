import XCTest
@testable import VelaCore

final class PlaceMatchingTests: XCTestCase {
    func testNearbyProviderCopiesMatch() {
        let osm = Place(id: "osm", name: "Perth Airport", location: LatLng(-31.93908, 115.968171), source: "osm")
        let google = Place(id: "google", name: "perth airport", location: LatLng(-31.93920, 115.9683), source: "google")
        XCTAssertTrue(osm.matchesNearby(google))
    }
    func testDifferentPlacesStayDistinct() {
        let first = Place(id: "a", name: "Perth Airport", location: LatLng(-31.939, 115.968), source: "osm")
        let otherName = Place(id: "b", name: "Airport Cafe", location: LatLng(-31.939, 115.968), source: "google")
        let distant = Place(id: "c", name: "Perth Airport", location: LatLng(-31.95, 115.97), source: "google")
        XCTAssertFalse(first.matchesNearby(otherName)); XCTAssertFalse(first.matchesNearby(distant))
    }
    func testStableIdentityMatchesEvenAfterRename() {
        let a = Place(id: "a", name: "Old", location: LatLng(0, 0), source: "osm")
        let b = Place(id: "a", name: "New", location: LatLng(1, 1), source: "osm")
        XCTAssertTrue(a.matchesNearby(b))
    }
}

import XCTest
@testable import VelaCore
final class SurveillanceCameraTests: XCTestCase {
    func testDistinguishesGenericSurveillanceFromPlateReadersAndDeduplicates() throws {
        let json = #"{"elements":[{"id":1,"lat":-31.78,"lon":115.97,"tags":{"man_made":"surveillance","operator":"Public Transport Authority","surveillance":"public","camera:direction":"SE"}},{"id":2,"lat":-31.79,"lon":115.98,"tags":{"surveillance:type":"ALPR","manufacturer":"Example"}},{"id":2,"lat":-31.79,"lon":115.98,"tags":{"surveillance:type":"ALPR"}},{"id":3,"lat":-31.8,"lon":115.9,"tags":{"highway":"traffic_signals"}}]}"#
        let items = try XCTUnwrap(SurveillanceCameras.parse(Data(json.utf8)))
        XCTAssertEqual(items.count, 2)
        XCTAssertFalse(items[0].isALPR)
        XCTAssertEqual(items[0].direction, "SE")
        XCTAssertTrue(items[1].isALPR)
        XCTAssertEqual(items[1].manufacturer, "Example")
    }
    func testMalformedInput() {
        XCTAssertNil(SurveillanceCameras.parse(Data("{}".utf8)))
    }
}

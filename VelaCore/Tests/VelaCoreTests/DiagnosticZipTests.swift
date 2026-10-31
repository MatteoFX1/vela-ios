import XCTest
@testable import VelaCore

final class DiagnosticZipTests: XCTestCase {
    func testStoredZipKnownCRCAndCentralDirectory() throws {
        let zip = try DiagnosticZip.archive([.init(name: "a.txt", data: Data("123456789".utf8))])
        XCTAssertEqual(Array(zip.prefix(4)), [0x50, 0x4b, 0x03, 0x04])
        XCTAssertEqual(Array(zip[14..<18]), [0x26, 0x39, 0xf4, 0xcb])
        XCTAssertNotNil(zip.range(of: Data([0x50, 0x4b, 0x01, 0x02])))
        XCTAssertEqual(Array(zip.suffix(22).prefix(4)), [0x50, 0x4b, 0x05, 0x06])
    }
    func testRejectsPaths() {
        XCTAssertThrowsError(try DiagnosticZip.archive([.init(name: "../x", data: Data())]))
    }
    func testArchiveCanBeReadBySystemUnzip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        defer { try? FileManager.default.removeItem(at: url) }
        try DiagnosticZip.archive([.init(name: "diagnostics.txt", data: Data("test".utf8)),
                                   .init(name: "heatmap.webp", data: Data([0, 1, 255]))]).write(to: url)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        task.arguments = ["-tq", url.path]
        task.standardOutput = Pipe(); task.standardError = Pipe()
        try task.run(); task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0)
    }
}

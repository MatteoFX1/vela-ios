import Foundation
// From Ausbloke's Kite fork (github.com/NotDiscordOfficial/kite-maps), GPL-3.0.

/// Small ZIP writer for diagnostic files. Uses uncompressed entries and CRC-32.
public enum DiagnosticZip {
    public struct Entry {
        public let name: String
        public let data: Data
        public init(name: String, data: Data) { self.name = name; self.data = data }
    }
    public enum Error: Swift.Error { case invalidEntry }
    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0) }
        }
        return crc ^ 0xffffffff
    }
    public static func archive(_ entries: [Entry]) throws -> Data {
        guard entries.count <= Int(UInt16.max) else { throw Error.invalidEntry }
        var result = Data(), central = Data()
        func put<T: FixedWidthInteger>(_ n: T, _ out: inout Data) {
            var value = n.littleEndian
            withUnsafeBytes(of: &value) { out.append(contentsOf: $0) }
        }
        for entry in entries {
            let name = Data(entry.name.utf8)
            guard !entry.name.isEmpty, !entry.name.contains("/"), !entry.name.contains("\\"),
                  name.count <= Int(UInt16.max), entry.data.count <= Int(UInt32.max),
                  result.count <= Int(UInt32.max) else { throw Error.invalidEntry }
            let size = UInt32(entry.data.count), crc = crc32(entry.data), offset = UInt32(result.count)
            put(UInt32(0x04034b50), &result); put(UInt16(20), &result); put(UInt16(0x800), &result)
            put(UInt16(0), &result); put(UInt16(0), &result); put(UInt16(0), &result)
            put(crc, &result); put(size, &result); put(size, &result); put(UInt16(name.count), &result); put(UInt16(0), &result)
            result.append(name); result.append(entry.data)
            put(UInt32(0x02014b50), &central); put(UInt16(20), &central); put(UInt16(20), &central); put(UInt16(0x800), &central)
            put(UInt16(0), &central); put(UInt16(0), &central); put(UInt16(0), &central); put(crc, &central)
            put(size, &central); put(size, &central); put(UInt16(name.count), &central); put(UInt16(0), &central)
            put(UInt16(0), &central); put(UInt16(0), &central); put(UInt16(0), &central); put(UInt32(0), &central); put(offset, &central)
            central.append(name)
        }
        guard result.count <= Int(UInt32.max), central.count <= Int(UInt32.max) else { throw Error.invalidEntry }
        let offset = UInt32(result.count), centralSize = UInt32(central.count)
        result.append(central)
        put(UInt32(0x06054b50), &result); put(UInt16(0), &result); put(UInt16(0), &result)
        put(UInt16(entries.count), &result); put(UInt16(entries.count), &result); put(centralSize, &result); put(offset, &result); put(UInt16(0), &result)
        return result
    }
}

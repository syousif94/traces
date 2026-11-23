import Foundation
import zlib

/// Minimal ZIP writer (stored entries, CRC-32) for fab packages. Gerbers are small; no compression
/// keeps this dependency-free and every fab house accepts stored entries.
enum ZipWriter {
    static func zip(_ files: [(String, Data)]) -> Data {
        var out = Data()
        var central = Data()
        var count: UInt16 = 0
        for (name, data) in files {
            let nameData = Data(name.utf8)
            let crc = data.withUnsafeBytes { buf -> UInt32 in
                UInt32(crc32(0, buf.bindMemory(to: UInt8.self).baseAddress, uInt(buf.count)))
            }
            let offset = UInt32(out.count)
            // Local file header
            out.append(le32(0x04034b50)); out.append(le16(20)); out.append(le16(0x0800)); out.append(le16(0))
            out.append(le16(0)); out.append(le16(0x21))  // time, date (1980-01-01)
            out.append(le32(crc)); out.append(le32(UInt32(data.count))); out.append(le32(UInt32(data.count)))
            out.append(le16(UInt16(nameData.count))); out.append(le16(0))
            out.append(nameData); out.append(data)
            // Central directory entry
            central.append(le32(0x02014b50)); central.append(le16(20)); central.append(le16(20)); central.append(le16(0x0800)); central.append(le16(0))
            central.append(le16(0)); central.append(le16(0x21))
            central.append(le32(crc)); central.append(le32(UInt32(data.count))); central.append(le32(UInt32(data.count)))
            central.append(le16(UInt16(nameData.count))); central.append(le16(0)); central.append(le16(0))
            central.append(le16(0)); central.append(le16(0)); central.append(le32(0)); central.append(le32(offset))
            central.append(nameData)
            count += 1
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        out.append(le32(0x06054b50)); out.append(le16(0)); out.append(le16(0))
        out.append(le16(count)); out.append(le16(count))
        out.append(le32(UInt32(central.count))); out.append(le32(cdOffset)); out.append(le16(0))
        return out
    }

    private static func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
}

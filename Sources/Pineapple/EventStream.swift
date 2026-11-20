import Foundation

/// AWS event stream framing (application/vnd.amazon.eventstream), used by Transcribe streaming.
/// Frame: total length (4) | headers length (4) | prelude CRC (4) | headers | payload | message CRC (4)
enum EventStream {
    struct Message {
        let headers: [String: String]
        let payload: Data
    }

    static func encode(headers: [(String, String)], payload: Data) -> Data {
        var headerBytes = Data()
        for (name, value) in headers {
            let n = Data(name.utf8), v = Data(value.utf8)
            headerBytes.append(UInt8(n.count))
            headerBytes.append(n)
            headerBytes.append(7) // string
            headerBytes.append(contentsOf: bigEndian(UInt16(v.count)))
            headerBytes.append(v)
        }
        let total = 12 + headerBytes.count + payload.count + 4
        var message = Data()
        message.append(contentsOf: bigEndian(UInt32(total)))
        message.append(contentsOf: bigEndian(UInt32(headerBytes.count)))
        message.append(contentsOf: bigEndian(crc32(message)))
        message.append(headerBytes)
        message.append(payload)
        message.append(contentsOf: bigEndian(crc32(message)))
        return message
    }

    static func decode(_ data: Data) -> Message? {
        let b = [UInt8](data)
        guard b.count >= 16 else { return nil }
        let total = Int(readUInt32(b, 0)), headersLength = Int(readUInt32(b, 4))
        guard total == b.count, 12 + headersLength + 4 <= total else { return nil }

        var headers: [String: String] = [:]
        var i = 12
        let headersEnd = 12 + headersLength
        func has(_ n: Int) -> Bool { i + n <= headersEnd }
        while i < headersEnd {
            let nameLength = Int(b[i]); i += 1
            guard has(nameLength + 1) else { return nil }
            let name = String(decoding: b[i..<(i + nameLength)], as: UTF8.self); i += nameLength
            let type = b[i]; i += 1
            switch type {
            case 0, 1: break                       // bool true / false
            case 2: i += 1                         // byte
            case 3: i += 2                         // short
            case 4: i += 4                         // int
            case 5, 8: i += 8                      // long, timestamp
            case 9: i += 16                        // uuid
            case 6, 7:                             // bytes, string
                guard has(2) else { return nil }
                let valueLength = Int(b[i]) << 8 | Int(b[i + 1]); i += 2
                guard has(valueLength) else { return nil }
                if type == 7 { headers[name] = String(decoding: b[i..<(i + valueLength)], as: UTF8.self) }
                i += valueLength
            default: return nil
            }
        }
        return Message(headers: headers, payload: Data(b[headersEnd..<(total - 4)]))
    }

    // MARK: helpers

    private static func bigEndian<T: FixedWidthInteger>(_ v: T) -> [UInt8] {
        withUnsafeBytes(of: v.bigEndian, Array.init)
    }

    private static func readUInt32(_ b: [UInt8], _ at: Int) -> UInt32 {
        UInt32(b[at]) << 24 | UInt32(b[at + 1]) << 16 | UInt32(b[at + 2]) << 8 | UInt32(b[at + 3])
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

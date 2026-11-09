import Foundation

enum PorterError: LocalizedError {
    case corrupt(String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .corrupt(let s): return "Couldn't read file: \(s)"
        case .message(let s): return s
        }
    }
}

/// Little-endian reader over a byte array (Wallpaper Engine files are little-endian).
struct BinaryReader {
    let bytes: [UInt8]
    var pos: Int = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var remaining: Int { bytes.count - pos }

    mutating func int32() throws -> Int32 {
        guard pos + 4 <= bytes.count else { throw PorterError.corrupt("unexpected end of data") }
        let v = UInt32(bytes[pos]) | UInt32(bytes[pos + 1]) << 8 | UInt32(bytes[pos + 2]) << 16 | UInt32(bytes[pos + 3]) << 24
        pos += 4
        return Int32(bitPattern: v)
    }

    mutating func int() throws -> Int { Int(try int32()) }

    mutating func data(_ n: Int) throws -> [UInt8] {
        guard n >= 0, pos + n <= bytes.count else { throw PorterError.corrupt("block runs past end of data") }
        let out = Array(bytes[pos ..< pos + n])
        pos += n
        return out
    }

    /// Null-terminated string.
    mutating func cString(max: Int = 512) throws -> String {
        var out = [UInt8]()
        while true {
            guard pos < bytes.count else { throw PorterError.corrupt("unterminated string") }
            let b = bytes[pos]
            pos += 1
            if b == 0 { break }
            out.append(b)
            if out.count > max { throw PorterError.corrupt("string too long") }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Int32 length prefix followed by that many bytes.
    mutating func sizedString() throws -> String {
        let n = try int()
        guard n >= 0, n < 4096 else { throw PorterError.corrupt("bad string length \(n)") }
        return String(decoding: try data(n), as: UTF8.self)
    }
}

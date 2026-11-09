import Foundation

/// Unpacks Wallpaper Engine `scene.pkg` archives.
/// Layout: [i32 len][magic "PKGV00xx"][i32 count] then per entry [i32 len][path][i32 offset][i32 length],
/// followed by the file data; offsets are relative to the end of the header.
enum PKG {
    static func extract(_ pkgURL: URL, to dest: URL) throws {
        let bytes = [UInt8](try Data(contentsOf: pkgURL))
        var r = BinaryReader(bytes)
        let magic = try r.sizedString()
        guard magic.hasPrefix("PKGV") else { throw PorterError.corrupt("scene.pkg has unknown header \(magic)") }
        let count = try r.int()
        guard count >= 0, count < 200_000 else { throw PorterError.corrupt("scene.pkg entry count \(count)") }

        var entries: [(path: String, offset: Int, length: Int)] = []
        entries.reserveCapacity(count)
        for _ in 0 ..< count {
            let path = try r.sizedString()
            let offset = try r.int()
            let length = try r.int()
            entries.append((path, offset, length))
        }
        let dataStart = r.pos
        let fm = FileManager.default

        for e in entries {
            guard let rel = safeRelativePath(e.path) else { continue }
            let start = dataStart + e.offset
            guard e.offset >= 0, e.length >= 0, start + e.length <= bytes.count else { continue }
            let out = dest.appendingPathComponent(rel)
            try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(bytes[start ..< start + e.length]).write(to: out)
        }
    }

    /// Rejects absolute paths and `..` so a malicious archive can't write outside the folder.
    static func safeRelativePath(_ p: String) -> String? {
        let parts = p.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "." }
        guard !parts.isEmpty, !parts.contains("..") else { return nil }
        return parts.joined(separator: "/")
    }
}

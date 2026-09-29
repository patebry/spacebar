import Foundation

/// What the info card of a disk image (.dmg) says beyond its size: whether it is encrypted, and how its data is stored, read from
/// its own bytes (the UDIF trailer and the block table it points to). Nothing is mounted or run; an image iCloud has evicted is
/// not read.
enum DiskImage {
    /// Past these a table is not read: the image is still shown, without its format.
    static let maxTableBytes = 16 << 20
    static let maxChunks = 2_000_000

    /// Rows for the info card: [label, value]. Blocks: call it off the main thread.
    static func details(_ path: String) -> [[String]] {
        guard !FileTypes.isDataless(path) else { return [] }
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size >= 512 else { return [] }
        let size = Int64(st.st_size)
        let head = read(fd, at: 0, count: 8)
        if head == Data("encrcdsa".utf8) || read(fd, at: size - 8, count: 8) == Data("cdsaencr".utf8) {
            return [["Encrypted", "Yes, with a password"]]
        }
        guard let f = format(fd, size: size) else { return [] }
        return [["Format", f], ["Encrypted", "No"]]
    }

    private static func read(_ fd: Int32, at offset: Int64, count: Int) -> Data? {
        var d = Data(count: count)
        let n = d.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(offset)) }
        return n == count ? d : nil
    }

    private static func be<T: FixedWidthInteger>(_ d: Data, _ at: Int, _: T.Type) -> T {
        d.subdata(in: (d.startIndex + at)..<(d.startIndex + at + MemoryLayout<T>.size)).reduce(T(0)) { $0 << 8 | T($1) }
    }

    /// The storage the block table's chunks use, by the codec most of the data is in.
    static func format(_ fd: Int32, size: Int64) -> String? {
        guard let koly = read(fd, at: size - 512, count: 512), koly.prefix(4) == Data("koly".utf8) else { return nil }
        let offset = be(koly, 216, UInt64.self), length = be(koly, 224, UInt64.self)
        guard length > 0, length <= maxTableBytes, offset < UInt64(size), offset + length <= UInt64(size),
              let xml = read(fd, at: Int64(offset), count: Int(length)),
              let plist = try? PropertyListSerialization.propertyList(from: xml, options: [], format: nil) as? [String: Any],
              let blkx = (plist["resource-fork"] as? [String: Any])?["blkx"] as? [[String: Any]] else { return nil }
        var sectors: [UInt32: UInt64] = [:]
        var chunks = 0
        for entry in blkx where chunks <= maxChunks {
            guard let mish = entry["Data"] as? Data, mish.count >= 204, mish.prefix(4) == Data("mish".utf8) else { continue }
            let n = Int(be(mish, 200, UInt32.self))
            for i in 0..<min(n, (mish.count - 204) / 40) {
                chunks += 1
                if chunks > maxChunks { break }
                let at = 204 + i * 40
                sectors[be(mish, at, UInt32.self), default: 0] &+= be(mish, at + 16, UInt64.self)
            }
        }
        let names: [UInt32: String] = [0x8000_0004: "Compressed (ADC)", 0x8000_0005: "Compressed (zlib)", 0x8000_0006: "Compressed (bzip2)",
                                       0x8000_0007: "Compressed (LZFSE)", 0x8000_0008: "Compressed (LZMA)", 0x0000_0001: "Uncompressed"]
        guard let top = sectors.filter({ names[$0.key] != nil && $0.value > 0 }).max(by: { $0.value < $1.value }) else {
            return !sectors.isEmpty && sectors.keys.allSatisfy({ [0, 2].contains($0) }) ? "Empty" : nil
        }
        return names[top.key]
    }
}

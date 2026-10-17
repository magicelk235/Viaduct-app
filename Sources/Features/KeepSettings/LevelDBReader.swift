import Foundation

/// Reads the LevelDB databases Chromium keeps extension storage in
/// (`Local Extension Settings/<id>`, `Sync Extension Settings/<id>`).
///
/// It does one job: list the live key/value pairs of a database directory that
/// nothing is writing to. Chrome keeps the real directory open, so callers hand
/// this a copy. It reads the write-ahead logs (`*.log`), the sorted tables
/// (`*.ldb`, older `*.sst`) and the MANIFEST that says which of them are current.
/// It never writes, and damaged input throws instead of crashing.
enum LevelDBReader {

    enum ReadError: LocalizedError {
        case unreadable(String)
        case corrupt(file: String, reason: String)
        case unsupportedCompression(file: String, type: UInt8)

        var errorDescription: String? {
            switch self {
            case .unreadable(let path):
                return "The browser's storage at \(path) couldn't be read."
            case .corrupt(let file, let reason):
                return "The browser's storage file \(file) is damaged (\(reason))."
            case .unsupportedCompression(let file, let type):
                return "The browser's storage file \(file) uses a compression Viaduct can't read (type \(type))."
            }
        }
    }

    /// Every live key with its newest value. Deleted keys are left out.
    static func entries(in directory: URL) throws -> [Data: Data] {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch {
            throw ReadError.unreadable(directory.path)
        }

        var logs: [(number: UInt64, name: String)] = []
        var tables: [UInt64: String] = [:]
        for name in names {
            let parts = name.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 2, let number = UInt64(parts[0]) else { continue }
            switch parts[1] {
            case "log": logs.append((number, name))
            case "ldb", "sst": tables[number] = name
            default: continue
            }
        }

        // Without the MANIFEST every file present gets read, and the sequence
        // numbers decide which version of a key is current. That's right for
        // anything still live, but a table LevelDB has finished with and not yet
        // deleted could bring back a key whose deletion marker was later compacted
        // away. The MANIFEST names the live files, so use it when it agrees with
        // the directory. When it lists a table that isn't there, the copy caught a
        // compaction halfway, and reading everything present is the safer choice.
        var liveTables = Array(tables.values)
        var liveLogs = logs
        if let manifest = readManifest(in: directory) {
            let listed = manifest.tables.compactMap { tables[$0] }
            if listed.count == manifest.tables.count {
                liveTables = listed
                if let logNumber = manifest.logNumber {
                    liveLogs = logs.filter { $0.number >= logNumber || $0.number == manifest.prevLogNumber }
                }
            }
        }

        var merged = Merge()
        for name in liveTables.sorted() {
            let bytes = try load(directory.appendingPathComponent(name))
            do {
                try readTable(bytes, file: name, into: &merged)
            } catch is ShortRead {
                throw ReadError.corrupt(file: name, reason: "truncated data")
            }
        }
        for log in liveLogs.sorted(by: { $0.number < $1.number }) {
            let bytes = try load(directory.appendingPathComponent(log.name))
            forEachLogRecord(bytes) { record in
                applyWriteBatch(record, into: &merged)
            }
        }
        return merged.live()
    }

    private static func load(_ url: URL) throws -> [UInt8] {
        do {
            return [UInt8](try Data(contentsOf: url))
        } catch {
            throw ReadError.unreadable(url.lastPathComponent)
        }
    }

    // MARK: - Merging

    /// Keeps the newest version of each key across every file read.
    private struct Merge {
        private var newest: [Data: (sequence: UInt64, value: Data?)] = [:]

        /// `value` is nil for a deletion.
        mutating func record(_ key: Data, sequence: UInt64, value: Data?) {
            if let existing = newest[key], existing.sequence >= sequence { return }
            newest[key] = (sequence, value)
        }

        func live() -> [Data: Data] {
            newest.compactMapValues { $0.value }
        }
    }

    // MARK: - Log files

    /// Reassembles the records of a LevelDB log file (the write-ahead log and the
    /// MANIFEST share the format: 32 KiB blocks of checksummed fragments) and hands
    /// each complete record to `body`. Damage is handled the way LevelDB's own
    /// recovery handles it: a fragment whose checksum fails is dropped along with
    /// the rest of its block, and a record cut off at the end of the file, a write
    /// that was still in progress when the copy was taken, is ignored.
    private static func forEachLogRecord(_ bytes: [UInt8], _ body: (ArraySlice<UInt8>) throws -> Void) rethrows {
        let blockSize = 32 * 1024
        let headerSize = 7
        var pending: [UInt8] = []
        var inRecord = false

        var blockStart = 0
        scan: while blockStart < bytes.count {
            let blockEnd = min(blockStart + blockSize, bytes.count)
            var p = blockStart
            while blockEnd - p >= headerSize {
                let storedCRC = UInt32(bytes[p]) | UInt32(bytes[p + 1]) << 8
                    | UInt32(bytes[p + 2]) << 16 | UInt32(bytes[p + 3]) << 24
                let length = Int(bytes[p + 4]) | Int(bytes[p + 5]) << 8
                let type = bytes[p + 6]
                let payloadStart = p + headerSize

                // Zero type and length is the zero fill of a preallocated file.
                if type == 0 && length == 0 {
                    inRecord = false
                    pending.removeAll()
                    break
                }
                guard length <= blockEnd - payloadStart else {
                    if blockEnd == bytes.count { break scan }
                    inRecord = false
                    pending.removeAll()
                    break
                }
                // The checksum covers the type byte and the payload.
                guard CRC32C.masked(bytes[(p + 6)..<(payloadStart + length)]) == storedCRC else {
                    inRecord = false
                    pending.removeAll()
                    break
                }

                let payload = bytes[payloadStart..<(payloadStart + length)]
                p = payloadStart + length
                switch type {
                case 1:  // whole record
                    inRecord = false
                    pending.removeAll()
                    try body(payload)
                case 2:  // first fragment
                    pending = Array(payload)
                    inRecord = true
                case 3:  // middle fragment
                    if inRecord { pending.append(contentsOf: payload) }
                case 4:  // last fragment
                    if inRecord {
                        pending.append(contentsOf: payload)
                        inRecord = false
                        try body(pending[...])
                        pending.removeAll()
                    }
                default:
                    inRecord = false
                    pending.removeAll()
                }
            }
            blockStart += blockSize
        }
    }

    /// A write-ahead log record is a WriteBatch: a starting sequence number, a
    /// count, then puts and deletes, each taking the next sequence number. A
    /// malformed batch keeps whatever it held before the damage, as LevelDB does.
    private static func applyWriteBatch(_ batch: ArraySlice<UInt8>, into merged: inout Merge) {
        var reader = ByteReader(batch)
        guard let sequence = try? reader.fixed64(), let count = try? reader.fixed32() else { return }
        var index: UInt64 = 0
        while index < UInt64(count), !reader.isAtEnd {
            do {
                switch try reader.byte() {
                case 1:
                    let key = try reader.lengthPrefixed()
                    let value = try reader.lengthPrefixed()
                    merged.record(Data(key), sequence: sequence &+ index, value: Data(value))
                case 0:
                    let key = try reader.lengthPrefixed()
                    merged.record(Data(key), sequence: sequence &+ index, value: nil)
                default:
                    return
                }
            } catch {
                return
            }
            index += 1
        }
    }

    // MARK: - MANIFEST

    private struct ManifestState {
        var tables: Set<UInt64> = []
        var logNumber: UInt64?
        var prevLogNumber: UInt64?
    }

    /// Replays the MANIFEST that CURRENT points to. Nil when either is missing or
    /// can't be parsed; the caller then reads every file present.
    private static func readManifest(in directory: URL) -> ManifestState? {
        guard let current = try? String(contentsOf: directory.appendingPathComponent("CURRENT"), encoding: .utf8)
        else { return nil }
        let name = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.hasPrefix("MANIFEST-"), !name.contains("/"),
              let data = try? Data(contentsOf: directory.appendingPathComponent(name))
        else { return nil }

        var state = ManifestState()
        do {
            try forEachLogRecord([UInt8](data)) { edit in
                try applyVersionEdit(edit, to: &state)
            }
        } catch {
            return nil
        }
        return state
    }

    /// One VersionEdit: tagged fields recording which table files were added to or
    /// removed from the database, and which log is current.
    private static func applyVersionEdit(_ edit: ArraySlice<UInt8>, to state: inout ManifestState) throws {
        var reader = ByteReader(edit)
        var removed: [UInt64] = []
        var added: [UInt64] = []
        while !reader.isAtEnd {
            switch try reader.varint32() {
            case 1:  // comparator name
                _ = try reader.lengthPrefixed()
            case 2:
                state.logNumber = try reader.varint64()
            case 3, 4:  // next file number, last sequence
                _ = try reader.varint64()
            case 5:  // compaction pointer: level, internal key
                _ = try reader.varint32()
                _ = try reader.lengthPrefixed()
            case 6:  // deleted file: level, number
                _ = try reader.varint32()
                removed.append(try reader.varint64())
            case 7:  // new file: level, number, size, smallest and largest key
                _ = try reader.varint32()
                added.append(try reader.varint64())
                _ = try reader.varint64()
                _ = try reader.lengthPrefixed()
                _ = try reader.lengthPrefixed()
            case 9:
                state.prevLogNumber = try reader.varint64()
            default:
                throw ShortRead()
            }
        }
        // Within an edit LevelDB applies removals first, so a file moved to another
        // level (removed and added in the same edit) stays live.
        for number in removed { state.tables.remove(number) }
        for number in added { state.tables.insert(number) }
    }

    // MARK: - Tables

    /// A table ends in a 48-byte footer pointing at its index block. Each index
    /// entry points at a data block, and data block keys are LevelDB internal keys:
    /// the user key followed by 8 bytes holding (sequence << 8 | type).
    private static func readTable(_ bytes: [UInt8], file: String, into merged: inout Merge) throws {
        let footerSize = 48
        guard bytes.count >= footerSize else {
            throw ReadError.corrupt(file: file, reason: "too short to be a table")
        }
        var magic = ByteReader(bytes[(bytes.count - 8)...])
        guard try magic.fixed64() == 0xdb47_7524_8b80_fb57 else {
            throw ReadError.corrupt(file: file, reason: "not a LevelDB table")
        }
        var footer = ByteReader(bytes[(bytes.count - footerSize)..<(bytes.count - 8)])
        _ = try blockHandle(&footer)  // metaindex: only the bloom filter, which a full scan doesn't need
        let indexHandle = try blockHandle(&footer)

        let index = try block(in: bytes, at: indexHandle, file: file)
        try forEachEntry(in: index, file: file) { _, handleBytes in
            var handleReader = ByteReader(handleBytes)
            let data = try block(in: bytes, at: try blockHandle(&handleReader), file: file)
            try forEachEntry(in: data, file: file) { internalKey, value in
                guard internalKey.count >= 8 else {
                    throw ReadError.corrupt(file: file, reason: "short key")
                }
                let split = internalKey.endIndex - 8
                var trailerReader = ByteReader(internalKey[split...])
                let trailer = try trailerReader.fixed64()
                let key = Data(internalKey[..<split])
                switch trailer & 0xff {
                case 1: merged.record(key, sequence: trailer >> 8, value: Data(value))
                case 0: merged.record(key, sequence: trailer >> 8, value: nil)
                default: throw ReadError.corrupt(file: file, reason: "unknown entry type")
                }
            }
        }
    }

    private static func blockHandle(_ reader: inout ByteReader) throws -> (offset: Int, size: Int) {
        guard let offset = Int(exactly: try reader.varint64()),
              let size = Int(exactly: try reader.varint64()) else { throw ShortRead() }
        return (offset, size)
    }

    /// A block's bytes, followed in the file by a compression type byte and a
    /// masked CRC-32C of the bytes plus that type.
    private static func block(in bytes: [UInt8], at handle: (offset: Int, size: Int), file: String) throws -> [UInt8] {
        guard handle.offset <= bytes.count,
              handle.size <= bytes.count - handle.offset,
              bytes.count - handle.offset - handle.size >= 5 else {
            throw ReadError.corrupt(file: file, reason: "block out of range")
        }
        let end = handle.offset + handle.size
        var crcReader = ByteReader(bytes[(end + 1)..<(end + 5)])
        guard CRC32C.masked(bytes[handle.offset...end]) == (try crcReader.fixed32()) else {
            throw ReadError.corrupt(file: file, reason: "block checksum mismatch")
        }
        let contents = bytes[handle.offset..<end]
        switch bytes[end] {
        case 0:
            return Array(contents)
        case 1:
            do {
                return try Snappy.decompress(contents)
            } catch {
                throw ReadError.corrupt(file: file, reason: "bad Snappy data")
            }
        case let type:
            throw ReadError.unsupportedCompression(file: file, type: type)
        }
    }

    /// Walks a block's entries in order. Keys are prefix-compressed against the
    /// previous key (shared length, unshared length, value length, then the bytes);
    /// the block ends with an array of restart offsets and its count, which a full
    /// scan only needs in order to know where the entries stop.
    private static func forEachEntry(in block: [UInt8], file: String,
                                     _ body: (ArraySlice<UInt8>, ArraySlice<UInt8>) throws -> Void) throws {
        guard block.count >= 4 else { throw ReadError.corrupt(file: file, reason: "block too short") }
        var tail = ByteReader(block[(block.count - 4)...])
        let restarts = Int(try tail.fixed32())
        guard restarts <= (block.count - 4) / 4 else {
            throw ReadError.corrupt(file: file, reason: "bad restart count")
        }
        var reader = ByteReader(block[0..<(block.count - 4 - restarts * 4)])
        var key: [UInt8] = []
        while !reader.isAtEnd {
            let shared = Int(try reader.varint32())
            let unshared = Int(try reader.varint32())
            let valueLength = Int(try reader.varint32())
            guard shared <= key.count else { throw ReadError.corrupt(file: file, reason: "bad key prefix") }
            key.removeSubrange(shared...)
            key.append(contentsOf: try reader.take(unshared))
            let value = try reader.take(valueLength)
            try body(key[...], value)
        }
    }
}

// MARK: - Byte decoding

private struct ShortRead: Error {}

/// Bounds-checked little-endian and varint decoding over a slice.
private struct ByteReader {
    private let bytes: ArraySlice<UInt8>
    private var position: Int

    init(_ bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
        position = bytes.startIndex
    }

    var isAtEnd: Bool { position >= bytes.endIndex }

    mutating func byte() throws -> UInt8 {
        guard position < bytes.endIndex else { throw ShortRead() }
        defer { position += 1 }
        return bytes[position]
    }

    mutating func fixed32() throws -> UInt32 {
        guard bytes.endIndex - position >= 4 else { throw ShortRead() }
        var value: UInt32 = 0
        for i in 0..<4 { value |= UInt32(bytes[position + i]) << (8 * UInt32(i)) }
        position += 4
        return value
    }

    mutating func fixed64() throws -> UInt64 {
        guard bytes.endIndex - position >= 8 else { throw ShortRead() }
        var value: UInt64 = 0
        for i in 0..<8 { value |= UInt64(bytes[position + i]) << (8 * UInt64(i)) }
        position += 8
        return value
    }

    mutating func varint32() throws -> UInt32 {
        guard let value = UInt32(exactly: try varint(maxBytes: 5)) else { throw ShortRead() }
        return value
    }

    mutating func varint64() throws -> UInt64 {
        try varint(maxBytes: 10)
    }

    private mutating func varint(maxBytes: Int) throws -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<maxBytes {
            let b = try byte()
            value |= UInt64(b & 0x7f) << (7 * UInt64(i))
            if b & 0x80 == 0 { return value }
        }
        throw ShortRead()
    }

    mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, count <= bytes.endIndex - position else { throw ShortRead() }
        defer { position += count }
        return bytes[position..<(position + count)]
    }

    mutating func lengthPrefixed() throws -> ArraySlice<UInt8> {
        try take(Int(try varint32()))
    }
}

/// CRC-32C (Castagnoli) with LevelDB's masking, which it applies so that a CRC
/// stored inside checksummed data doesn't produce degenerate checksums.
private enum CRC32C {
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? (c >> 1) ^ 0x82f6_3b78 : c >> 1 }
        return c
    }

    static func masked(_ data: ArraySlice<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        table.withUnsafeBufferPointer { table in
            data.withUnsafeBufferPointer { bytes in
                for b in bytes {
                    crc = table[Int((crc ^ UInt32(b)) & 0xff)] ^ (crc >> 8)
                }
            }
        }
        crc ^= 0xffff_ffff
        return ((crc >> 15) | (crc << 17)) &+ 0xa282_ead8
    }
}

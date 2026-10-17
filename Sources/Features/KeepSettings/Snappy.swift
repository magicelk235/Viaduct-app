import Foundation

/// Decoder for Snappy's raw block format, which LevelDB uses to compress table
/// blocks. Decompression only: Viaduct reads Chrome's stores and never writes one.
///
/// The input comes from files another program wrote, so every length and offset
/// is checked before it is used, and anything malformed throws.
enum Snappy {
    enum DecodeError: Error {
        case truncated
        case badLength
        case badOffset
    }

    static func decompress(_ input: ArraySlice<UInt8>) throws -> [UInt8] {
        try input.withUnsafeBufferPointer { src -> [UInt8] in
            let srcEnd = src.count
            var ip = 0

            // Preamble: the uncompressed length as a varint of at most 32 bits.
            var declared: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard ip < srcEnd, shift <= 28 else { throw DecodeError.truncated }
                let byte = src[ip]
                ip += 1
                declared |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { break }
                shift += 7
            }
            // The densest element is a 3-byte copy that yields 64 bytes, so a
            // declared size far beyond ~22x the input can't be real. Refusing it
            // keeps a corrupt preamble from turning into a huge allocation.
            guard declared <= UInt64(UInt32.max),
                  declared <= UInt64(srcEnd) * 32 else { throw DecodeError.badLength }

            let length = Int(declared)
            var output = [UInt8](repeating: 0, count: length)
            var op = 0

            try output.withUnsafeMutableBufferPointer { dst in
                func copyBack(offset: Int, count: Int) throws {
                    guard offset > 0, offset <= op else { throw DecodeError.badOffset }
                    guard count <= length - op else { throw DecodeError.badLength }
                    // Byte by byte on purpose: when offset < count the copy reads
                    // bytes it has just written, which is how Snappy encodes runs.
                    var from = op - offset
                    for _ in 0..<count {
                        dst[op] = dst[from]
                        op += 1
                        from += 1
                    }
                }

                while ip < srcEnd {
                    let tag = src[ip]
                    ip += 1
                    switch tag & 0x03 {
                    case 0x00:
                        // Literal. Lengths up to 60 sit in the tag; longer ones
                        // follow it in 1–4 little-endian bytes.
                        var count = Int(tag >> 2)
                        if count >= 60 {
                            let extra = count - 59
                            guard srcEnd - ip >= extra else { throw DecodeError.truncated }
                            var value = 0
                            for i in 0..<extra { value |= Int(src[ip + i]) << (8 * i) }
                            ip += extra
                            count = value
                        }
                        count += 1
                        guard count <= srcEnd - ip else { throw DecodeError.truncated }
                        guard count <= length - op else { throw DecodeError.badLength }
                        memcpy(dst.baseAddress! + op, src.baseAddress! + ip, count)
                        ip += count
                        op += count
                    case 0x01:
                        // Copy, 3-bit length and 11-bit offset.
                        guard ip < srcEnd else { throw DecodeError.truncated }
                        let count = 4 + Int((tag >> 2) & 0x07)
                        let offset = (Int(tag >> 5) << 8) | Int(src[ip])
                        ip += 1
                        try copyBack(offset: offset, count: count)
                    case 0x02:
                        // Copy, 6-bit length and 16-bit offset.
                        guard srcEnd - ip >= 2 else { throw DecodeError.truncated }
                        let count = 1 + Int(tag >> 2)
                        let offset = Int(src[ip]) | Int(src[ip + 1]) << 8
                        ip += 2
                        try copyBack(offset: offset, count: count)
                    default:
                        // Copy, 6-bit length and 32-bit offset.
                        guard srcEnd - ip >= 4 else { throw DecodeError.truncated }
                        let count = 1 + Int(tag >> 2)
                        let offset = Int(src[ip]) | Int(src[ip + 1]) << 8
                            | Int(src[ip + 2]) << 16 | Int(src[ip + 3]) << 24
                        ip += 4
                        try copyBack(offset: offset, count: count)
                    }
                }
            }

            guard op == length else { throw DecodeError.badLength }
            return output
        }
    }
}

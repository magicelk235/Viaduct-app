import Foundation
import CryptoKit

/// Works out the Chrome extension id behind a file or folder, for features that
/// key off it (official Safari versions, carrying settings over).
enum ExtensionIdentity {
    /// The id from a path that carries one (a browser profile's
    /// Extensions/<id>/<version>, a store download named <id>.crx), else from
    /// the manifest's "key", which Chrome derives the id from. Nil when neither
    /// is there, as with most zips.
    static func chromeId(forSource path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let candidates = url.pathComponents.reversed().prefix(3)
            + [url.deletingPathExtension().lastPathComponent]
        if let id = candidates.first(where: isChromeId) { return id }
        return manifestKey(at: url).flatMap(chromeId(fromKey:))
    }

    static func isChromeId(_ s: String) -> Bool {
        s.count == 32 && s.allSatisfy { ("a"..."p").contains($0) }
    }

    /// Chrome's id is the first 128 bits of SHA-256 over the public key, written
    /// with the letters a–p standing in for hex digits 0–f.
    static func chromeId(fromKey base64: String) -> String? {
        guard let der = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else { return nil }
        let hex = SHA256.hash(data: der).prefix(16).map { String(format: "%02x", $0) }.joined()
        return String(hex.map { c -> Character in
            let v = Int(String(c), radix: 16)!
            return Character(UnicodeScalar(UInt8(97 + v)))
        })
    }

    private static func manifestKey(at url: URL) -> String? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        let data: Data?
        if isDir.boolValue {
            data = try? Data(contentsOf: url.appendingPathComponent("manifest.json"))
        } else {
            // unzip copes with the header a .crx puts in front of the zip.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            p.arguments = ["-p", url.path, "manifest.json"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            do { try p.run() } catch { return nil }
            data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
        }
        guard let data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["key"] as? String
    }
}

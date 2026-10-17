import Foundation

/// An extension's chrome.storage contents as a Chromium browser saved them.
struct ExtensionStorageSnapshot: Equatable {
    /// Storage key → the value's JSON text, exactly as the browser stored it.
    var local: [String: String]
    var sync: [String: String]

    var isEmpty: Bool { local.isEmpty && sync.isEmpty }
}

/// Brings an extension's saved settings (`chrome.storage.local` and `.sync`)
/// over from a Chromium profile into its converted Safari version.
///
/// Safari keeps extension storage in its own container, which nothing outside
/// Safari can write to, so the settings travel inside the extension instead: a
/// small script carrying the data runs first in the background and writes it
/// into Safari's storage the first time the extension starts.
enum ExtensionSettingsTransfer {

    enum TransferError: LocalizedError {
        case invalidExtensionId(String)
        case unpackFailed(String)
        case unreadableManifest
        case noBackground
        case missingBackgroundFile(String)

        var errorDescription: String? {
            switch self {
            case .invalidExtensionId(let id):
                return "“\(id)” isn't a Chrome extension ID."
            case .unpackFailed(let file):
                return "Viaduct couldn't unpack \(file)."
            case .unreadableManifest:
                return "The extension's manifest.json is missing or can't be read."
            case .noBackground:
                return "This extension has no background script, so there's nothing to load its Chrome settings into."
            case .missingBackgroundFile(let path):
                return "The extension's background script (\(path)) is missing, so its Chrome settings can't be brought over."
            }
        }
    }

    /// The script that carries the data, at the root of the staged extension.
    static let seedFileName = "viaduct-storage-seed.js"

    // MARK: - Reading the browser's storage

    /// The profile whose storage for `chromeId` changed most recently, among the
    /// profiles of every installed Chromium browser that hold any. Nil when none
    /// does. Reads the stores, so call it off the main thread.
    static func locate(chromeId: String) -> BrowserProfile? {
        guard isExtensionId(chromeId) else { return nil }
        let candidates = BrowserProfiles.all().compactMap { profile -> (profile: BrowserProfile, written: Date)? in
            let dates = [profile.localSettingsDir, profile.syncSettingsDir].compactMap {
                lastDataWrite(in: $0.appendingPathComponent(chromeId, isDirectory: true))
            }
            guard let newest = dates.max() else { return nil }
            return (profile, newest)
        }
        // A store can have files and still read back empty (an extension that
        // cleared its storage), so take the newest one that actually holds data.
        for candidate in candidates.sorted(by: { $0.written > $1.written }) {
            if let found = try? snapshot(chromeId: chromeId, profile: candidate.profile), !found.isEmpty {
                return candidate.profile
            }
        }
        return nil
    }

    /// Both storage areas of `chromeId` in `profile`. The browser may be running
    /// and holding the databases open, so they're read from a temporary copy;
    /// nothing in the profile is ever written. Keys that aren't UTF-8 and values
    /// that aren't valid JSON are left out.
    static func snapshot(chromeId: String, profile: BrowserProfile) throws -> ExtensionStorageSnapshot {
        guard isExtensionId(chromeId) else { throw TransferError.invalidExtensionId(chromeId) }
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory
            .appendingPathComponent("viaduct-settings-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: scratch) }

        let local = try readStore(profile.localSettingsDir.appendingPathComponent(chromeId, isDirectory: true),
                                  via: scratch.appendingPathComponent("local", isDirectory: true))
        let sync = try readStore(profile.syncSettingsDir.appendingPathComponent(chromeId, isDirectory: true),
                                 via: scratch.appendingPathComponent("sync", isDirectory: true))
        return ExtensionStorageSnapshot(local: local, sync: sync)
    }

    private static func isExtensionId(_ id: String) -> Bool {
        id.utf8.count == 32 && id.utf8.allSatisfy { $0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "p") }
    }

    /// LevelDB's numbered data files: write-ahead logs and tables.
    private static func isDataFile(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 2
            && !parts[0].isEmpty && parts[0].allSatisfy { ("0"..."9").contains($0) }
            && ["log", "ldb", "sst"].contains(parts[1])
    }

    /// When a store's data last changed, nil when it holds none. Every write
    /// lands in a .log; merely opening the database touches only LOG and LOCK,
    /// which are ignored here.
    private static func lastDataWrite(in store: URL) -> Date? {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: store, includingPropertiesForKeys: keys)
        else { return nil }
        var newest: Date?
        for file in files where isDataFile(file.lastPathComponent) {
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, (values.fileSize ?? 0) > 0,
                  let date = values.contentModificationDate else { continue }
            newest = max(newest ?? date, date)
        }
        return newest
    }

    private static func readStore(_ store: URL, via copy: URL) throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: store.path) else { return [:] }
        try copyStore(store, to: copy)
        var items: [String: String] = [:]
        for (rawKey, rawValue) in try LevelDBReader.entries(in: copy) {
            guard let key = String(data: rawKey, encoding: .utf8),
                  let value = String(data: rawValue, encoding: .utf8),
                  (try? JSONSerialization.jsonObject(with: rawValue, options: .fragmentsAllowed)) != nil
            else { continue }
            items[key] = value
        }
        return items
    }

    /// Copies the files LevelDB reads. The browser can be writing while this
    /// runs, and the order makes that safe: logs first, then CURRENT and the
    /// MANIFEST, then the tables. A log only disappears once a table holding its
    /// data is in the MANIFEST, so if a log is gone the later MANIFEST copy names
    /// that table and the table copy, later still, picks it up. A table that's
    /// still being written isn't in the MANIFEST yet, so the reader skips it.
    private static func copyStore(_ store: URL, to copy: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: copy, withIntermediateDirectories: true)
        let phases: [(String) -> Bool] = [
            { isDataFile($0) && $0.hasSuffix(".log") },
            { $0 == "CURRENT" || $0.hasPrefix("MANIFEST-") },
            { isDataFile($0) && !$0.hasSuffix(".log") },
        ]
        for belongs in phases {
            for name in try fm.contentsOfDirectory(atPath: store.path) where belongs(name) {
                let file = store.appendingPathComponent(name)
                do {
                    try fm.copyItem(at: file, to: copy.appendingPathComponent(name))
                } catch where !fm.fileExists(atPath: file.path) {
                    // Deleted by a compaction since the listing; what replaced it
                    // is in the files copied after this.
                    continue
                }
            }
        }
    }

    // MARK: - Staging the extension

    /// Copies or unpacks `source` (an unpacked folder, .crx or .zip) into
    /// Caches/Viaduct/seeded/<name>/, replacing an earlier copy, and hooks a
    /// script carrying `snapshot` into its background. Returns that folder, which
    /// is what to convert. An empty snapshot is staged without a script.
    static func stageWithSeed(source: URL, snapshot: ExtensionStorageSnapshot, name: String) throws -> URL {
        let fm = FileManager.default
        let seededDir = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Viaduct", isDirectory: true)
            .appendingPathComponent("seeded", isDirectory: true)
        try fm.createDirectory(at: seededDir, withIntermediateDirectories: true)
        let dest = seededDir.appendingPathComponent(folderName(name), isDirectory: true)

        // Everything happens in a scratch folder next to the destination, so a
        // failure leaves nothing half-done behind (and `source` may itself be the
        // earlier copy), and only the folder that holds manifest.json moves into
        // place, since archives often nest it one level down.
        let work = seededDir.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        try unpack(source, into: work)
        StagedFolder.makeOwnerWritable(work)
        guard let root = manifestRoot(in: work) else { throw TransferError.unreadableManifest }

        // The Web Store's signed hashes; they stop matching once a file changes.
        let metadata = root.appendingPathComponent("_metadata", isDirectory: true)
        if fm.fileExists(atPath: metadata.path) { try fm.removeItem(at: metadata) }

        let local = dataLiteral(snapshot.local)
        let sync = dataLiteral(snapshot.sync)
        if local != nil || sync != nil {
            try hookSeed(seedScript(local: local ?? "{}", sync: sync ?? "{}"), into: root)
        }

        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: root, to: dest)
        return dest
    }

    private static func folderName(_ name: String) -> String {
        var cleaned = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            let unsafe = scalar == "/" || scalar == ":" || scalar.properties.generalCategory == .control
            cleaned.append(unsafe ? "-" : scalar)
        }
        var result = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasPrefix(".") { result.removeFirst() }
        // File names are capped at 255 bytes.
        while result.utf8.count > 200 { result.removeLast() }
        return result.isEmpty ? "extension" : result
    }

    private static func unpack(_ source: URL, into work: URL) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw TransferError.unpackFailed(source.lastPathComponent)
        }
        if isDirectory.boolValue {
            try fm.copyItem(at: source, to: work)
            return
        }
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-o", "-qq", source.path, "-d", work.path]
        unzip.standardOutput = FileHandle.nullDevice
        unzip.standardError = FileHandle.nullDevice
        do {
            try unzip.run()
        } catch {
            throw TransferError.unpackFailed(source.lastPathComponent)
        }
        unzip.waitUntilExit()
        // 1 is a warning. A .crx is a zip behind a short header, which unzip
        // skips with exactly that warning.
        guard unzip.terminationStatus <= 1 else { throw TransferError.unpackFailed(source.lastPathComponent) }
    }

    /// The folder holding manifest.json: `dir` itself or a real (not symlinked)
    /// folder one level down.
    private static func manifestRoot(in dir: URL) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.appendingPathComponent("manifest.json").path) { return dir }
        let subfolders = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
        for sub in subfolders where sub.lastPathComponent != "__MACOSX" {
            let values = try? sub.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            if fm.fileExists(atPath: sub.appendingPathComponent("manifest.json").path) { return sub }
        }
        return nil
    }

    // MARK: - Hooking the seed into the background

    /// Makes `seed` run before anything else in the extension's background.
    ///
    /// Viaduct's converter rewrites backgrounds, and each hook here is chosen to
    /// survive that:
    /// - MV3 `service_worker`: the converter turns the worker into a generated
    ///   background page that runs its own runtime scripts and then the worker
    ///   file, as a classic script or, when it has import/export syntax, as a
    ///   module. Its own runtime goes first either way, so the seed has to travel
    ///   inside the worker file. A classic file gets the seed's source at the
    ///   top, unless it calls importScripts: the converter hoists every literal
    ///   importScripts target into the page as its own script ahead of the
    ///   worker, in call order, so code pulled in that way would run before an
    ///   inline seed. Such a worker gets an importScripts of the seed file
    ///   ahead of its own calls instead, which the converter hoists first. A
    ///   module would evaluate its imports before any code at its top, so it
    ///   imports the seed file first instead; modules evaluate their imports
    ///   in order. The converter decides module or classic from the same syntax
    ///   test used here, and the seed itself contains no module syntax, so the
    ///   decision doesn't change.
    /// - MV2 `background.scripts`: the converter leaves the list alone and
    ///   Safari runs it in order, so the seed file goes first in it.
    /// - MV2 `background.page`: a script tag for the seed goes in front of the
    ///   page's first script. The converter later puts its own runtime at the top
    ///   of the head, ahead of it, which is fine: the seed wraps what that runtime
    ///   leaves behind.
    private static func hookSeed(_ seed: String, into root: URL) throws {
        let manifestURL = root.appendingPathComponent("manifest.json")
        guard let manifestData = try? Data(contentsOf: manifestURL),
              var manifest = (try? JSONSerialization.jsonObject(with: Data(stripJSONComments([UInt8](manifestData)))))
                as? [String: Any]
        else { throw TransferError.unreadableManifest }
        let background = manifest["background"] as? [String: Any]
        let seedURL = root.appendingPathComponent(seedFileName)

        if let worker = background?["service_worker"] as? String {
            guard let url = fileInside(root, worker), let bytes = try? Data(contentsOf: url) else {
                throw TransferError.missingBackgroundFile(worker)
            }
            var source = [UInt8](bytes)
            if hasModuleSyntax(String(decoding: source, as: UTF8.self)) {
                try Data(seed.utf8).write(to: seedURL, options: .atomic)
                let bom = source.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
                source.insert(contentsOf: Array("import \"/\(seedFileName)\";\n".utf8), at: bom)
            } else if String(decoding: source, as: UTF8.self)
                        .range(of: #"\bimportScripts\s*\("#, options: .regularExpression) != nil {
                // A leading "/" resolves from the extension root for the
                // converter, wherever the worker sits.
                try Data(seed.utf8).write(to: seedURL, options: .atomic)
                let at = directivePrologueEnd(source)
                let call = (at > 0 ? "\n" : "") + "importScripts(\"/\(seedFileName)\");\n"
                source.insert(contentsOf: Array(call.utf8), at: at)
            } else {
                let at = directivePrologueEnd(source)
                source.insert(contentsOf: Array(((at > 0 ? "\n" : "") + seed).utf8), at: at)
            }
            try Data(source).write(to: url, options: .atomic)

        } else if let scripts = background?["scripts"] as? [String], !scripts.isEmpty {
            try Data(seed.utf8).write(to: seedURL, options: .atomic)
            var updated = background ?? [:]
            updated["scripts"] = [seedFileName] + scripts.filter { $0 != seedFileName }
            manifest["background"] = updated
            let json = try JSONSerialization.data(withJSONObject: manifest,
                                                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try json.write(to: manifestURL, options: .atomic)

        } else if let page = background?["page"] as? String {
            let path = String(page.prefix { $0 != "?" && $0 != "#" })
            guard let url = fileInside(root, path), let bytes = try? Data(contentsOf: url) else {
                throw TransferError.missingBackgroundFile(page)
            }
            try Data(seed.utf8).write(to: seedURL, options: .atomic)
            // Latin-1 maps every byte to a character and back, so a page that
            // isn't UTF-8 still comes out byte for byte as it went in.
            let encoding: String.Encoding = String(data: bytes, encoding: .utf8) != nil ? .utf8 : .isoLatin1
            guard let html = String(data: bytes, encoding: encoding),
                  let updated = insertingSeedTag(into: html).data(using: encoding)
            else { throw TransferError.missingBackgroundFile(page) }
            try updated.write(to: url, options: .atomic)

        } else {
            throw TransferError.noBackground
        }
    }

    /// `path` from the manifest as an existing file inside `root`. Nil when it's
    /// missing or leads outside the extension through ".." or a symlink, since
    /// this is about to write to it.
    private static func fileInside(_ root: URL, _ path: String) -> URL? {
        let parts = path.split(separator: "/").filter { $0 != "." }
        guard !parts.isEmpty, !parts.contains("..") else { return nil }
        let url = parts.reduce(root) { $0.appendingPathComponent(String($1)) }.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard url.path.hasPrefix(root.resolvingSymlinksInPath().path + "/"),
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return url
    }

    /// The converter's own test for a worker that has to load as a module:
    /// import/export statements or import.meta. Same patterns, so both sides
    /// agree on what the worker is.
    private static let moduleSyntax: [NSRegularExpression] = [
        #"\bimport\s*\.\s*meta\b"#,
        #"(^|[;}\n])\s*import\s*["'`{*]"#,
        #"(^|[;}\n])\s*import\s+[\w$]+\s*(?:,\s*[{*]|from\b)"#,
        #"(^|[;}\n])\s*export\s*(?:default\b|[{*]|(?:const|let|var|function|class|async)\b)"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    private static func hasModuleSyntax(_ source: String) -> Bool {
        let range = NSRange(source.startIndex..., in: source)
        return moduleSyntax.contains { $0.firstMatch(in: source, range: range) != nil }
    }

    /// Byte offset just past a script's leading byte order mark and directive
    /// prologue ("use strict" and the like). Code placed in front of a directive
    /// turns it into a plain expression, which would quietly take a strict
    /// bundle out of strict mode.
    private static func directivePrologueEnd(_ s: [UInt8]) -> Int {
        var end = s.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        while true {
            var i = skipSpaceAndComments(s, from: end, crossingLines: true)
            guard i < s.count, s[i] == UInt8(ascii: "\"") || s[i] == UInt8(ascii: "'") else { break }
            let quote = s[i]
            i += 1
            while i < s.count, s[i] != quote, s[i] != 0x0A, s[i] != 0x0D {
                i += s[i] == UInt8(ascii: "\\") ? 2 : 1
            }
            guard i < s.count, s[i] == quote else { break }
            i = skipSpaceAndComments(s, from: i + 1, crossingLines: false)
            if i < s.count, s[i] == UInt8(ascii: ";") {
                end = i + 1
            } else if i >= s.count || s[i] == 0x0A || s[i] == 0x0D {
                end = i
            } else {
                // `"use strict".length` and the like: an expression, not a directive.
                break
            }
        }
        return end
    }

    private static func skipSpaceAndComments(_ s: [UInt8], from start: Int, crossingLines: Bool) -> Int {
        var i = start
        while i < s.count {
            switch s[i] {
            case 0x20, 0x09:
                i += 1
            case 0x0A where crossingLines, 0x0D where crossingLines:
                i += 1
            case UInt8(ascii: "/") where i + 1 < s.count && s[i + 1] == UInt8(ascii: "/"):
                while i < s.count, s[i] != 0x0A, s[i] != 0x0D { i += 1 }
            case UInt8(ascii: "/") where i + 1 < s.count && s[i + 1] == UInt8(ascii: "*"):
                i += 2
                while i + 1 < s.count, !(s[i] == UInt8(ascii: "*") && s[i + 1] == UInt8(ascii: "/")) { i += 1 }
                i = min(i + 2, s.count)
            default:
                return i
            }
        }
        return i
    }

    /// Puts the seed's script tag in front of the page's first script, skipping
    /// any inside HTML comments. A page without scripts gets it after <head>, or
    /// after the doctype, or at the very top.
    private static func insertingSeedTag(into html: String) -> String {
        let tag = "<script src=\"/\(seedFileName)\"></script>"
        let text = html as NSString
        let whole = NSRange(location: 0, length: text.length)

        func insideComment(_ location: Int) -> Bool {
            let open = text.range(of: "<!--", options: .backwards, range: NSRange(location: 0, length: location))
            guard open.location != NSNotFound else { return false }
            let close = text.range(of: "-->", range: NSRange(location: open.location, length: location - open.location))
            return close.location == NSNotFound
        }

        let script = try! NSRegularExpression(pattern: #"<script(?=[\s/>])"#, options: .caseInsensitive)
        if let first = script.matches(in: html, range: whole).first(where: { !insideComment($0.range.location) }) {
            return text.replacingCharacters(in: NSRange(location: first.range.location, length: 0), with: tag + "\n")
        }
        for pattern in [#"<head(?=[\s/>])[^>]*>"#, #"<!doctype[^>]*>"#] {
            let regex = try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            if let match = regex.matches(in: html, range: whole).first(where: { !insideComment($0.range.location) }) {
                let end = match.range.location + match.range.length
                return text.replacingCharacters(in: NSRange(location: end, length: 0), with: "\n" + tag)
            }
        }
        return tag + "\n" + html
    }

    /// Chrome accepts // and /* */ comments and trailing commas in manifest.json,
    /// JSONSerialization doesn't. Strips them (and a byte order mark) outside of
    /// string literals.
    private static func stripJSONComments(_ s: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(s.count)
        var i = s.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        var inString = false
        while i < s.count {
            let c = s[i]
            if inString {
                out.append(c)
                if c == UInt8(ascii: "\\"), i + 1 < s.count {
                    out.append(s[i + 1])
                    i += 2
                    continue
                }
                if c == UInt8(ascii: "\"") { inString = false }
                i += 1
                continue
            }
            if c == UInt8(ascii: "\"") {
                inString = true
                out.append(c)
                i += 1
            } else if c == UInt8(ascii: "/"), i + 1 < s.count, s[i + 1] == UInt8(ascii: "/") || s[i + 1] == UInt8(ascii: "*") {
                i = skipSpaceAndComments(s, from: i, crossingLines: false)
            } else if c == UInt8(ascii: ","),
                      case let next = skipSpaceAndComments(s, from: i + 1, crossingLines: true),
                      next < s.count, s[next] == UInt8(ascii: "}") || s[next] == UInt8(ascii: "]") {
                i += 1
            } else {
                out.append(c)
                i += 1
            }
        }
        return out
    }

    // MARK: - The seed script

    /// The seed: the data as an object literal, then the code that writes it.
    /// Kept to ES5 plus Promise, and free of module syntax, so it runs as a
    /// classic script, a module, or at the top of a service worker.
    private static func seedScript(local: String, sync: String) -> String {
        #"""
        // Added by Viaduct: this extension's saved settings, carried over from Chrome.
        // It runs before the extension's own background code and fills each storage
        // area only while that area is still empty, so nothing already saved in
        // Safari is replaced. Until it's done, the extension's storage calls wait.
        ;(function () {
          "use strict";

          var DATA = {
            local: \#(local),
            sync: \#(sync)
          };

          // Viaduct's runtime keeps a few bookkeeping keys of its own in storage and
          // may write them before this runs. They don't mean the extension has saved
          // anything.
          var OWN_KEY = /^__(c2s|viaduct)/;
          var METHODS = ["get", "set", "remove", "clear", "getBytesInUse"];
          // The extension is never held up longer than this, even by a request the
          // browser leaves unanswered.
          var LIMIT_MS = 15000;
          // Taken through a variable: the converter warns about background files
          // that call timers directly, and this one is only a safety net.
          var later = typeof setTimeout === "function" ? setTimeout : null;
          var has = Object.prototype.hasOwnProperty;

          var roots = [];
          try { if (typeof browser !== "undefined" && browser) roots.push(browser); } catch (e) {}
          try { if (typeof chrome !== "undefined" && chrome && roots.indexOf(chrome) < 0) roots.push(chrome); } catch (e) {}

          // Every distinct object the extension can reach a storage area through.
          function areas(name) {
            var found = [];
            for (var i = 0; i < roots.length; i++) {
              var area = null;
              try { area = roots[i].storage && roots[i].storage[name]; } catch (e) {}
              if (area && found.indexOf(area) < 0) found.push(area);
            }
            return found;
          }

          function ownKeys(object) {
            var list = [];
            if (object && typeof object === "object") {
              for (var key in object) if (has.call(object, key)) list.push(key);
            }
            return list;
          }

          function lastError() {
            for (var i = 0; i < roots.length; i++) {
              try {
                var error = roots[i].runtime && roots[i].runtime.lastError;
                if (error) return error;
              } catch (e) {}
            }
            return null;
          }

          // Calls a storage method and settles with its result, whether the browser
          // answers through the callback, the returned promise, or both.
          function invoke(fn, args) {
            return new Promise(function (resolve, reject) {
              var settled = false;
              function finish(error, value) {
                if (settled) return;
                settled = true;
                if (error) reject(error); else resolve(value);
              }
              var result;
              try {
                result = fn.apply(undefined, args.concat([function (value) { finish(lastError(), value); }]));
              } catch (e) {
                // A promise-only implementation may refuse the extra argument.
                try { result = fn.apply(undefined, args); } catch (e2) { finish(e2); return; }
              }
              if (result && typeof result.then === "function") {
                result.then(function (value) { finish(null, value); },
                            function (error) { finish(error || new Error("Storage call failed")); });
              }
            });
          }

          var released = false;
          var open;
          var ready = new Promise(function (resolve) { open = resolve; });
          function release() {
            if (released) return;
            released = true;
            DATA = null;
            open();
          }

          // Until release, a call is queued and then made with the original method,
          // so callback and promise callers both get what they'd have got anyway.
          function gate(original) {
            return function () {
              if (released) return original.apply(undefined, arguments);
              var args = arguments;
              return ready.then(function () { return original.apply(undefined, args); });
            };
          }

          function install(target, name, fn) {
            try { target[name] = fn; if (target[name] === fn) return true; } catch (e) {}
            try {
              Object.defineProperty(target, name, { value: fn, writable: true, configurable: true });
              if (target[name] === fn) return true;
            } catch (e) {}
            return false;
          }

          // An area gets all of its methods held or none. With only some held, an
          // early write could land between the emptiness check and the seeding.
          function hold(area) {
            var replaced = [];
            for (var i = 0; i < METHODS.length; i++) {
              var name = METHODS[i], fn, own;
              try { fn = area[name]; own = has.call(area, name); } catch (e) { continue; }
              if (typeof fn !== "function") continue;
              if (!install(area, name, gate(fn.bind(area)))) {
                for (var j = replaced.length - 1; j >= 0; j--) {
                  var undo = replaced[j];
                  try { if (undo.own) install(area, undo.name, undo.fn); else delete area[undo.name]; } catch (e) {}
                }
                return;
              }
              replaced.push({ name: name, fn: fn, own: own });
            }
          }

          // sync goes first: where sync is only an alias of local, local's values win.
          var plan = [];
          var names = ["sync", "local"];
          for (var n = 0; n < names.length; n++) {
            var items = DATA[names[n]];
            if (!ownKeys(items).length) continue;
            var targets = areas(names[n]);
            for (var t = 0; t < targets.length; t++) {
              try {
                if (typeof targets[t].get === "function" && typeof targets[t].set === "function") {
                  plan.push({ get: targets[t].get.bind(targets[t]), set: targets[t].set.bind(targets[t]), items: items });
                  break;
                }
              } catch (e) {}
            }
          }
          if (!plan.length) { release(); return; }

          var held = [];
          var all = areas("local").concat(areas("sync"));
          for (var h = 0; h < all.length; h++) {
            if (held.indexOf(all[h]) < 0) { held.push(all[h]); hold(all[h]); }
          }
          if (later) later(release, LIMIT_MS);

          Promise.all(plan.map(function (step) {
            return invoke(step.get, [null]).then(function (current) {
              if (!current || typeof current !== "object") return false;
              var keys = ownKeys(current);
              for (var k = 0; k < keys.length; k++) if (!OWN_KEY.test(keys[k])) return false;
              return true;
            }, function () { return false; });
          })).then(function (empty) {
            var chain = Promise.resolve();
            plan.forEach(function (step, i) {
              if (!empty[i]) return;
              chain = chain.then(function () {
                if (!released) return invoke(step.set, [step.items]).then(null, function () {});
              });
            });
            return chain;
          }).then(release, release);
        })();

        """#
    }

    /// One storage area's entries as a JavaScript object literal, nil when none
    /// of them can be written out.
    ///
    /// The stored JSON is re-emitted rather than pasted: JSON is almost valid
    /// JavaScript, but not entirely. A "__proto__" key in an object literal sets
    /// the prototype instead of making a property, so it's written as a computed
    /// key; a number Chrome would never write, like 01, is a syntax error in strict
    /// code, so anything outside strict JSON is dropped. Strings are re-escaped
    /// too, see `jsString`.
    private static func dataLiteral(_ entries: [String: String]) -> String? {
        let lines = entries.keys.sorted().compactMap { key -> String? in
            guard let value = jsLiteral(json: entries[key]!) else { return nil }
            return "      " + jsKey(key) + ": " + value
        }
        return lines.isEmpty ? nil : "{\n" + lines.joined(separator: ",\n") + "\n    }"
    }

    private static func jsKey(_ key: String) -> String {
        key == "__proto__" ? "[" + jsString(key) + "]" : jsString(key)
    }

    private static let escapes: [String] = (0..<128).map { String(format: "\\u%04x", $0) }

    /// `text` as a JavaScript string literal in which only lowercase letters,
    /// digits, spaces and non-ASCII characters appear as themselves.
    ///
    /// Everything else is a \u escape, because the converter edits extension
    /// scripts with text patterns, the seed included: it rewrites
    /// "chrome-extension:" and `chrome.scripting.ExecutionWorld.X` (the latter into
    /// a quoted string, which would break the literal around it), hoists
    /// importScripts("…") calls, decides module loading from `import`/`export`
    /// text, and looks for `onClicked`. None of those can match without
    /// punctuation or a capital letter. This also covers </script>, and U+2028
    /// and U+2029, which older engines don't accept inside string literals.
    private static func jsString(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x61...0x7A, 0x30...0x39, 0x20:
                out.unicodeScalars.append(scalar)
            case 0x00...0x7F:
                out += escapes[Int(scalar.value)]
            case 0x2028:
                out += "\\u2028"
            case 0x2029:
                out += "\\u2029"
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
        return out
    }

    /// Re-emits a JSON text as an equivalent JavaScript expression, validating it
    /// against strict JSON on the way. Nil when it isn't strict JSON or nests
    /// deeper than Chrome itself stores.
    private static func jsLiteral(json text: String) -> String? {
        enum Expect { case value, valueOrClose, key, keyOrClose, colon, commaOrClose, end }
        let s = Array(text.unicodeScalars)
        var out = ""
        var stack: [Unicode.Scalar] = []
        var expect = Expect.value
        var i = 0

        func closeValue() { expect = stack.isEmpty ? .end : .commaOrClose }

        while i < s.count {
            let c = s[i]
            if c == " " || c == "\t" || c == "\n" || c == "\r" {
                i += 1
                continue
            }
            switch expect {
            case .end:
                return nil
            case .colon:
                guard c == ":" else { return nil }
                out += ":"
                i += 1
                expect = .value
            case .commaOrClose:
                if c == "," {
                    out += ","
                    i += 1
                    expect = stack.last == "{" ? .key : .value
                } else if (c == "}" && stack.last == "{") || (c == "]" && stack.last == "[") {
                    out.unicodeScalars.append(c)
                    i += 1
                    stack.removeLast()
                    closeValue()
                } else {
                    return nil
                }
            case .key, .keyOrClose:
                if c == "}" && expect == .keyOrClose {
                    out += "}"
                    i += 1
                    stack.removeLast()
                    closeValue()
                } else {
                    guard c == "\"", let (key, end) = jsonString(s, at: i) else { return nil }
                    out += jsKey(key)
                    i = end
                    expect = .colon
                }
            case .value, .valueOrClose:
                if c == "]" && expect == .valueOrClose {
                    out += "]"
                    i += 1
                    stack.removeLast()
                    closeValue()
                } else if c == "{" || c == "[" {
                    // Chrome's JSON reader stops at 200 levels.
                    guard stack.count < 200 else { return nil }
                    out.unicodeScalars.append(c)
                    i += 1
                    stack.append(c)
                    expect = c == "{" ? .keyOrClose : .valueOrClose
                } else if c == "\"" {
                    guard let (value, end) = jsonString(s, at: i) else { return nil }
                    out += jsString(value)
                    i = end
                    closeValue()
                } else if let word = ["true", "false", "null"].first(where: { matches($0, s, at: i) }) {
                    out += word
                    i += word.unicodeScalars.count
                    closeValue()
                } else if let end = jsonNumberEnd(s, at: i) {
                    out.unicodeScalars.append(contentsOf: s[i..<end])
                    i = end
                    closeValue()
                } else {
                    return nil
                }
            }
        }
        return expect == .end ? out : nil
    }

    private static func matches(_ word: String, _ s: [Unicode.Scalar], at start: Int) -> Bool {
        var i = start
        for scalar in word.unicodeScalars {
            guard i < s.count, s[i] == scalar else { return false }
            i += 1
        }
        return true
    }

    /// Decodes the JSON string whose opening quote is at `start`. Returns the
    /// text and the index just past the closing quote.
    private static func jsonString(_ s: [Unicode.Scalar], at start: Int) -> (String, Int)? {
        var text = String.UnicodeScalarView()
        var i = start + 1
        while i < s.count {
            let c = s[i]
            if c == "\"" { return (String(text), i + 1) }
            if c != "\\" {
                // Raw control characters aren't allowed in a JSON string.
                guard c.value >= 0x20 else { return nil }
                text.append(c)
                i += 1
                continue
            }
            guard i + 1 < s.count else { return nil }
            i += 1
            switch s[i] {
            case "\"": text.append("\"")
            case "\\": text.append("\\")
            case "/": text.append("/")
            case "b": text.append("\u{8}")
            case "f": text.append("\u{C}")
            case "n": text.append("\n")
            case "r": text.append("\r")
            case "t": text.append("\t")
            case "u":
                guard var value = hex4(s, at: i + 1) else { return nil }
                i += 4
                if (0xD800...0xDBFF).contains(value) {
                    guard i + 2 < s.count, s[i + 1] == "\\", s[i + 2] == "u",
                          let low = hex4(s, at: i + 3), (0xDC00...0xDFFF).contains(low) else { return nil }
                    value = 0x10000 + ((value - 0xD800) << 10) + (low - 0xDC00)
                    i += 6
                }
                // A lone low surrogate has no scalar.
                guard let scalar = Unicode.Scalar(value) else { return nil }
                text.append(scalar)
            default:
                return nil
            }
            i += 1
        }
        return nil
    }

    private static func hex4(_ s: [Unicode.Scalar], at start: Int) -> UInt32? {
        guard start >= 0, start + 4 <= s.count else { return nil }
        var value: UInt32 = 0
        for scalar in s[start..<(start + 4)] {
            guard let digit = Character(scalar).hexDigitValue else { return nil }
            value = value << 4 | UInt32(digit)
        }
        return value
    }

    /// End of the JSON number starting at `start`, nil when there isn't one:
    /// -?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?
    private static func jsonNumberEnd(_ s: [Unicode.Scalar], at start: Int) -> Int? {
        func isDigit(_ i: Int) -> Bool { i < s.count && ("0"..."9").contains(s[i]) }
        var i = start
        if i < s.count, s[i] == "-" { i += 1 }
        guard isDigit(i) else { return nil }
        if s[i] == "0" {
            i += 1
        } else {
            while isDigit(i) { i += 1 }
        }
        if i < s.count, s[i] == "." {
            i += 1
            guard isDigit(i) else { return nil }
            while isDigit(i) { i += 1 }
        }
        if i < s.count, s[i] == "e" || s[i] == "E" {
            i += 1
            if i < s.count, s[i] == "+" || s[i] == "-" { i += 1 }
            guard isDigit(i) else { return nil }
            while isDigit(i) { i += 1 }
        }
        return i
    }
}

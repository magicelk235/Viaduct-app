import Foundation

enum StagedFolder {
    /// Store packages can carry read-only entries (Google ships some .crx files
    /// with r-x modes), and copies keep them. The CLI patches files in place
    /// while staging, so a read-only one fails the whole conversion with EACCES.
    static func makeOwnerWritable(_ root: URL) {
        let fm = FileManager.default
        var urls = [root]
        if let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
            urls += walker.compactMap { $0 as? URL }
        }
        for url in urls {
            guard let mode = (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int,
                  mode & 0o200 == 0 else { continue }
            try? fm.setAttributes([.posixPermissions: mode | 0o200], ofItemAtPath: url.path)
        }
    }
}

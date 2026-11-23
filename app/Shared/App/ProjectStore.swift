import Foundation
import Observation

/// Projects are plain folders. The default library is ~/Documents/Traces on the Mac and the
/// app's Documents folder on iPhone/iPad (visible in Files). Folders opened elsewhere are remembered
/// as security-scoped bookmarks.
@MainActor @Observable
final class ProjectStore {
    struct Item: Identifiable, Hashable {
        var id: String { url.path }
        var url: URL
        var name: String
        var modified: Date
        var external: Bool
    }

    var items: [Item] = []

    static var libraryURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #if os(macOS)
        let url = docs.appendingPathComponent("Traces", isDirectory: true)
        // The app was called Traceworks: move its old library folder over once.
        let old = docs.appendingPathComponent("Traceworks", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path), fm.fileExists(atPath: old.path) {
            try? fm.moveItem(at: old, to: url)
        }
        return url
        #else
        return docs
        #endif
    }

    private let bookmarksKey = "externalProjectBookmarks"

    init() { reload() }

    func reload() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.libraryURL, withIntermediateDirectories: true)
        var out: [Item] = []
        let dirs = (try? fm.contentsOfDirectory(at: Self.libraryURL, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        for d in dirs where (try? d.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            guard isProject(d) else { continue }
            out.append(Item(url: d, name: d.lastPathComponent, modified: modified(d), external: false))
        }
        for b in bookmarks() {
            var stale = false
            if let u = try? URL(resolvingBookmarkData: b, options: bookmarkResolveOptions, relativeTo: nil, bookmarkDataIsStale: &stale), !out.contains(where: { $0.url.path == u.path }) {
                out.append(Item(url: u, name: u.lastPathComponent, modified: modified(u), external: true))
            }
        }
        items = out.sorted { $0.modified > $1.modified }
    }

    private func isProject(_ d: URL) -> Bool {
        let fm = FileManager.default
        return ["index.tsx", "index.circuit.tsx", "package.json"].contains { fm.fileExists(atPath: d.appendingPathComponent($0).path) }
    }

    private func modified(_ u: URL) -> Date {
        (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    func templates() -> [URL] {
        guard let t = Bundle.main.url(forResource: "templates", withExtension: nil) else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(at: t, includingPropertiesForKeys: nil)) ?? []).filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.path < $1.path }
    }

    func create(from template: URL, name: String) throws -> URL {
        let fm = FileManager.default
        var base = name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        if base.isEmpty { base = template.lastPathComponent }
        var dest = Self.libraryURL.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: dest.path) { dest = Self.libraryURL.appendingPathComponent("\(base)-\(n)", isDirectory: true); n += 1 }
        try fm.copyItem(at: template, to: dest)
        // Name the package after the folder so the tsci CLI agrees with the app.
        let pkg = dest.appendingPathComponent("package.json")
        if var json = (try? Data(contentsOf: pkg)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) {
            json["name"] = dest.lastPathComponent
            if let d = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: pkg) }
        }
        reload()
        return dest
    }

    func remember(_ url: URL) {
        guard !url.path.hasPrefix(Self.libraryURL.path) else { return }
        guard let b = try? url.bookmarkData(options: bookmarkCreateOptions, includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        var all = bookmarks().filter { d in
            var s = false
            return (try? URL(resolvingBookmarkData: d, options: bookmarkResolveOptions, relativeTo: nil, bookmarkDataIsStale: &s))?.path != url.path
        }
        all.insert(b, at: 0)
        UserDefaults.standard.set(Array(all.prefix(20)), forKey: bookmarksKey)
        reload()
    }

    func forget(_ item: Item) {
        let all = bookmarks().filter { d in
            var s = false
            return (try? URL(resolvingBookmarkData: d, options: bookmarkResolveOptions, relativeTo: nil, bookmarkDataIsStale: &s))?.path != item.url.path
        }
        UserDefaults.standard.set(all, forKey: bookmarksKey)
        reload()
    }

    private func bookmarks() -> [Data] { UserDefaults.standard.array(forKey: bookmarksKey) as? [Data] ?? [] }

    private var bookmarkCreateOptions: URL.BookmarkCreationOptions {
        #if os(macOS)
        [.withSecurityScope]
        #else
        []
        #endif
    }
    private var bookmarkResolveOptions: URL.BookmarkResolutionOptions {
        #if os(macOS)
        [.withSecurityScope]
        #else
        []
        #endif
    }
}

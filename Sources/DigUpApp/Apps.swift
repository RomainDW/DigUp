import AppKit
import Foundation

/// An installed app the panel can launch: found by name, outside the index (apps are never indexed).
nonisolated struct AppEntry: Sendable, Equatable, Identifiable {
    let url: URL
    /// The name Finder shows, in the Mac's language ("Calculatrice" on a French Mac).
    let name: String
    /// Every name it can be found by, folded (lowercased, without accents): the shown name and the bundle's file name.
    let keys: [String]

    var id: String { AppCatalog.rowPrefix + url.path }
}

/// The apps in the usual places, matched by name as you type: a prefix ("fin" → Finder), the start of a later word
/// ("code" → Visual Studio Code), initials ("vsc"), or letters in order ("chrm" → Google Chrome).
@Observable
final class AppCatalog {
    /// Rows for apps carry this before their path, so they never collide with a file result's id.
    nonisolated static let rowPrefix = "\u{0}app:"
    static let maxShown = 4
    /// The list is read again when the panel opens if it's older than this.
    static let staleAfter: TimeInterval = 60

    /// Where apps live. Finder isn't in an Applications folder, so it's named on its own.
    nonisolated static let folders: [URL] = [
        URL(fileURLWithPath: "/Applications"),
        URL(fileURLWithPath: "/System/Applications"),
        URL(fileURLWithPath: "/System/Library/CoreServices/Applications"),
        // Safari: /Applications/Safari.app is a hidden link to it, which the walk skips.
        URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
    ]
    nonisolated static let extras: [URL] = [URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")]

    private(set) var apps: [AppEntry] = []
    @ObservationIgnored private var scannedAt = Date.distantPast
    @ObservationIgnored private var scanning = false
    @ObservationIgnored private let defaults = UserDefaults.standard
    private static let launchesKey = "appLaunches"

    /// Reads the app folders again if the list is old (in the background: the panel shows at once).
    func refreshIfStale(then done: @escaping () -> Void = {}) {
        guard !scanning, Date().timeIntervalSince(scannedAt) > Self.staleAfter else { return }
        scanning = true
        Task {
            let found = await Task.detached(priority: .userInitiated) { Self.scan() }.value
            apps = found
            scannedAt = Date()
            scanning = false
            done()
        }
    }

    /// The best few apps for what's typed, the ones you launch most first among equally good matches.
    func matches(_ query: String) -> [AppEntry] {
        let folded = Self.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !folded.isEmpty else { return [] }
        let launches = defaults.dictionary(forKey: Self.launchesKey) as? [String: Int] ?? [:]
        return apps.compactMap { app -> (AppEntry, Int)? in
            let score = app.keys.map { Self.score(folded, against: $0) }.max() ?? 0
            guard score > 0 else { return nil }
            return (app, score * 1000 + min(launches[app.url.path] ?? 0, 999))
        }
        .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name.count < $1.0.name.count }
        .prefix(Self.maxShown)
        .map(\.0)
    }

    func app(withID id: String) -> AppEntry? {
        guard id.hasPrefix(Self.rowPrefix) else { return nil }
        return apps.first { $0.id == id }
    }

    func launch(_ app: AppEntry) {
        var launches = defaults.dictionary(forKey: Self.launchesKey) as? [String: Int] ?? [:]
        launches[app.url.path, default: 0] += 1
        defaults.set(launches, forKey: Self.launchesKey)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: app.url, configuration: configuration) { _, error in
            if let error { log("apps: couldn't open \(app.url.path): \(error.localizedDescription)") }
        }
    }

    // MARK: Matching

    /// 0 when it doesn't match; higher is better.
    nonisolated static func score(_ query: String, against name: String) -> Int {
        if name == query { return 100 }
        if name.hasPrefix(query) { return 90 }
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if words.dropFirst().contains(where: { $0.hasPrefix(query) }) { return 75 }
        let initials = String(words.compactMap(\.first))
        if query.count >= 2, initials.hasPrefix(query) { return 70 }
        if query.count >= 3, name.contains(query) { return 50 }
        if query.count >= 3, isSubsequence(query, of: name) { return 20 }
        return 0
    }

    nonisolated static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var rest = haystack[...]
        for character in needle {
            guard let found = rest.firstIndex(of: character) else { return false }
            rest = rest[rest.index(after: found)...]
        }
        return true
    }

    nonisolated static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    // MARK: Finding apps

    nonisolated static func scan() -> [AppEntry] {
        let manager = FileManager.default
        var seen = Set<String>()
        var found: [AppEntry] = []
        func add(_ url: URL) {
            let path = url.resolvingSymlinksInPath().path
            guard seen.insert(path).inserted else { return }
            let name = manager.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "", options: [.anchored, .backwards])
            let stem = url.deletingPathExtension().lastPathComponent
            found.append(AppEntry(url: url, name: name, keys: Array(Set([fold(name), fold(stem)]))))
        }
        for url in extras where manager.fileExists(atPath: url.path) { add(url) }
        for folder in folders {
            // Apps, and apps one folder down (/Applications/Utilities, a vendor's folder), never inside an app.
            guard let walker = manager.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                  options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
                continue
            }
            for case let url as URL in walker {
                if url.pathExtension == "app" {
                    walker.skipDescendants()
                    add(url)
                } else if walker.level >= 2 {
                    walker.skipDescendants()
                }
            }
        }
        return found
    }
}

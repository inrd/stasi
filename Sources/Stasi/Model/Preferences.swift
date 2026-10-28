import Foundation

@MainActor
enum Preferences {
    private static let folderBookmarkKey = "outputFolderBookmark"

    private static var defaults: UserDefaults { .standard }

    static func loadOutputFolder() -> URL? {
        guard let data = defaults.data(forKey: folderBookmarkKey) else { return nil }

        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            return nil
        }

        if stale, let refreshed = try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            defaults.set(refreshed, forKey: folderBookmarkKey)
        }

        return url
    }

    static func saveOutputFolder(_ url: URL) {
        guard let data = try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }

        defaults.set(data, forKey: folderBookmarkKey)
    }
}

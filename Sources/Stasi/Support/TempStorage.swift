import Foundation

enum TempStorage {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Stasi/Temp", isDirectory: true)
    }

    static func makeURL() -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("take-\(UUID().uuidString).caf")
    }

    /// Raw takes left behind by a crash are kept for a day, then cleaned up.
    static func cleanOld(olderThanHours hours: Double = 24) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys
        ) else { return }

        let cutoff = Date().addingTimeInterval(-hours * 3600)
        for item in items {
            let modified = (try? item.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            if modified < cutoff {
                try? FileManager.default.removeItem(at: item)
            }
        }
    }
}

import Foundation
import os

/// Logs to both the unified log and `~/Library/Logs/Stasi/stasi.log`.
/// The file is what you want when a menu bar app fails silently.
enum Log {
    private static let logger = Logger(subsystem: "com.ineardisplay.stasi", category: "stasi")
    private static let lock = NSLock()

    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Stasi", isDirectory: true)
    static let fileURL = directory.appendingPathComponent("stasi.log")

    static func info(_ message: String) { write("INFO", message) }
    static func error(_ message: String) { write("ERROR", message) }

    private static func write(_ level: String, _ message: String) {
        logger.log("\(level, privacy: .public) \(message, privacy: .public)")

        lock.lock()
        defer { lock.unlock() }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "[\(stamp)] \(level) \(message)\n".data(using: .utf8) else { return }

        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: fileURL)
        }
    }
}

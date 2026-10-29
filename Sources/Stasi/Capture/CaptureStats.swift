import Foundation
import os

struct CaptureStats {
    var peak: Float = 0
    var frames: Int64 = 0
    var callbacks: Int64 = 0
}

/// Written on the Core Audio thread, read on the main thread.
final class StatsBox: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: CaptureStats())

    func record(peak: Float, frames: Int64) {
        lock.withLock { stats in
            stats.peak = max(stats.peak, peak)
            stats.frames += frames
            stats.callbacks += 1
        }
    }

    func snapshot() -> CaptureStats { lock.withLock { $0 } }
}

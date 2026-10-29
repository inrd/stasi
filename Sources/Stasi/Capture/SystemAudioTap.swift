import Accelerate
import CoreAudio
import Foundation

/// Captures the system's output through a Core Audio process tap.
///
/// An aggregate device is required to read a tap. The default output device is
/// used as the clock source (as a clock device only, so its own inputs never
/// appear in the aggregate); the tap contributes the only input stream.
///
/// Threading rules, enforced by convention rather than the compiler:
/// - `start()` and `stop()` are never concurrent, and never run on the audio
///   thread.
/// - `handleIO` runs on the Core Audio thread and touches only `firstBuffer`,
///   `writer` and `stats`.
/// - Everything else is read/written on the starting thread, before the IOProc
///   exists or after it has been stopped.
final class SystemAudioTap: @unchecked Sendable {
    /// Written by `start`, cleared by `stop`; only those two methods use it.
    private(set) var tapID = AudioObjectID(kAudioObjectUnknown)
    /// Written by `start`, cleared by `stop`; only those two methods use it.
    private(set) var aggregateID = AudioObjectID(kAudioObjectUnknown)
    /// Written by `start` before the IOProc exists; read only by `start`.
    private(set) var tapFormat = AudioStreamBasicDescription()

    /// Written on the audio thread, read on the main thread. Internally locked.
    let stats = StatsBox()

    /// Written by `start`, cleared by `stop`; only those two methods use it.
    private var procID: AudioDeviceIOProcID?
    /// Prepared before the IOProc exists, then written by the audio thread.
    /// Internally locked, except for the file handle, which only the audio
    /// thread reads while capture runs.
    private let writer: TempFloatWriter

    /// Audio thread only. Read by `stop` after `AudioDeviceStop`, which
    /// guarantees the callback can no longer run.
    private var firstBuffer: (count: Int, channels: UInt32, bytes: UInt32)?

    init(writer: TempFloatWriter) {
        self.writer = writer
    }

    /// Must not be called on the main thread: `AudioDeviceStart` blocks for
    /// several seconds while the aggregate device comes up.
    func start() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Stasi Tap"
        description.uuid = UUID()
        description.isPrivate = true

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr, tap != kAudioObjectUnknown else {
            throw StasiError("Could not create the audio tap (\(osStatusName(status))).")
        }
        tapID = tap

        if let format = readASBD(objectID: tap, selector: kAudioTapPropertyFormat) {
            tapFormat = format
            Log.info("tap format \(describe(format))")
        }

        let tapUID = readString(objectID: tap, selector: kAudioTapPropertyUID)
            ?? description.uuid.uuidString

        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Stasi Aggregate",
            kAudioAggregateDeviceUIDKey: "com.ineardisplay.stasi.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceTapAutoStartKey: 1,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: 1,
            ]],
        ]

        if let outputUID = defaultOutputDeviceUID() {
            // Use the output device as a clock only. Listing it as a sub-device
            // also pulls its input streams into the aggregate: with a device
            // that has inputs (BlackHole, an interface), input stream 0 is the
            // device, not the tap, and the file format and `handleIO` both pick
            // the wrong stream. A clock device contributes no streams.
            aggregate[kAudioAggregateDeviceClockDeviceKey] = outputUID
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = []
        } else {
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = []
            Log.error("no default output device; aggregate has no clock source")
        }

        var aggregateIDValue = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateIDValue)
        guard status == noErr, aggregateIDValue != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(tap)
            tapID = kAudioObjectUnknown
            throw StasiError("Could not create the capture device (\(osStatusName(status))).")
        }
        aggregateID = aggregateIDValue

        // The callback's buffers follow the aggregate's input format. The tap
        // keeps its native rate in that format even when the aggregate's clock
        // device runs at another rate (the aggregate then resamples), so the
        // rate to write at is the device's nominal rate, not the stream's.
        var ioFormat = readASBD(
            objectID: aggregateID,
            selector: kAudioDevicePropertyStreamFormat,
            scope: kAudioObjectPropertyScopeInput
        ) ?? tapFormat
        if let clockRate = readNominalSampleRate(objectID: aggregateID) {
            ioFormat.mSampleRate = clockRate
        }
        Log.info("capture format \(describe(ioFormat))")

        guard writer.prepare(format: ioFormat) else {
            stop()
            throw StasiError("Could not open the recording file (\(writer.lastError ?? "unknown error")).")
        }

        var pid: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&pid, aggregateID, nil) { [weak self] _, input, _, output, _ in
            self?.handleIO(input: input, output: output)
        }
        guard status == noErr, let pid else {
            throw StasiError("Could not create the audio callback (\(osStatusName(status))).")
        }
        procID = pid

        status = AudioDeviceStart(aggregateID, pid)
        guard status == noErr else {
            throw StasiError("Could not start audio capture (\(osStatusName(status))).")
        }
        Log.info("capture started")
    }

    func stop() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil

        // Safe to read now that the callback can no longer run.
        if let firstBuffer {
            self.firstBuffer = nil
            Log.info(
                "first buffer buffers=\(firstBuffer.count) "
                    + "channels=\(firstBuffer.channels) bytes=\(firstBuffer.bytes)"
            )
        }

        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }

        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        Log.info("capture stopped")
    }

    private func handleIO(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>
    ) {
        let inputList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        if hasData(inputList) {
            ingest(inputList)
            return
        }
        let outputList = UnsafeMutableAudioBufferListPointer(output)
        if hasData(outputList) {
            ingest(outputList)
        }
    }

    private func hasData(_ list: UnsafeMutableAudioBufferListPointer) -> Bool {
        guard list.count > 0, list[0].mData != nil else { return false }
        return list[0].mDataByteSize > 0
    }

    private func ingest(_ list: UnsafeMutableAudioBufferListPointer) {
        let first = list[0]
        guard let data = first.mData, first.mDataByteSize > 0 else { return }

        if firstBuffer == nil {
            firstBuffer = (list.count, first.mNumberChannels, first.mDataByteSize)
        }

        let floatCount = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        guard floatCount > 0 else { return }

        var peak: Float = 0
        vDSP_maxmgv(data.assumingMemoryBound(to: Float.self), 1, &peak, vDSP_Length(floatCount))

        let channels = max(Int(first.mNumberChannels), 1)
        let frames = UInt32(floatCount / channels)

        stats.record(peak: peak, frames: Int64(frames))
        writer.write(list: list, frames: frames)
    }
}

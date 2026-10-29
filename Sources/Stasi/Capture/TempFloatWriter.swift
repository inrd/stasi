import AudioToolbox
import Foundation

/// Writes the lossless float32 working copy that normalization reads back.
///
/// Float32 is chosen so capture involves no conversion at all, and so a take
/// can be normalized later without a second generation of quantization.
///
/// `prepare` creates the file and primes asynchronous writing on the calling
/// (non-audio) thread. After that, `write` only copies each buffer into the
/// file's internal ring buffer, so a slow disk can never stall the audio
/// callback.
final class TempFloatWriter: @unchecked Sendable {
    let url: URL

    private var file: ExtAudioFileRef?
    private var sampleRate: Double = 48_000
    private var channels: UInt32 = 2
    private var nonInterleaved = false
    private var permanentlyFailed = false

    private(set) var framesWritten: Int64 = 0

    /// Frames discarded because the disk could not keep up. Non-zero means the
    /// take is missing audio.
    private(set) var droppedFrames: Int64 = 0

    private var failureOperation: String?
    private var failureStatus: OSStatus = noErr

    var lastError: String? {
        guard let failureOperation else { return nil }
        return "\(failureOperation): \(osStatusName(failureStatus))"
    }

    init(url: URL) {
        self.url = url
    }

    deinit {
        close()
    }

    /// Opens the file and primes asynchronous writing.
    ///
    /// Must not be called on the audio thread: it creates the file, sets the
    /// client format and allocates the ring buffer that `write` later uses.
    @discardableResult
    func prepare(format: AudioStreamBasicDescription) -> Bool {
        if file != nil { return true }
        guard !permanentlyFailed else { return false }

        if format.mSampleRate > 0 { sampleRate = format.mSampleRate }
        if format.mChannelsPerFrame > 0 { channels = format.mChannelsPerFrame }
        nonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0

        guard let created = open() else { return false }

        // The first asynchronous call must be a zero-frame call made outside a
        // time-critical context; it allocates the internal buffer.
        let status = ExtAudioFileWriteAsync(created, 0, nil)
        guard status == noErr else {
            recordFailure("ExtAudioFileWriteAsync (prime)", status)
            Log.error("\(lastError!) path=\(url.path)")
            ExtAudioFileDispose(created)
            return false
        }

        file = created
        Log.info(
            "temp opened \(url.lastPathComponent) rate=\(Int(sampleRate)) "
                + "channels=\(channels) nonInterleaved=\(nonInterleaved)"
        )
        return true
    }

    /// Called on the Core Audio thread.
    ///
    /// Hands the buffer list to `ExtAudioFileWriteAsync`, which copies it into
    /// an internal ring buffer and returns; the disk write happens on a
    /// background thread. Nothing here may allocate, log or touch the file.
    func write(list: UnsafeMutableAudioBufferListPointer, frames: UInt32) {
        guard frames > 0 else { return }
        guard let file, !permanentlyFailed else {
            droppedFrames += Int64(frames)
            return
        }

        let status = ExtAudioFileWriteAsync(file, frames, list.unsafeMutablePointer)
        guard status == noErr else {
            // Failures from earlier writes surface on later calls. An overflow
            // only means the disk fell behind: count the gap and keep going,
            // since the writer recovers once the disk catches up. Do not
            // dispose the file here; that would flush it on the audio thread.
            if status != kExtAudioFileError_AsyncWriteBufferOverflow,
               status != kExtAudioFileError_AsyncWriteTooLarge {
                recordFailure("ExtAudioFileWriteAsync", status)
            }
            droppedFrames += Int64(frames)
            return
        }
        framesWritten += Int64(frames)
    }

    private func open() -> ExtAudioFileRef? {
        var fileFormat = AudioStreamBasicDescription()
        fileFormat.mSampleRate = sampleRate
        fileFormat.mFormatID = kAudioFormatLinearPCM
        fileFormat.mFormatFlags = kAudioFormatFlagsNativeFloatPacked
        fileFormat.mFramesPerPacket = 1
        fileFormat.mChannelsPerFrame = channels
        fileFormat.mBitsPerChannel = 32
        fileFormat.mBytesPerFrame = 4 * channels
        fileFormat.mBytesPerPacket = 4 * channels

        // CAF only stores interleaved PCM, so the file is always interleaved.
        // The client format mirrors the buffers the audio thread hands over.
        var clientFormat = fileFormat
        if nonInterleaved {
            clientFormat.mFormatFlags |= kAudioFormatFlagIsNonInterleaved
            clientFormat.mBytesPerFrame = 4
            clientFormat.mBytesPerPacket = 4
        }

        var created: ExtAudioFileRef?
        var status = ExtAudioFileCreateWithURL(
            url as CFURL,
            kAudioFileCAFType,
            &fileFormat,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &created
        )
        guard status == noErr, let created else {
            recordFailure("ExtAudioFileCreateWithURL", status)
            Log.error("\(lastError!) path=\(url.path)")
            return nil
        }

        let size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = ExtAudioFileSetProperty(created, kExtAudioFileProperty_ClientDataFormat, size, &clientFormat)
        guard status == noErr else {
            recordFailure("ExtAudioFileSetProperty", status)
            Log.error(lastError!)
            ExtAudioFileDispose(created)
            return nil
        }

        return created
    }

    private func recordFailure(_ operation: String, _ status: OSStatus) {
        permanentlyFailed = true
        failureOperation = operation
        failureStatus = status
    }

    func close() {
        guard let file else { return }
        self.file = nil
        // Disposing flushes writes still queued by ExtAudioFileWriteAsync.
        ExtAudioFileDispose(file)

        // An async buffer overflow is not always reported, so check what
        // actually reached the file rather than trusting the accepted count.
        if let onDisk = Self.frameCount(of: url), onDisk < framesWritten {
            droppedFrames += framesWritten - onDisk
        }
        Log.info("temp closed frames=\(framesWritten) dropped=\(droppedFrames)")
    }

    private static func frameCount(of url: URL) -> Int64? {
        var file: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(url as CFURL, &file) == noErr, let file else { return nil }
        defer { ExtAudioFileDispose(file) }

        var frames: Int64 = 0
        var size = UInt32(MemoryLayout<Int64>.size)
        let status = ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &size, &frames)
        return status == noErr ? frames : nil
    }
}

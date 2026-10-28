import AudioToolbox
import Foundation

/// Writes the lossless float32 working copy that normalization reads back.
///
/// Float32 is chosen so capture involves no conversion at all, and so a take
/// can be normalized later without a second generation of quantization.
final class TempFloatWriter: @unchecked Sendable {
    let url: URL

    private var file: ExtAudioFileRef?
    private var sampleRate: Double = 48_000
    private var permanentlyFailed = false

    private(set) var framesWritten: Int64 = 0
    private(set) var lastError: String?

    init(url: URL) {
        self.url = url
    }

    func configure(sampleRate: Double) {
        if sampleRate > 0 { self.sampleRate = sampleRate }
    }

    func write(list: UnsafeMutableAudioBufferListPointer, frames: UInt32) {
        guard frames > 0, !permanentlyFailed else { return }
        if file == nil, !open(list: list) { return }
        guard let file else { return }

        let status = ExtAudioFileWrite(file, frames, list.unsafeMutablePointer)
        if status != noErr {
            permanentlyFailed = true
            lastError = "ExtAudioFileWrite: \(osStatusName(status))"
            Log.error(lastError!)
            self.file = nil
            ExtAudioFileDispose(file)
            return
        }
        framesWritten += Int64(frames)
    }

    private func open(list: UnsafeMutableAudioBufferListPointer) -> Bool {
        let nonInterleaved = list.count > 1

        var format = AudioStreamBasicDescription()
        format.mSampleRate = sampleRate
        format.mFormatID = kAudioFormatLinearPCM
        format.mFormatFlags = kAudioFormatFlagsNativeFloatPacked
        format.mFramesPerPacket = 1
        format.mChannelsPerFrame = 2
        format.mBitsPerChannel = 32
        if nonInterleaved {
            format.mFormatFlags |= kAudioFormatFlagIsNonInterleaved
            format.mBytesPerFrame = 4
            format.mBytesPerPacket = 4
        } else {
            format.mBytesPerFrame = 8
            format.mBytesPerPacket = 8
        }

        var created: ExtAudioFileRef?
        var status = ExtAudioFileCreateWithURL(
            url as CFURL,
            kAudioFileCAFType,
            &format,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &created
        )
        guard status == noErr, let created else {
            permanentlyFailed = true
            lastError = "ExtAudioFileCreateWithURL: \(osStatusName(status))"
            Log.error("\(lastError!) path=\(url.path)")
            return false
        }

        var client = format
        let size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = ExtAudioFileSetProperty(created, kExtAudioFileProperty_ClientDataFormat, size, &client)
        guard status == noErr else {
            permanentlyFailed = true
            lastError = "ExtAudioFileSetProperty: \(osStatusName(status))"
            Log.error(lastError!)
            ExtAudioFileDispose(created)
            return false
        }

        file = created
        Log.info("temp opened \(url.lastPathComponent) rate=\(Int(sampleRate)) nonInterleaved=\(nonInterleaved)")
        return true
    }

    func close() {
        guard let file else { return }
        ExtAudioFileDispose(file)
        self.file = nil
        Log.info("temp closed frames=\(framesWritten)")
    }
}

import CoreAudio
import Foundation

struct StasiError: Error, LocalizedError, CustomStringConvertible {
    let message: String

    init(_ message: String) { self.message = message }

    var description: String { message }
    var errorDescription: String? { message }
}

func osStatusName(_ status: OSStatus) -> String {
    if status == noErr { return "noErr" }

    let value = UInt32(bitPattern: status)
    let bytes: [UInt8] = [
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8(value & 0xFF),
    ]
    if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }), let fourCC = String(bytes: bytes, encoding: .ascii) {
        return "'\(fourCC)' (\(status))"
    }
    return "\(status)"
}

func readASBD(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioStreamBasicDescription? {
    var asbd = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &asbd)
    guard status == noErr else { return nil }
    return asbd
}

func readString(objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
    var stored: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let status = withUnsafeMutablePointer(to: &stored) { pointer in
        AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
    }
    guard status == noErr else { return nil }
    let value = stored as String
    return value.isEmpty ? nil : value
}

func defaultOutputDeviceUID() -> String? {
    var deviceID = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address, 0, nil, &size, &deviceID
    )
    guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
    return readString(objectID: deviceID, selector: kAudioDevicePropertyDeviceUID)
}

func describe(_ format: AudioStreamBasicDescription) -> String {
    let flags = format.mFormatFlags
    let layout = (flags & kAudioFormatFlagIsNonInterleaved) != 0 ? "non-interleaved" : "interleaved"
    let kind: String
    if format.mFormatID == kAudioFormatLinearPCM {
        kind = (flags & kAudioFormatFlagIsFloat) != 0
            ? "float\(format.mBitsPerChannel)"
            : "int\(format.mBitsPerChannel)"
    } else {
        kind = "formatID=\(format.mFormatID)"
    }
    return String(
        format: "%.0f Hz, %u ch, %@, %@, bytesPerFrame=%u",
        format.mSampleRate,
        format.mChannelsPerFrame,
        kind,
        layout,
        format.mBytesPerFrame
    )
}

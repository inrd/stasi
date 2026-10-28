import CoreAudio
import Foundation

/// Watches the system's default output device.
///
/// Changing the output device mid-take is not hot-swapped: sample rate and clock
/// source can change with it, so the engine finalizes the current file instead.
final class AudioDeviceObserver: @unchecked Sendable {
    var onChange: (@Sendable (String?) -> Void)?

    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private let queue = DispatchQueue(label: "app.stasi.device-observer")
    private var listener: AudioObjectPropertyListenerBlock?
    private var currentUID: String?

    func start() {
        guard listener == nil else { return }

        currentUID = defaultOutputDeviceUID()

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let uid = defaultOutputDeviceUID()
            // The property also fires for unrelated hardware changes.
            guard uid != self.currentUID else { return }
            self.currentUID = uid
            self.onChange?(uid)
        }
        listener = block

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            block
        )

        if status != noErr {
            Log.error("could not observe the output device (\(osStatusName(status)))")
            listener = nil
            return
        }
        Log.info("observing output device (currently \(currentUID ?? "unknown"))")
    }

    func stop() {
        guard let listener else { return }
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            listener
        )
        self.listener = nil
        Log.info("stopped observing output device")
    }
}

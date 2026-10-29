import CoreAudio
import Foundation

/// Watches the system's default output device.
///
/// Changing the output device mid-take is not hot-swapped: sample rate and clock
/// source can change with it, so the engine finalizes the current file instead.
///
/// Main-actor isolated, so the compiler checks the state that used to be a
/// documented rule: `currentUID` and `listener` are only touched on the main
/// thread. The HAL delivers the listener block on `queue`; the block reads the
/// device UID there (a thread-safe HAL query) and hops to the main actor before
/// comparing or reporting it.
@MainActor
final class AudioDeviceObserver {
    /// Set once at init, so the listener never races with a reassignment.
    private let onChange: @MainActor @Sendable (String?) -> Void
    private let queue = DispatchQueue(label: "app.stasi.device-observer")

    /// Main thread only.
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    /// Main thread only.
    private var listener: AudioObjectPropertyListenerBlock?
    /// Main thread only after `start` registers the listener; the block hops to
    /// the main actor before reading it.
    private var currentUID: String?

    init(onChange: @escaping @MainActor @Sendable (String?) -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard listener == nil else { return }

        currentUID = defaultOutputDeviceUID()

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            let uid = defaultOutputDeviceUID()
            Task { @MainActor [weak self] in
                self?.defaultOutputDeviceChanged(to: uid)
            }
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

    private func defaultOutputDeviceChanged(to uid: String?) {
        // The property also fires for unrelated hardware changes.
        guard uid != currentUID else { return }
        currentUID = uid
        onChange(uid)
    }
}

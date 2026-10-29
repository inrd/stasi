import AppKit
import Foundation

@MainActor
final class RecorderModel: ObservableObject {
    static let shared = RecorderModel()

    enum State: Equatable {
        case idle
        case starting
        case recording
        case saving(progress: Double)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var warning: String?
    @Published private(set) var notice: String?
    @Published private(set) var lastFile: URL?
    @Published private(set) var lastSummary: String?
    @Published private(set) var outputFolder: URL?

    private var tap: SystemAudioTap?
    private var writer: TempFloatWriter?
    private var tempURL: URL?
    private var destinationURL: URL?
    private var recordingStart: Date?
    private var ticker: Timer?
    private var quitHandler: (() -> Void)?

    private lazy var deviceObserver = AudioDeviceObserver { [weak self] uid in
        self?.outputDeviceChanged(to: uid)
    }
    private var restartAfterSave = false
    private var pendingNote: String?
    private var lastDiskCheck = Date.distantPast
    private var droppedFramesAtSave: Int64 = 0
    private var writeErrorAtSave: String?

    /// 24-bit stereo: 6 bytes per frame.
    private let wavBytesPerFrame: Int64 = 6

    private init() {
        outputFolder = Preferences.loadOutputFolder()
    }

    // MARK: Derived state

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    var isSaving: Bool {
        if case .saving = state { return true }
        return false
    }

    var isStarting: Bool {
        if case .starting = state { return true }
        return false
    }

    var needsFinalize: Bool { isRecording || isSaving }

    var elapsedLabel: String {
        let total = Int(elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: Lifecycle

    func bootstrap() {
        TempStorage.cleanOld()

        if let seconds = Self.autoRecordSeconds {
            Log.info("auto-record test hook armed for \(seconds)s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.start()
            }
        }

        guard outputFolder == nil else { return }
        // Let the app finish launching before presenting a modal panel.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.chooseFolder()
        }
    }

    // MARK: Folder

    @discardableResult
    func chooseFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose where Stasi saves WAV recordings"
        panel.directoryURL = outputFolder
            ?? FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first

        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return false }

        outputFolder = url
        Preferences.saveOutputFolder(url)
        Log.info("output folder set to \(url.path)")
        return true
    }

    func revealOutputFolder() {
        guard let outputFolder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([outputFolder])
    }

    func revealLastFile() {
        guard let lastFile else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastFile])
    }

    // MARK: Recording

    func toggle() {
        if isRecording {
            stop()
        } else {
            start()
        }
    }

    func start() {
        start(userInitiated: true)
    }

    private func start(userInitiated: Bool) {
        switch state {
        case .idle, .failed:
            break
        default:
            return
        }

        guard let folder = outputFolder, FileManager.default.fileExists(atPath: folder.path) else {
            if userInitiated {
                if chooseFolder() { start(userInitiated: true) }
            } else {
                notice = "Could not continue in a new file: the output folder is unavailable."
            }
            return
        }

        guard hasFreeSpace(in: folder, minimum: 500 * 1024 * 1024) else {
            warning = "Not enough free disk space to record."
            return
        }

        let destination = makeDestinationURL(in: folder)
        let temp = TempStorage.makeURL()
        let writer = TempFloatWriter(url: temp)
        let tap = SystemAudioTap(writer: writer)

        self.writer = writer
        self.tap = tap
        self.tempURL = temp
        self.destinationURL = destination
        self.warning = nil
        self.lastSummary = nil
        self.elapsed = 0
        self.droppedFramesAtSave = 0
        self.writeErrorAtSave = nil
        self.state = .starting
        if userInitiated { notice = nil }

        Log.info("starting capture -> \(destination.lastPathComponent)")

        Task { [weak self] in
            do {
                // AudioDeviceStart blocks for seconds; keep it off the main thread.
                try await Task.detached(priority: .userInitiated) {
                    try tap.start()
                }.value

                guard let self else { return }
                self.recordingStart = Date()
                self.lastDiskCheck = Date()
                self.state = .recording
                self.startTicker()
                self.startDeviceObserver()

                if let seconds = Self.autoRecordSeconds {
                    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                        self?.stop()
                    }
                }
            } catch {
                self?.fail(error, keptFile: nil)
            }
        }
    }

    func stop() {
        stop(note: nil, restart: false)
    }

    private func stop(note: String?, restart: Bool) {
        guard isRecording else { return }

        ticker?.invalidate()
        ticker = nil
        deviceObserver.stop()
        if let recordingStart {
            elapsed = Date().timeIntervalSince(recordingStart)
        }

        pendingNote = note
        restartAfterSave = restart

        state = .saving(progress: 0)
        Log.info("stopping after \(String(format: "%.2f", elapsed))s" + (note.map { " (\($0))" } ?? ""))

        tap?.stop()
        // `stats.frames` counts every frame the callback received, including
        // any the writer could not queue. The file is the only reliable record
        // of what survived, so the loss is simply the difference.
        let receivedFrames = tap?.stats.snapshot().frames ?? 0
        let onDiskFrames = writer?.close()
        droppedFramesAtSave = onDiskFrames.map { max(0, receivedFrames - $0) } ?? 0
        Log.info(
            "capture frames received=\(receivedFrames) "
                + "onDisk=\(onDiskFrames.map(String.init) ?? "unknown") "
                + "dropped=\(droppedFramesAtSave)"
        )
        writeErrorAtSave = writer?.lastError
        beginNormalize()
    }

    /// Called from `applicationShouldTerminate`. Completion runs when it is safe
    /// to quit (after the file is finalized).
    func finalizeBeforeQuit(_ completion: @escaping () -> Void) {
        if isRecording {
            quitHandler = completion
            stop()
        } else if isSaving {
            quitHandler = completion
        } else {
            completion()
        }
    }

    // MARK: System events

    private func startDeviceObserver() {
        deviceObserver.start()
    }

    private func outputDeviceChanged(to uid: String?) {
        guard isRecording else { return }
        Log.info("default output changed to \(uid ?? "none")")
        stop(note: "Output device changed — recording saved.", restart: false)
    }

    /// Called from `NSWorkspace.willSleepNotification`.
    func systemWillSleep() {
        guard isRecording else { return }
        Log.info("system will sleep; finalizing")
        stop(note: "The Mac went to sleep — recording saved.", restart: false)
    }

    // MARK: Ticker

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let recordingStart else { return }
        elapsed = Date().timeIntervalSince(recordingStart)

        guard let tap else { return }
        let stats = tap.stats.snapshot()

        // A RIFF WAV cannot exceed 4 GiB; roll into a new file before that.
        if stats.frames * wavBytesPerFrame >= Self.maxWavBytes {
            stop(note: "Reached the file size limit — continuing in a new file.", restart: true)
            return
        }

        if Date().timeIntervalSince(lastDiskCheck) > 5 {
            lastDiskCheck = Date()
            if let folder = destinationURL?.deletingLastPathComponent(),
               !hasFreeSpace(in: folder, minimum: 200 * 1024 * 1024) {
                stop(note: "Disk almost full — recording saved.", restart: false)
                return
            }
        }

        if let writeError = writer?.lastError {
            warning = "File write failed: \(writeError)"
        } else if stats.peak == 0, elapsed > 2.5, stats.frames > 0 {
            warning = "Silence — if audio is playing, grant System Audio Recording in System Settings."
        } else {
            warning = nil
        }
    }

    // MARK: Finalize

    private func beginNormalize() {
        guard let temp = tempURL, let destination = destinationURL else {
            state = .idle
            finishQuitIfNeeded()
            return
        }

        Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try WavNormalizer.normalize(
                        source: temp,
                        destination: destination,
                        settings: WavSettings()
                    ) { progress in
                        Task { @MainActor [weak self] in
                            guard let self, self.isSaving else { return }
                            self.state = .saving(progress: progress)
                        }
                    }
                }.value

                try? FileManager.default.removeItem(at: temp)
                self?.didFinish(result, destination: destination)
            } catch {
                // Keep the raw take: a failed normalize should never lose audio.
                self?.fail(error, keptFile: temp)
            }
        }
    }

    private func didFinish(_ result: NormalizationResult, destination: URL) {
        tap = nil
        writer = nil
        tempURL = nil
        destinationURL = nil
        recordingStart = nil

        lastFile = destination
        lastSummary = String(
            format: "%.2f s · peak %.3f → %.3f (%+.1f dB)",
            result.duration, result.peakBefore, result.peakAfter, result.gainDB
        )
        if let writeError = writeErrorAtSave {
            warning = "File write failed: \(writeError)"
        } else if droppedFramesAtSave > 0 {
            warning = "Audio dropped — the disk could not keep up (\(droppedFramesAtSave) frames)."
        } else {
            warning = result.wasSilent ? "The recording was silent." : nil
        }
        notice = pendingNote
        pendingNote = nil
        state = .idle

        Log.info("saved \(destination.lastPathComponent) \(lastSummary ?? "")")
        finishQuitIfNeeded()

        if restartAfterSave, quitHandler == nil {
            restartAfterSave = false
            // Let the finished take's notice be seen before starting again.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.start(userInitiated: false)
            }
        }
    }

    private func fail(_ error: Error, keptFile: URL?) {
        ticker?.invalidate()
        ticker = nil

        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        Log.error("capture failed: \(message)")

        deviceObserver.stop()
        tap?.stop()
        tap = nil
        writer = nil
        tempURL = nil
        pendingNote = nil
        restartAfterSave = false
        destinationURL = nil
        recordingStart = nil

        state = .failed(message)
        warning = keptFile.map { "Raw audio kept at \($0.lastPathComponent)" }
        finishQuitIfNeeded()
    }

    private func finishQuitIfNeeded() {
        guard let quitHandler else { return }
        self.quitHandler = nil
        quitHandler()
    }

    // MARK: Helpers

    private func hasFreeSpace(in folder: URL, minimum: Int64) -> Bool {
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage else { return true }
        return available > minimum
    }

    /// Stay clear of the 4 GiB RIFF ceiling.
    private static var maxWavBytes: Int64 {
        if let override = numericArgument("--max-wav-bytes") { return Int64(override) }
        return 3_900_000_000
    }

    private static func numericArgument(_ name: String) -> Double? {
        guard let index = CommandLine.arguments.firstIndex(of: name),
              index + 1 < CommandLine.arguments.count,
              let value = Double(CommandLine.arguments[index + 1]) else { return nil }
        return value
    }

    /// Test hook: `--auto-record <seconds>` records without touching the UI.
    private static var autoRecordSeconds: Double? { numericArgument("--auto-record") }

    private func makeDestinationURL(in folder: URL) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")

        let base = formatter.string(from: Date())
        var candidate = folder.appendingPathComponent("\(base).wav")
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(index).wav")
            index += 1
        }
        return candidate
    }
}

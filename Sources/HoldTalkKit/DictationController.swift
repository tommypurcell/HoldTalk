import AppKit
import AVFoundation

/// Connects the keyboard, microphone, transcription, pill and paste, following
/// what `DictationMachine` decides.
@MainActor
public final class DictationController {
    public var onRecordingChanged: ((Bool) -> Void)?
    public var onNotice: ((String) -> Void)?

    private var config: Config
    private var env: EnvFile
    private var machine: DictationMachine
    private let monitor = HotkeyMonitor()
    private let recorder: AudioRecording
    private let insert: (String, Bool) -> TextInserter.Outcome
    private let makePipeline: (Config, EnvFile) -> DictationPipeline
    private let pill = PillWindow()

    private var secondTapTimer: DispatchWorkItem?
    private var undoTimer: DispatchWorkItem?
    private var limitTimer: Timer?
    private var recordingStarted = Date()
    private var stoppedAtLimit = false
    private var processingTask: Task<Void, Never>?
    private var sleepObservers: [NSObjectProtocol] = []

    public convenience init(config: Config, env: EnvFile) {
        let inserter = TextInserter()
        self.init(config: config, env: env, recorder: Recorder(),
                  insert: { inserter.insert($0, restoreClipboard: $1) },
                  makePipeline: { DictationPipeline.make(config: $0, env: $1) })
    }

    /// Tests pass a fake recorder and paste here, so they can't type into other apps.
    init(config: Config, env: EnvFile, recorder: AudioRecording,
         insert: @escaping (String, Bool) -> TextInserter.Outcome,
         makePipeline: @escaping (Config, EnvFile) -> DictationPipeline) {
        self.config = config
        self.env = env
        self.recorder = recorder
        self.insert = insert
        self.makePipeline = makePipeline
        machine = Self.makeMachine(config)
        recorder.noiseSuppression = config.noiseSuppression
        recorder.onLevel = { [weak self] level in
            MainActor.assumeIsolated { self?.pill.setLevel(level) }
        }
        recorder.onFailure = { [weak self] message in
            MainActor.assumeIsolated {
                self?.send(.recordingFailed)
                self?.report(message, isError: true)
            }
        }
        monitor.onSignal = { [weak self] signal in self?.handle(signal) }
        Self.removeLeftoverAudio()

        // Don't leave the mic open behind a sleeping or locked Mac.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            sleepObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.send(.shutDown) }
            })
        }
        sleepObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.send(.shutDown) }
        })
    }

    public var isWatchingKeyboard: Bool { monitor.isWatching }

    public func setEnabled(_ enabled: Bool) {
        if enabled {
            if let hotkey = try? Hotkey.parse(config.hotkey) { monitor.start(hotkey: hotkey) }
        } else {
            send(.shutDown)
            monitor.stop()
        }
    }

    /// Applies new settings. Anything running is cancelled first.
    public func apply(config: Config, env: EnvFile, enabled: Bool) {
        send(.shutDown)
        self.config = config
        self.env = env
        machine = Self.makeMachine(config)
        recorder.noiseSuppression = config.noiseSuppression
        setEnabled(enabled)
    }

    private static func makeMachine(_ config: Config) -> DictationMachine {
        DictationMachine(tapMaxSeconds: config.tapMaxMilliseconds / 1000,
                         doubleTapWindowSeconds: config.doubleTapWindowMilliseconds / 1000)
    }

    func handle(_ signal: HotkeyMonitor.Signal) {
        let now = ProcessInfo.processInfo.systemUptime
        switch signal {
        case .hotkeyDown: send(.hotkeyDown(at: now))
        case .hotkeyUp: send(.hotkeyUp(at: now))
        case .otherKey: send(.otherKey(at: now))
        case .escape: send(.escape)
        }
    }

    private func send(_ event: DictationMachine.Event) {
        let effects = machine.handle(event)
        stoppedAtLimit = event == .recordingLimitReached && !effects.isEmpty
        for effect in effects { perform(effect) }
        refreshPill()
    }

    private func perform(_ effect: DictationMachine.Effect) {
        switch effect {
        case .startRecording:
            recordingStarted = Date()
            pill.setLevel(0)
            recorder.start()
            startLimitTimer()
            onRecordingChanged?(true)

        case .finishRecording:
            stopLimitTimer()
            onRecordingChanged?(false)
            startProcessing()

        case .discardRecording:
            stopLimitTimer()
            recorder.discard()
            onRecordingChanged?(false)
            pill.hide()

        case .pauseRecording:
            // The limit clock keeps ticking on purpose: pausing must not buy
            // extra recording time. The pill shows the undo offer instead of
            // the meter, and the mic reports as off.
            recorder.pause()
            onRecordingChanged?(false)

        case .resumeRecording:
            // recordingStarted is untouched, so the limit still counts from
            // when the recording first began.
            pill.setLevel(0)
            recorder.resume()
            onRecordingChanged?(true)

        case .cancelProcessing:
            processingTask?.cancel()
            processingTask = nil
            pill.hide()

        case .startSecondTapTimer(let delay):
            let work = DispatchWorkItem { [weak self] in self?.send(.secondTapTimedOut) }
            secondTapTimer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)

        case .cancelSecondTapTimer:
            secondTapTimer?.cancel()
            secondTapTimer = nil

        case .startUndoTimer(let delay):
            let work = DispatchWorkItem { [weak self] in self?.send(.undoWindowTimedOut) }
            undoTimer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)

        case .cancelUndoTimer:
            undoTimer?.cancel()
            undoTimer = nil
        }
    }

    private func refreshPill() {
        switch machine.state {
        case .holding, .awaitingSecondTap:
            pill.show(.holding)
        case .handsFree:
            pill.show(handsFreeContent())
        case .awaitingUndo:
            pill.show(.cancelled(hint: "press \(config.hotkey) to undo"))
        case .processing:
            pill.show(.transcribing)
        case .idle:
            break
        }
    }

    private func handsFreeContent() -> PillContent {
        let elapsed = Int(Date().timeIntervalSince(recordingStarted))
        return .handsFree(secondsLeft: max(0, Int(config.maxRecordingSeconds) - elapsed), elapsed: elapsed)
    }

    private func startLimitTimer() {
        stopLimitTimer()
        // Ticks each second to update the pill's clock and enforce the limit.
        limitTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if Date().timeIntervalSince(self.recordingStarted) >= self.config.maxRecordingSeconds {
                    self.send(.recordingLimitReached)
                } else if self.machine.state == .handsFree {
                    self.pill.show(self.handsFreeContent())
                }
            }
        }
    }

    private func stopLimitTimer() {
        limitTimer?.invalidate()
        limitTimer = nil
    }

    private func startProcessing() {
        let pipeline = makePipeline(config, env)
        let restoreClipboard = config.restoreClipboard
        let recorder = recorder

        processingTask = Task { [weak self] in
            let audio = await recorder.finish()
            guard !Task.isCancelled else { return }
            guard !audio.isLikelyEmpty else {
                self?.finish(message: "No speech heard")
                return
            }
            do {
                let wav = try Self.writeTemporaryAudio(audio)
                defer { try? FileManager.default.removeItem(at: wav) }
                let result = try await pipeline.run(wav: wav)
                // This runs on the main thread, as Esc does, so the check can't race:
                // once Esc is handled, this can never paste.
                guard !Task.isCancelled else { return }
                self?.deliver(result, restoreClipboard: restoreClipboard)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.finish(message: error.localizedDescription, isError: true)
            }
        }
    }

    private func deliver(_ result: DictationPipeline.Result, restoreClipboard: Bool) {
        guard !result.text.isEmpty else {
            finish(message: result.notice ?? "No speech heard", isError: result.notice != nil)
            return
        }
        switch insert(result.text, restoreClipboard) {
        case .pasted:
            let limitNote = stoppedAtLimit ? "Stopped at the \(limitDescription) limit" : nil
            finish(message: result.notice ?? limitNote, isError: result.notice != nil)
        case .copiedOnly:
            finish(message: "Copied. Allow Accessibility to paste automatically", isError: true)
        }
    }

    private var limitDescription: String {
        let seconds = Int(config.maxRecordingSeconds)
        return seconds % 60 == 0 ? "\(seconds / 60) minute" : "\(seconds) second"
    }

    private func finish(message: String?, isError: Bool = false) {
        processingTask = nil
        _ = machine.handle(.processingFinished)
        if let message {
            report(message, isError: isError)
        } else {
            pill.hide()
        }
    }

    private func report(_ message: String, isError: Bool) {
        pill.flash(message, isError: isError)
        if isError { onNotice?(message) }
    }

    // MARK: - Temporary audio

    private static var audioFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("holdtalk", isDirectory: true)
    }

    /// Speech is only on disk while being transcribed, readable only by you.
    private static func writeTemporaryAudio(_ audio: SpeechAudio) throws -> URL {
        let folder = audioFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent("\(UUID().uuidString).wav")
        guard FileManager.default.createFile(atPath: url.path, contents: audio.wavData(),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw TranscriptionError("Couldn't write temporary audio.")
        }
        return url
    }

    /// Removes anything left behind by a crash.
    private static func removeLeftoverAudio() {
        try? FileManager.default.removeItem(at: audioFolder)
    }
}

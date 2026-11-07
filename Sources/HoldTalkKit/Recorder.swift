import AVFoundation
import Foundation

public protocol AudioRecording: AnyObject {
    var onLevel: ((Float) -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    func start()
    /// Stops capturing but keeps what was recorded, for the undo window after Esc.
    func pause()
    /// Continues the same recording after a pause.
    func resume()
    func finish() async -> SpeechAudio
    func discard()
}

/// Records the microphone into memory. Audio is never written to disk here.
///
/// All engine work runs on one background queue because starting the mic can take
/// hundreds of milliseconds, and the main thread has to keep timing key presses.
/// Being serial also keeps start and stop in order after a very quick tap.
public final class Recorder: AudioRecording {
    public var onLevel: ((Float) -> Void)?
    public var onFailure: ((String) -> Void)?

    private let queue = DispatchQueue(label: "holdtalk.recorder")
    private var engine: AVAudioEngine?
    private var resampler: SpeechResampler?
    private var samples: [Float] = []
    private var configObserver: NSObjectProtocol?

    public init() {}

    public func start() {
        queue.async { [self] in
            samples = []
            samples.reserveCapacity(Int(SpeechAudio.sampleRate) * 60)
            let access = AVCaptureDevice.authorizationStatus(for: .audio)
            if access == .denied || access == .restricted {
                DispatchQueue.main.async { [onFailure] in onFailure?("Microphone access is off") }
                return
            }
            do {
                try startEngine()
            } catch {
                stopEngine()
                DispatchQueue.main.async { [onFailure] in onFailure?(error.localizedDescription) }
            }
        }
    }

    /// Stops capturing but keeps the samples already recorded, so Esc can be
    /// undone. The mic is fully released while paused: nothing is captured.
    public func pause() {
        queue.async { [self] in
            if let resampler { samples.append(contentsOf: resampler.flush()) }
            stopEngine()
        }
    }

    /// Carries on with the same recording after a pause. Whatever was said
    /// before Esc is still in the buffer, and the resampler starts fresh.
    public func resume() {
        queue.async { [self] in
            guard engine == nil else { return }
            do {
                try startEngine()
            } catch {
                stopEngine()
                DispatchQueue.main.async { [onFailure] in onFailure?(error.localizedDescription) }
            }
        }
    }

    /// Stops and hands back everything recorded.
    public func finish() async -> SpeechAudio {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if let resampler { samples.append(contentsOf: resampler.flush()) }
                stopEngine()
                let audio = SpeechAudio(samples: samples)
                samples = []
                continuation.resume(returning: audio)
            }
        }
    }

    public func discard() {
        queue.async { [self] in
            stopEngine()
            samples = []
        }
    }

    private struct NoMicrophone: LocalizedError {
        var errorDescription: String? { "No microphone is available." }
    }

    private func startEngine() throws {
        let engine = AVAudioEngine()
        self.engine = engine
        try installTap(on: engine)
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.queue.async { self?.restartAfterDeviceChange() }
        }
        try engine.start()
    }

    private func installTap(on engine: AVAudioEngine) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let resampler = SpeechResampler(inputFormat: format) else { throw NoMicrophone() }
        self.resampler = resampler
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.queue.async {
                // A buffer still in flight from an earlier recording must not join this one.
                guard self?.resampler === resampler else { return }
                self?.append(buffer)
            }
        }
    }

    /// A headset was plugged in or removed mid-sentence. Keep what's recorded and carry on.
    private func restartAfterDeviceChange() {
        guard let engine else { return }
        if let resampler { samples.append(contentsOf: resampler.flush()) }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        do {
            try installTap(on: engine)
            try engine.start()
        } catch {
            stopEngine()
            DispatchQueue.main.async { [onFailure] in onFailure?("The microphone changed and couldn't restart.") }
        }
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard engine != nil, let converted = resampler?.convert(buffer), !converted.isEmpty else { return }
        samples.append(contentsOf: converted)
        let level = converted.reduce(0) { max($0, abs($1)) }
        DispatchQueue.main.async { [onLevel] in onLevel?(level) }
    }

    private func stopEngine() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        resampler = nil
    }
}

import XCTest
@testable import HoldTalkKit

private final class FakeRecorder: AudioRecording {
    var onLevel: ((Float) -> Void)?
    var onFailure: ((String) -> Void)?
    var starts = 0, finishes = 0, discards = 0
    var audio = SpeechAudio(samples: Array(repeating: 0.2, count: 16_000))
    func start() { starts += 1 }
    func finish() async -> SpeechAudio { finishes += 1; return audio }
    func discard() { discards += 1 }
}

private final class SlowTranscriber: Transcriber {
    let name = "slow"
    let seconds: Double
    let text: String
    var sawWav = false
    var wavPermissions: Int?
    var wavPath: String?
    init(seconds: Double, text: String) { self.seconds = seconds; self.text = text }
    func transcribe(wav: URL) async throws -> String {
        sawWav = FileManager.default.fileExists(atPath: wav.path)
        wavPath = wav.path
        wavPermissions = (try? FileManager.default.attributesOfItem(atPath: wav.path)[.posixPermissions]) as? Int
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return text
    }
}

/// The real controller and timers. Only the mic, transcriber and paste are fake.
@MainActor
final class DictationControllerTests: XCTestCase {
    private var recorder = FakeRecorder()
    private var pasted: [String] = []
    private var restoreFlags: [Bool] = []
    private var outcome = TextInserter.Outcome.pasted

    override func setUp() async throws {
        recorder = FakeRecorder()
        pasted = []
        restoreFlags = []
        outcome = .pasted
    }

    private func makeController(config: Config = Config(), transcriber: Transcriber) -> DictationController {
        DictationController(
            config: config, env: EnvFile(), recorder: recorder,
            insert: { [weak self] text, restore in
                self?.pasted.append(text)
                self?.restoreFlags.append(restore)
                return self?.outcome ?? .pasted
            },
            makePipeline: { _, _ in DictationPipeline(transcribers: [transcriber], cleaner: nil) })
    }

    private func wait(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func hold(_ controller: DictationController, for seconds: Double = 0.3) async {
        controller.handle(.hotkeyDown)
        await wait(seconds)
        controller.handle(.hotkeyUp)
    }

    func testHoldRecordsTranscribesAndPastesOnce() async {
        let transcriber = SlowTranscriber(seconds: 0.05, text: " hello world ")
        let controller = makeController(transcriber: transcriber)
        await hold(controller)
        XCTAssertEqual(recorder.starts, 1)
        await wait(0.3)
        XCTAssertEqual(pasted, ["hello world"])
        XCTAssertEqual(restoreFlags, [false], "Default leaves the transcript on the clipboard")
        XCTAssertTrue(transcriber.sawWav)
        XCTAssertEqual(transcriber.wavPermissions, 0o600, "Speech audio is private to you")
        XCTAssertFalse(FileManager.default.fileExists(atPath: transcriber.wavPath!), "Audio is deleted afterwards")
    }

    func testRestoreClipboardFlagReachesPaste() async {
        var config = Config()
        config.restoreClipboard = true
        let controller = makeController(config: config, transcriber: SlowTranscriber(seconds: 0, text: "hi"))
        await hold(controller)
        await wait(0.2)
        XCTAssertEqual(restoreFlags, [true])
    }

    func testEscDuringTranscriptionNeverPastesAndNextDictationWorks() async {
        let transcriber = SlowTranscriber(seconds: 0.5, text: "must not appear")
        let controller = makeController(transcriber: transcriber)
        await hold(controller)
        await wait(0.1)
        controller.handle(.escape)
        await wait(0.7)
        XCTAssertEqual(pasted, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: transcriber.wavPath ?? "/"), "Cancelled audio is deleted")

        await hold(controller)
        await wait(0.8)
        XCTAssertEqual(pasted, ["must not appear"], "The next dictation still works")
    }

    func testEscWhileRecordingDiscardsWithoutTranscribing() async {
        let transcriber = SlowTranscriber(seconds: 0, text: "no")
        let controller = makeController(transcriber: transcriber)
        controller.handle(.hotkeyDown)
        await wait(0.3)
        controller.handle(.escape)
        controller.handle(.hotkeyUp)
        await wait(0.2)
        XCTAssertEqual(recorder.discards, 1)
        XCTAssertEqual(recorder.finishes, 0)
        XCTAssertNil(transcriber.wavPath)
        XCTAssertEqual(pasted, [])
    }

    func testSingleTapDiscardsAfterWindow() async {
        let controller = makeController(transcriber: SlowTranscriber(seconds: 0, text: "no"))
        await hold(controller, for: 0.05)
        XCTAssertEqual(recorder.discards, 0, "Still waiting for a possible second tap")
        await wait(0.5)
        XCTAssertEqual(recorder.discards, 1)
        XCTAssertEqual(pasted, [])
    }

    func testDoubleTapHandsFreeThenTapStops() async {
        let controller = makeController(transcriber: SlowTranscriber(seconds: 0, text: "hands free"))
        await hold(controller, for: 0.05)
        await wait(0.05)
        await hold(controller, for: 0.05)
        await wait(0.6)
        XCTAssertEqual(recorder.discards, 0, "The window timer must not throw it away")
        XCTAssertEqual(recorder.finishes, 0, "Still recording with nothing held")

        controller.handle(.hotkeyDown)
        controller.handle(.hotkeyUp)
        await wait(0.2)
        XCTAssertEqual(recorder.starts, 1)
        XCTAssertEqual(pasted, ["hands free"])
    }

    func testHandsFreeAutoStopsAtLimitAndKeepsTheSpeech() async {
        var config = Config()
        config.maxRecordingSeconds = 1
        let controller = makeController(config: config, transcriber: SlowTranscriber(seconds: 0, text: "long session"))
        await hold(controller, for: 0.05)
        await wait(0.05)
        await hold(controller, for: 0.05)
        await wait(1.5)
        XCTAssertEqual(recorder.finishes, 1)
        XCTAssertEqual(pasted, ["long session"])
    }

    func testSilenceIsNeverTranscribed() async {
        recorder.audio = SpeechAudio(samples: Array(repeating: 0, count: 32_000))
        let transcriber = SlowTranscriber(seconds: 0, text: "Thanks for watching!")
        let controller = makeController(transcriber: transcriber)
        await hold(controller)
        await wait(0.2)
        XCTAssertNil(transcriber.wavPath)
        XCTAssertEqual(pasted, [])

        recorder.audio = SpeechAudio(samples: Array(repeating: 0.2, count: 16_000))
        await hold(controller)
        await wait(0.2)
        XCTAssertEqual(pasted.count, 1, "Returns to idle afterwards")
    }

    func testMicFailureReturnsToIdle() async {
        let controller = makeController(transcriber: SlowTranscriber(seconds: 0, text: "x"))
        controller.handle(.hotkeyDown)
        recorder.onFailure?("No microphone is available.")
        controller.handle(.hotkeyUp)
        await wait(0.1)
        XCTAssertEqual(recorder.finishes, 0)
        await hold(controller)
        await wait(0.2)
        XCTAssertEqual(pasted, ["x"])
    }

    func testTurningOffCancelsEverything() async {
        let controller = makeController(transcriber: SlowTranscriber(seconds: 0.3, text: "no"))
        await hold(controller)
        await wait(0.05)
        controller.setEnabled(false)
        await wait(0.5)
        XCTAssertEqual(pasted, [])
    }

    func testPressingTheHotkeyPreparesTranscriptionAndTurningOffReleasesIt() async {
        var prepared: [Config] = []
        var released = 0
        var config = Config()
        config.language = "en"
        let transcriber = SlowTranscriber(seconds: 0, text: "hi")
        let controller = DictationController(
            config: config, env: EnvFile(), recorder: recorder,
            insert: { _, _ in .pasted },
            makePipeline: { _, _ in DictationPipeline(transcribers: [transcriber], cleaner: nil) },
            prepareTranscription: { prepared.append($0) },
            releaseTranscription: { released += 1 })

        XCTAssertEqual(prepared, [], "Nothing loads until you press the hotkey")
        controller.handle(.hotkeyDown)
        XCTAssertEqual(prepared, [config])
        XCTAssertEqual(released, 0)

        controller.setEnabled(false)
        XCTAssertEqual(released, 1, "Turning off frees the model's memory")
    }
}

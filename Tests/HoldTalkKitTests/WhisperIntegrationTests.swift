import AppKit
import XCTest
@testable import HoldTalkKit

/// Uses the real whisper-cli and model. Skipped on machines without them.
final class WhisperIntegrationTests: XCTestCase {
    private var folder: URL!
    private var wav: URL!

    override func setUpWithError() throws {
        let config = Config()
        try XCTSkipIf(config.whisperExecutable == nil, "whisper-cli isn't installed")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: config.modelURL.path), "model isn't downloaded")

        folder = FileManager.default.temporaryDirectory.appendingPathComponent("holdtalk-test-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        wav = folder.appendingPathComponent("speech.wav")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", wav.path, "--data-format=LEI16@16000", "The quick brown fox jumps over the lazy dog."]
        try say.run()
        say.waitUntilExit()
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func makeServer(idleSeconds: TimeInterval = 300) throws -> WhisperServer {
        let config = Config()
        let cli = try XCTUnwrap(config.whisperExecutable)
        let executable = cli.deletingLastPathComponent().appendingPathComponent("whisper-server")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: executable.path), "whisper-server isn't installed")
        return WhisperServer(executable: executable, model: config.modelURL, idleSeconds: idleSeconds)
    }

    private func serverTranscriber(_ server: WhisperServer, fallback: Transcriber? = nil) -> WhisperServerTranscriber {
        WhisperServerTranscriber(server: server, language: "en", session: .holdTalk, fallback: fallback ?? makeTranscriber())
    }

    func testServerTranscribesAndReusesTheSameProcess() async throws {
        let server = try makeServer()
        defer { server.stop() }
        let first = try await serverTranscriber(server).transcribe(wav: wav)
        XCTAssertTrue(first.lowercased().contains("quick brown fox"), first)
        let port = server.port
        let second = try await serverTranscriber(server).transcribe(wav: wav)
        XCTAssertTrue(second.lowercased().contains("lazy dog"), second)
        XCTAssertEqual(server.port, port, "The model stays loaded between dictations")
    }

    func testServerLineBreaksDoNotReachTheText() async throws {
        let server = try makeServer()
        defer { server.stop() }
        let pipeline = DictationPipeline(transcribers: [serverTranscriber(server)], cleaner: nil)
        let result = try await pipeline.run(wav: wav)
        XCTAssertFalse(result.text.contains("\n"), result.text)
        XCTAssertTrue(result.text.lowercased().contains("quick brown fox"), result.text)
    }

    func testCancellingKillsTheServerAndNeverReturnsText() async throws {
        let server = try makeServer()
        defer { server.stop() }
        let long = folder.appendingPathComponent("long.wav")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", long.path, "--data-format=LEI16@16000", String(repeating: "This sentence is here to make the recording long. ", count: 40)]
        try say.run()
        say.waitUntilExit()

        server.start()
        let port = try XCTUnwrap(server.port)
        let transcriber = serverTranscriber(server)
        let task = Task { try await transcriber.transcribe(wav: long) }
        try await Task.sleep(nanoseconds: 500_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled work must not return text")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertNil(server.port)
        XCTAssertFalse(WhisperServer.acceptsConnections(port: port), "The server must be gone")
    }

    func testBrokenServerFallsBackToWhisperCli() async throws {
        let server = WhisperServer(executable: URL(fileURLWithPath: "/nonexistent/whisper-server"), model: Config().modelURL)
        defer { server.stop() }
        let text = try await serverTranscriber(server).transcribe(wav: wav)
        XCTAssertTrue(text.lowercased().contains("quick brown fox"), text)
    }

    func testIdleServerStopsAndStartsAgainWhenNeeded() async throws {
        let server = try makeServer(idleSeconds: 1)
        defer { server.stop() }
        _ = try await serverTranscriber(server).transcribe(wav: wav)
        let port = try XCTUnwrap(server.port)
        try await Task.sleep(nanoseconds: 1_800_000_000)
        XCTAssertNil(server.port, "Idle servers release their memory")
        XCTAssertFalse(WhisperServer.acceptsConnections(port: port))

        let text = try await serverTranscriber(server).transcribe(wav: wav)
        XCTAssertTrue(text.lowercased().contains("lazy dog"), text)
    }

    private func makeTranscriber() -> WhisperCppTranscriber {
        let config = Config()
        return WhisperCppTranscriber(executable: config.whisperExecutable!, model: config.modelURL, language: "auto")
    }

    func testTranscribesRealSpeechOffline() async throws {
        let started = Date()
        let text = try await makeTranscriber().transcribe(wav: wav)
        print("whisper took \(Date().timeIntervalSince(started))s: \(text)")
        let tidy = tidyTranscript(text).lowercased()
        XCTAssertTrue(tidy.contains("quick brown fox"), tidy)
        XCTAssertTrue(tidy.contains("lazy dog"), tidy)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(leftovers, ["speech.wav"], "The transcript text file must be removed")
    }

    func testCancellingKillsWhisperProcess() async throws {
        let transcriber = makeTranscriber()
        let wav = wav!
        let started = Date()
        let task = Task { try await transcriber.transcribe(wav: wav) }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(runningWhisperArguments(containing: wav.path).isEmpty, "whisper-cli should be running")
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled work must not return text")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        XCTAssertTrue(runningWhisperArguments(containing: wav.path).isEmpty, "whisper-cli must be gone")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(leftovers, ["speech.wav"])
    }

    private func runningWhisperArguments(containing text: String) -> String {
        let ps = Process()
        let pipe = Pipe()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "command"]
        ps.standardOutput = pipe
        try? ps.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        return output.split(separator: "\n").filter { $0.contains("whisper-cli") && $0.contains(text) }.joined()
    }

    func testPillRendersEveryState() throws {
        let outputFolder = ProcessInfo.processInfo.environment["HOLDTALK_PILL_OUTPUT"]
        let states: [(String, PillContent, Float)] = [
            ("hold", .holding, 0.25),
            ("handsfree", .handsFree(secondsLeft: 288, elapsed: 12), 0.1),
            ("ending", .handsFree(secondsLeft: 21, elapsed: 279), 0.02),
            ("transcribing", .transcribing, 0),
            ("note", .message("Cleanup unavailable, used the raw text", isError: true), 0),
        ]
        for (name, content, level) in states {
            let view = PillView()
            view.content = content
            view.level = level
            view.setFrameSize(view.fittingWindowSize)
            XCTAssertGreaterThan(view.frame.width, 60)
            XCTAssertLessThan(view.frame.width, 560)
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            if let outputFolder {
                try rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: outputFolder).appendingPathComponent("pill-\(name).png"))
            }
        }
    }
}

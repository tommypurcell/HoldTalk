import XCTest
@testable import HoldTalkKit

/// Uses fake programs, so these run without Whisper installed and never start a real server.
final class WhisperServerTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("holdtalk-server-test-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func program(_ name: String, _ script: String = "#!/bin/sh\n") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func model(_ name: String = "model.bin") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data().write(to: url)
        return url
    }

    private func config(server: Bool = true) throws -> Config {
        var config = Config()
        config.whisperPath = try program("whisper-cli").path
        config.localModel = try model().path
        config.whisperServer = server
        return config
    }

    // MARK: - The exit fix

    func testWhisperCliGetsTheSpeedSettingAndKeepsItsEnvironment() async throws {
        let script = """
        #!/bin/sh
        for last; do :; done
        printf '%s|%s' "$GGML_METAL_NO_RESIDENCY" "$HOME" > "$last.txt"
        """
        let transcriber = WhisperCppTranscriber(executable: try program("fake-cli", script), model: try model(), language: "en")
        let text = try await transcriber.transcribe(wav: folder.appendingPathComponent("speech.wav"))
        XCTAssertEqual(text, "1|\(ProcessInfo.processInfo.environment["HOME"] ?? "")")
    }

    // MARK: - Choosing a server

    func testHostFindsTheServerNextToWhisperCli() throws {
        _ = try program("whisper-server")
        XCTAssertNotNil(WhisperServerHost().server(for: try config()))
    }

    func testHostReusesAServerForTheSameSettings() throws {
        _ = try program("whisper-server")
        let host = WhisperServerHost()
        let settings = try config()
        XCTAssertTrue(host.server(for: settings) === host.server(for: settings))
    }

    func testHostReplacesTheServerWhenTheModelChanges() throws {
        _ = try program("whisper-server")
        let host = WhisperServerHost()
        var settings = try config()
        let first = host.server(for: settings)
        settings.localModel = try model("other.bin").path
        XCTAssertFalse(first === host.server(for: settings))
    }

    func testNoServerWhenTheSettingIsOff() throws {
        _ = try program("whisper-server")
        XCTAssertNil(WhisperServerHost().server(for: try config(server: false)))
    }

    func testNoServerForCloudTranscribers() throws {
        _ = try program("whisper-server")
        var settings = try config()
        settings.transcriber = "groq"
        XCTAssertNil(WhisperServerHost().server(for: settings), "A cloud setup mustn't load the local model")
    }

    func testNoServerWhenItIsntInstalled() throws {
        XCTAssertNil(WhisperServerHost().server(for: try config()))
    }

    func testNoServerWhenTheModelIsMissing() throws {
        _ = try program("whisper-server")
        var settings = try config()
        settings.localModel = folder.appendingPathComponent("missing.bin").path
        XCTAssertNil(WhisperServerHost().server(for: settings))
    }

    // MARK: - The pipeline

    func testPipelineUsesTheServerWhenThereIsOne() throws {
        let server = WhisperServer(executable: try program("whisper-server"), model: try model())
        let pipeline = DictationPipeline.make(config: try config(), env: EnvFile(), whisperServer: server)
        XCTAssertEqual(pipeline.transcribers.count, 1)
        XCTAssertTrue(pipeline.transcribers.first is WhisperServerTranscriber)
    }

    func testPipelineUsesWhisperCliWithoutAServer() throws {
        let pipeline = DictationPipeline.make(config: try config(), env: EnvFile())
        XCTAssertTrue(pipeline.transcribers.first is WhisperCppTranscriber)
    }

    func testCloudStaysFirstWithALocalServerAsItsFallback() throws {
        var settings = try config()
        settings.transcriber = "groq"
        let server = WhisperServer(executable: try program("whisper-server"), model: try model())
        let pipeline = DictationPipeline.make(config: settings, env: EnvFile("GROQ_API_KEY=k"), whisperServer: server)
        XCTAssertEqual(pipeline.transcribers.first?.name, "Groq")
    }

    // MARK: - The setting

    func testSettingDefaultsToOnAndCanBeTurnedOff() throws {
        XCTAssertTrue(try Config.parse(Data("{}".utf8)).whisperServer)
        XCTAssertFalse(try Config.parse(Data(#"{"whisperServer": false}"#.utf8)).whisperServer)
        XCTAssertThrowsError(try Config.parse(Data(#"{"whisperServer": "yes"}"#.utf8)))
    }

    // MARK: - The tailored window

    private func audioBytes(seconds: Double) -> Int {
        44 + Int(seconds * 16_000) * 2
    }

    func testWindowCoversTheClipPlusTwoSeconds() {
        XCTAssertEqual(WhisperServerTranscriber.audioWindow(audioBytes: audioBytes(seconds: 3)), 250)
        XCTAssertEqual(WhisperServerTranscriber.audioWindow(audioBytes: audioBytes(seconds: 0)), 100)
        XCTAssertEqual(WhisperServerTranscriber.audioWindow(audioBytes: audioBytes(seconds: 27)), 1450)
    }

    func testLongClipsUseTheFullWindow() {
        XCTAssertNil(WhisperServerTranscriber.audioWindow(audioBytes: audioBytes(seconds: 28)))
        XCTAssertNil(WhisperServerTranscriber.audioWindow(audioBytes: audioBytes(seconds: 300)))
    }

    private func requestText(tailored: Bool, seconds: Double) throws -> String {
        let server = WhisperServer(executable: try program("whisper-server"), model: try model())
        let transcriber = WhisperServerTranscriber(server: server, language: "auto", session: .holdTalk,
                                                   fallback: FixedText(), tailoredWindow: tailored)
        let audio = Data(count: audioBytes(seconds: seconds))
        return String(decoding: transcriber.requestBody(audio: audio, boundary: "b"), as: UTF8.self)
    }

    func testRequestSendsTheWindowOnlyWhenTurnedOn() throws {
        XCTAssertTrue(try requestText(tailored: true, seconds: 3).contains("name=\"audio_ctx\"\r\n\r\n250\r\n"))
        XCTAssertFalse(try requestText(tailored: false, seconds: 3).contains("audio_ctx"))
        XCTAssertFalse(try requestText(tailored: true, seconds: 60).contains("audio_ctx"))
    }

    func testPipelinePassesTheSettingToTheServer() throws {
        var settings = try config()
        settings.tailoredWindow = true
        let server = WhisperServer(executable: try program("whisper-server"), model: try model())
        let pipeline = DictationPipeline.make(config: settings, env: EnvFile(), whisperServer: server)
        XCTAssertEqual((pipeline.transcribers.first as? WhisperServerTranscriber)?.tailoredWindow, true)
    }

    func testTailoredWindowIsOffByDefault() throws {
        XCTAssertFalse(try Config.parse(Data("{}".utf8)).tailoredWindow)
        XCTAssertTrue(try Config.parse(Data(#"{"tailoredWindow": true}"#.utf8)).tailoredWindow)
    }
}

private struct FixedText: Transcriber {
    let name = "fixed"
    func transcribe(wav: URL) async throws -> String { "" }
}

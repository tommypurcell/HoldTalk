import AVFoundation
import ApplicationServices
import Foundation

/// Runs the real app's transcription on a test audio file and reports what happened.
/// It never records, listens for keys, pastes, or reads `.env`, so it can't reach a cloud service.
public enum SelfTest {
    public struct Run: Encodable, Equatable {
        public let name: String
        public let seconds: Double
        public let matchedWords: Double
        public let usedFallback: Bool
        public let text: String
    }

    public struct Report: Encodable {
        public let passed: Bool
        public let failures: [String]
        public let warnings: [String]
        public let permissions: [String: String]
        public let runs: [Run]
    }

    /// The share of expected words that came back, ignoring case and punctuation.
    static func matchedWords(expected: String, actual: String) -> Double {
        func words(_ text: String) -> [String] {
            text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        }
        let wanted = words(expected)
        guard !wanted.isEmpty else { return 0 }
        var remaining = words(actual)
        var found = 0
        for word in wanted {
            if let index = remaining.firstIndex(of: word) {
                remaining.remove(at: index)
                found += 1
            }
        }
        return Double(found) / Double(wanted.count)
    }

    static func failures(for runs: [Run], minimumMatch: Double = 0.8) -> [String] {
        var failures: [String] = []
        for run in runs {
            if run.matchedWords < minimumMatch {
                failures.append("\(run.name): only \(Int(run.matchedWords * 100))% of the words matched")
            }
            if run.usedFallback {
                failures.append("\(run.name): whisper-server failed and it fell back to whisper-cli")
            }
        }
        return failures
    }

    static func permissions() -> [String: String] {
        let microphone: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = "granted"
        case .notDetermined: microphone = "not asked yet"
        default: microphone = "denied"
        }
        return [
            "microphone": microphone,
            "inputMonitoring": CGPreflightListenEventAccess() ? "granted" : "not granted",
            "accessibility": AXIsProcessTrusted() ? "granted" : "not granted",
        ]
    }

    /// Notes when the server gave up and whisper-cli was used instead.
    private final class FallbackSpy: Transcriber {
        let name = "fallback"
        let wrapped: Transcriber
        var used = false
        init(wrapped: Transcriber) { self.wrapped = wrapped }
        func transcribe(wav: URL) async throws -> String {
            used = true
            return try await wrapped.transcribe(wav: wav)
        }
    }

    private static func timed(_ name: String, expected: String, wav: URL, spy: FallbackSpy? = nil,
                      _ transcriber: Transcriber) async throws -> Run {
        spy?.used = false
        let start = Date()
        let text = tidyTranscript(try await transcriber.transcribe(wav: wav))
        return Run(name: name, seconds: (Date().timeIntervalSince(start) * 1000).rounded() / 1000,
                   matchedWords: matchedWords(expected: expected, actual: text),
                   usedFallback: spy?.used ?? false, text: text)
    }

    public static func run(audio: URL, expected: String) async -> Report {
        let settings = (try? Data(contentsOf: Paths.config)).flatMap { try? Config.parse($0) } ?? Config()
        var failures: [String] = []
        var warnings: [String] = []
        var runs: [Run] = []

        guard let cli = settings.whisperExecutable else {
            return Report(passed: false, failures: ["whisper-cli isn't installed. Run: brew install whisper-cpp"],
                          warnings: [], permissions: permissions(), runs: [])
        }
        let model = settings.modelURL
        guard FileManager.default.fileExists(atPath: model.path) else {
            return Report(passed: false, failures: ["Speech model missing: \(model.path)"],
                          warnings: [], permissions: permissions(), runs: [])
        }

        let local = WhisperCppTranscriber(executable: cli, model: model, language: "auto")
        do {
            runs.append(try await timed("whisper-cli", expected: expected, wav: audio, local))

            let serverPath = cli.deletingLastPathComponent().appendingPathComponent("whisper-server")
            if FileManager.default.isExecutableFile(atPath: serverPath.path) {
                let server = WhisperServer(executable: serverPath, model: model)
                let spy = FallbackSpy(wrapped: local)
                let full = WhisperServerTranscriber(server: server, language: "auto", session: .holdTalk, fallback: spy)
                let tailored = WhisperServerTranscriber(server: server, language: "auto", session: .holdTalk,
                                                        fallback: spy, tailoredWindow: true)
                runs.append(try await timed("whisper-server first run", expected: expected, wav: audio, spy: spy, full))
                runs.append(try await timed("whisper-server loaded", expected: expected, wav: audio, spy: spy, full))
                runs.append(try await timed("whisper-server tailored window", expected: expected, wav: audio, spy: spy, tailored))

                let port = server.port
                server.stop()
                try await Task.sleep(nanoseconds: 500_000_000)
                if let port, WhisperServer.acceptsConnections(port: port) {
                    failures.append("whisper-server was still running after being stopped")
                }
            } else {
                warnings.append("whisper-server isn't installed next to whisper-cli, so only whisper-cli was tested")
            }
        } catch {
            failures.append("Transcription failed: \(error.localizedDescription)")
        }

        failures += Self.failures(for: runs)
        let permissions = permissions()
        for (name, state) in permissions.sorted(by: { $0.key < $1.key }) where state != "granted" {
            warnings.append("\(name) is \(state). The live hotkey, mic or paste won't work until a person grants it")
        }
        return Report(passed: failures.isEmpty, failures: failures, warnings: warnings, permissions: permissions, runs: runs)
    }

    /// Handles `--self-test --audio <wav> --expected <text> --output <json>`, then exits.
    public static func runFromCommandLine(_ arguments: [String]) -> Never {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard let audio = value("--audio"), let expected = value("--expected"), let output = value("--output") else {
            FileHandle.standardError.write(Data("Usage: --self-test --audio <wav> --expected <text> --output <json>\n".utf8))
            exit(2)
        }
        Task {
            let report = await run(audio: URL(fileURLWithPath: audio), expected: expected)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try? encoder.encode(report).write(to: URL(fileURLWithPath: output))
            exit(report.passed ? 0 : 1)
        }
        dispatchMain()
    }
}

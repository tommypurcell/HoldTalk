import Foundation

/// Turns recorded audio into the final text: transcribe, then clean up.
public struct DictationPipeline {
    public struct Result: Equatable {
        public let text: String
        /// Something the user should know, e.g. the cleanup step failed.
        public let notice: String?
    }

    /// Tried in order. Local is only ever a fallback for the cloud, never the
    /// reverse, so choosing local guarantees audio stays on this Mac.
    let transcribers: [Transcriber]
    let cleaner: TextCleaner?
    /// Written when a config choice couldn't be honored, e.g. no API key.
    let setupNotice: String?

    public init(transcribers: [Transcriber], cleaner: TextCleaner?, setupNotice: String? = nil) {
        self.transcribers = transcribers
        self.cleaner = cleaner
        self.setupNotice = setupNotice
    }

    /// Returns `nil` text when no speech was found.
    public func run(wav: URL) async throws -> Result {
        var notice = setupNotice
        let raw = tidyTranscript(try await transcribe(wav: wav, notice: &notice))
        try Task.checkCancellation()
        guard !raw.isEmpty else { return Result(text: "", notice: notice) }

        guard let cleaner else { return Result(text: raw, notice: notice) }
        do {
            let output = try await cleaner.clean(raw)
            try Task.checkCancellation()
            if let accepted = CleanupPrompt.accept(output, for: raw) {
                return Result(text: accepted, notice: notice)
            }
            return Result(text: raw, notice: "Cleanup reply looked wrong, used the raw text")
        } catch where !Task.isCancelled && !(error is CancellationError) {
            // Being offline must never lose what was said.
            return Result(text: raw, notice: "Cleanup unavailable, used the raw text")
        }
    }

    private func transcribe(wav: URL, notice: inout String?) async throws -> String {
        guard !transcribers.isEmpty else {
            throw TranscriptionError(notice ?? "No transcriber is available.")
        }
        var lastError: Error?
        for transcriber in transcribers {
            try Task.checkCancellation()
            do {
                if lastError != nil { notice = "\(transcribers[0].name) failed, used \(transcriber.name)" }
                return try await transcriber.transcribe(wav: wav)
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                lastError = error
            }
        }
        throw lastError ?? TranscriptionError("Transcription failed.")
    }

    /// Builds the pipeline the settings and .env ask for.
    public static func make(config: Config, env: EnvFile, session: URLSession = .holdTalk,
                            whisperServer: WhisperServer? = nil) -> DictationPipeline {
        var transcribers: [Transcriber] = []
        var notices: [String] = []

        func cloud(_ name: String, _ url: String, _ keyName: String, _ defaultModel: String) {
            if let key = env[keyName] {
                transcribers.append(WhisperAPITranscriber(
                    name: name, endpoint: URL(string: url)!, apiKey: key,
                    model: config.transcriberModel ?? defaultModel,
                    language: config.language, session: session))
            } else {
                notices.append("No \(keyName) in .env, used local Whisper")
            }
        }
        switch config.transcriber {
        case "groq":
            cloud("Groq", "https://api.groq.com/openai/v1/audio/transcriptions", "GROQ_API_KEY", "whisper-large-v3-turbo")
        case "openai":
            cloud("OpenAI", "https://api.openai.com/v1/audio/transcriptions", "OPENAI_API_KEY", "gpt-transcribe")
        default:
            break
        }

        if let executable = config.whisperExecutable,
           FileManager.default.fileExists(atPath: config.modelURL.path) {
            let local = WhisperCppTranscriber(executable: executable, model: config.modelURL, language: config.language)
            if let whisperServer {
                transcribers.append(WhisperServerTranscriber(server: whisperServer, language: config.language,
                                                             session: session, fallback: local,
                                                             tailoredWindow: config.tailoredWindow))
            } else {
                transcribers.append(local)
            }
        } else if transcribers.isEmpty {
            notices = [config.whisperExecutable == nil
                ? "whisper-cli isn't installed. Run: brew install whisper-cpp"
                : "Speech model missing: \(config.modelURL.path)"]
        }

        return DictationPipeline(transcribers: transcribers,
                                 cleaner: makeCleaner(config: config, env: env, session: session),
                                 setupNotice: notices.first)
    }

    static func makeCleaner(config: Config, env: EnvFile, session: URLSession) -> TextCleaner? {
        guard config.cleanupEnabled else { return nil }
        let order = config.cleanupProvider == "auto" ? ["groq", "anthropic", "openai"] : [config.cleanupProvider]
        for provider in order {
            switch provider {
            case "groq":
                if let key = env["GROQ_API_KEY"] {
                    return ChatCompletionsCleaner(
                        endpoint: URL(string: "https://api.groq.com/openai/v1/chat/completions")!,
                        apiKey: key, model: config.cleanupModel ?? "llama-3.3-70b-versatile",
                        casing: config.casing, timeout: config.cleanupTimeoutSeconds, session: session)
                }
            case "anthropic":
                if let key = env["ANTHROPIC_API_KEY"] {
                    return AnthropicCleaner(
                        apiKey: key, model: config.cleanupModel ?? "claude-haiku-5-5",
                        casing: config.casing, timeout: config.cleanupTimeoutSeconds, session: session)
                }
            default:
                if let key = env["OPENAI_API_KEY"] {
                    return ChatCompletionsCleaner(
                        endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!,
                        apiKey: key, model: config.cleanupModel ?? "gpt-5.6-luna",
                        casing: config.casing, timeout: config.cleanupTimeoutSeconds, session: session)
                }
            }
        }
        return nil
    }
}

extension URLSession {
    /// Keeps nothing on disk: no cookies, no cache of dictated text.
    public static let holdTalk = URLSession(configuration: .ephemeral)
}

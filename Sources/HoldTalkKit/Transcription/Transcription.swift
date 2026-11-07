import Foundation

public protocol Transcriber {
    var name: String { get }
    func transcribe(wav: URL) async throws -> String
}

public struct TranscriptionError: LocalizedError {
    public let errorDescription: String?
    public init(_ message: String) { errorDescription = message }
}

/// Runs whisper.cpp as a separate process, so Esc can kill it outright.
public struct WhisperCppTranscriber: Transcriber {
    public let name = "whisper.cpp"
    let executable: URL
    let model: URL
    let language: String

    public init(executable: URL, model: URL, language: String) {
        self.executable = executable
        self.model = model
        self.language = language
    }

    public func transcribe(wav: URL) async throws -> String {
        let outputBase = wav.deletingPathExtension().path + "-out"
        let outputFile = URL(fileURLWithPath: outputBase + ".txt")
        defer { try? FileManager.default.removeItem(at: outputFile) }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["-m", model.path, "-f", wav.path, "-l", language,
                             "-nt", "-np", "-otxt", "-of", outputBase]
        // Without this, whisper-cli can wait up to about half a second to exit after writing the text.
        process.environment = ProcessInfo.processInfo.environment.merging(["GGML_METAL_NO_RESIDENCY": "1"]) { _, new in new }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let status = try await run(process)
        try Task.checkCancellation()
        guard status == 0 else {
            throw TranscriptionError("whisper-cli stopped with error \(status). Check the model file: \(model.path)")
        }
        return try String(contentsOf: outputFile, encoding: .utf8)
    }

    private func run(_ process: Process) async throws -> Int32 {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
                // Cancelled while starting up: the handler below ran too early to see it.
                if Task.isCancelled { Self.kill(process) }
            }
        } onCancel: {
            Self.kill(process)
        }
    }

    private static func kill(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            if process.isRunning { Darwin.kill(pid, SIGKILL) }
        }
    }
}

/// Groq and OpenAI share this upload format.
public struct WhisperAPITranscriber: Transcriber {
    public let name: String
    let endpoint: URL
    let apiKey: String
    let model: String
    let language: String
    let session: URLSession

    public init(name: String, endpoint: URL, apiKey: String, model: String, language: String, session: URLSession) {
        self.name = name
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.language = language
        self.session = session
    }

    public func transcribe(wav: URL) async throws -> String {
        let boundary = "holdtalk-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", model)
        field("response_format", "json")
        if language != "auto" { field("language", language) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(try Data(contentsOf: wav))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: endpoint, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.upload(for: request, from: body)
        try HTTP.check(response, data, service: name)
        struct Reply: Decodable { let text: String }
        return try JSONDecoder().decode(Reply.self, from: data).text
    }
}

enum HTTP {
    static func check(_ response: URLResponse, _ data: Data, service: String) throws {
        guard let status = (response as? HTTPURLResponse)?.statusCode else { return }
        guard (200..<300).contains(status) else {
            throw TranscriptionError("\(service) returned error \(status).")
        }
    }
}

/// Removes Whisper's non-speech markers such as [BLANK_AUDIO] and joins its lines.
public func tidyTranscript(_ text: String) -> String {
    let withoutMarkers = text
        .replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
        .replacingOccurrences(of: #"(?m)^\s*\([^)]*\)\s*$"#, with: " ", options: .regularExpression)
    return withoutMarkers
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}

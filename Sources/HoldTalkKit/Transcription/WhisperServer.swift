import Darwin
import Foundation

/// Keeps whisper-server running while you dictate, so the model is already loaded
/// when you let go of the hotkey. It stops after a few idle minutes to free the memory.
public final class WhisperServer {
    private let executable: URL
    private let model: URL
    private let idleSeconds: TimeInterval
    private let queue = DispatchQueue(label: "holdtalk.whisper-server")
    private var process: Process?
    private var lifeline: Pipe?
    private var currentPort: UInt16?
    private var useCount = 0
    private var idleTimer: DispatchWorkItem?

    public init(executable: URL, model: URL, idleSeconds: TimeInterval = 300) {
        self.executable = executable
        self.model = model
        self.idleSeconds = idleSeconds
    }

    deinit { shutDown() }

    /// Called when recording starts, so the server is ready by the time it ends.
    public func start() {
        queue.async { [self] in
            launchIfNeeded()
            restartIdleTimer()
        }
    }

    public func stop() {
        queue.async { [self] in shutDown() }
    }

    var port: UInt16? { queue.sync { currentPort } }

    fileprivate func matches(executable: URL, model: URL) -> Bool {
        self.executable == executable && self.model == model
    }

    /// Returns the port once the server accepts connections.
    fileprivate func beginUse() async throws -> UInt16 {
        let port: UInt16? = queue.sync {
            launchIfNeeded()
            useCount += 1
            return currentPort
        }
        guard let port else { throw TranscriptionError("whisper-server didn't start.") }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            try Task.checkCancellation()
            if Self.acceptsConnections(port: port) { return port }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw TranscriptionError("whisper-server didn't become ready.")
    }

    fileprivate func endUse() {
        queue.async { [self] in
            useCount = max(0, useCount - 1)
            restartIdleTimer()
        }
    }

    private func launchIfNeeded() {
        if process?.isRunning == true { return }
        shutDown()
        guard let port = Self.freePort() else { return }

        // Closing the lifeline kills the server. The system closes it if HoldTalk
        // quits or crashes, so the server can't outlive the app.
        let script = #""$0" "$@" </dev/null >/dev/null 2>&1 & server=$!; cat >/dev/null; kill -KILL "$server""#
        let process = Process()
        let lifeline = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Same search settings as whisper-cli's defaults, so the text doesn't change.
        process.arguments = ["-c", script, executable.path, "-m", model.path, "--host", "127.0.0.1",
                             "--port", String(port), "-bs", "5", "-bo", "5"]
        process.standardInput = lifeline
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            self.process = process
            self.lifeline = lifeline
            currentPort = port
        } catch {
            currentPort = nil
        }
    }

    private func shutDown() {
        idleTimer?.cancel()
        idleTimer = nil
        try? lifeline?.fileHandleForWriting.close()
        lifeline = nil
        process = nil
        currentPort = nil
    }

    private func restartIdleTimer() {
        idleTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.useCount == 0 { self.shutDown() } else { self.restartIdleTimer() }
        }
        idleTimer = timer
        queue.asyncAfter(deadline: .now() + idleSeconds, execute: timer)
    }

    private static func freePort() -> UInt16? {
        let socketID = socket(AF_INET, SOCK_STREAM, 0)
        guard socketID >= 0 else { return nil }
        defer { close(socketID) }
        var address = loopback(port: 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(socketID, generic, length) == 0 && getsockname(socketID, generic, &length) == 0
            }
        }
        return bound ? UInt16(bigEndian: address.sin_port) : nil
    }

    static func acceptsConnections(port: UInt16) -> Bool {
        let socketID = socket(AF_INET, SOCK_STREAM, 0)
        guard socketID >= 0 else { return false }
        defer { close(socketID) }
        var address = loopback(port: port)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                connect(socketID, generic, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private static func loopback(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return address
    }
}

/// Finds the right server for the current settings, and stops one that no longer fits.
public final class WhisperServerHost {
    private var server: WhisperServer?

    public init() {}

    public func server(for config: Config) -> WhisperServer? {
        guard config.whisperServer, config.transcriber == "local",
              let cli = config.whisperExecutable,
              FileManager.default.fileExists(atPath: config.modelURL.path) else {
            stop()
            return nil
        }
        let executable = cli.deletingLastPathComponent().appendingPathComponent("whisper-server")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            stop()
            return nil
        }
        if server?.matches(executable: executable, model: config.modelURL) != true {
            stop()
            server = WhisperServer(executable: executable, model: config.modelURL)
        }
        return server
    }

    public func stop() {
        server?.stop()
        server = nil
    }
}

/// Transcribes with the running server, and uses whisper-cli if anything goes wrong.
public struct WhisperServerTranscriber: Transcriber {
    public let name = "whisper.cpp"
    let server: WhisperServer
    let language: String
    let session: URLSession
    let fallback: Transcriber

    public init(server: WhisperServer, language: String, session: URLSession, fallback: Transcriber) {
        self.server = server
        self.language = language
        self.session = session
        self.fallback = fallback
    }

    public func transcribe(wav: URL) async throws -> String {
        do {
            defer { server.endUse() }
            let port = try await server.beginUse()
            return try await send(wav: wav, port: port)
        } catch {
            server.stop()
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            return try await fallback.transcribe(wav: wav)
        }
    }

    private func send(wav: URL, port: UInt16) async throws -> String {
        let boundary = "holdtalk-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("language", language)
        field("response_format", "json")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(try Data(contentsOf: wav))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/inference")!, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.upload(for: request, from: body)
        try HTTP.check(response, data, service: "whisper-server")
        struct Reply: Decodable { let text: String }
        return try JSONDecoder().decode(Reply.self, from: data).text
    }
}

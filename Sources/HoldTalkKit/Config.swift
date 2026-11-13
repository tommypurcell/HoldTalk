import Foundation

/// The settings file, `~/.config/holdtalk/config.json`. Missing settings use these defaults.
public struct Config: Codable, Equatable {
    public var hotkey = "fn"
    /// "local", "groq" or "openai".
    public var transcriber = "local"
    /// "large-v3-turbo-q5_0", "small", "medium", or a full path to a ggml model file.
    public var localModel = "large-v3-turbo-q5_0"
    /// Leave unset to look in the usual Homebrew folders.
    public var whisperPath: String?
    /// "auto" or a language code such as "en".
    public var language = "auto"
    /// Overrides the default speech model for the groq or openai transcriber.
    public var transcriberModel: String?

    public var cleanupEnabled = true
    /// "auto" uses the first key found in .env. Otherwise "groq", "anthropic" or "openai".
    public var cleanupProvider = "auto"
    public var cleanupModel: String?
    /// "sentence", "lowercase" or "preserve".
    public var casing = "sentence"
    public var cleanupTimeoutSeconds: Double = 8

    /// false leaves the transcript on the clipboard. true puts your old clipboard back.
    public var restoreClipboard = false

    /// Recording stops and transcribes at this limit, so nothing records all afternoon.
    public var maxRecordingSeconds: Double = 300
    public var tapMaxMilliseconds: Double = 250
    public var doubleTapWindowMilliseconds: Double = 350

    public init() {}

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case hotkey, transcriber, localModel, whisperPath, language, transcriberModel
        case cleanupEnabled, cleanupProvider, cleanupModel, casing, cleanupTimeoutSeconds
        case restoreClipboard, maxRecordingSeconds, tapMaxMilliseconds, doubleTapWindowMilliseconds
    }

    public struct Invalid: LocalizedError {
        public let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Config()
        func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try values.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        hotkey = try read(.hotkey, defaults.hotkey)
        transcriber = try read(.transcriber, defaults.transcriber)
        localModel = try read(.localModel, defaults.localModel)
        whisperPath = try values.decodeIfPresent(String.self, forKey: .whisperPath)
        language = try read(.language, defaults.language)
        transcriberModel = try values.decodeIfPresent(String.self, forKey: .transcriberModel)
        cleanupEnabled = try read(.cleanupEnabled, defaults.cleanupEnabled)
        cleanupProvider = try read(.cleanupProvider, defaults.cleanupProvider)
        cleanupModel = try values.decodeIfPresent(String.self, forKey: .cleanupModel)
        casing = try read(.casing, defaults.casing)
        cleanupTimeoutSeconds = try read(.cleanupTimeoutSeconds, defaults.cleanupTimeoutSeconds)
        restoreClipboard = try read(.restoreClipboard, defaults.restoreClipboard)
        maxRecordingSeconds = try read(.maxRecordingSeconds, defaults.maxRecordingSeconds)
        tapMaxMilliseconds = try read(.tapMaxMilliseconds, defaults.tapMaxMilliseconds)
        doubleTapWindowMilliseconds = try read(.doubleTapWindowMilliseconds, defaults.doubleTapWindowMilliseconds)
    }

    /// Reads and checks settings. A typo fails loudly instead of silently using a default.
    public static func parse(_ data: Data) throws -> Config {
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Invalid("The settings file must be one JSON object.")
        }
        let known = Set(CodingKeys.allCases.map(\.stringValue))
        if let unknown = raw.keys.sorted().first(where: { !known.contains($0) }) {
            throw Invalid("Unknown setting \"\(unknown)\".")
        }
        let config = try JSONDecoder().decode(Config.self, from: data)
        try config.validate()
        return config
    }

    public func validate() throws {
        _ = try Hotkey.parse(hotkey)
        guard ["local", "groq", "openai"].contains(transcriber) else {
            throw Invalid("transcriber must be local, groq or openai.")
        }
        guard ["auto", "groq", "anthropic", "openai"].contains(cleanupProvider) else {
            throw Invalid("cleanupProvider must be auto, groq, anthropic or openai.")
        }
        guard ["sentence", "lowercase", "preserve"].contains(casing) else {
            throw Invalid("casing must be sentence, lowercase or preserve.")
        }
        guard maxRecordingSeconds > 0 else { throw Invalid("maxRecordingSeconds must be above 0.") }
        guard cleanupTimeoutSeconds > 0 else { throw Invalid("cleanupTimeoutSeconds must be above 0.") }
        guard tapMaxMilliseconds > 0 else { throw Invalid("tapMaxMilliseconds must be above 0.") }
        guard doubleTapWindowMilliseconds > 0 else {
            throw Invalid("doubleTapWindowMilliseconds must be above 0.")
        }
    }

    public var modelURL: URL {
        if localModel.contains("/") {
            return URL(fileURLWithPath: (localModel as NSString).expandingTildeInPath)
        }
        return Paths.models.appendingPathComponent("ggml-\(localModel).bin")
    }

    public var whisperExecutable: URL? {
        let candidates = whisperPath.map { [($0 as NSString).expandingTildeInPath] } ?? [
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
            "/opt/homebrew/bin/whisper-cpp",
            "/usr/local/bin/whisper-cpp",
        ]
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:))
            .map(URL.init(fileURLWithPath:))
    }
}

public enum Paths {
    public static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/holdtalk")
    public static let config = folder.appendingPathComponent("config.json")
    public static let env = folder.appendingPathComponent(".env")
    public static let models = folder.appendingPathComponent("models")
}

/// Reads simple KEY=value lines. Blank or placeholder-free values count as no key.
public struct EnvFile: Equatable {
    public private(set) var values: [String: String] = [:]

    public init(_ text: String = "") {
        for line in text.split(whereSeparator: \.isNewline) {
            var entry = line.trimmingCharacters(in: .whitespaces)
            if entry.hasPrefix("#") { continue }
            if entry.hasPrefix("export ") { entry.removeFirst("export ".count) }
            guard let equals = entry.firstIndex(of: "=") else { continue }
            let key = entry[..<equals].trimmingCharacters(in: .whitespaces)
            var value = entry[entry.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty, !value.isEmpty { values[key] = value }
        }
    }

    public static func load(from url: URL = Paths.env) -> EnvFile {
        EnvFile((try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }

    public subscript(key: String) -> String? { values[key] }
}

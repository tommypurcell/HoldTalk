import XCTest
@testable import HoldTalkKit

final class SettingsTests: XCTestCase {
    func testHotkeyParsing() throws {
        XCTAssertEqual(try Hotkey.parse("fn"), .modifier(.fn))
        XCTAssertEqual(try Hotkey.parse("Right_Option"), .modifier(.rightOption))
        XCTAssertEqual(try Hotkey.parse("ctrl+option+space"),
                       .combo(keyCode: 49, modifiers: [.control, .option]))
        XCTAssertEqual(try Hotkey.parse("cmd + shift + f13"),
                       .combo(keyCode: 105, modifiers: [.command, .shift]))
        XCTAssertThrowsError(try Hotkey.parse("space"))
        XCTAssertThrowsError(try Hotkey.parse("banana+space"))
        XCTAssertThrowsError(try Hotkey.parse("ctrl+esc"), "Esc is reserved for cancel")
    }

    func testEmptyConfigUsesDefaults() throws {
        let config = try Config.parse(Data("{}".utf8))
        XCTAssertEqual(config, Config())
        XCTAssertEqual(config.hotkey, "fn")
        XCTAssertEqual(config.maxRecordingSeconds, 300)
        XCTAssertFalse(config.restoreClipboard, "Leaves the transcript on the clipboard by default")
        XCTAssertTrue(config.noiseSuppression, "Cuts background noise by default")
    }

    func testNoiseSuppressionCanBeTurnedOff() throws {
        let config = try Config.parse(Data(#"{"noiseSuppression":false}"#.utf8))
        XCTAssertFalse(config.noiseSuppression)
    }

    func testConfigReadsValuesAndRoundTrips() throws {
        let json = #"{"hotkey":"right_option","transcriber":"groq","restoreClipboard":true,"casing":"lowercase"}"#
        let config = try Config.parse(Data(json.utf8))
        XCTAssertEqual(config.hotkey, "right_option")
        XCTAssertEqual(config.transcriber, "groq")
        XCTAssertTrue(config.restoreClipboard)
        XCTAssertEqual(try Config.parse(JSONEncoder().encode(config)), config)
    }

    func testConfigRejectsMistakes() {
        for bad in [#"{"hotkeyy":"fn"}"#, #"{"transcriber":"siri"}"#, #"{"casing":"shouty"}"#,
                    #"{"maxRecordingSeconds":0}"#, #"{"hotkey":"banana"}"#, "[]", "not json"] {
            XCTAssertThrowsError(try Config.parse(Data(bad.utf8)), bad)
        }
    }

    func testModelNamesAndPaths() {
        var config = Config()
        XCTAssertTrue(config.modelURL.path.hasSuffix(".config/holdtalk/models/ggml-small.bin"))
        config.localModel = "medium"
        XCTAssertTrue(config.modelURL.path.hasSuffix("ggml-medium.bin"))
        config.localModel = "/models/custom.bin"
        XCTAssertEqual(config.modelURL.path, "/models/custom.bin")
    }

    func testEnvFile() {
        let env = EnvFile("""
        # comment
        GROQ_API_KEY=abc
        export OPENAI_API_KEY="def"
        ANTHROPIC_API_KEY='g=h'
        EMPTY=

        not a line
        """)
        XCTAssertEqual(env["GROQ_API_KEY"], "abc")
        XCTAssertEqual(env["OPENAI_API_KEY"], "def")
        XCTAssertEqual(env["ANTHROPIC_API_KEY"], "g=h")
        XCTAssertNil(env["EMPTY"])
        XCTAssertNil(env["MISSING"])
    }
}

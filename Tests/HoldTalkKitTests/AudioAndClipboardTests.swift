import AppKit
import AVFoundation
import XCTest
@testable import HoldTalkKit

final class AudioTests: XCTestCase {
    func testWavHeaderAndLength() {
        let data = SpeechAudio(samples: [0, 1, -1, 2]).wavData()
        XCTAssertEqual(data.count, 44 + 8)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(data[24], 0x80, "16000 Hz, low byte")
        XCTAssertEqual(data[25], 0x3E, "16000 Hz, high byte")
        let samples = data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        XCTAssertEqual(samples, [0, Int16.max, -Int16.max, Int16.max], "Loud samples clip instead of overflowing")
    }

    func testSilenceDetection() {
        XCTAssertTrue(SpeechAudio(samples: []).isLikelyEmpty)
        XCTAssertTrue(SpeechAudio(samples: Array(repeating: 0, count: 32000)).isLikelyEmpty, "silent")
        XCTAssertTrue(SpeechAudio(samples: Array(repeating: 0.5, count: 1000)).isLikelyEmpty, "too short")
        XCTAssertFalse(SpeechAudio(samples: Array(repeating: 0.1, count: 32000)).isLikelyEmpty)
    }

    /// A 440 Hz tone at 48 kHz stereo must come out as 440 Hz at 16 kHz mono,
    /// even when split across buffers as the mic delivers it.
    func testResamplerKeepsLengthAndPitch() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let resampler = try XCTUnwrap(SpeechResampler(inputFormat: format))
        var output: [Float] = []
        let bufferFrames: AVAudioFrameCount = 4800
        for bufferIndex in 0..<20 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: bufferFrames))
            buffer.frameLength = bufferFrames
            for frame in 0..<Int(bufferFrames) {
                let time = Double(bufferIndex * Int(bufferFrames) + frame) / 48_000
                let value = Float(sin(2 * .pi * 440 * time)) * 0.5
                buffer.floatChannelData![0][frame] = value
                buffer.floatChannelData![1][frame] = value
            }
            output += resampler.convert(buffer)
        }
        let beforeFlush = output.count
        output += resampler.flush()
        XCTAssertGreaterThan(output.count, beforeFlush, "The filter holds back the newest audio")
        XCTAssertEqual(Double(output.count), 32_000, accuracy: 100, "2 seconds at 16 kHz, nothing clipped")
        let settled = Array(output.dropFirst(1000).prefix(16_000))
        let crossings = zip(settled, settled.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
        XCTAssertEqual(Double(crossings), 440, accuracy: 3, "Pitch per second")
        XCTAssertGreaterThan(settled.max() ?? 0, 0.3, "Downmixing mustn't lose the signal")
    }

    /// Voice processing delivers 9 untagged channels. Downmixing those gives
    /// silence, so the first channel must be converted on its own.
    func testResamplerKeepsVoiceProcessingChannels() throws {
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 9))
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: layout)
        let resampler = try XCTUnwrap(SpeechResampler(inputFormat: format, firstChannelOnly: true))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        for frame in 0..<48_000 {
            let value = Float(sin(2 * .pi * 440 * Double(frame) / 48_000)) * 0.5
            for channel in 0..<9 { buffer.floatChannelData![channel][frame] = value }
        }
        let output = resampler.convert(buffer) + resampler.flush()
        XCTAssertEqual(Double(output.count), 16_000, accuracy: 100)
        XCTAssertGreaterThan(output.max() ?? 0, 0.3, "The voice must not come out silent")
    }
}

final class ClipboardTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("holdtalk-test-\(UUID().uuidString)"))
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
    }

    func testDefaultLeavesTranscriptOnClipboard() {
        pasteboard.clearContents()
        pasteboard.setString("old", forType: .string)
        ClipboardSwap(pasteboard: pasteboard).put("transcript", willRestore: false)
        XCTAssertEqual(pasteboard.string(forType: .string), "transcript")
    }

    func testRestoreBringsBackEveryType() {
        let imageType = NSPasteboard.PasteboardType.png
        pasteboard.clearContents()
        pasteboard.setString("old", forType: .string)
        pasteboard.setData(Data([1, 2, 3]), forType: imageType)

        let swap = ClipboardSwap(pasteboard: pasteboard)
        swap.put("transcript", willRestore: true)
        XCTAssertEqual(pasteboard.string(forType: .string), "transcript")
        swap.restore()
        XCTAssertEqual(pasteboard.string(forType: .string), "old")
        XCTAssertEqual(pasteboard.data(forType: imageType), Data([1, 2, 3]))
    }

    func testRestoreLeavesSomethingCopiedAfterwards() {
        pasteboard.clearContents()
        pasteboard.setString("old", forType: .string)
        let swap = ClipboardSwap(pasteboard: pasteboard)
        swap.put("transcript", willRestore: true)
        pasteboard.clearContents()
        pasteboard.setString("newer copy", forType: .string)
        swap.restore()
        XCTAssertEqual(pasteboard.string(forType: .string), "newer copy")
    }

    func testRestoringAnEmptyClipboard() {
        pasteboard.clearContents()
        let swap = ClipboardSwap(pasteboard: pasteboard)
        swap.put("transcript", willRestore: true)
        swap.restore()
        XCTAssertNil(pasteboard.string(forType: .string))
    }
}

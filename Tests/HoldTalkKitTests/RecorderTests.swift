import AVFoundation
import XCTest
@testable import HoldTalkKit

/// Records one real second from the microphone, in memory, and throws it away.
/// Skipped unless access was already granted, so it never causes a permission prompt.
final class RecorderTests: XCTestCase {
    func testRecordsFromRealMicrophoneAtSpeechFormat() async throws {
        try XCTSkipUnless(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                          "This process has no microphone access")
        let recorder = Recorder()
        var failure: String?
        recorder.onFailure = { failure = $0 }
        recorder.start()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let audio = await recorder.finish()
        XCTAssertNil(failure)
        print("mic recorded \(audio.duration)s, peak \(audio.peak)")
        XCTAssertGreaterThan(audio.duration, 0.5)
        XCTAssertLessThan(audio.duration, 1.6)
    }

    func testRecordsFromRealMicrophoneWithoutNoiseSuppression() async throws {
        try XCTSkipUnless(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                          "This process has no microphone access")
        let recorder = Recorder()
        recorder.noiseSuppression = false
        var failure: String?
        recorder.onFailure = { failure = $0 }
        recorder.start()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let audio = await recorder.finish()
        XCTAssertNil(failure)
        XCTAssertGreaterThan(audio.duration, 0.5)
        XCTAssertLessThan(audio.duration, 1.6)
    }

    func testDiscardThenFinishReturnsNothing() async {
        let recorder = Recorder()
        recorder.discard()
        let audio = await recorder.finish()
        XCTAssertEqual(audio.samples.count, 0)
    }
}

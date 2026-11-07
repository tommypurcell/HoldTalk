import Foundation

/// The rules for hold-to-talk, double-tap and Esc, with no audio or UI in it.
///
/// Recording starts the moment the hotkey goes down, to catch the first word.
/// Only on release do we know what the press meant:
///
///   long press               -> hold-to-talk: transcribe on release
///   short tap, then nothing  -> accidental tap: throw the audio away
///   short tap, then a press  -> hands-free: keeps recording until one more tap
public struct DictationMachine {
    public enum State: Equatable {
        case idle
        case holding(since: TimeInterval)
        case awaitingSecondTap
        case handsFree
        case processing
    }

    public enum Event: Equatable {
        case hotkeyDown(at: TimeInterval)
        case hotkeyUp(at: TimeInterval)
        /// Another key was pressed while a modifier hotkey was down, e.g. fn+arrow.
        case otherKey(at: TimeInterval)
        case escape
        case secondTapTimedOut
        case recordingLimitReached
        case recordingFailed
        case processingFinished
        /// Turned off from the menu, or the Mac is going to sleep.
        case shutDown
    }

    public enum Effect: Equatable {
        case startRecording
        case finishRecording
        case discardRecording
        case cancelProcessing
        case startSecondTapTimer(TimeInterval)
        case cancelSecondTapTimer
    }

    /// A press shorter than this counts as a tap rather than a hold.
    public var tapMaxSeconds: TimeInterval
    /// How long after a tap the second tap can arrive.
    public var doubleTapWindowSeconds: TimeInterval
    /// A key chord this soon after pressing the hotkey means the user wanted the
    /// chord (fn+arrow, right-cmd+C), not dictation.
    public var chordCancelSeconds: TimeInterval

    public private(set) var state: State = .idle

    public init(tapMaxSeconds: TimeInterval = 0.25,
                doubleTapWindowSeconds: TimeInterval = 0.35,
                chordCancelSeconds: TimeInterval = 1.0) {
        self.tapMaxSeconds = tapMaxSeconds
        self.doubleTapWindowSeconds = doubleTapWindowSeconds
        self.chordCancelSeconds = chordCancelSeconds
    }

    public var isRecording: Bool {
        switch state {
        case .holding, .awaitingSecondTap, .handsFree: return true
        case .idle, .processing: return false
        }
    }

    public mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.idle, .hotkeyDown(let time)):
            state = .holding(since: time)
            return [.startRecording]

        case (.holding(let since), .hotkeyUp(let time)):
            if time - since < tapMaxSeconds {
                state = .awaitingSecondTap
                return [.startSecondTapTimer(doubleTapWindowSeconds)]
            }
            state = .processing
            return [.finishRecording]

        case (.holding(let since), .otherKey(let time)):
            guard time - since < chordCancelSeconds else { return [] }
            state = .idle
            return [.discardRecording]

        case (.awaitingSecondTap, .hotkeyDown):
            state = .handsFree
            return [.cancelSecondTapTimer]

        case (.awaitingSecondTap, .secondTapTimedOut):
            state = .idle
            return [.discardRecording]

        case (.handsFree, .hotkeyDown):
            state = .processing
            return [.finishRecording]

        case (.holding, .recordingLimitReached), (.handsFree, .recordingLimitReached):
            state = .processing
            return [.finishRecording]

        case (.awaitingSecondTap, .recordingLimitReached):
            state = .processing
            return [.cancelSecondTapTimer, .finishRecording]

        case (.holding, .escape), (.handsFree, .escape),
             (.holding, .recordingFailed), (.handsFree, .recordingFailed),
             (.holding, .shutDown), (.handsFree, .shutDown):
            state = .idle
            return [.discardRecording]

        case (.awaitingSecondTap, .escape),
             (.awaitingSecondTap, .recordingFailed),
             (.awaitingSecondTap, .shutDown):
            state = .idle
            return [.cancelSecondTapTimer, .discardRecording]

        case (.processing, .escape), (.processing, .shutDown):
            state = .idle
            return [.cancelProcessing]

        case (.processing, .processingFinished):
            state = .idle
            return []

        default:
            // Everything else is deliberately ignored. For example, the release
            // after a hands-free stop tap, or a press while still transcribing.
            return []
        }
    }
}

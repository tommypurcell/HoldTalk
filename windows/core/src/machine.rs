//! The rules for hold-to-talk, double-tap and Esc, with no audio or UI in it.
//! A direct port of `Sources/HoldTalkKit/DictationMachine.swift`: keep the two in step.
//!
//! Recording starts the moment the hotkey goes down, to catch the first word.
//! Only on release do we know what the press meant:
//!
//!   long press               -> hold-to-talk: transcribe on release
//!   short tap, then nothing  -> accidental tap: throw the audio away
//!   short tap, then a press  -> hands-free: keeps recording until one more tap
//!
//! Esc during a recording pauses the mic and offers a short undo window:
//! pressing the hotkey again resumes the same audio (hands-free, so it is
//! finished with one more tap and never by a release), and letting the window
//! run out throws the audio away.

/// Times are seconds on any steady clock.
pub type Seconds = f64;

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum State {
    Idle,
    Holding { since: Seconds },
    AwaitingSecondTap,
    HandsFree,
    /// Esc was pressed while recording: mic is off, audio kept in memory
    /// for a few seconds in case the undo is wanted.
    AwaitingUndo,
    Processing,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Event {
    HotkeyDown(Seconds),
    HotkeyUp(Seconds),
    /// Another key was pressed while a modifier hotkey was down, e.g. ctrl+C.
    OtherKey(Seconds),
    Escape,
    SecondTapTimedOut,
    /// The undo window after Esc closed; the audio is now gone.
    UndoWindowTimedOut,
    RecordingLimitReached,
    RecordingFailed,
    ProcessingFinished,
    /// Turned off from the tray, or the PC is going to sleep or locking.
    ShutDown,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Effect {
    StartRecording,
    FinishRecording,
    DiscardRecording,
    /// Esc offered an undo: stop capturing, keep the audio in memory.
    PauseRecording,
    /// Undo was chosen: carry on recording into the same audio.
    ResumeRecording,
    CancelProcessing,
    StartSecondTapTimer(Seconds),
    CancelSecondTapTimer,
    StartUndoTimer(Seconds),
    CancelUndoTimer,
}

#[derive(Debug, Clone)]
pub struct DictationMachine {
    /// A press shorter than this counts as a tap rather than a hold.
    pub tap_max_seconds: Seconds,
    /// How long after a tap the second tap can arrive.
    pub double_tap_window_seconds: Seconds,
    /// A key chord this soon after pressing the hotkey means the user wanted the
    /// chord (right ctrl+C), not dictation.
    pub chord_cancel_seconds: Seconds,
    /// How long after Esc the undo is still possible.
    pub undo_window_seconds: Seconds,
    state: State,
}

impl Default for DictationMachine {
    fn default() -> Self {
        Self::new(0.25, 0.35)
    }
}

impl DictationMachine {
    pub fn new(tap_max_seconds: Seconds, double_tap_window_seconds: Seconds) -> Self {
        Self {
            tap_max_seconds,
            double_tap_window_seconds,
            chord_cancel_seconds: 1.0,
            undo_window_seconds: 5.0,
            state: State::Idle,
        }
    }

    pub fn state(&self) -> State {
        self.state
    }

    /// True while the mic is capturing. The undo window has the mic off, even
    /// though the recording can still be resumed.
    pub fn is_recording(&self) -> bool {
        matches!(self.state, State::Holding { .. } | State::AwaitingSecondTap | State::HandsFree)
    }

    pub fn handle(&mut self, event: Event) -> Vec<Effect> {
        use Effect::*;
        use Event::*;
        use State::*;

        match (self.state, event) {
            (Idle, HotkeyDown(time)) => {
                self.state = Holding { since: time };
                vec![StartRecording]
            }
            (Holding { since }, HotkeyUp(time)) => {
                if time - since < self.tap_max_seconds {
                    self.state = AwaitingSecondTap;
                    return vec![StartSecondTapTimer(self.double_tap_window_seconds)];
                }
                self.state = Processing;
                vec![FinishRecording]
            }
            (Holding { since }, OtherKey(time)) => {
                if time - since >= self.chord_cancel_seconds {
                    return vec![];
                }
                self.state = Idle;
                vec![DiscardRecording]
            }
            (AwaitingSecondTap, HotkeyDown(_)) => {
                self.state = HandsFree;
                vec![CancelSecondTapTimer]
            }
            (AwaitingSecondTap, SecondTapTimedOut) => {
                self.state = Idle;
                vec![DiscardRecording]
            }
            (HandsFree, HotkeyDown(_)) => {
                self.state = Processing;
                vec![FinishRecording]
            }
            (Holding { .. }, RecordingLimitReached) | (HandsFree, RecordingLimitReached) => {
                self.state = Processing;
                vec![FinishRecording]
            }
            (AwaitingSecondTap, RecordingLimitReached) => {
                self.state = Processing;
                vec![CancelSecondTapTimer, FinishRecording]
            }
            (Holding { .. }, Escape) | (HandsFree, Escape) => {
                // Off goes the mic, and a window opens to take the undo back.
                self.state = AwaitingUndo;
                vec![PauseRecording, StartUndoTimer(self.undo_window_seconds)]
            }
            (AwaitingSecondTap, Escape) => {
                self.state = AwaitingUndo;
                vec![CancelSecondTapTimer, PauseRecording, StartUndoTimer(self.undo_window_seconds)]
            }
            (AwaitingUndo, HotkeyDown(_)) => {
                // The hotkey again during the window takes the undo: the recording
                // resumes hands-free, so one more tap finishes and transcribes it,
                // and a release can never sneak a paste in after Esc.
                self.state = HandsFree;
                vec![CancelUndoTimer, ResumeRecording]
            }
            (AwaitingUndo, Escape) => {
                self.state = Idle;
                vec![CancelUndoTimer, DiscardRecording]
            }
            (AwaitingUndo, UndoWindowTimedOut) => {
                self.state = Idle;
                vec![DiscardRecording]
            }
            (AwaitingUndo, RecordingLimitReached) => {
                // The limit clock keeps running while paused, so the undo window
                // cannot be used to record for longer.
                self.state = Idle;
                vec![CancelUndoTimer, DiscardRecording]
            }
            (Holding { .. }, RecordingFailed)
            | (HandsFree, RecordingFailed)
            | (Holding { .. }, ShutDown)
            | (HandsFree, ShutDown) => {
                self.state = Idle;
                vec![DiscardRecording]
            }
            (AwaitingSecondTap, RecordingFailed) | (AwaitingSecondTap, ShutDown) => {
                self.state = Idle;
                vec![CancelSecondTapTimer, DiscardRecording]
            }
            (AwaitingUndo, RecordingFailed) | (AwaitingUndo, ShutDown) => {
                self.state = Idle;
                vec![CancelUndoTimer, DiscardRecording]
            }
            (Processing, Escape) | (Processing, ShutDown) => {
                self.state = Idle;
                vec![CancelProcessing]
            }
            (Processing, ProcessingFinished) => {
                self.state = Idle;
                vec![]
            }
            // Everything else is deliberately ignored. For example, the release
            // after a hands-free stop tap, a press while still transcribing, or
            // the release of a key still held during the undo window.
            _ => vec![],
        }
    }
}

#[cfg(test)]
mod tests {
    use super::Effect::*;
    use super::Event::*;
    use super::State::*;
    use super::*;

    fn machine() -> DictationMachine {
        DictationMachine::new(0.25, 0.35)
    }

    #[test]
    fn long_hold_records_then_transcribes_on_release() {
        let mut m = machine();
        assert_eq!(m.handle(HotkeyDown(10.0)), vec![StartRecording]);
        assert_eq!(m.state(), Holding { since: 10.0 });
        assert_eq!(m.handle(HotkeyUp(12.0)), vec![FinishRecording]);
        assert_eq!(m.state(), Processing);
        assert_eq!(m.handle(ProcessingFinished), vec![]);
        assert_eq!(m.state(), Idle);
    }

    #[test]
    fn single_quick_tap_is_thrown_away() {
        let mut m = machine();
        m.handle(HotkeyDown(10.0));
        assert_eq!(m.handle(HotkeyUp(10.1)), vec![StartSecondTapTimer(0.35)]);
        assert!(m.is_recording());
        assert_eq!(m.handle(SecondTapTimedOut), vec![DiscardRecording]);
        assert_eq!(m.state(), Idle);
    }

    #[test]
    fn double_tap_starts_hands_free_and_one_more_tap_stops() {
        let mut m = machine();
        m.handle(HotkeyDown(10.0));
        m.handle(HotkeyUp(10.1));
        assert_eq!(m.handle(HotkeyDown(10.2)), vec![CancelSecondTapTimer]);
        assert_eq!(m.state(), HandsFree);
        assert_eq!(m.handle(HotkeyUp(10.3)), vec![], "Releasing the second tap must not stop it");
        assert_eq!(m.state(), HandsFree);
        assert_eq!(m.handle(HotkeyDown(40.0)), vec![FinishRecording]);
        assert_eq!(m.state(), Processing);
        assert_eq!(m.handle(HotkeyUp(40.1)), vec![], "Releasing the stop tap does nothing");
    }

    #[test]
    fn hands_free_auto_stops_at_limit_and_transcribes() {
        let mut m = machine();
        m.handle(HotkeyDown(10.0));
        m.handle(HotkeyUp(10.1));
        m.handle(HotkeyDown(10.2));
        assert_eq!(m.handle(RecordingLimitReached), vec![FinishRecording]);
        assert_eq!(m.state(), Processing);
    }

    #[test]
    fn stuck_hold_also_stops_at_limit() {
        let mut m = machine();
        m.handle(HotkeyDown(10.0));
        assert_eq!(m.handle(RecordingLimitReached), vec![FinishRecording]);
        assert_eq!(m.handle(HotkeyUp(400.0)), vec![], "A late release does nothing");
        assert_eq!(m.state(), Processing);
    }

    #[test]
    fn escape_during_hold_offers_undo_then_times_out() {
        let mut m = machine();
        m.handle(HotkeyDown(10.0));
        assert_eq!(m.handle(Escape), vec![PauseRecording, StartUndoTimer(5.0)]);
        assert_eq!(m.state(), AwaitingUndo);
        assert!(!m.is_recording(), "The mic is off while undo is offered");
        assert_eq!(m.handle(HotkeyUp(11.0)), vec![], "Release during the window does nothing");
        assert_eq!(m.handle(UndoWindowTimedOut), vec![DiscardRecording]);
        assert_eq!(m.state(), Idle);
    }

    #[test]
    fn escape_during_awaiting_second_tap_offers_undo() {
        let mut m = machine();
        m.handle(HotkeyDown(10.0));
        m.handle(HotkeyUp(10.1));
        assert_eq!(m.handle(Escape), vec![CancelSecondTapTimer, PauseRecording, StartUndoTimer(5.0)]);
        assert_eq!(m.state(), AwaitingUndo);
        assert_eq!(m.handle(UndoWindowTimedOut), vec![DiscardRecording]);
        assert_eq!(m.state(), Idle);
    }

    #[test]
    fn escape_during_hands_free_offers_undo() {
        let mut m = machine();
        m.handle(HotkeyDown(10.0));
        m.handle(HotkeyUp(10.1));
        m.handle(HotkeyDown(10.2));
        assert_eq!(m.handle(Escape), vec![PauseRecording, StartUndoTimer(5.0)]);
        assert_eq!(m.state(), AwaitingUndo);
    }

    #[test]
    fn undo_resumes_hands_free_and_a_tap_finishes() {
        let mut m = machine();
        m.handle(HotkeyDown(10.0));
        m.handle(Escape);
        assert_eq!(m.handle(HotkeyDown(12.0)), vec![CancelUndoTimer, ResumeRecording]);
        assert_eq!(m.state(), HandsFree);
        assert!(m.is_recording());
        assert_eq!(m.handle(HotkeyUp(12.1)), vec![], "Release after undo must not finish");
        assert_eq!(m.handle(HotkeyDown(20.0)), vec![FinishRecording]);
        assert_eq!(m.state(), Processing);
    }

    #[test]
    fn undo_after_tap_keeps_earlier_audio_and_transcribes_on_stop() {
        let mut m = machine();
        m.handle(HotkeyDown(10.0));
        m.handle(HotkeyUp(10.1));
        m.handle(Escape);
        m.handle(HotkeyDown(11.0));
        assert_eq!(m.state(), HandsFree);
        assert_eq!(m.handle(HotkeyDown(20.0)), vec![FinishRecording]);
    }

    #[test]
    fn second_escape_during_undo_window_discards_now() {
        let mut m = machine();
        m.handle(HotkeyDown(10.0));
        m.handle(Escape);
        assert_eq!(m.handle(Escape), vec![CancelUndoTimer, DiscardRecording]);
        assert_eq!(m.state(), Idle);
    }

    #[test]
    fn undo_keeps_the_recording_limit() {
        let mut m = machine();
        m.handle(HotkeyDown(10.0));
        m.handle(Escape);
        m.handle(HotkeyDown(12.0));
        assert_eq!(m.handle(RecordingLimitReached), vec![FinishRecording]);
        assert_eq!(m.state(), Processing);
    }

    #[test]
    fn limit_during_undo_window_discards() {
        let mut m = machine();
        m.handle(HotkeyDown(10.0));
        m.handle(Escape);
        assert_eq!(m.handle(RecordingLimitReached), vec![CancelUndoTimer, DiscardRecording]);
        assert_eq!(m.state(), Idle);
    }

    #[test]
    fn shut_down_during_undo_window_discards() {
        let mut m = machine();
        m.handle(HotkeyDown(10.0));
        m.handle(Escape);
        assert_eq!(m.handle(ShutDown), vec![CancelUndoTimer, DiscardRecording]);
        assert_eq!(m.state(), Idle);
    }

    #[test]
    fn mic_failure_during_undo_window_discards() {
        let mut m = machine();
        m.handle(HotkeyDown(10.0));
        m.handle(Escape);
        assert_eq!(m.handle(RecordingFailed), vec![CancelUndoTimer, DiscardRecording]);
        assert_eq!(m.state(), Idle);
    }

    #[test]
    fn escape_kills_running_transcription() {
        let mut m = machine();
        m.handle(HotkeyDown(10.0));
        m.handle(HotkeyUp(12.0));
        assert_eq!(m.handle(Escape), vec![CancelProcessing]);
        assert_eq!(m.state(), Idle);
    }

    #[test]
    fn escape_while_idle_does_nothing() {
        let mut m = machine();
        assert_eq!(m.handle(Escape), vec![]);
        assert_eq!(m.state(), Idle);
    }

    #[test]
    fn press_while_transcribing_is_ignored() {
        let mut m = machine();
        m.handle(HotkeyDown(10.0));
        m.handle(HotkeyUp(12.0));
        assert_eq!(m.handle(HotkeyDown(13.0)), vec![]);
        assert_eq!(m.handle(HotkeyUp(14.0)), vec![]);
        assert_eq!(m.state(), Processing);
    }

    #[test]
    fn late_timer_cannot_drop_hands_free() {
        let mut m = machine();
        m.handle(HotkeyDown(10.0));
        m.handle(HotkeyUp(10.1));
        m.handle(HotkeyDown(10.2));
        assert_eq!(m.handle(SecondTapTimedOut), vec![]);
        assert_eq!(m.state(), HandsFree);
    }

    #[test]
    fn chord_soon_after_press_cancels() {
        let mut m = machine();
        m.handle(HotkeyDown(10.0));
        assert_eq!(m.handle(OtherKey(10.4)), vec![DiscardRecording]);
        assert_eq!(m.state(), Idle);
    }

    #[test]
    fn key_long_after_press_keeps_recording() {
        let mut m = machine();
        m.handle(HotkeyDown(10.0));
        assert_eq!(m.handle(OtherKey(13.0)), vec![]);
        assert_eq!(m.state(), Holding { since: 10.0 });
    }

    #[test]
    fn mic_failure_returns_to_idle() {
        let mut m = machine();
        m.handle(HotkeyDown(10.0));
        assert_eq!(m.handle(RecordingFailed), vec![DiscardRecording]);
        assert_eq!(m.state(), Idle);
    }

    #[test]
    fn shut_down_stops_everything() {
        let mut m = machine();
        m.handle(HotkeyDown(10.0));
        assert_eq!(m.handle(ShutDown), vec![DiscardRecording]);
        m.handle(HotkeyDown(20.0));
        m.handle(HotkeyUp(22.0));
        assert_eq!(m.handle(ShutDown), vec![CancelProcessing]);
        assert_eq!(m.state(), Idle);
    }
}

//! Connects the keyboard, microphone, transcription, pill and paste, following
//! what `DictationMachine` decides. A port of the Mac app's `DictationController.swift`.
//!
//! Everything here runs on one thread that handles one message at a time, as the
//! Mac app does on its main thread. That is what makes Esc safe: once Esc has
//! been handled, a transcription that finishes later is recognised as stale and
//! can never paste.

use crate::audio::SpeechAudio;
use crate::config::{Config, EnvFile};
use crate::machine::{DictationMachine, Effect, Event, State};
use crate::pipeline::{Outcome, Pipeline};
use crate::{CancelFlag, Error};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Signal {
    HotkeyDown,
    HotkeyUp,
    OtherKey,
    Escape,
}

pub enum Input {
    /// From the keyboard hook, with the time the key event happened.
    Key(Signal, Instant),
    RecordingFailed(String),
    /// Loudness of the latest mic buffer, 0 to 1.
    Level(f32),
    /// The PC is going to sleep or locking.
    ShutDown,
    SetEnabled(bool),
    Apply(Box<Config>, EnvFile),
    Quit,
    /// A transcription finished. The number says which one.
    Done(u64, Result<Outcome, Error>),
}

/// What the floating pill is showing.
#[derive(Debug, Clone, PartialEq)]
pub enum PillContent {
    Holding,
    HandsFree { seconds_left: u64, elapsed: u64 },
    Transcribing,
    /// Esc was pressed: the mic is off and the undo can still be taken.
    Cancelled { hint: String },
    Message { text: String, is_error: bool },
}

pub trait Pill: Send {
    fn show(&mut self, content: PillContent);
    fn level(&mut self, level: f32);
    /// Shows a message briefly, then hides.
    fn flash(&mut self, text: &str, is_error: bool);
    fn hide(&mut self);
}

pub trait Recorder: Send {
    fn start(&mut self);
    /// Stops capturing but keeps what was recorded, for the undo window after Esc.
    fn pause(&mut self);
    /// Continues the same recording after a pause.
    fn resume(&mut self);
    /// Stops and hands back everything recorded.
    fn finish(&mut self) -> SpeechAudio;
    fn discard(&mut self);
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Inserted {
    Pasted,
    /// The text is on the clipboard but couldn't be pasted. Says why.
    CopiedOnly(String),
}

pub trait Inserter: Send {
    fn insert(&mut self, text: &str, restore_clipboard: bool) -> Inserted;
}

/// News for the tray.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Notice {
    Recording(bool),
    Problem(String),
}

pub struct Parts {
    pub recorder: Box<dyn Recorder>,
    pub inserter: Box<dyn Inserter>,
    pub pill: Box<dyn Pill>,
    pub make_pipeline: Box<dyn Fn(&Config, &EnvFile) -> Pipeline + Send>,
    /// Called when recording starts, so whisper-server is loaded by the time it ends.
    pub warm_up: Box<dyn Fn(&Config) + Send>,
    pub notify: Box<dyn FnMut(Notice) + Send>,
}

pub struct Controller {
    config: Config,
    env: EnvFile,
    enabled: bool,
    machine: DictationMachine,
    parts: Parts,
    inbox: Sender<Input>,
    epoch: Instant,

    second_tap_deadline: Option<Instant>,
    undo_deadline: Option<Instant>,
    next_tick: Option<Instant>,
    recording_started: Instant,
    stopped_at_limit: bool,

    /// Bumped whenever a transcription starts or is cancelled, so a stale
    /// result is recognised and dropped.
    generation: u64,
    cancel: CancelFlag,
}

impl Controller {
    /// Starts the controller on its own thread. Send it `Input`s. `parts` gets
    /// the inbox too, so the mic can send levels and failures.
    pub fn spawn(config: Config, env: EnvFile, parts: impl FnOnce(Sender<Input>) -> Parts) -> (Sender<Input>, JoinHandle<()>) {
        let (inbox, messages) = mpsc::channel();
        let parts = parts(inbox.clone());
        let machine = Self::make_machine(&config);
        let controller = Controller {
            config,
            env,
            enabled: true,
            machine,
            parts,
            inbox: inbox.clone(),
            epoch: Instant::now(),
            second_tap_deadline: None,
            undo_deadline: None,
            next_tick: None,
            recording_started: Instant::now(),
            stopped_at_limit: false,
            generation: 0,
            cancel: CancelFlag::new(),
        };
        let thread = std::thread::Builder::new()
            .name("holdtalk-controller".into())
            .spawn(move || controller.run(messages))
            .expect("controller thread");
        (inbox, thread)
    }

    fn make_machine(config: &Config) -> DictationMachine {
        DictationMachine::new(config.tap_max_milliseconds / 1000.0, config.double_tap_window_milliseconds / 1000.0)
    }

    fn run(mut self, messages: Receiver<Input>) {
        loop {
            let next = [self.second_tap_deadline, self.undo_deadline, self.next_tick].into_iter().flatten().min();
            let received = match next {
                Some(deadline) => messages.recv_timeout(deadline.saturating_duration_since(Instant::now())),
                None => messages.recv().map_err(|_| RecvTimeoutError::Disconnected),
            };
            match received {
                Ok(Input::Quit) | Err(RecvTimeoutError::Disconnected) => {
                    self.send(Event::ShutDown);
                    return;
                }
                Ok(input) => self.handle(input),
                Err(RecvTimeoutError::Timeout) => {}
            }
            self.fire_timers();
        }
    }

    fn handle(&mut self, input: Input) {
        match input {
            Input::Key(signal, at) => {
                if !self.enabled {
                    return;
                }
                let at = at.saturating_duration_since(self.epoch).as_secs_f64();
                self.send(match signal {
                    Signal::HotkeyDown => Event::HotkeyDown(at),
                    Signal::HotkeyUp => Event::HotkeyUp(at),
                    Signal::OtherKey => Event::OtherKey(at),
                    Signal::Escape => Event::Escape,
                });
            }
            Input::RecordingFailed(message) => {
                self.send(Event::RecordingFailed);
                self.report(&message, true);
            }
            Input::Level(level) => {
                if self.machine.is_recording() {
                    self.parts.pill.level(level);
                }
            }
            Input::ShutDown => self.send(Event::ShutDown),
            Input::SetEnabled(enabled) => {
                if !enabled {
                    self.send(Event::ShutDown);
                }
                self.enabled = enabled;
            }
            Input::Apply(config, env) => {
                // Anything running is cancelled first.
                self.send(Event::ShutDown);
                self.machine = Self::make_machine(&config);
                self.config = *config;
                self.env = env;
            }
            Input::Done(generation, result) => self.finished(generation, result),
            Input::Quit => {}
        }
    }

    fn fire_timers(&mut self) {
        let now = Instant::now();
        if self.second_tap_deadline.is_some_and(|d| d <= now) {
            self.second_tap_deadline = None;
            self.send(Event::SecondTapTimedOut);
        }
        if self.undo_deadline.is_some_and(|d| d <= now) {
            self.undo_deadline = None;
            self.send(Event::UndoWindowTimedOut);
        }
        if self.next_tick.is_some_and(|d| d <= now) {
            // Ticks each second to update the pill's clock and enforce the limit.
            self.next_tick = Some(now + Duration::from_secs(1));
            if self.recording_started.elapsed().as_secs_f64() >= self.config.max_recording_seconds {
                self.send(Event::RecordingLimitReached);
            } else if self.machine.state() == State::HandsFree {
                let content = self.hands_free_content();
                self.parts.pill.show(content);
            }
        }
    }

    fn send(&mut self, event: Event) {
        let effects = self.machine.handle(event);
        self.stopped_at_limit = event == Event::RecordingLimitReached && !effects.is_empty();
        for effect in effects {
            self.perform(effect);
        }
        self.refresh_pill();
    }

    fn perform(&mut self, effect: Effect) {
        match effect {
            Effect::StartRecording => {
                self.recording_started = Instant::now();
                self.parts.pill.level(0.0);
                self.parts.recorder.start();
                (self.parts.warm_up)(&self.config);
                self.next_tick = Some(Instant::now() + Duration::from_secs(1));
                (self.parts.notify)(Notice::Recording(true));
            }
            Effect::FinishRecording => {
                self.next_tick = None;
                (self.parts.notify)(Notice::Recording(false));
                self.start_processing();
            }
            Effect::DiscardRecording => {
                self.next_tick = None;
                self.parts.recorder.discard();
                (self.parts.notify)(Notice::Recording(false));
                self.parts.pill.hide();
            }
            Effect::PauseRecording => {
                // The limit clock keeps ticking on purpose: pausing must not buy
                // extra recording time.
                self.parts.recorder.pause();
                (self.parts.notify)(Notice::Recording(false));
            }
            Effect::ResumeRecording => {
                // recording_started is untouched, so the limit still counts from
                // when the recording first began.
                self.parts.pill.level(0.0);
                self.parts.recorder.resume();
                (self.parts.notify)(Notice::Recording(true));
            }
            Effect::CancelProcessing => {
                self.cancel.cancel();
                self.generation += 1;
                self.parts.pill.hide();
            }
            Effect::StartSecondTapTimer(delay) => {
                self.second_tap_deadline = Some(Instant::now() + Duration::from_secs_f64(delay));
            }
            Effect::CancelSecondTapTimer => self.second_tap_deadline = None,
            Effect::StartUndoTimer(delay) => {
                self.undo_deadline = Some(Instant::now() + Duration::from_secs_f64(delay));
            }
            Effect::CancelUndoTimer => self.undo_deadline = None,
        }
    }

    fn refresh_pill(&mut self) {
        let content = match self.machine.state() {
            State::Holding { .. } | State::AwaitingSecondTap => PillContent::Holding,
            State::HandsFree => self.hands_free_content(),
            State::AwaitingUndo => PillContent::Cancelled { hint: format!("press {} to undo", self.hotkey_name()) },
            State::Processing => PillContent::Transcribing,
            State::Idle => return,
        };
        self.parts.pill.show(content);
    }

    /// "right_ctrl" reads as "Right Ctrl".
    fn hotkey_name(&self) -> String {
        self.config
            .hotkey
            .split('_')
            .map(|word| {
                let mut chars = word.chars();
                chars.next().map(|c| c.to_uppercase().chain(chars).collect::<String>()).unwrap_or_default()
            })
            .collect::<Vec<_>>()
            .join(" ")
    }

    fn hands_free_content(&self) -> PillContent {
        let elapsed = self.recording_started.elapsed().as_secs();
        let limit = self.config.max_recording_seconds as u64;
        PillContent::HandsFree { seconds_left: limit.saturating_sub(elapsed), elapsed }
    }

    fn start_processing(&mut self) {
        let audio = self.parts.recorder.finish();
        if audio.is_likely_empty() {
            self.finish(Some("No speech heard".into()), false);
            return;
        }
        self.generation += 1;
        let generation = self.generation;
        self.cancel = CancelFlag::new();
        let cancel = self.cancel.clone();
        let pipeline = (self.parts.make_pipeline)(&self.config, &self.env);
        let inbox = self.inbox.clone();
        // The WAV stays in memory: whisper-server and the cloud APIs take it
        // straight from here, and only the whisper-cli fallback writes a file.
        let wav = audio.wav_data();
        std::thread::spawn(move || {
            let result = pipeline.run(&wav, &cancel);
            let _ = inbox.send(Input::Done(generation, result));
        });
    }

    fn finished(&mut self, generation: u64, result: Result<Outcome, Error>) {
        // Esc, a shutdown or a newer recording got here first: never paste.
        if generation != self.generation || self.machine.state() != State::Processing {
            return;
        }
        match result {
            Ok(outcome) => self.deliver(outcome),
            Err(Error::Cancelled) => {}
            Err(Error::Failed(message)) => self.finish(Some(message), true),
        }
    }

    fn deliver(&mut self, outcome: Outcome) {
        if outcome.text.is_empty() {
            let is_error = outcome.notice.is_some();
            self.finish(Some(outcome.notice.unwrap_or_else(|| "No speech heard".into())), is_error);
            return;
        }
        match self.parts.inserter.insert(&outcome.text, self.config.restore_clipboard) {
            Inserted::Pasted => {
                let limit_note = self.stopped_at_limit.then(|| format!("Stopped at the {} limit", self.limit_description()));
                let is_error = outcome.notice.is_some();
                self.finish(outcome.notice.or(limit_note), is_error);
            }
            Inserted::CopiedOnly(reason) => self.finish(Some(reason), true),
        }
    }

    fn limit_description(&self) -> String {
        let seconds = self.config.max_recording_seconds as u64;
        if seconds % 60 == 0 {
            format!("{} minute", seconds / 60)
        } else {
            format!("{seconds} second")
        }
    }

    fn finish(&mut self, message: Option<String>, is_error: bool) {
        self.machine.handle(Event::ProcessingFinished);
        match message {
            Some(message) => self.report(&message, is_error),
            None => self.parts.pill.hide(),
        }
    }

    fn report(&mut self, message: &str, is_error: bool) {
        self.parts.pill.flash(message, is_error);
        if is_error {
            (self.parts.notify)(Notice::Problem(message.to_string()));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pipeline::tests::{fixed, FakeTranscriber};
    use crate::transcribe::Transcriber;
    use std::sync::{Arc, Mutex};

    #[derive(Default, Clone)]
    struct Log(Arc<Mutex<Vec<String>>>);

    impl Log {
        fn push(&self, entry: String) {
            self.0.lock().unwrap().push(entry);
        }
        fn entries(&self) -> Vec<String> {
            self.0.lock().unwrap().clone()
        }
        fn wait_for(&self, entry: &str) -> bool {
            let deadline = Instant::now() + Duration::from_secs(3);
            while Instant::now() < deadline {
                if self.entries().iter().any(|e| e == entry) {
                    return true;
                }
                std::thread::sleep(Duration::from_millis(5));
            }
            false
        }
    }

    struct FakeRecorder {
        log: Log,
        audio: SpeechAudio,
    }

    impl Recorder for FakeRecorder {
        fn start(&mut self) {
            self.log.push("mic start".into());
        }
        fn pause(&mut self) {
            self.log.push("mic pause".into());
        }
        fn resume(&mut self) {
            self.log.push("mic resume".into());
        }
        fn finish(&mut self) -> SpeechAudio {
            self.log.push("mic finish".into());
            self.audio.clone()
        }
        fn discard(&mut self) {
            self.log.push("mic discard".into());
        }
    }

    struct FakeInserter(Log, Inserted);

    impl Inserter for FakeInserter {
        fn insert(&mut self, text: &str, _: bool) -> Inserted {
            self.0.push(format!("paste {text}"));
            self.1.clone()
        }
    }

    struct FakePill(Log);

    impl Pill for FakePill {
        fn show(&mut self, content: PillContent) {
            self.0.push(format!("pill {content:?}"));
        }
        fn level(&mut self, _: f32) {}
        fn flash(&mut self, text: &str, is_error: bool) {
            self.0.push(format!("flash {text} {is_error}"));
        }
        fn hide(&mut self) {
            self.0.push("pill hide".into());
        }
    }

    /// Takes a moment, like a real transcription, so Esc can arrive first.
    struct Slow;

    impl Transcriber for Slow {
        fn name(&self) -> &str {
            "slow"
        }
        fn transcribe(&self, _: &[u8], _: &CancelFlag) -> Result<String, Error> {
            std::thread::sleep(Duration::from_millis(300));
            Ok("too late".into())
        }
    }

    fn speech() -> SpeechAudio {
        SpeechAudio::new(vec![0.2; 16_000])
    }

    fn start(
        audio: SpeechAudio,
        transcriber: fn() -> Box<dyn Transcriber>,
        inserted: Inserted,
        config: Config,
    ) -> (Sender<Input>, Log) {
        let log = Log::default();
        let notices = log.clone();
        let parts = Parts {
            recorder: Box::new(FakeRecorder { log: log.clone(), audio }),
            inserter: Box::new(FakeInserter(log.clone(), inserted)),
            pill: Box::new(FakePill(log.clone())),
            make_pipeline: Box::new(move |_, _| Pipeline { transcribers: vec![transcriber()], cleaner: None, setup_notice: None }),
            warm_up: Box::new(|_| {}),
            notify: Box::new(move |notice| notices.push(format!("notice {notice:?}"))),
        };
        let (inbox, _) = Controller::spawn(config, EnvFile::default(), |_| parts);
        (inbox, log)
    }

    fn hold(inbox: &Sender<Input>, seconds: u64) {
        let at = Instant::now();
        inbox.send(Input::Key(Signal::HotkeyDown, at)).unwrap();
        inbox.send(Input::Key(Signal::HotkeyUp, at + Duration::from_secs(seconds))).unwrap();
    }

    #[test]
    fn hold_transcribes_and_pastes() {
        let (inbox, log) = start(speech(), || fixed("hello"), Inserted::Pasted, Config::default());
        hold(&inbox, 2);
        assert!(log.wait_for("paste hello"), "{:?}", log.entries());
        assert!(log.wait_for("pill hide"));
        let entries = log.entries();
        assert!(entries.contains(&"pill Transcribing".to_string()));
        assert!(entries.contains(&"notice Recording(true)".to_string()));
    }

    #[test]
    fn escape_while_transcribing_never_pastes() {
        let (inbox, log) = start(speech(), || Box::new(Slow), Inserted::Pasted, Config::default());
        hold(&inbox, 2);
        assert!(log.wait_for("pill Transcribing"));
        inbox.send(Input::Key(Signal::Escape, Instant::now())).unwrap();
        std::thread::sleep(Duration::from_millis(500));
        assert!(!log.entries().iter().any(|e| e.starts_with("paste")), "{:?}", log.entries());
    }

    #[test]
    fn quick_tap_is_thrown_away() {
        let config = Config { double_tap_window_milliseconds: 50.0, ..Config::default() };
        let (inbox, log) = start(speech(), || fixed("hello"), Inserted::Pasted, config);
        let at = Instant::now();
        inbox.send(Input::Key(Signal::HotkeyDown, at)).unwrap();
        inbox.send(Input::Key(Signal::HotkeyUp, at + Duration::from_millis(100))).unwrap();
        assert!(log.wait_for("mic discard"), "{:?}", log.entries());
        assert!(!log.entries().iter().any(|e| e.starts_with("paste")));
    }

    #[test]
    fn silence_is_never_transcribed() {
        let (inbox, log) = start(SpeechAudio::new(vec![0.0; 16_000]), || fixed("ghost words"), Inserted::Pasted, Config::default());
        hold(&inbox, 2);
        assert!(log.wait_for("flash No speech heard false"), "{:?}", log.entries());
        assert!(!log.entries().iter().any(|e| e.starts_with("paste")));
    }

    #[test]
    fn failed_paste_says_why() {
        let reason = "Copied. Windows doesn't allow pasting into apps run as administrator";
        let (inbox, log) = start(speech(), || fixed("hello"), Inserted::CopiedOnly(reason.into()), Config::default());
        hold(&inbox, 2);
        assert!(log.wait_for(&format!("flash {reason} true")), "{:?}", log.entries());
        assert!(log.wait_for(&format!("notice Problem({reason:?})")));
    }

    #[test]
    fn transcription_error_is_reported() {
        let (inbox, log) = start(
            speech(),
            || Box::new(FakeTranscriber { name: "x", result: Err(Error::failed("whisper broke")) }),
            Inserted::Pasted,
            Config::default(),
        );
        hold(&inbox, 2);
        assert!(log.wait_for("flash whisper broke true"), "{:?}", log.entries());
    }

    #[test]
    fn escape_offers_undo_with_the_hotkey_name() {
        let (inbox, log) = start(speech(), || fixed("hello"), Inserted::Pasted, Config::default());
        inbox.send(Input::Key(Signal::HotkeyDown, Instant::now())).unwrap();
        inbox.send(Input::Key(Signal::Escape, Instant::now())).unwrap();
        assert!(log.wait_for("pill Cancelled { hint: \"press Right Ctrl to undo\" }"), "{:?}", log.entries());
        assert!(log.wait_for("mic pause"));
    }

    #[test]
    fn recording_limit_stops_and_says_so() {
        let config = Config { max_recording_seconds: 1.0, ..Config::default() };
        let (inbox, log) = start(speech(), || fixed("hello"), Inserted::Pasted, config);
        inbox.send(Input::Key(Signal::HotkeyDown, Instant::now())).unwrap();
        assert!(log.wait_for("paste hello"), "{:?}", log.entries());
        assert!(log.wait_for("flash Stopped at the 1 second limit false"), "{:?}", log.entries());
    }

    #[test]
    fn disabled_ignores_the_hotkey() {
        let (inbox, log) = start(speech(), || fixed("hello"), Inserted::Pasted, Config::default());
        inbox.send(Input::SetEnabled(false)).unwrap();
        hold(&inbox, 2);
        std::thread::sleep(Duration::from_millis(200));
        assert!(!log.entries().iter().any(|e| e == "mic start"));
    }

    #[test]
    fn sleep_discards_a_recording() {
        let (inbox, log) = start(speech(), || fixed("hello"), Inserted::Pasted, Config::default());
        inbox.send(Input::Key(Signal::HotkeyDown, Instant::now())).unwrap();
        inbox.send(Input::ShutDown).unwrap();
        assert!(log.wait_for("mic discard"), "{:?}", log.entries());
    }
}

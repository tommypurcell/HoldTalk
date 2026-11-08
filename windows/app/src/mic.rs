//! Records the microphone into memory. Audio is never written to disk here.
//!
//! The mic stream lives on its own thread, because opening it can take a moment
//! and the keyboard hook must never wait. Commands reach it over a channel, so
//! start and stop stay in order after a very quick tap.

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use holdtalk_core::audio::{Resampler, SpeechAudio};
use holdtalk_core::controller::{Input, Recorder};
use std::sync::mpsc::{self, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

enum Command {
    Start,
    Pause,
    Resume,
    Finish(Sender<SpeechAudio>),
    Discard,
    /// A headset was plugged in or removed mid-sentence. Keep what's recorded and carry on.
    DeviceChanged,
}

pub struct MicRecorder {
    commands: Sender<Command>,
}

#[derive(Default)]
struct Capture {
    resampler: Option<Resampler>,
    samples: Vec<f32>,
    last_level: Option<Instant>,
}

impl Capture {
    fn flush(&mut self) {
        if let Some(mut resampler) = self.resampler.take() {
            let rest = resampler.flush();
            self.samples.extend(rest);
        }
    }
}

impl MicRecorder {
    pub fn new(inbox: Sender<Input>) -> MicRecorder {
        let (commands, receiver) = mpsc::channel::<Command>();
        let own = commands.clone();
        std::thread::Builder::new()
            .name("holdtalk-mic".into())
            .spawn(move || {
                let capture = Arc::new(Mutex::new(Capture::default()));
                let mut stream: Option<cpal::Stream> = None;
                let open = |stream: &mut Option<cpal::Stream>| match open_stream(&capture, &inbox, &own) {
                    Ok(opened) => *stream = Some(opened),
                    Err(message) => {
                        *stream = None;
                        let _ = inbox.send(Input::RecordingFailed(message));
                    }
                };
                for command in receiver {
                    match command {
                        Command::Start => {
                            stream = None;
                            *capture.lock().unwrap() = Capture::default();
                            open(&mut stream);
                        }
                        Command::Pause => {
                            // The mic is fully released while paused: nothing is captured.
                            stream = None;
                            capture.lock().unwrap().flush();
                        }
                        Command::Resume => {
                            if stream.is_none() {
                                open(&mut stream);
                            }
                        }
                        Command::Finish(reply) => {
                            stream = None;
                            let mut capture = capture.lock().unwrap();
                            capture.flush();
                            let _ = reply.send(SpeechAudio::new(std::mem::take(&mut capture.samples)));
                        }
                        Command::Discard => {
                            stream = None;
                            *capture.lock().unwrap() = Capture::default();
                        }
                        Command::DeviceChanged => {
                            if stream.is_some() {
                                stream = None;
                                capture.lock().unwrap().flush();
                                if let Err(_) = open_stream(&capture, &inbox, &own).map(|s| stream = Some(s)) {
                                    let _ = inbox
                                        .send(Input::RecordingFailed("The microphone changed and couldn't restart.".into()));
                                }
                            }
                        }
                    }
                }
            })
            .expect("mic thread");
        MicRecorder { commands }
    }
}

impl Recorder for MicRecorder {
    fn start(&mut self) {
        let _ = self.commands.send(Command::Start);
    }

    fn pause(&mut self) {
        let _ = self.commands.send(Command::Pause);
    }

    fn resume(&mut self) {
        let _ = self.commands.send(Command::Resume);
    }

    fn finish(&mut self) -> SpeechAudio {
        let (reply, answer) = mpsc::channel();
        let _ = self.commands.send(Command::Finish(reply));
        answer.recv_timeout(Duration::from_secs(5)).unwrap_or_default()
    }

    fn discard(&mut self) {
        let _ = self.commands.send(Command::Discard);
    }
}

/// Explains the usual reasons a mic won't open, in words a person can act on.
fn friendly(error: impl std::fmt::Display) -> String {
    let text = error.to_string();
    let lower = text.to_lowercase();
    if lower.contains("0x80070005") || lower.contains("denied") {
        "Microphone access is off. Turn on \"Let desktop apps access your microphone\" in Settings > Privacy & security > Microphone.".into()
    } else {
        format!("The microphone couldn't start: {text}")
    }
}

fn open_stream(
    capture: &Arc<Mutex<Capture>>,
    inbox: &Sender<Input>,
    commands: &Sender<Command>,
) -> Result<cpal::Stream, String> {
    let device = cpal::default_host().default_input_device().ok_or("No microphone is available.")?;
    let supported = device.default_input_config().map_err(friendly)?;
    let format = supported.sample_format();
    let config: cpal::StreamConfig = supported.into();
    capture.lock().unwrap().resampler = Some(Resampler::new(config.sample_rate.0, config.channels));

    let commands = commands.clone();
    let on_error = move |error: cpal::StreamError| {
        if matches!(error, cpal::StreamError::DeviceNotAvailable) {
            let _ = commands.send(Command::DeviceChanged);
        }
    };
    let stream = match format {
        cpal::SampleFormat::F32 => {
            let (capture, inbox) = (capture.clone(), inbox.clone());
            device.build_input_stream(&config, move |data: &[f32], _: &_| append(&capture, &inbox, data), on_error, None)
        }
        cpal::SampleFormat::I16 => {
            let (capture, inbox) = (capture.clone(), inbox.clone());
            device.build_input_stream(
                &config,
                move |data: &[i16], _: &_| {
                    let samples: Vec<f32> = data.iter().map(|s| *s as f32 / 32_768.0).collect();
                    append(&capture, &inbox, &samples)
                },
                on_error,
                None,
            )
        }
        cpal::SampleFormat::U16 => {
            let (capture, inbox) = (capture.clone(), inbox.clone());
            device.build_input_stream(
                &config,
                move |data: &[u16], _: &_| {
                    let samples: Vec<f32> = data.iter().map(|s| (*s as f32 - 32_768.0) / 32_768.0).collect();
                    append(&capture, &inbox, &samples)
                },
                on_error,
                None,
            )
        }
        other => return Err(format!("The microphone uses an unsupported format ({other:?}).")),
    }
    .map_err(friendly)?;
    stream.play().map_err(friendly)?;
    Ok(stream)
}

fn append(capture: &Arc<Mutex<Capture>>, inbox: &Sender<Input>, data: &[f32]) {
    let mut capture = capture.lock().unwrap();
    let Some(resampler) = capture.resampler.as_mut() else { return };
    let converted = resampler.convert(data);
    let level = converted.iter().fold(0.0f32, |peak, s| peak.max(s.abs()));
    capture.samples.extend(converted);
    // About 20 updates a second is plenty for the meter.
    if capture.last_level.map_or(true, |at| at.elapsed() >= Duration::from_millis(50)) {
        capture.last_level = Some(Instant::now());
        let _ = inbox.send(Input::Level(level));
    }
}

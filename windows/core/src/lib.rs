//! Everything in HoldTalk for Windows that doesn't touch Windows itself: the
//! dictation rules, settings, audio format, transcription, cleanup and the
//! controller that ties them together. It builds and tests on any OS, so most of
//! the app can be checked on a Mac with `cargo test`.

pub mod audio;
pub mod cleanup;
pub mod config;
pub mod controller;
pub mod hotkey;
mod http;
#[cfg(windows)]
mod job;
pub mod machine;
pub mod model;
pub mod pipeline;
pub mod server;
pub mod transcribe;

use std::fmt;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    /// Esc, or the app shutting down. Never shown to the user.
    Cancelled,
    Failed(String),
}

impl Error {
    pub fn failed(message: impl Into<String>) -> Error {
        Error::Failed(message.into())
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Cancelled => f.write_str("Cancelled."),
            Error::Failed(message) => f.write_str(message),
        }
    }
}

impl std::error::Error for Error {}

/// Set once to stop work that's already running, such as a transcription.
#[derive(Debug, Clone, Default)]
pub struct CancelFlag(Arc<AtomicBool>);

impl CancelFlag {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn cancel(&self) {
        self.0.store(true, Ordering::SeqCst);
    }

    pub fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::SeqCst)
    }

    pub fn check(&self) -> Result<(), Error> {
        if self.is_cancelled() {
            Err(Error::Cancelled)
        } else {
            Ok(())
        }
    }
}

//! Stand-ins for systems other than Windows. Dictation needs the Windows
//! keyboard hook and paste, so here the hotkey does nothing and text is
//! reported instead of typed. The pill, tray and mic still work.

use holdtalk_core::controller::{Input, Inserted, Inserter};
use holdtalk_core::hotkey::Hotkey;
use std::sync::mpsc::Sender;
use tauri::WebviewWindow;

pub struct Keyboard;

impl Keyboard {
    pub fn start(_hotkey: Hotkey, _inbox: Sender<Input>) -> Result<Keyboard, String> {
        Ok(Keyboard)
    }
}

pub struct Paster;

impl Paster {
    pub fn new() -> Self {
        Paster
    }
}

impl Inserter for Paster {
    fn insert(&mut self, text: &str, _restore_clipboard: bool) -> Inserted {
        eprintln!("HoldTalk would paste: {text}");
        Inserted::CopiedOnly("Pasting only works on Windows".into())
    }
}

pub fn prepare_pill(_window: &WebviewWindow) {}

pub fn show_without_focus(window: &WebviewWindow) {
    let _ = window.show();
}

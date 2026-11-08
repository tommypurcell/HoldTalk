//! The floating pill: a small always-on-top window that never takes focus, so
//! typing carries on in your app. The drawing is in `ui/pill.html`.

use crate::platform;
use holdtalk_core::controller::{Pill, PillContent};
use serde_json::json;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tauri::{AppHandle, PhysicalPosition, WebviewUrl, WebviewWindow, WebviewWindowBuilder};

const WIDTH: f64 = 520.0;
const HEIGHT: f64 = 56.0;

pub fn create(app: &AppHandle) -> tauri::Result<WebviewWindow> {
    let window = WebviewWindowBuilder::new(app, "pill", WebviewUrl::App("pill.html".into()))
        .title("HoldTalk")
        .inner_size(WIDTH, HEIGHT)
        .transparent(true)
        .decorations(false)
        .shadow(false)
        .resizable(false)
        .always_on_top(true)
        .skip_taskbar(true)
        .focused(false)
        .focusable(false)
        .visible(false)
        .build()?;
    // Clicks go through to whatever is underneath.
    let _ = window.set_ignore_cursor_events(true);
    platform::prepare_pill(&window);
    Ok(window)
}

/// Bottom middle of the main screen, just above the taskbar.
fn place(window: &WebviewWindow) {
    let Ok(Some(monitor)) = window.primary_monitor() else { return };
    let area = monitor.work_area();
    let scale = monitor.scale_factor();
    let width = (WIDTH * scale) as i32;
    let height = (HEIGHT * scale) as i32;
    let x = area.position.x + (area.size.width as i32 - width) / 2;
    let y = area.position.y + area.size.height as i32 - height - (4.0 * scale) as i32;
    let _ = window.set_position(PhysicalPosition::new(x, y));
}

#[derive(Clone)]
pub struct TauriPill {
    window: WebviewWindow,
    /// Bumped on every change, so a flash's timer only hides its own message.
    shown: Arc<AtomicU64>,
}

impl TauriPill {
    pub fn new(window: WebviewWindow) -> Self {
        Self { window, shown: Arc::default() }
    }

    fn render(&self, dot: &str, title: &str, detail: Option<&str>, meter: bool, pulse: bool) -> u64 {
        let id = self.shown.fetch_add(1, Ordering::SeqCst) + 1;
        let parts = json!({ "dot": dot, "title": title, "detail": detail, "meter": meter, "pulse": pulse });
        let _ = self.window.eval(format!("window.holdtalk && window.holdtalk.show({parts})"));
        place(&self.window);
        platform::show_without_focus(&self.window);
        id
    }
}

fn clock(seconds: u64) -> String {
    format!("{}:{:02}", seconds / 60, seconds % 60)
}

impl Pill for TauriPill {
    fn show(&mut self, content: PillContent) {
        match content {
            PillContent::Holding => self.render("red", "Hold", None, true, true),
            PillContent::HandsFree { seconds_left, elapsed } => {
                let warning = seconds_left <= 30;
                let detail = if warning { format!("stops in {}", clock(seconds_left)) } else { clock(elapsed) };
                self.render(if warning { "amber" } else { "red" }, "Hands-free", Some(&detail), true, true)
            }
            PillContent::Transcribing => self.render("blue", "Transcribing", Some("esc"), false, false),
            // Amber and still: no pulsing, no meter, the mic is off.
            PillContent::Cancelled { hint } => self.render("amber", "Cancelled", Some(&hint), false, false),
            PillContent::Message { text, is_error } => {
                self.render(if is_error { "amber" } else { "blue" }, &text, None, false, false)
            }
        };
    }

    fn level(&mut self, level: f32) {
        let _ = self.window.eval(format!("window.holdtalk && window.holdtalk.level({level})"));
    }

    fn flash(&mut self, text: &str, is_error: bool) {
        let id = self.render(if is_error { "amber" } else { "blue" }, text, None, false, false);
        let pill = self.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_secs_f64(if is_error { 4.0 } else { 2.5 }));
            if pill.shown.load(Ordering::SeqCst) == id {
                let mut pill = pill;
                pill.hide();
            }
        });
    }

    fn hide(&mut self) {
        self.shown.fetch_add(1, Ordering::SeqCst);
        let _ = self.window.eval("window.holdtalk && window.holdtalk.hide()");
        let _ = self.window.hide();
    }
}

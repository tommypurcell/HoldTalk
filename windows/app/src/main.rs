//! HoldTalk for Windows: hold a key, speak, and the text is typed where your
//! cursor is. This file starts everything and runs the tray menu. The dictation
//! rules live in `holdtalk-core`, shared with the tests.

// No console window behind the app in release builds.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod mic;
mod pill;
mod platform;

use holdtalk_core::config::{executable, Config, EnvFile, Paths};
use holdtalk_core::controller::{Controller, Input, Notice, Parts, Pill};
use holdtalk_core::hotkey::Hotkey;
use holdtalk_core::pipeline::Pipeline;
use holdtalk_core::server::ServerHost;
use holdtalk_core::{model, transcribe, CancelFlag};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};
use tauri::menu::{CheckMenuItem, Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Manager, RunEvent};
use tauri_plugin_autostart::{MacosLauncher, ManagerExt};

/// Shared between the tray, the controller's notices and the model download.
struct App {
    paths: Paths,
    servers: Arc<ServerHost>,
    inbox: Mutex<Option<Sender<Input>>>,
    config: Mutex<Config>,
    keyboard: Mutex<Option<platform::Keyboard>>,
    pill: Mutex<Option<pill::TauriPill>>,
    enabled: AtomicBool,
    recording: AtomicBool,
    last_notice: Mutex<Option<String>>,
    /// Percent done while the speech model downloads.
    download: Mutex<Option<u32>>,
}

impl App {
    fn send(&self, input: Input) {
        if let Some(inbox) = self.inbox.lock().unwrap().as_ref() {
            let _ = inbox.send(input);
        }
    }

    fn set_notice(&self, notice: Option<String>) {
        *self.last_notice.lock().unwrap() = notice;
    }

    fn model_missing(&self) -> bool {
        let config = self.config.lock().unwrap();
        config.transcriber == "local" && !config.model_path(&self.paths).is_file()
    }
}

/// Reads the settings, writing a default file the first time so "Open
/// Settings File" has something to open.
fn load_config(paths: &Paths) -> Result<Config, String> {
    if !paths.config.exists() {
        let _ = std::fs::create_dir_all(&paths.folder);
        let text = serde_json::to_string_pretty(&Config::default()).unwrap_or_default();
        let _ = std::fs::write(&paths.config, text + "\n");
    }
    let text = std::fs::read_to_string(&paths.config).map_err(|e| format!("Couldn't read the settings: {e}"))?;
    Config::parse(&text).map_err(|e| e.0)
}

fn start_keyboard(app: &App, config: &Config) {
    let mut keyboard = app.keyboard.lock().unwrap();
    // The old hook goes first, so two never run at once.
    *keyboard = None;
    let Some(inbox) = app.inbox.lock().unwrap().clone() else { return };
    let started = Hotkey::parse(&config.hotkey).map_err(|e| e.0).and_then(|hotkey| platform::Keyboard::start(hotkey, inbox));
    match started {
        Ok(started) => *keyboard = Some(started),
        Err(message) => app.set_notice(Some(message)),
    }
}

fn hotkey_label(config: &Config) -> String {
    let words: Vec<String> = config
        .hotkey
        .split(|c| c == '_' || c == '+')
        .map(|word| {
            let mut chars = word.chars();
            chars.next().map(|c| c.to_uppercase().chain(chars).collect()).unwrap_or_default()
        })
        .collect();
    let joiner = if config.hotkey.contains('+') { "+" } else { " " };
    words.join(joiner)
}

fn build_menu(handle: &AppHandle) -> tauri::Result<Menu<tauri::Wry>> {
    let app = handle.state::<App>();
    let config = app.config.lock().unwrap().clone();
    let menu = Menu::new(handle)?;
    let enabled = app.enabled.load(Ordering::SeqCst);
    menu.append(&CheckMenuItem::with_id(handle, "toggle", "HoldTalk On", true, enabled, None::<&str>)?)?;
    let how = if config.transcriber == "local" { "local Whisper".to_string() } else { format!("{} Whisper", config.transcriber) };
    let summary = format!("Hold {} to talk · {how}", hotkey_label(&config));
    menu.append(&MenuItem::with_id(handle, "summary", summary, false, None::<&str>)?)?;
    if let Some(notice) = app.last_notice.lock().unwrap().clone() {
        let short: String = notice.chars().take(70).collect();
        menu.append(&MenuItem::with_id(handle, "notice", short, false, None::<&str>)?)?;
    }
    menu.append(&PredefinedMenuItem::separator(handle)?)?;
    match *app.download.lock().unwrap() {
        Some(percent) => {
            let text = format!("Downloading speech model… {percent}%");
            menu.append(&MenuItem::with_id(handle, "downloading", text, false, None::<&str>)?)?;
        }
        None if app.model_missing() => {
            menu.append(&MenuItem::with_id(handle, "download", "Download speech model", true, None::<&str>)?)?;
        }
        None => {}
    }
    let at_login = handle.autolaunch().is_enabled().unwrap_or(false);
    menu.append(&CheckMenuItem::with_id(handle, "login", "Launch at Login", true, at_login, None::<&str>)?)?;
    menu.append(&MenuItem::with_id(handle, "settings", "Open Settings File", true, None::<&str>)?)?;
    menu.append(&MenuItem::with_id(handle, "folder", "Open Settings Folder", true, None::<&str>)?)?;
    menu.append(&MenuItem::with_id(handle, "reload", "Reload Settings", true, None::<&str>)?)?;
    menu.append(&PredefinedMenuItem::separator(handle)?)?;
    menu.append(&MenuItem::with_id(handle, "quit", "Quit HoldTalk", true, None::<&str>)?)?;
    Ok(menu)
}

/// Rebuilds the tray menu, on the main thread where menus must be changed.
fn refresh_tray(handle: &AppHandle) {
    let inner = handle.clone();
    let _ = handle.run_on_main_thread(move || {
        let Some(tray) = inner.tray_by_id("main") else { return };
        if let Ok(menu) = build_menu(&inner) {
            let _ = tray.set_menu(Some(menu));
        }
        let recording = inner.state::<App>().recording.load(Ordering::SeqCst);
        let _ = tray.set_tooltip(Some(if recording { "HoldTalk: recording" } else { "HoldTalk" }));
    });
}

fn on_menu(handle: &AppHandle, id: &str) {
    let app = handle.state::<App>();
    match id {
        "toggle" => {
            let enabled = !app.enabled.load(Ordering::SeqCst);
            app.enabled.store(enabled, Ordering::SeqCst);
            app.send(Input::SetEnabled(enabled));
        }
        "download" => start_download(handle),
        "login" => {
            let autolaunch = handle.autolaunch();
            let result = if autolaunch.is_enabled().unwrap_or(false) { autolaunch.disable() } else { autolaunch.enable() };
            if let Err(error) = result {
                app.set_notice(Some(format!("Launch at login failed: {error}")));
            }
        }
        "settings" => platform::edit(&app.paths.config),
        "folder" => platform::open(&app.paths.folder),
        "reload" => reload(handle),
        "quit" => {
            app.send(Input::Quit);
            *app.keyboard.lock().unwrap() = None;
            app.servers.stop();
            handle.exit(0);
            return;
        }
        _ => {}
    }
    refresh_tray(handle);
}

/// Applies new settings. Anything running is cancelled first.
fn reload(handle: &AppHandle) {
    let app = handle.state::<App>();
    match load_config(&app.paths) {
        Ok(config) => {
            app.set_notice(None);
            *app.config.lock().unwrap() = config.clone();
            app.send(Input::Apply(Box::new(config.clone()), EnvFile::load(&app.paths.env)));
            start_keyboard(&app, &config);
        }
        Err(message) => app.set_notice(Some(message)),
    }
    refresh_tray(handle);
}

/// Fetches the speech model in the background, showing progress in the tray.
fn start_download(handle: &AppHandle) {
    let app = handle.state::<App>();
    let config = app.config.lock().unwrap().clone();
    {
        let mut download = app.download.lock().unwrap();
        if download.is_some() || !model::is_downloadable(&config.local_model) {
            return;
        }
        *download = Some(0);
    }
    let target = config.model_path(&app.paths);
    let handle = handle.clone();
    std::thread::spawn(move || {
        let app = handle.state::<App>();
        flash(&app, "Downloading the speech model. It's about 500 MB.", false);
        let mut shown = 0;
        let result = model::download(&config.local_model, &target, &CancelFlag::new(), |done| {
            let percent = (done * 100.0) as u32;
            if percent != shown {
                shown = percent;
                *app.download.lock().unwrap() = Some(percent);
                refresh_tray(&handle);
            }
        });
        *app.download.lock().unwrap() = None;
        match result {
            Ok(()) => {
                app.set_notice(None);
                flash(&app, &format!("Ready. Hold {} and speak", hotkey_label(&config)), false);
            }
            Err(error) => {
                app.set_notice(Some(error.to_string()));
                flash(&app, &error.to_string(), true);
            }
        }
        refresh_tray(&handle);
    });
}

fn flash(app: &App, text: &str, is_error: bool) {
    if let Some(pill) = app.pill.lock().unwrap().as_mut() {
        pill.flash(text, is_error);
    }
}

fn main() {
    let paths = Paths::standard();
    let (config, notice) = match load_config(&paths) {
        Ok(config) => (config, None),
        Err(message) => (Config::default(), Some(message)),
    };
    transcribe::remove_leftover_audio();

    let app = tauri::Builder::default()
        // Must come first: a second launch just exits.
        .plugin(tauri_plugin_single_instance::init(|_, _, _| {}))
        .plugin(tauri_plugin_autostart::init(MacosLauncher::LaunchAgent, None))
        .setup(move |tauri_app| {
            let handle = tauri_app.handle().clone();
            let whisper_folder = handle.path().resource_dir().ok().map(|dir| dir.join("whisper"));
            let servers = Arc::new(ServerHost::default());
            tauri_app.manage(App {
                paths: paths.clone(),
                servers: servers.clone(),
                inbox: Mutex::new(None),
                config: Mutex::new(config.clone()),
                keyboard: Mutex::new(None),
                pill: Mutex::new(None),
                enabled: AtomicBool::new(true),
                recording: AtomicBool::new(false),
                last_notice: Mutex::new(notice),
                download: Mutex::new(None),
            });

            let pill = pill::TauriPill::new(pill::create(&handle)?);
            *handle.state::<App>().pill.lock().unwrap() = Some(pill.clone());

            let env = EnvFile::load(&paths.env);
            let (pipeline_paths, pipeline_servers, pipeline_folder) = (paths.clone(), servers.clone(), whisper_folder.clone());
            let (warm_paths, warm_servers, warm_folder) = (paths.clone(), servers.clone(), whisper_folder.clone());
            let notify_handle = handle.clone();
            let (inbox, _) = Controller::spawn(config.clone(), env, move |inbox| Parts {
                recorder: Box::new(mic::MicRecorder::new(inbox)),
                inserter: Box::new(platform::Paster::new()),
                pill: Box::new(pill),
                make_pipeline: Box::new(move |config, env| {
                    Pipeline::make(config, env, &pipeline_paths, pipeline_folder.as_deref(), &pipeline_servers)
                }),
                warm_up: Box::new(move |config| {
                    if config.transcriber != "local" {
                        return;
                    }
                    let model = config.model_path(&warm_paths);
                    let Some(cli) = config.whisper_cli(warm_folder.as_deref()) else { return };
                    let server = cli.with_file_name(executable("whisper-server"));
                    if server.is_file() && model.is_file() {
                        let server = warm_servers.server(&server, &model);
                        std::thread::spawn(move || server.warm_up());
                    }
                }),
                notify: Box::new(move |notice| {
                    let app = notify_handle.state::<App>();
                    match notice {
                        Notice::Recording(on) => app.recording.store(on, Ordering::SeqCst),
                        Notice::Problem(message) => app.set_notice(Some(message)),
                    }
                    refresh_tray(&notify_handle);
                }),
            });
            *handle.state::<App>().inbox.lock().unwrap() = Some(inbox);
            start_keyboard(&handle.state::<App>(), &config);

            let menu = build_menu(&handle)?;
            TrayIconBuilder::with_id("main")
                .icon(handle.default_window_icon().cloned().expect("app icon"))
                .tooltip("HoldTalk")
                .menu(&menu)
                .show_menu_on_left_click(true)
                .on_menu_event(|handle, event| on_menu(handle, event.id().as_ref()))
                .build(&handle)?;

            // First run: fetch the default model without being asked, since
            // nothing works without it.
            if handle.state::<App>().model_missing() {
                start_download(&handle);
            } else {
                flash(&handle.state::<App>(), &format!("HoldTalk is on. Hold {} and speak", hotkey_label(&config)), false);
            }
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("HoldTalk couldn't start");

    app.run(|_, event| {
        // The pill is the only window and it's never closed by hand, so keep
        // running in the tray until Quit.
        if let RunEvent::ExitRequested { api, code, .. } = event {
            if code.is_none() {
                api.prevent_exit();
            }
        }
    });
}

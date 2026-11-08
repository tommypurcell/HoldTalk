//! Windows: the keyboard hook, sleep and lock watching, paste, and the pill's
//! no-focus window.

use holdtalk_core::controller::{Input, Inserted, Inserter, Signal};
use holdtalk_core::hotkey::{Hotkey, ModifierKey};
use std::cell::RefCell;
use std::collections::HashSet;
use std::ptr::{null, null_mut};
use std::sync::mpsc::{self, Sender};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};
use tauri::WebviewWindow;
use windows_sys::Win32::Foundation::{CloseHandle, HANDLE, HWND, LPARAM, LRESULT, WPARAM};
use windows_sys::Win32::Security::{GetTokenInformation, TokenElevation, TOKEN_ELEVATION, TOKEN_QUERY};
use windows_sys::Win32::System::DataExchange::{
    CloseClipboard, EmptyClipboard, EnumClipboardFormats, GetClipboardData, GetClipboardSequenceNumber, OpenClipboard,
    RegisterClipboardFormatW, SetClipboardData,
};
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::System::Memory::{GlobalAlloc, GlobalFree, GlobalLock, GlobalSize, GlobalUnlock, GMEM_MOVEABLE};
use windows_sys::Win32::System::RemoteDesktop::{
    WTSRegisterSessionNotification, WTSUnRegisterSessionNotification, NOTIFY_FOR_THIS_SESSION,
};
use windows_sys::Win32::System::Threading::{
    GetCurrentProcess, GetCurrentThreadId, OpenProcess, OpenProcessToken, PROCESS_QUERY_LIMITED_INFORMATION,
};
use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
    RegisterHotKey, SendInput, UnregisterHotKey, GetAsyncKeyState, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT,
    KEYEVENTF_KEYUP, MOD_ALT, MOD_CONTROL, MOD_NOREPEAT, MOD_SHIFT, MOD_WIN, VK_CONTROL, VK_ESCAPE, VK_LMENU, VK_LSHIFT,
    VK_LWIN, VK_RMENU, VK_RSHIFT, VK_RWIN,
};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    CallNextHookEx, CreateWindowExW, DefWindowProcW, DestroyWindow, DispatchMessageW, GetForegroundWindow,
    GetMessageW, GetWindowLongPtrW, GetWindowThreadProcessId, PostThreadMessageW, RegisterClassW, SetWindowLongPtrW,
    SetWindowPos, SetWindowsHookExW, ShowWindow, TranslateMessage, UnhookWindowsHookEx, GWL_EXSTYLE, HWND_TOPMOST,
    KBDLLHOOKSTRUCT, LLKHF_INJECTED, MSG, PBT_APMSUSPEND, SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOSIZE, SW_SHOWNOACTIVATE,
    WH_KEYBOARD_LL, WM_HOTKEY, WM_KEYDOWN, WM_POWERBROADCAST, WM_QUIT, WM_SYSKEYDOWN, WM_WTSSESSION_CHANGE, WNDCLASSW,
    WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW, WS_POPUP, WTS_SESSION_LOCK,
};

// MARK: - Keyboard

/// An unassigned key code. Sending it while Alt or Win is down tells Windows the
/// key was used, so letting go doesn't open the menu bar or the Start menu.
const MASK_KEY: u16 = 0xE8;

struct HookState {
    hotkey: Hotkey,
    inbox: Sender<Input>,
    modifier_down: bool,
    combo_down: bool,
    held: HashSet<u32>,
    escape_kept: bool,
}

thread_local! {
    /// The hook and window procedures run on the thread that installed them,
    /// so their state lives here.
    static STATE: RefCell<Option<HookState>> = const { RefCell::new(None) };
}

/// Watches the keyboard with a low-level hook.
///
/// The hook only reads key codes to spot the hotkey and Esc. It never stores
/// or logs what you type, and it passes every key on to your app, with two
/// exceptions explained in `on_key`. It has to answer quickly or Windows
/// removes it, so it only sends messages and never waits.
pub struct Keyboard {
    thread_id: u32,
    thread: Option<JoinHandle<()>>,
}

impl Keyboard {
    pub fn start(hotkey: Hotkey, inbox: Sender<Input>) -> Result<Keyboard, String> {
        let (ready, started) = mpsc::channel::<Result<u32, String>>();
        let thread = std::thread::Builder::new()
            .name("holdtalk-keyboard".into())
            .spawn(move || unsafe { run_keyboard_thread(hotkey, inbox, ready) })
            .map_err(|e| e.to_string())?;
        let thread_id = started.recv().map_err(|_| "The keyboard watcher didn't start.".to_string())??;
        Ok(Keyboard { thread_id, thread: Some(thread) })
    }
}

impl Drop for Keyboard {
    fn drop(&mut self) {
        unsafe {
            PostThreadMessageW(self.thread_id, WM_QUIT, 0, 0);
        }
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

unsafe fn run_keyboard_thread(hotkey: Hotkey, inbox: Sender<Input>, ready: Sender<Result<u32, String>>) {
    STATE.with(|state| {
        *state.borrow_mut() = Some(HookState {
            hotkey,
            inbox,
            modifier_down: false,
            combo_down: false,
            held: HashSet::new(),
            escape_kept: false,
        })
    });
    let module = GetModuleHandleW(null());
    let hook = SetWindowsHookExW(WH_KEYBOARD_LL, Some(hook_proc), module, 0);
    if hook.is_null() {
        let _ = ready.send(Err("Windows didn't allow HoldTalk to watch the keyboard.".into()));
        return;
    }
    // Combinations go through RegisterHotKey, which keeps them out of your app.
    // Its message only says "pressed", so the hook spots the release.
    let mut registered = false;
    if let Hotkey::Combo { key, modifiers } = hotkey {
        let mut flags = MOD_NOREPEAT;
        if modifiers.ctrl {
            flags |= MOD_CONTROL;
        }
        if modifiers.alt {
            flags |= MOD_ALT;
        }
        if modifiers.shift {
            flags |= MOD_SHIFT;
        }
        if modifiers.win {
            flags |= MOD_WIN;
        }
        if RegisterHotKey(null_mut(), 1, flags, key) == 0 {
            UnhookWindowsHookEx(hook);
            let _ = ready.send(Err("Another app already uses that hotkey. Pick a different one in the settings.".into()));
            return;
        }
        registered = true;
    }
    let watcher = create_watcher_window(module);
    if !watcher.is_null() {
        WTSRegisterSessionNotification(watcher, NOTIFY_FOR_THIS_SESSION);
    }
    let _ = ready.send(Ok(GetCurrentThreadId()));

    let mut message: MSG = std::mem::zeroed();
    while GetMessageW(&mut message, null_mut(), 0, 0) > 0 {
        if message.message == WM_HOTKEY && message.hwnd.is_null() {
            with_state(|state| {
                if !state.combo_down {
                    state.combo_down = true;
                    state.send(Signal::HotkeyDown);
                }
            });
            continue;
        }
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }

    if registered {
        UnregisterHotKey(null_mut(), 1);
    }
    if !watcher.is_null() {
        WTSUnRegisterSessionNotification(watcher);
        DestroyWindow(watcher);
    }
    UnhookWindowsHookEx(hook);
    STATE.with(|state| *state.borrow_mut() = None);
}

fn with_state(work: impl FnOnce(&mut HookState)) {
    STATE.with(|state| {
        if let Ok(mut state) = state.try_borrow_mut() {
            if let Some(state) = state.as_mut() {
                work(state);
            }
        }
    });
}

impl HookState {
    fn send(&self, signal: Signal) {
        let _ = self.inbox.send(Input::Key(signal, Instant::now()));
    }

    /// Returns true to keep the key from reaching apps.
    fn on_key(&mut self, info: &KBDLLHOOKSTRUCT, message: u32) -> bool {
        // Keys HoldTalk sends itself, such as Ctrl+V, are not the user's.
        if info.flags & LLKHF_INJECTED != 0 {
            return false;
        }
        let vk = info.vkCode;
        let down = message == WM_KEYDOWN || message == WM_SYSKEYDOWN;
        // Held keys repeat their key-down. Only the first one counts.
        let repeat = if down {
            !self.held.insert(vk)
        } else {
            self.held.remove(&vk);
            false
        };

        if vk == VK_ESCAPE as u32 {
            if down && !repeat {
                self.send(Signal::Escape);
                // Exception 1: Esc while the hotkey is held means cancel. Passed on,
                // it would become Ctrl+Esc (Start menu) or Alt+Esc (switch window).
                if self.modifier_down || self.combo_down {
                    self.escape_kept = true;
                    return true;
                }
            } else if !down && self.escape_kept {
                self.escape_kept = false;
                return true;
            }
            return false;
        }

        match self.hotkey {
            Hotkey::Modifier(key) => {
                if vk == key.virtual_key() {
                    if down && !self.modifier_down {
                        self.modifier_down = true;
                        self.send(Signal::HotkeyDown);
                    } else if !down && self.modifier_down {
                        self.modifier_down = false;
                        self.send(Signal::HotkeyUp);
                        if key.needs_tap_mask() {
                            // Exception 2: the release of Alt or Win is replaced by
                            // the mask key and then the release, so it doesn't open
                            // the menu bar or the Start menu.
                            release_with_mask(key);
                            return true;
                        }
                    }
                } else if down && !repeat && self.modifier_down {
                    self.send(Signal::OtherKey);
                }
            }
            Hotkey::Combo { key, .. } => {
                if !down && vk == key && self.combo_down {
                    self.combo_down = false;
                    self.send(Signal::HotkeyUp);
                }
            }
        }
        false
    }
}

unsafe extern "system" fn hook_proc(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code >= 0 {
        let info = &*(lparam as *const KBDLLHOOKSTRUCT);
        let mut keep = false;
        with_state(|state| keep = state.on_key(info, wparam as u32));
        if keep {
            return 1;
        }
    }
    CallNextHookEx(null_mut(), code, wparam, lparam)
}

fn release_with_mask(key: ModifierKey) {
    send_keys(&[(MASK_KEY, false), (MASK_KEY, true), (key.virtual_key() as u16, true)]);
}

/// A hidden window that hears about sleep and screen lock. Message-only windows
/// don't get those broadcasts, so this one is a real, never-shown window.
unsafe fn create_watcher_window(module: HANDLE) -> HWND {
    let class: Vec<u16> = "HoldTalkWatcher\0".encode_utf16().collect();
    let mut description: WNDCLASSW = std::mem::zeroed();
    description.lpfnWndProc = Some(watcher_proc);
    description.hInstance = module;
    description.lpszClassName = class.as_ptr();
    RegisterClassW(&description);
    CreateWindowExW(WS_EX_TOOLWINDOW, class.as_ptr(), class.as_ptr(), WS_POPUP, 0, 0, 0, 0, null_mut(), null_mut(), module, null())
}

unsafe extern "system" fn watcher_proc(window: HWND, message: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    // Don't leave the mic open behind a sleeping or locked PC.
    let sleeping = message == WM_POWERBROADCAST && wparam == PBT_APMSUSPEND as usize;
    let locking = message == WM_WTSSESSION_CHANGE && wparam == WTS_SESSION_LOCK as usize;
    if sleeping || locking {
        with_state(|state| {
            let _ = state.inbox.send(Input::ShutDown);
        });
    }
    DefWindowProcW(window, message, wparam, lparam)
}

// MARK: - Paste

fn key_input(vk: u16, up: bool) -> INPUT {
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT { wVk: vk, wScan: 0, dwFlags: if up { KEYEVENTF_KEYUP } else { 0 }, time: 0, dwExtraInfo: 0 },
        },
    }
}

/// Returns how many key events Windows accepted.
fn send_keys(keys: &[(u16, bool)]) -> u32 {
    let inputs: Vec<INPUT> = keys.iter().map(|(vk, up)| key_input(*vk, *up)).collect();
    unsafe { SendInput(inputs.len() as u32, inputs.as_ptr(), std::mem::size_of::<INPUT>() as i32) }
}

fn is_down(vk: u16) -> bool {
    unsafe { GetAsyncKeyState(vk as i32) < 0 }
}

/// Types the text into the focused app using the clipboard and Ctrl+V.
pub struct Paster;

impl Paster {
    pub fn new() -> Self {
        Paster
    }
}

impl Inserter for Paster {
    fn insert(&mut self, text: &str, restore_clipboard: bool) -> Inserted {
        let saved = if restore_clipboard { Clipboard::snapshot() } else { None };
        let Some(own_change) = Clipboard::put(text, restore_clipboard) else {
            return Inserted::CopiedOnly("Couldn't use the clipboard. Another app may be holding it.".into());
        };
        if foreground_is_elevated() && !process_is_elevated(unsafe { GetCurrentProcess() }).unwrap_or(false) {
            // Never restore here: the clipboard is the only copy of the text.
            return Inserted::CopiedOnly("Copied. Windows doesn't let HoldTalk paste into apps run as administrator".into());
        }

        // Shift, Alt or Win still held would turn Ctrl+V into another shortcut.
        let mut keys = Vec::new();
        let others = [VK_LSHIFT, VK_RSHIFT, VK_LMENU, VK_RMENU, VK_LWIN, VK_RWIN];
        let held: Vec<u16> = others.into_iter().filter(|vk| is_down(*vk)).collect();
        if held.iter().any(|vk| ![VK_LSHIFT, VK_RSHIFT].contains(vk)) {
            keys.extend([(MASK_KEY, false), (MASK_KEY, true)]);
        }
        keys.extend(held.iter().map(|vk| (*vk, true)));
        keys.extend([(VK_CONTROL, false), (b'V' as u16, false), (b'V' as u16, true), (VK_CONTROL, true)]);
        if send_keys(&keys) == 0 {
            return Inserted::CopiedOnly("Copied. Windows blocked the paste, so press Ctrl+V".into());
        }

        if let Some(saved) = saved {
            // Apps read the clipboard some time after Ctrl+V, so wait before swapping back.
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_millis(600));
                Clipboard::restore(saved, own_change);
            });
        }
        Inserted::Pasted
    }
}

struct Clipboard;

/// Everything on the clipboard, format by format, so it can be put back.
type Saved = Vec<(u32, Vec<u8>)>;

/// Formats that hold GDI handles instead of memory, which can't be copied as
/// bytes. Windows recreates most of them from the memory formats anyway.
fn is_handle_format(format: u32) -> bool {
    matches!(format, 2 | 3 | 9 | 14 | 0x80..=0x8F | 0x200..=0x3FF)
}

impl Clipboard {
    fn open() -> bool {
        for _ in 0..10 {
            if unsafe { OpenClipboard(null_mut()) } != 0 {
                return true;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        false
    }

    fn format(name: &str) -> u32 {
        let wide: Vec<u16> = name.encode_utf16().chain(Some(0)).collect();
        unsafe { RegisterClipboardFormatW(wide.as_ptr()) }
    }

    unsafe fn set(format: u32, bytes: &[u8]) {
        let memory = GlobalAlloc(GMEM_MOVEABLE, bytes.len().max(1));
        if memory.is_null() {
            return;
        }
        let pointer = GlobalLock(memory) as *mut u8;
        if pointer.is_null() {
            GlobalFree(memory);
            return;
        }
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), pointer, bytes.len());
        GlobalUnlock(memory);
        if SetClipboardData(format, memory).is_null() {
            GlobalFree(memory);
        }
    }

    /// Puts the text on the clipboard, kept out of Win+V history and the cloud
    /// clipboard. `will_restore` also asks clipboard managers to skip it. Returns
    /// the clipboard's change number afterwards.
    fn put(text: &str, will_restore: bool) -> Option<u32> {
        if !Self::open() {
            return None;
        }
        unsafe {
            EmptyClipboard();
            let wide: Vec<u8> = text.encode_utf16().chain(Some(0)).flat_map(u16::to_le_bytes).collect();
            const CF_UNICODETEXT: u32 = 13;
            Self::set(CF_UNICODETEXT, &wide);
            let no = 0u32.to_le_bytes();
            Self::set(Self::format("CanIncludeInClipboardHistory"), &no);
            Self::set(Self::format("CanUploadToCloudClipboard"), &no);
            if will_restore {
                Self::set(Self::format("ExcludeClipboardContentFromMonitorProcessing"), &no);
            }
            CloseClipboard();
            Some(GetClipboardSequenceNumber())
        }
    }

    fn snapshot() -> Option<Saved> {
        if !Self::open() {
            return None;
        }
        let mut saved = Vec::new();
        unsafe {
            let mut format = 0;
            loop {
                format = EnumClipboardFormats(format);
                if format == 0 {
                    break;
                }
                if is_handle_format(format) {
                    continue;
                }
                let memory = GetClipboardData(format);
                if memory.is_null() {
                    continue;
                }
                let size = GlobalSize(memory);
                let pointer = GlobalLock(memory) as *const u8;
                if pointer.is_null() {
                    continue;
                }
                saved.push((format, std::slice::from_raw_parts(pointer, size).to_vec()));
                GlobalUnlock(memory);
            }
            CloseClipboard();
        }
        Some(saved)
    }

    /// Does nothing if something new was copied in the meantime, because that's
    /// newer than what we saved.
    fn restore(saved: Saved, own_change: u32) {
        if unsafe { GetClipboardSequenceNumber() } != own_change || !Self::open() {
            return;
        }
        unsafe {
            EmptyClipboard();
            for (format, bytes) in &saved {
                Self::set(*format, bytes);
            }
            CloseClipboard();
        }
    }
}

/// True when the app you're typing in runs as administrator. Windows blocks
/// keys sent from normal apps to those, without saying so.
fn foreground_is_elevated() -> bool {
    unsafe {
        let window = GetForegroundWindow();
        if window.is_null() {
            return false;
        }
        let mut process_id = 0;
        GetWindowThreadProcessId(window, &mut process_id);
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, process_id);
        if process.is_null() {
            return false;
        }
        // An app we may not even look at is one running above us.
        let elevated = process_is_elevated(process).unwrap_or(true);
        CloseHandle(process);
        elevated
    }
}

fn process_is_elevated(process: HANDLE) -> Option<bool> {
    unsafe {
        let mut token: HANDLE = null_mut();
        if OpenProcessToken(process, TOKEN_QUERY, &mut token) == 0 {
            return None;
        }
        let mut elevation = TOKEN_ELEVATION { TokenIsElevated: 0 };
        let mut size = 0;
        let ok = GetTokenInformation(
            token,
            TokenElevation,
            &mut elevation as *mut _ as *mut core::ffi::c_void,
            std::mem::size_of::<TOKEN_ELEVATION>() as u32,
            &mut size,
        );
        CloseHandle(token);
        (ok != 0).then_some(elevation.TokenIsElevated != 0)
    }
}

// MARK: - Pill window

fn raw_window(window: &WebviewWindow) -> Option<HWND> {
    window.hwnd().ok().map(|hwnd| hwnd.0 as HWND)
}

/// Makes the pill a tool window that never takes focus, so showing it can't
/// pull the cursor out of the app you're typing in.
pub fn prepare_pill(window: &WebviewWindow) {
    let Some(hwnd) = raw_window(window) else { return };
    unsafe {
        let style = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
        SetWindowLongPtrW(hwnd, GWL_EXSTYLE, style | (WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW) as isize);
    }
}

pub fn show_without_focus(window: &WebviewWindow) {
    let Some(hwnd) = raw_window(window) else {
        let _ = window.show();
        return;
    };
    unsafe {
        ShowWindow(hwnd, SW_SHOWNOACTIVATE);
        SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    }
}

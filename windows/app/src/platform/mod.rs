//! The parts that talk to Windows itself: the keyboard hook, paste, and the
//! pill's no-focus window. Other systems get stand-ins, so the rest of the app
//! still builds and runs on a Mac for checking the pill and tray.

#[cfg(windows)]
mod windows;
#[cfg(windows)]
pub use self::windows::*;

#[cfg(not(windows))]
mod other;
#[cfg(not(windows))]
pub use self::other::*;

/// Opens a file or folder the way double-clicking it would.
pub fn open(path: &std::path::Path) {
    let mut command = if cfg!(windows) {
        let mut command = std::process::Command::new("explorer.exe");
        command.arg(path);
        command
    } else {
        let mut command = std::process::Command::new("open");
        command.arg(path);
        command
    };
    let _ = command.spawn();
}

/// Opens the settings file in Notepad, since .json files may have no app set.
pub fn edit(path: &std::path::Path) {
    if cfg!(windows) {
        let _ = std::process::Command::new("notepad.exe").arg(path).spawn();
    } else {
        let _ = std::process::Command::new("open").arg("-t").arg(path).spawn();
    }
}

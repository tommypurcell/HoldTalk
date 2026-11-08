# HoldTalk for Windows

The Windows version of HoldTalk: hold **Right Ctrl**, speak, let go, and the text
is typed where your cursor is. It works the same way as the Mac app: double-tap for
hands-free, Esc to cancel (press the hotkey within 5 seconds to undo), and a
5-minute limit. Speech is transcribed on your PC with
[whisper.cpp](https://github.com/ggml-org/whisper.cpp).

> **Early test build.** It isn't code-signed yet, so Windows SmartScreen will warn
> when you run the installer. Click **More info**, then **Run anyway**.

## Install

1. Download `HoldTalk_*_x64-setup.exe` from the newest
   [release](https://github.com/tommypurcell/HoldTalk/releases), which may be a pre-release.
2. Run it. No administrator access is needed.
3. HoldTalk starts in the tray (bottom right, beside the clock; you may have to
   click **^** to see it) and downloads the speech model, about 500 MB, the first time.
4. When the pill says it's ready, hold Right Ctrl and speak.

If nothing records, turn on **Settings > Privacy & security > Microphone > Let
desktop apps access your microphone**.

## Uninstall

Tray menu > **Quit HoldTalk**, then **Settings > Apps > Installed apps > HoldTalk > Uninstall**.
To also remove settings and the speech model, see [UNINSTALL.md](UNINSTALL.md).

## Settings

The tray menu has **Open Settings File**, which opens
`%APPDATA%\HoldTalk\config.json`. It uses the same keys as the Mac app (see
[docs/guide.md](../docs/guide.md)), with two differences:

- `hotkey` defaults to `right_ctrl`. You can also use `right_alt`, `right_shift`,
  `right_win` and the left versions, or a combination such as `ctrl+alt+space`.
  `fn` doesn't work, because Windows can't see that key.
- `whisperPath` points to `whisper-cli.exe` if you want your own build.

For cleanup, put API keys in `%APPDATA%\HoldTalk\.env`, as on the Mac. After
editing, choose **Reload Settings**.

## Known limits

- It can't paste into apps running as administrator. The text is left on the
  clipboard instead, and the pill says so.
- No code signing yet, so antivirus apps may also be wary of a keyboard hook.

## Develop

```
windows/
  core/   Dictation rules, settings, audio, transcription, cleanup. Builds and tests anywhere.
  app/    The Windows app: tray, pill, mic, keyboard hook and paste (Tauri).
```

```bash
cd windows
cargo test -p holdtalk-core   # runs on Mac too, with the real whisper-server if Homebrew's is installed
cargo run -p holdtalk         # on a Mac this shows the tray and pill, but the hotkey and paste are Windows-only
```

The installer is built by `.github/workflows/windows.yml`, which adds a pinned
whisper.cpp build and runs `cargo tauri build`.

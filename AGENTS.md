# Agent guide

HoldTalk is a dictation app: a macOS menu bar app written in Swift, plus a Windows version in `windows/`. Hold or
double-tap a hotkey, speak, and the text is pasted at the cursor. Follow this guide when changing the code. To install or use the app, see
[README.md](README.md) and [docs/guide.md](docs/guide.md).

## Commands

```bash
swift build
swift test                       # The Whisper and mic tests skip if those aren't available
scripts/build-app.sh             # Builds build/HoldTalk.app
scripts/build-app.sh --install   # Also copies it to ~/Applications
```

Whisper needs `brew install whisper-cpp` and `scripts/download-model.sh small`.

## Where things are

Everything is in `Sources/HoldTalkKit/`, except the small entry point in `Sources/HoldTalk/main.swift`.

| File | What it does |
| --- | --- |
| `DictationMachine.swift` | The rules for hold, double-tap and Esc, as a pure state machine with no audio or UI |
| `DictationController.swift` | Connects the keyboard, mic, transcription, pill and paste |
| `HotkeyMonitor.swift`, `Hotkey.swift` | Watches the hotkey and Esc, and parses hotkey settings |
| `Recorder.swift`, `Audio.swift` | Records the mic and converts it to 16 kHz mono |
| `Transcription.swift` | Runs `whisper-cli` or calls the Groq or OpenAI API |
| `Cleanup.swift`, `Pipeline.swift` | LLM cleanup, and the choice of providers |
| `TextInserter.swift`, `Clipboard.swift` | Pastes with Cmd-V and handles the clipboard |
| `Pill.swift`, `MenuBarApp.swift` | The floating pill and the menu bar |
| `Config.swift` | Reads `config.json` and `.env` |

## Windows

The Windows app is in `windows/` and is written in Rust with Tauri. `windows/core/` has the dictation rules,
settings, transcription and cleanup, and builds and tests on any OS. `windows/app/` has the tray, pill, mic,
keyboard hook and paste. See [windows/README.md](windows/README.md).

```bash
cd windows
cargo test -p holdtalk-core   # Works on a Mac too
cargo run -p holdtalk         # On a Mac the hotkey and paste do nothing
```

`windows/core/src/machine.rs` is a port of `DictationMachine.swift`, so change both together. The cleanup prompt
is copied from `Cleanup.swift`, and a test fails if the two drift apart. The installer is built by
`.github/workflows/windows.yml`. The rules below apply to both apps.

**Installing it on a Windows PC for someone**

1. Download the installer from the newest release, which may be a pre-release:
   `gh release download --repo tommypurcell/HoldTalk --pattern "*-setup.exe"`, or download
   `HoldTalk_*_x64-setup.exe` from https://github.com/tommypurcell/HoldTalk/releases.
2. Run it. It installs for the current user with no administrator access. SmartScreen warns because the
   build isn't signed yet, so the person has to click **More info** and then **Run anyway**.
3. HoldTalk starts in the tray and downloads the speech model (about 500 MB) to
   `%APPDATA%\HoldTalk\models`. The pill says when it's ready.
4. If recording fails, have the person turn on **Settings > Privacy & security > Microphone > Let desktop apps
   access your microphone**.
5. Ask the person to hold Right Ctrl, say a sentence and let go in Notepad. You can't test this yourself:
   keys you send are ignored by the hook, and a real voice is needed.
6. Settings are in `%APPDATA%\HoldTalk\config.json`, and API keys for cleanup are in
   `%APPDATA%\HoldTalk\.env`. After a change, choose **Reload Settings** in the tray menu. Never read, print
   or commit the `.env`.

## Rules

**Privacy**

- Add no accounts, telemetry, analytics or crash reporting.
- Never log or save transcripts, or keep audio after it's transcribed.
- Never let local mode fall back to the cloud.
- If a change sends new data off the Mac, say so in the pull request and update the table in `docs/guide.md`.

**Behavior**

- Esc must never paste, and must stop any running `whisper-cli`.
- The keyboard watcher stays listen-only, so Esc still reaches the user's app.
- Keep the recording limit in both modes.
- If cleanup fails, paste the raw transcript rather than losing it.

**Code**

- Put hotkey logic in `DictationMachine` and test it there.
- Add third-party packages only if the maintainer agrees. There are none today.
- Add new settings to `Config.swift` and to the table in `docs/guide.md`.

**Tests**

- Tests must never post real key events, because they would type into the user's apps.
- Never call a paid API from a test. Use the mock in `PipelineTests.swift`.

**Secrets**

- Never commit `.env`, API keys, model files or recordings.

## Pull requests

1. Work on a branch. `main` is protected, and only the maintainer merges.
2. Keep each change focused, and add a test if it changes behavior.
3. Run `swift test` and report the result.
4. Say what you ran in the real app and what you didn't. The live hotkey, paste and permission flows can't be covered by `swift test`, so ask a person to try them.

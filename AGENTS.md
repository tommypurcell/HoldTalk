# Agent guide

HoldTalk is a macOS menu bar dictation app written in Swift. Hold or double-tap a hotkey, speak, and the text is
pasted at the cursor. Follow this guide when changing the code. To install or use the app, see
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

The app's code is in `Sources/HoldTalkKit/`, grouped by what it does. `Sources/HoldTalk/main.swift` is only the entry point.

| Folder | Files | What they do |
| --- | --- | --- |
| `Dictation/` | `DictationMachine.swift` | The rules for hold, double-tap and Esc, as a pure state machine with no audio or UI |
| | `DictationController.swift` | Connects the keyboard, mic, transcription, pill and paste |
| `Hotkey/` | `HotkeyMonitor.swift`, `Hotkey.swift` | Watches the hotkey and Esc, and parses hotkey settings |
| `Audio/` | `Recorder.swift`, `Audio.swift` | Records the mic and converts it to 16 kHz mono |
| `Transcription/` | `Pipeline.swift` | Runs transcription and cleanup, and chooses the providers |
| | `Transcription.swift` | Runs `whisper-cli` or calls the Groq or OpenAI API |
| | `WhisperServer.swift` | Keeps `whisper-server` running while you dictate, and falls back to `whisper-cli` |
| | `Cleanup.swift` | LLM cleanup |
| `Paste/` | `TextInserter.swift`, `Clipboard.swift` | Pastes with Cmd-V and handles the clipboard |
| `Interface/` | `MenuBarApp.swift`, `Pill.swift` | The menu bar and the floating pill |
| `Settings/` | `Config.swift` | Reads `config.json` and `.env` |

Tests are in `Tests/HoldTalkKitTests/`, the app bundle's settings are in `Resources/`, build scripts are in `scripts/`, and user docs are in `docs/`.

## Rules

**Privacy**

- Add no accounts, telemetry, analytics or crash reporting.
- Never log or save transcripts, or keep audio after it's transcribed.
- Never let local mode fall back to the cloud.
- If a change sends new data off the Mac, say so in the pull request and update the table in `docs/guide.md`.

**Behavior**

- Esc must never paste, and must stop any running `whisper-cli` or `whisper-server` work.
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

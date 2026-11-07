# HoldTalk guide

## How the hotkey works

| Do this | What happens |
| --- | --- |
| Hold the hotkey | Records while held. Transcribes and pastes on release. |
| Double-tap the hotkey | Hands-free: records with nothing held. One more tap stops and pastes. |
| Press Esc | Pauses the recording with the mic off, and shows **press \<hotkey\> to undo** on the pill for 5 seconds. Press the hotkey again to keep the same recording (one more tap finishes it), or do nothing and the audio is deleted. Esc during transcription still kills it. Esc always reaches your app too. |
| Reach the limit | Recording stops and transcribes at 5 minutes, in either mode. |

A single quick tap is treated as an accident and thrown away.

## Permissions

Grant these in **System Settings → Privacy & Security**. The menu shows each one's status and links to its page.

| Permission | Why | Without it |
| --- | --- | --- |
| **Microphone** | Records your voice, only while dictating. | Nothing records. |
| **Input Monitoring** | Sees the hotkey and Esc. It's a listen-only watcher, so it can't block or change keys. It checks key codes and never stores what you type. | `fn` and other single-key hotkeys don't work. Combination hotkeys work, but Esc won't cancel. |
| **Accessibility** | Sends Cmd-V to paste. | Text is copied but not pasted, and the pill tells you. |

If a new grant doesn't take effect, quit and reopen HoldTalk.

macOS ties grants to the app's signature. `build-app.sh` signs with your Apple Development certificate if you
have one, so grants survive rebuilds. Without one it signs ad hoc, and you'll need to remove and re-add HoldTalk
in those lists after each rebuild.

HoldTalk only listens to `fn`, so it can't stop macOS from also opening the emoji picker or Apple Dictation on that
key. That's why **Press 🌐 key to** needs to be **Do Nothing**.

## Settings

Edit `~/.config/holdtalk/config.json`, which is created on first launch, then choose **Reload Settings** in the
menu. If the file has a mistake, the menu shows the error and the running settings stay in place.

| Setting | Default | Options |
| --- | --- | --- |
| `hotkey` | `"fn"` | `fn`, `right_option`, `left_option`, `right_command`, `left_command`, `right_control`, `left_control`, `right_shift`, `left_shift`, or a combination such as `"control+option+space"` |
| `transcriber` | `"local"` | `local`, `groq`, `openai` |
| `transcriberModel` | Provider's default | Groq: `whisper-large-v3-turbo`. OpenAI: `gpt-transcribe`. |
| `localModel` | `"small"` | `small`, `medium`, or a full path to a ggml model |
| `whisperPath` | Found automatically | Full path to `whisper-cli` |
| `language` | `"auto"` | `auto` or a code such as `en`. Setting it improves accuracy on very short clips. |
| `cleanupEnabled` | `true` | `false` pastes the raw transcript |
| `cleanupProvider` | `"auto"` | `auto` (first key found: Groq, Anthropic, OpenAI), `groq`, `anthropic`, `openai` |
| `cleanupModel` | Provider's default | Groq: `llama-3.3-70b-versatile`. Anthropic: `claude-haiku-5-5`. OpenAI: `gpt-5.6-luna`. |
| `casing` | `"sentence"` | `sentence`, `lowercase`, `preserve` |
| `cleanupTimeoutSeconds` | `8` | After this, the raw transcript is pasted |
| `restoreClipboard` | `false` | `false` leaves the transcript on the clipboard. `true` puts your previous clipboard back. |
| `maxRecordingSeconds` | `300` | Limit for both modes |
| `tapMaxMilliseconds` | `250` | A shorter press counts as a tap |
| `doubleTapWindowMilliseconds` | `350` | Time allowed for the second tap |

## API keys

Put keys in `~/.config/holdtalk/.env`, using the names in `.env.example`, then choose **Reload Settings**.

## What stays on your Mac

| Your setup | Audio | Text |
| --- | --- | --- |
| `local`, no API keys in `.env` | Stays on your Mac | Stays on your Mac |
| `local`, with an API key | Stays on your Mac | **Sent to the LLM provider for cleanup.** Set `cleanupEnabled` to `false` to stop this. |
| `groq` or `openai` | **Sent to that provider** | **Sent to the LLM provider** |

- A cloud transcriber falls back to local if it fails. Local never falls back to the cloud.
- Offline, cleanup fails and you get the raw transcript, including filler words.
- Audio is held in memory, then written to a private temp file only while being transcribed, and deleted afterwards.
- Transcripts aren't logged or saved. Web requests use an ephemeral session with no cache.

## Good to know

- **No text cursor:** HoldTalk doesn't check for one. It sends Cmd-V to the app in front, and if nothing takes the paste, the text stays on your clipboard. With `restoreClipboard` on, that text is lost after 0.6 seconds.
- **Sleep and lock:** recording or transcribing in progress is dropped when the Mac sleeps, locks or switches user.
- **Password fields:** while macOS Secure Input is on, HoldTalk may not see Esc, and a paste may be blocked.
- **Chords:** with a single-key hotkey, pressing another key within 1 second cancels, so fn+arrow doesn't start dictation.
- **While transcribing:** the hotkey is ignored until the current text is pasted, or until you press Esc.
- **After Esc:** the recording is paused, not gone: for 5 seconds the hotkey takes the undo, with everything said so far still in it. The mic is off during that window and the pill's dot is amber and still, so it's clear nothing is being captured. The 5-minute limit keeps running across the pause, so undoing can't buy extra recording time. The audio never touches disk; it's deleted the moment the window ends.
- **Start-up delay:** the mic takes a moment to open, so start speaking just after you press.
- **Odd output in silence:** Whisper can invent text for very quiet audio. HoldTalk drops silent audio and Whisper's markers, but background noise can still get through.

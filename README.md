> **AI agents:** read [AGENTS.md](AGENTS.md) first.

<div align="center">

```text
██╗  ██╗ ██████╗ ██╗     ██████╗ ████████╗ █████╗ ██╗     ██╗  ██╗
██║  ██║██╔═══██╗██║     ██╔══██╗╚══██╔══╝██╔══██╗██║     ██║ ██╔╝
███████║██║   ██║██║     ██║  ██║   ██║   ███████║██║     █████╔╝ 
██╔══██║██║   ██║██║     ██║  ██║   ██║   ██╔══██║██║     ██╔═██╗ 
██║  ██║╚██████╔╝███████╗██████╔╝   ██║   ██║  ██║███████╗██║  ██╗
╚═╝  ╚═╝ ╚═════╝ ╚══════╝╚═════╝    ╚═╝   ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝
```

**Hold a key. Speak. Let go.**

[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)
![Swift](https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white)
![Runs locally](https://img.shields.io/badge/runs-locally-brightgreen)
![No telemetry](https://img.shields.io/badge/telemetry-none-brightgreen)

</div>

# HoldTalk

Free, open-source dictation for your Mac. Hold a key, speak, and let go. The text appears at your cursor.
HoldTalk runs locally on whisper.cpp. It requires no account and sends no telemetry.

| Do this | What happens |
| --- | --- |
| Hold `fn` | Records while held, then pastes on release |
| Double-tap `fn` | Records hands-free. One more tap stops and pastes. |
| Press Esc | Cancels. Press `fn` within 5 seconds to undo. |

## Install

HoldTalk requires macOS 13 or later.

```bash
git clone https://github.com/tommypurcell/HoldTalk.git
cd HoldTalk
brew install whisper-cpp
scripts/download-model.sh small
scripts/build-app.sh --install
open ~/Applications/HoldTalk.app
```

Then:

1. Allow HoldTalk under **Microphone**, **Input Monitoring** and **Accessibility** in **System Settings → Privacy & Security**.
2. Set **Press 🌐 key to** **Do Nothing** in **System Settings → Keyboard**.

## Optional: clean up the text

Add a Groq, Anthropic or OpenAI key to remove filler words and fix punctuation. Without a key, you get the raw transcript. Gemini support is [coming soon](https://github.com/tommypurcell/HoldTalk/issues/6).

```bash
cp .env.example ~/.config/holdtalk/.env
chmod 600 ~/.config/holdtalk/.env
```

With a key, HoldTalk sends your text to that provider. Your audio stays on your Mac unless you choose a cloud transcriber.

## More

- [Guide](docs/guide.md): settings, changing the hotkey, privacy and troubleshooting
- [Contributing](CONTRIBUTING.md)

## Credits

Built with Claude Code from the Wispr Flow prompt on [Can I Vibecode It?](https://canivibecodeit.com/wispr-flow).
Transcription runs on [whisper.cpp](https://github.com/ggml-org/whisper.cpp) and OpenAI's Whisper models.

## License

[MIT](LICENSE)

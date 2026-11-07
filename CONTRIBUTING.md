# Contributing

Bug reports and pull requests are welcome. For a big change, open an issue first so we can agree on it.

## Set up

Follow the [install steps](README.md#install), then:

```bash
swift test               # The Whisper and mic tests skip if those aren't available
scripts/build-app.sh     # Builds build/HoldTalk.app without installing
```

## Send a pull request

1. Fork the repo and create a branch.
2. Make one focused change, and include unit tests for it.
3. Run `swift test`.
4. Open a pull request saying what changed, and what you tried in the real app.

`main` is protected, so all outside changes go through a pull request and need the maintainer's approval.

## Keep these true

HoldTalk has no accounts or telemetry, and local mode works offline. Changes need to keep it that way. See the
rules in [AGENTS.md](AGENTS.md), which apply to people too.

Using an AI agent? Point it at [AGENTS.md](AGENTS.md).

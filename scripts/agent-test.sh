#!/bin/bash
# Builds and runs the real app against test speech, for agents and people.
# It doesn't install anything, record the mic, press keys, or use API keys.
# Usage: agent-test.sh [--skip-tests]
# Exit codes: 0 passed, 1 failed, 2 setup problem. The report is build/agent-test-report.json.
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
report="$root/build/agent-test-report.json"
sentence="Please send the updated report to the team before the meeting tomorrow."
skip_tests=false
[ "${1:-}" = "--skip-tests" ] && skip_tests=true

fail_setup() { echo "SETUP PROBLEM: $1"; exit 2; }

echo "== 1. Setup"
[ "$(uname)" = "Darwin" ] || fail_setup "HoldTalk only runs on macOS."
command -v swift >/dev/null || fail_setup "Swift isn't installed. Run: xcode-select --install"
command -v say >/dev/null || fail_setup "The say command is missing."
echo "OK"

if [ "$skip_tests" = false ]; then
    echo "== 2. Unit tests"
    log="$(mktemp)"
    if swift test >"$log" 2>&1; then
        grep -E 'Executed [0-9]+ tests' "$log" | tail -1
        rm -f "$log"
    else
        grep -E 'error:|Test Case .*failed|Executed [0-9]+ tests' "$log" | tail -30
        rm -f "$log"
        echo "FAILED: unit tests"
        exit 1
    fi
else
    echo "== 2. Unit tests: skipped"
fi

echo "== 3. Build the app"
scripts/build-app.sh | tail -2 || { echo "FAILED: build"; exit 1; }
app="$root/build/HoldTalk.app"
codesign --verify "$app" || { echo "FAILED: the app's signature is invalid"; exit 1; }

echo "== 4. Run the real app on test speech"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
say -o "$work/speech.wav" --data-format=LEI16@16000 "$sentence" || fail_setup "Couldn't generate test speech."
rm -f "$report"
# open launches it as its own app, so the report shows this app's permissions, not the terminal's.
open -n "$app" --args --self-test --audio "$work/speech.wav" --expected "$sentence" --output "$report"
for _ in $(seq 1 240); do
    [ -s "$report" ] && break
    sleep 0.5
done
[ -s "$report" ] || { echo "FAILED: the app wrote no report within 120 seconds"; exit 1; }
sleep 0.2
cat "$report"
echo

echo "== 5. Result"
if [ "$(plutil -extract passed raw "$report")" = "true" ]; then
    echo "PASSED. Report: $report"
    echo "A person still needs to try: hold fn, double-tap fn, Esc, and pasting into another app."
    exit 0
fi
echo "FAILED. Report: $report"
exit 1

#!/bin/bash
# End-to-end test for the holdtalk command. It runs the real build, open and quit
# steps, but in a throwaway HOME so your ~/Applications and ~/.config stay untouched.
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
fake_home="$(mktemp -d)"
failures=0

cleanup() {
    pkill -x HoldTalk 2>/dev/null || true
    rm -rf "$fake_home"
}
trap cleanup EXIT

hold() { HOME="$fake_home" node "$root/bin/holdtalk.js" "$@"; }

check() {
    local name="$1"; shift
    if "$@"; then
        echo "PASS: $name"
    else
        echo "FAIL: $name"
        failures=$((failures + 1))
    fi
}

running() { pgrep -x HoldTalk >/dev/null; }
stopped() { ! running; }

check "status runs before install" hold status
check "app is not installed yet" test ! -d "$fake_home/Applications/HoldTalk.app"

check "start builds, installs and opens the app" hold start
check "app is installed into the fake home" test -d "$fake_home/Applications/HoldTalk.app"
sleep 3
check "app process is running" running

check "start again doesn't start a second copy" hold start
check "stop quits the app" hold stop
sleep 2
check "app process is gone after stop" stopped

# The npm package is what users run, so check the packed tarball too.
pack_dir="$fake_home/pack"
prefix_dir="$fake_home/prefix"
mkdir -p "$pack_dir" "$prefix_dir"
check "npm pack builds a tarball" bash -c "cd '$root' && npm pack --pack-destination '$pack_dir' >/dev/null 2>&1"
check "the tarball installs a holdtalk command" \
    npm install -g --prefix "$prefix_dir" "$pack_dir"/holdtalk-*.tgz
check "the installed command runs status" \
    env HOME="$fake_home" "$prefix_dir/bin/holdtalk" status

if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "All checks passed"

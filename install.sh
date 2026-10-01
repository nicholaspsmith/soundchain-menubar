#!/bin/bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Copyright (c) 2026 Nicholas Smith

# Build SoundChain.app and symlink it into ~/Applications (rebuilds propagate).
set -euo pipefail
cd "$(dirname "$0")"
scripts/build-app.sh
mkdir -p "$HOME/Applications"
# Re-arm the Menumon release hook (every push is a release) for this clone.
RELEASE_KIT="$(cd .. && pwd)/StatusItemKit/scripts/release/adopt.sh"
if [ -x "$RELEASE_KIT" ]; then
    "$RELEASE_KIT" --hooks-only || echo "Release hook: adopt.sh failed" >&2
else
    echo "Release hook: StatusItemKit not found beside this repo — clone it and re-run" >&2
fi
ln -sfn "$PWD/build/SoundChain.app" "$HOME/Applications/SoundChain.app"
echo "Installed ~/Applications/SoundChain.app -> $PWD/build/SoundChain.app"

# Ask to register Start at Login. SMAppService can only register the calling
# process's own bundle, so this runs the installed binary's headless --login.
BIN="$HOME/Applications/SoundChain.app/Contents/MacOS/SoundChain"
if [ "$("$BIN" --login status 2>/dev/null)" = "on" ]; then
    echo "Start at Login: already on"
elif [ -t 0 ]; then
    read -r -p "Start SoundChain at login? [Y/n] " answer
    case "$answer" in
        [nN]*) echo "Start at Login: left off (turn it on from the menu)" ;;
        *) if "$BIN" --login on >/dev/null; then
               echo "Start at Login: on"
           else
               echo "Start at Login: could not register (turn it on from the menu)" >&2
           fi ;;
    esac
else
    echo "Start at Login: off (not asked: no terminal). Turn it on from the menu, or run"
    echo "    $BIN --login on"
fi

# Quit a running copy so the rebuild takes effect, then launch.
if pgrep -xq SoundChain; then
    osascript -e 'tell application id "com.nicholaspsmith.SoundChain" to quit' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -xq SoundChain || break; sleep 0.5; done
    pkill -x SoundChain 2>/dev/null || true
fi
open "$HOME/Applications/SoundChain.app"
echo "SoundChain is running in the menu bar."

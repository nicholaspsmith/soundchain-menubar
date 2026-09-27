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
# Re-arm the Menubarn release hook (every push is a release) for this clone.
RELEASE_KIT="$(cd .. && pwd)/StatusItemKit/scripts/release/adopt.sh"
if [ -x "$RELEASE_KIT" ]; then
    "$RELEASE_KIT" --hooks-only || echo "Release hook: adopt.sh failed" >&2
else
    echo "Release hook: StatusItemKit not found beside this repo — clone it and re-run" >&2
fi
ln -sfn "$PWD/build/SoundChain.app" "$HOME/Applications/SoundChain.app"
echo "Installed ~/Applications/SoundChain.app -> $PWD/build/SoundChain.app"
echo "Start at Login: use the menu, or run"
echo "    ~/Applications/SoundChain.app/Contents/MacOS/SoundChain --login on"

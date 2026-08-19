#!/bin/bash
# Replace the copy in /Applications with the one just built, and reopen it.
#
# The waiting is the point. Pulling the bundle out from under a running copy leaves that
# process alive with no bundle on disk, and Sparkle answers by putting "the updater failed
# to start" on screen every time it is dismissed. So: ask it to quit, wait for the process
# to actually go, and only then replace anything.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
source="$root/build/Silicon Optimizer.app"
destination="/Applications/Silicon Optimizer.app"

[ -d "$source" ] || { echo "no build at $source — run Scripts/build-app.sh first" >&2; exit 1; }

if pgrep -x SiliconOptimizer > /dev/null; then
    echo "==> Quitting the running copy"
    osascript -e 'quit app "Silicon Optimizer"' 2>/dev/null || true
    for _ in $(seq 1 40); do
        pgrep -x SiliconOptimizer > /dev/null || break
        sleep 0.25
    done
    if pgrep -x SiliconOptimizer > /dev/null; then
        echo "it is still running after 10s — quit it by hand, then run this again" >&2
        exit 1
    fi
fi

echo "==> Installing"
rm -rf "$destination"
cp -R "$source" "$destination"
open "$destination"
echo "==> Running $destination"

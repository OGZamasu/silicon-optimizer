#!/bin/bash
# Compares the pinned ElevenLabs OpenAPI snapshot with the live spec and lists the operations
# added, removed and changed since it was pinned.
#
#   Scripts/check-elevenlabs-spec.sh                   # fetch https://api.elevenlabs.io/openapi.json
#   Scripts/check-elevenlabs-spec.sh --against FILE    # compare with a file instead (no network)
#
# The live spec is public: no key is sent, and the fetch goes only to api.elevenlabs.io over
# https. This is for the owner or the orchestrator; the test suite runs it only with --against.
#
# Exit status: 0 no drift, 3 drift (the list says what), anything else an error.
#
# To take a refresh: copy the new spec over Scripts/elevenlabs/openapi.json, run
# Scripts/elevenlabs-catalog.py, update the pinned SHA-256 in the catalog tests, and list every
# added operation in Sources/SiliconElevenLabs/ElevenLabsRiskTable.swift. Until it is listed,
# an added non-GET operation is treated as destructive.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PINNED="$ROOT/Scripts/elevenlabs/openapi.json"
AGAINST=""
LIVE_URL="https://api.elevenlabs.io/openapi.json"

while [ $# -gt 0 ]; do
    case "$1" in
        --against) AGAINST=${2:?--against needs a file}; shift 2 ;;
        --pinned) PINNED=${2:?--pinned needs a file}; shift 2 ;;
        -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$AGAINST" ]; then
    SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/elevenlabs-spec.XXXXXX")
    trap 'rm -rf "$SCRATCH"' EXIT
    curl --fail --silent --show-error --max-time 120 --proto '=https' --proto-redir '=https' \
        -o "$SCRATCH/openapi.json" "$LIVE_URL"
    AGAINST="$SCRATCH/openapi.json"
fi

echo "pinned sha256 $(shasum -a 256 "$PINNED" | cut -c1-64)"
echo "live   sha256 $(shasum -a 256 "$AGAINST" | cut -c1-64)"
status=0
python3 "$ROOT/Scripts/elevenlabs-catalog.py" diff "$PINNED" "$AGAINST" || status=$?
case $status in
    0) echo "no drift" ;;
    3) echo "drift: see the list above" ;;
esac
exit $status

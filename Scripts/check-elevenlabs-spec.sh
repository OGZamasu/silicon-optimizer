#!/bin/bash
# Compares the pinned ElevenLabs OpenAPI snapshot with the live spec and lists the operations
# added, removed and changed since it was pinned — and, for the WebSocket APIs the OpenAPI spec
# does not describe, compares the four pinned AsyncAPI documents with the ones in the docs.
#
#   Scripts/check-elevenlabs-spec.sh                   # fetch both (no key; https to elevenlabs hosts)
#   Scripts/check-elevenlabs-spec.sh --against FILE    # compare the OpenAPI with a file (no network;
#                                                      # the AsyncAPI check is skipped)
#   Scripts/check-elevenlabs-spec.sh --asyncapi-against DIR
#                                                      # compare the AsyncAPI with DIR/<name>.md or
#                                                      # .yaml (no network)
#   --only-asyncapi                                    # skip the OpenAPI part (with --against
#                                                      # alone it is refused: nothing local to
#                                                      # compare, and --against means no network)
#
# The live specs are public: no key is sent, and the fetches go only to api.elevenlabs.io and
# elevenlabs.io over https. This is for the owner or the orchestrator; the test suite runs it only
# against local files.
#
# Exit status: 0 no drift, 3 drift (the list says what), anything else an error.
#
# To take an OpenAPI refresh: copy the new spec over Scripts/elevenlabs/openapi.json, run
# Scripts/elevenlabs-catalog.py, update the pinned SHA-256 in the catalog tests, and list every
# added operation in Sources/SiliconElevenLabs/ElevenLabsRiskTable.swift. Until it is listed,
# an added non-GET operation is treated as destructive. To take an AsyncAPI refresh: run
# `Scripts/elevenlabs-asyncapi.py extract PAGE.md > Scripts/elevenlabs/asyncapi/<name>.yaml` and
# run the realtime tests, which hold the sockets' parameter and message names to those files.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PINNED="$ROOT/Scripts/elevenlabs/openapi.json"
ASYNCAPI_PINNED="$ROOT/Scripts/elevenlabs/asyncapi"
AGAINST=""
ASYNCAPI_AGAINST=""
ONLY_ASYNCAPI=0
LIVE_URL="https://api.elevenlabs.io/openapi.json"
# name → the docs page whose .md form embeds the socket's AsyncAPI YAML.
ASYNCAPI_PAGES=(
    "tts-stream-input https://elevenlabs.io/docs/api-reference/text-to-speech/v-1-text-to-speech-voice-id-stream-input.md"
    "tts-multi-stream-input https://elevenlabs.io/docs/api-reference/text-to-speech/v-1-text-to-speech-voice-id-multi-stream-input.md"
    "stt-realtime https://elevenlabs.io/docs/api-reference/speech-to-text/v-1-speech-to-text-realtime.md"
    "agents-conversation https://elevenlabs.io/docs/eleven-agents/api-reference/eleven-agents/websocket.md"
)

while [ $# -gt 0 ]; do
    case "$1" in
        --against) AGAINST=${2:?--against needs a file}; shift 2 ;;
        --pinned) PINNED=${2:?--pinned needs a file}; shift 2 ;;
        --asyncapi-against) ASYNCAPI_AGAINST=${2:?--asyncapi-against needs a folder}; shift 2 ;;
        --asyncapi-pinned) ASYNCAPI_PINNED=${2:?--asyncapi-pinned needs a folder}; shift 2 ;;
        --only-asyncapi) ONLY_ASYNCAPI=1; shift ;;
        -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

SCRATCH=""
scratch() {
    if [ -z "$SCRATCH" ]; then
        SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/elevenlabs-spec.XXXXXX")
        trap 'rm -rf "$SCRATCH"' EXIT
    fi
}

# The AsyncAPI check runs against a folder when one is given, live on a live run, and never next
# to a local OpenAPI comparison: --against means no network.
if [ "$ONLY_ASYNCAPI" = 1 ] && [ -n "$AGAINST" ] && [ -z "$ASYNCAPI_AGAINST" ]; then
    echo "--only-asyncapi with --against has nothing local to compare: add --asyncapi-against DIR (no network)," \
        "or drop --against for a live run" >&2
    exit 2
fi
RUN_ASYNCAPI=0
if [ -n "$ASYNCAPI_AGAINST" ] || [ -z "$AGAINST" ]; then
    RUN_ASYNCAPI=1
fi

status=0
if [ "$ONLY_ASYNCAPI" = 0 ]; then
    if [ -z "$AGAINST" ]; then
        scratch
        curl --fail --silent --show-error --max-time 120 --proto '=https' --proto-redir '=https' \
            -o "$SCRATCH/openapi.json" "$LIVE_URL"
        AGAINST="$SCRATCH/openapi.json"
    fi
    echo "pinned sha256 $(shasum -a 256 "$PINNED" | cut -c1-64)"
    echo "live   sha256 $(shasum -a 256 "$AGAINST" | cut -c1-64)"
    python3 "$ROOT/Scripts/elevenlabs-catalog.py" diff "$PINNED" "$AGAINST" || status=$?
    case $status in
        0) echo "no drift" ;;
        3) echo "drift: see the list above" ;;
        *) exit $status ;;
    esac
fi

if [ "$RUN_ASYNCAPI" = 1 ]; then
    for entry in "${ASYNCAPI_PAGES[@]}"; do
        name=${entry%% *}
        url=${entry#* }
        pinned="$ASYNCAPI_PINNED/$name.yaml"
        if [ -n "$ASYNCAPI_AGAINST" ]; then
            live="$ASYNCAPI_AGAINST/$name.yaml"
            [ -f "$live" ] || live="$ASYNCAPI_AGAINST/$name.md"
            [ -f "$live" ] || { echo "asyncapi $name: no $name.yaml or $name.md in $ASYNCAPI_AGAINST" >&2; exit 2; }
        else
            scratch
            live="$SCRATCH/$name.md"
            curl --fail --silent --show-error --max-time 120 --proto '=https' --proto-redir '=https' \
                -o "$live" "$url"
        fi
        echo "asyncapi $name"
        one=0
        python3 "$ROOT/Scripts/elevenlabs-asyncapi.py" diff "$pinned" "$live" || one=$?
        case $one in
            0) echo "asyncapi $name: no drift" ;;
            3) echo "asyncapi $name: drift, see above"; status=3 ;;
            *) exit $one ;;
        esac
    done
fi
exit $status

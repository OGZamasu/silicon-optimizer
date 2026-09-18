#!/bin/bash
# Fake-provider regression: hostile model IDs remain JSON data and bearer values never
# appear in curl's process arguments.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT HUP INT TERM
mkdir -p "$TMP_DIR/home"

FAKE_CURL="$TMP_DIR/curl"
cat > "$FAKE_CURL" <<'FAKE'
#!/bin/bash
set -euo pipefail

config=''
body=''
url=''
while [[ $# -gt 0 ]]; do
  [[ "$1" == *test-secret* ]] && { echo 'secret found in curl argv' >&2; exit 90; }
  case "$1" in
    --config) config="$2"; shift 2 ;;
    -d) body="$2"; shift 2 ;;
    -w|-X|-H|--max-time) shift 2 ;;
    -s) shift ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done

[[ -f "$config" ]] || { echo 'missing curl config' >&2; exit 91; }
mode="$(stat -f '%Lp' "$config" 2>/dev/null || stat -c '%a' "$config")"
[[ "$mode" == 600 ]] || { echo "curl config mode is $mode" >&2; exit 92; }
grep -Fq 'Authorization: Bearer test-secret' "$config" || exit 93

case "$url" in
  */models)
    python3 -c 'import json,os; print(json.dumps({"data": [{"id": os.environ["HOSTILE_MODEL"]}]}))'
    ;;
  */chat/completions)
    python3 -c 'import json,os,sys
body=json.loads(sys.argv[1])
assert body["model"] == os.environ["HOSTILE_MODEL"]
print(json.dumps({"choices": [{"message": {"content": "pong"}, "finish_reason": "stop"}]}))' "$body"
    ;;
  */requests)
    printf '{"request_id":"fixture-request"}\n200\n'
    ;;
  */requests/fixture-request)
    printf '{"status":"success","outcome":{"audio_url":"https://example.invalid/audio.mp3"}}\n'
    ;;
  *) echo "unexpected URL: $url" >&2; exit 94 ;;
esac
FAKE
chmod +x "$FAKE_CURL"

SENTINEL="$TMP_DIR/model-id-executed"
HOSTILE_MODEL="x'});__import__('pathlib').Path('${SENTINEL}').write_text('owned');#"
OUTPUT="$TMP_DIR/output"
if ! env -u OPENROUTER_API_KEY -u TOKENHARBOR_API_KEY -u AIHUBMIX_API_KEY \
  HOME="$TMP_DIR/home" SILICON_ENV_FILE="$TMP_DIR/no-env" CURL_BIN="$FAKE_CURL" \
  NVIDIA_API_KEY='test-secret' GMI_API_KEY='test-secret' HOSTILE_MODEL="$HOSTILE_MODEL" \
  "$ROOT/Scripts/verify-cloud.sh" > "$OUTPUT"; then
  cat "$OUTPUT" >&2
  echo 'cloud verifier rejected the fake provider' >&2
  exit 1
fi

[[ ! -e "$SENTINEL" ]] || { echo 'hostile model ID executed as Python' >&2; exit 1; }
grep -Fq 'NVIDIA: chat answered — pong' "$OUTPUT"
echo "Cloud verifier fake-provider checks passed."

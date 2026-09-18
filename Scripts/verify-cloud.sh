#!/usr/bin/env bash
#
# Exercises the bring-your-own-key providers against the real thing.
#
# The unit tests are hermetic — they pin the wire as the providers *document* it. This is the
# other half: proof that the documentation was right. Nothing here can run in CI, because it
# needs credentials, which is exactly why it exists as a script you run rather than a test
# that silently never runs.
#
# Keys are never printed, and only ever read. Easiest first:
#
#   cp .env.example .env      # then paste your keys into it
#   Scripts/verify-cloud.sh
#
# .env is gitignored. Putting a key there beats putting it on a command line, which lands it
# in your shell history and in the transcript of whatever tool ran the command.
#
# Three sources, in order: the environment, then .env at the repo root, then
# ~/.config/silicon-optimizer/<slug>.key — nvidia.key, open-router.key, gmi.key. The first
# one that has a value wins.
#
#   Keys: build.nvidia.com/settings/api-keys · openrouter.ai/keys · console.gmicloud.ai/apikeys
#         tokenharbor.ai/dashboard/api-keys · aihubmix.com/token
#
#   Scripts/verify-cloud.sh              # chat everywhere, plus GMI speech
#   Scripts/verify-cloud.sh --music      # …and a song, which takes 30–60s
#
# This spends real quota: one short completion per configured provider, one speech clip, and
# a song only if you ask for one.

set -uo pipefail

WITH_MUSIC=0
[[ "${1:-}" == "--music" ]] && WITH_MUSIC=1
CURL_BIN="${CURL_BIN:-curl}"
command -v "$CURL_BIN" >/dev/null || { echo "curl executable not found: $CURL_BIN" >&2; exit 1; }

# curl exposes literal -H arguments to every same-user process through the process list.
# Put bearer headers in owner-only config files instead and remove them on every exit path.
AUTH_DIR="$(mktemp -d)"
chmod 700 "$AUTH_DIR"
AUTH_SEQUENCE=0
cleanup() { rm -rf "$AUTH_DIR"; }
trap cleanup EXIT HUP INT TERM

make_auth_config() {       # bearer, output-variable
  local bearer="$1" output_var="$2" escaped path
  case "$bearer" in
    *$'\n'*|*$'\r'*) echo 'bearer token contains a newline' >&2; return 1 ;;
  esac
  AUTH_SEQUENCE=$((AUTH_SEQUENCE+1))
  path="$AUTH_DIR/auth-${AUTH_SEQUENCE}.conf"
  escaped="${bearer//\\/\\\\}"
  escaped="${escaped//\"/\\\"}"
  ( umask 077; printf 'header = "Authorization: Bearer %s"\n' "$escaped" > "$path" )
  chmod 600 "$path"
  printf -v "$output_var" '%s' "$path"
}

pass=0; fail=0; skip=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$((fail+1)); }
note() { printf '    %s\n' "$1"; }
none() { printf '  \033[33m–\033[0m %s\n' "$1"; skip=$((skip+1)); }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# Pulls a value out of a JSON body without shelling a key into an argument list.
jqp() { python3 -c "$1" 2>/dev/null; }

# .env, read rather than sourced. Sourcing would execute it, and a file whose whole job is to
# hold pasted secrets is the last thing to hand to the shell — one stray backtick in a pasted
# key and it runs. This pulls out a single KEY=VALUE line and nothing else.
#
# No associative array: macOS ships bash 3.2, which has none.
ENV_FILE="${SILICON_ENV_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.env}"

dotenv_get() {            # var-name
  [[ -r "$ENV_FILE" ]] || return 0
  # A leading # makes the line a comment and stops it matching at all. First value wins.
  sed -n "s/^[[:space:]]*${1}[[:space:]]*=[[:space:]]*//p" "$ENV_FILE" \
    | sed -e "s/^[\"']//" -e "s/[\"']$//" -e 's/[[:space:]]*$//' \
    | grep -v '^$' | head -n 1
}

# The environment wins, then .env, then ~/.config/silicon-optimizer/<slug>.key.
key_for() {               # env-var-name, slug
  local var="$1" slug="$2" value=""

  # Indirect expansion combined with a default is unreliable on bash 3.2, so the guard comes
  # off for exactly one line rather than the expression getting clever.
  set +u
  value="${!var}"
  set -u
  if [[ -n "$value" ]]; then printf '%s' "$value"; return; fi

  value="$(dotenv_get "$var")"
  if [[ -n "$value" ]]; then printf '%s' "$value"; return; fi

  local file="${HOME}/.config/silicon-optimizer/${slug}.key"
  # tr strips the newline an editor adds; a bearer containing one fails in a way that reads
  # exactly like a wrong key.
  [[ -r "$file" ]] && tr -d '\r\n' < "$file"
}

# --- chat ---------------------------------------------------------------------------------
#
# One function for all three: they are the same API. That is the whole premise of the chat
# half of this feature, so if this loop needs a special case, something is wrong.

verify_chat() {           # name, base, key, model-filter
  local name="$1" base="$2" key="$3" filter="$4"
  local auth_config
  make_auth_config "$key" auth_config || { bad "${name}: invalid bearer token"; return; }

  local models
  models=$("$CURL_BIN" -q --config "$auth_config" -s --max-time 30 "${base}/models")
  local count
  count=$(printf '%s' "$models" | jqp 'import json,sys; print(len(json.load(sys.stdin)["data"]))')
  if [[ -z "$count" ]]; then
    bad "${name}: GET /models did not return a list"
    note "$(printf '%s' "$models" | head -c 200)"
    return
  fi
  ok "${name}: ${count} models listed"

  # Prefer a model matching the filter, else the first one. Discovered, never assumed —
  # the same rule the app follows.
  local model
  model=$(printf '%s' "$models" | MODEL_FILTER="$filter" python3 -c '
import json,os,sys
d = json.load(sys.stdin)["data"]
m = [x["id"] for x in d if os.environ["MODEL_FILTER"].lower() in x["id"].lower()] or [x["id"] for x in d]
print(m[0] if m else "")' 2>/dev/null)
  if [[ -z "$model" ]]; then bad "${name}: no usable model id"; return; fi
  note "using ${model}"

  local body reply
  body=$(python3 -c 'import json,sys
print(json.dumps({"model": sys.argv[1],
                  "messages": [{"role": "user", "content": "Reply with exactly: pong"}],
                  "max_tokens": 512}))' "$model")
  reply=$("$CURL_BIN" -q --config "$auth_config" -s --max-time 120 -X POST "${base}/chat/completions" \
    -H 'Content-Type: application/json' -d "$body")

  # A reasoning model can answer with an empty `content` and its thinking somewhere else, so
  # "no content" is not the same as "no answer" and must not be reported as one.
  local verdict
  verdict=$(printf '%s' "$reply" | jqp "
import json,sys
d = json.load(sys.stdin)
c = (d.get('choices') or [{}])[0]
m = c.get('message') or {}
text = (m.get('content') or '').strip()
if text:
    print('ok|' + text[:60].replace(chr(10), ' '))
elif m.get('reasoning') or m.get('reasoning_content'):
    print('ok|(reasoned, empty content — finish_reason ' + str(c.get('finish_reason')) + ')')
elif c.get('finish_reason') == 'length':
    print('cut|budget spent before any content')
else:
    print('no|')")

  case "$verdict" in
    ok\|*)  ok "${name}: chat answered — ${verdict#ok|}" ;;
    cut\|*) bad "${name}: ${verdict#cut|}" ;;
    *)
      bad "${name}: chat returned no answer"
      note "$(printf '%s' "$reply" | head -c 300)"
      ;;
  esac
}

# --- GMI's audio queue --------------------------------------------------------------------
#
# The part the hermetic tests cannot prove. Payload shapes here were read out of GMI's docs
# and never sent anywhere: speech quotes its numerics and music does not, which is the kind
# of detail that is either right or embarrassing.

verify_audio() {          # label, model, payload-json, auth-config
  local label="$1" model="$2" payload="$3" auth_config="$4"
  local queue="https://console.gmicloud.ai/api/v1/ie/requestqueue/apikey/requests"

  local body submitted request_id
  body=$(python3 -c 'import json,sys
print(json.dumps({"model": sys.argv[1], "payload": json.loads(sys.argv[2])}))' "$model" "$payload")
  local status_code
  submitted=$("$CURL_BIN" -q --config "$auth_config" -s --max-time 60 -w '\n%{http_code}' -X POST "$queue" \
    -H 'Content-Type: application/json' -d "$body")
  status_code="${submitted##*$'\n'}"
  submitted="${submitted%$'\n'*}"

  request_id=$(printf '%s' "$submitted" | jqp 'import json,sys; print(json.load(sys.stdin).get("request_id",""))')
  if [[ -z "$request_id" ]]; then
    bad "${label}: submit rejected (HTTP ${status_code})"
    # An empty body says nothing; the status code at least says which wall was hit.
    note "$(printf '%s' "$submitted" | head -c 300)"
    return
  fi
  ok "${label}: accepted (${request_id})"

  # Terminal states are success / failed / cancelled — poll on anything else.
  local waited=0 status='' out=''
  while (( waited < 300 )); do
    out=$("$CURL_BIN" -q --config "$auth_config" -s --max-time 30 "${queue}/${request_id}")
    status=$(printf '%s' "$out" | jqp 'import json,sys; print(json.load(sys.stdin).get("status","").lower())')
    case "$status" in
      success|succeeded|failed|error|cancelled|canceled) break ;;
    esac
    sleep 5; waited=$((waited+5))
    printf '    …%s (%ss)\r' "${status:-waiting}" "$waited"
  done
  printf '\033[K'

  if [[ "$status" != "success" && "$status" != "succeeded" ]]; then
    bad "${label}: finished as '${status:-timed out}'"
    note "$(printf '%s' "$out" | head -c 300)"
    return
  fi

  # All three spellings, the way the app reads them.
  local url
  url=$(printf '%s' "$out" | jqp "
import json,sys
o = json.load(sys.stdin).get('outcome') or {}
found = [o['audio_url']] if isinstance(o.get('audio_url'), str) else []
for k in ('media_urls','medias'):
    for e in (o.get(k) or []):
        if isinstance(e, dict) and e.get('url'): found.append(e['url'])
print(found[0] if found else '')")
  if [[ -n "$url" ]]; then
    ok "${label}: audio returned"
    note "${url:0:90}"
  else
    bad "${label}: reported success but carried no audio URL"
    note "$(printf '%s' "$out" | head -c 300)"
  fi
}

# --- run ----------------------------------------------------------------------------------

NVIDIA_KEY=$(key_for NVIDIA_API_KEY nvidia)
OPENROUTER_KEY=$(key_for OPENROUTER_API_KEY open-router)
GMI_KEY=$(key_for GMI_API_KEY gmi)
TOKENHARBOR_KEY=$(key_for TOKENHARBOR_API_KEY token-harbor)
AIHUBMIX_KEY=$(key_for AIHUBMIX_API_KEY aihubmix)

section 'NVIDIA'
if [[ -n "$NVIDIA_KEY" ]]; then
  verify_chat 'NVIDIA' 'https://integrate.api.nvidia.com/v1' "$NVIDIA_KEY" 'nemotron'
else
  none 'no NVIDIA key — set NVIDIA_API_KEY in .env'
fi

section 'OpenRouter'
if [[ -n "$OPENROUTER_KEY" ]]; then
  verify_chat 'OpenRouter' 'https://openrouter.ai/api/v1' "$OPENROUTER_KEY" 'minimax'
else
  none 'no OpenRouter key — set OPENROUTER_API_KEY in .env'
fi

section 'Token Harbor'
if [[ -n "$TOKENHARBOR_KEY" ]]; then
  # Prefer a :free model, so the check costs nothing.
  verify_chat 'Token Harbor' 'https://tokenharbor.ai/v1' "$TOKENHARBOR_KEY" ':free'
else
  none 'no Token Harbor key — set TOKENHARBOR_API_KEY in .env'
fi

section 'AIHubMix'
if [[ -n "$AIHUBMIX_KEY" ]]; then
  verify_chat 'AIHubMix' 'https://aihubmix.com/v1' "$AIHUBMIX_KEY" '-free'
else
  none 'no AIHubMix key — set AIHUBMIX_API_KEY in .env'
fi

section 'GMI Cloud'
if [[ -n "$GMI_KEY" ]]; then
  GMI_AUTH_CONFIG=''
  make_auth_config "$GMI_KEY" GMI_AUTH_CONFIG || { bad 'GMI Cloud: invalid bearer token'; GMI_AUTH_CONFIG=''; }
fi
if [[ -n "${GMI_AUTH_CONFIG:-}" ]]; then
  verify_chat 'GMI Cloud' 'https://api.gmi-serving.com/v1' "$GMI_KEY" 'minimax'

  verify_audio 'speech' 'minimax-tts-speech-2.6-turbo' \
    '{"text": "The wire contract holds.", "voice_id": "English_expressive_narrator", "format": "mp3", "speed": "1"}' \
    "$GMI_AUTH_CONFIG"

  if (( WITH_MUSIC )); then
    verify_audio 'music' 'minimax-music-3.0' \
      '{"lyrics": "[verse]\\nSilicon hums in the dark\\n[chorus]\\nEverything runs where you are", "prompt": "warm lo-fi, mellow piano", "format": "mp3", "sample_rate": 44100}' \
      "$GMI_AUTH_CONFIG"
  else
    none 'music (pass --music; it takes 30-60s)'
  fi
else
  none 'no GMI key — set GMI_API_KEY in .env'
fi

printf '\n\033[1m%d passed, %d failed, %d skipped\033[0m\n' "$pass" "$fail" "$skip"
(( fail == 0 ))

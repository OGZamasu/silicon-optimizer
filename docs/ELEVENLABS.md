# ElevenLabs

Link an ElevenLabs API key in Settings and every operation of the ElevenLabs REST API is
available in the app and over MCP. This file describes how that is built, one section per part.

## Core: the catalog, the client and the key

Everything that talks to ElevenLabs lives in the `SiliconElevenLabs` target. It depends on
Foundation alone. Neither `SiliconControl` nor the MCP bridge links it: the control routes carry
raw JSON between HTTP and the app, so the MCP process never holds the key.

| File | What it holds |
|---|---|
| `ElevenLabsOperation.swift` | The operation, parameter, body, response-kind and risk types |
| `ElevenLabsCatalog.swift`, `Generated/ElevenLabsCatalogData.swift` | All 403 operations, loaded from the generated catalog |
| `ElevenLabsRiskTable.swift` | The reviewed risk class of every operation, the billable ones and the credential-returning ones |
| `ElevenLabsClient.swift`, `ElevenLabsRequestBuilder.swift`, `ElevenLabsWire.swift` | Checking arguments, building requests, decoding answers |
| `ElevenLabsClient+Helpers.swift` | Typed shortcuts for the operations the app uses most |
| `URLSessionTransport.swift` | The production transport |
| `ElevenLabsTesting.swift` | The fakes every test uses |
| `Sources/SiliconUI/AppModel+ElevenLabs.swift` | The Keychain key, Connect and Remove, the client the app shares, where outputs go |

### The catalog

The catalog comes from a pinned copy of ElevenLabs' OpenAPI spec, `Scripts/elevenlabs/openapi.json`
(SHA-256 `b3fe16f8d37a3b735df8514737e045b8d190f8618eb5c93f7caa7523feed80a0`). It holds 403
operations: 159 GET, 168 POST, 32 PATCH, 43 DELETE and 1 PUT. The running app never fetches
the spec.

`Scripts/elevenlabs-catalog.py` (standard library only) turns the spec into
`Sources/SiliconElevenLabs/Generated/ElevenLabsCatalogData.swift`. For each operation it keeps:

- the id, method and path;
- a display group, taken from the path first and the tag second (24 operations have no tag);
- the summary, and the description cut to 1,500 characters. The description is vendor text,
  so it is shown as data;
- the path, query and header parameters. `xi-api-key` is left out because the client adds it;
- the request body, JSON or multipart, with its file fields (including arrays of files);
- the kind of answer: JSON, audio, another binary, text, server-sent events or
  `multipart/mixed`;
- whether the operation streams. That is true for the `…/stream` paths and for anything the
  spec marks `x-fern-streaming`.

Schemas are resolved inline, five levels deep, with a cycle guard. A reference below that depth
keeps its name, type and enum, and is marked `x-truncated`. The explorer edits a value like that
as JSON.

The catalog is a Swift file, not a SwiftPM resource. `Scripts/build-app.sh` assembles the app
bundle without SwiftPM's resource bundles, so `Bundle.module` would find nothing in the
installed app. The file holds one JSON line per operation, so a refresh shows up as a readable
diff. It is parsed once, on first use.

To check for drift and refresh the catalog:

```bash
Scripts/check-elevenlabs-spec.sh                  # compare the pinned spec with the live one
Scripts/check-elevenlabs-spec.sh --against FILE   # compare with a file you already have
```

The check script downloads the public spec from `https://api.elevenlabs.io/openapi.json` without
sending a key. It lists the operations added, removed or changed (method, path, parameters,
body or responses). The test suite runs it only with `--against`. To take a new spec:

1. Copy the spec over `Scripts/elevenlabs/openapi.json`.
2. Run `Scripts/elevenlabs-catalog.py`. With `--check` it only reports whether the committed
   catalog is stale, and a test runs it that way.
3. Update the pinned SHA-256 in `CoreCatalogTests`.
4. List every added operation in `ElevenLabsRiskTable.swift`. Until an operation is listed,
   the client treats it as a read if it is a GET, as real-world if its path is in a real-world
   family, and as destructive otherwise.

### Risk, cost and credentials

Every operation has an explicit class in `ElevenLabsRiskTable.swift`:

| Class | Count | What it means | What it takes |
|---|---|---|---|
| `read` | 171 | Every GET. Also the POSTs that only compute or download (usage queries, cost estimates, summaries, RAG retrieval, similar-voice search, history and Studio snapshot downloads) | Nothing |
| `generate` | 52 | Billable creation: speech, dialogue, voice changer, sound effects, music, isolation, transcription, alignment, voice design, dubbing, Studio and Audio Native conversion, Flows, agent simulations and test runs | Nothing extra. The answer reports `character-cost` |
| `modify` | 90 | Edits to the owner's own resources that cost nothing by themselves | Nothing extra |
| `destructive` | 34 | Deletes, the knowledge-base bulk delete (a POST), and cancelling a knowledge-base crawl (it removes the documents the crawl made) | In the app, a confirmation. Over MCP or control, `confirm: true` and the owner's switch |
| `realWorld` | 56 | Reaches outside the account or changes who can get into it — including agent tools and environment variables, because a webhook tool points an agent at an outside URL with headers, as an MCP server does | Same as destructive |

The real-world families, by path: outbound calls and messages (`/v1/convai/twilio`, `exotel`,
`whatsapp`, `sip-trunk`), batch calling, phone numbers, WhatsApp accounts, secrets, MCP
servers, Agents Platform settings, workspace invites, members, groups, webhooks, auth
connections and resource sharing, service accounts and their API keys, and
`/v1/workspaces/api-keys`. The last one includes `disable`, which switches off the key that
sends it. Every non-GET inside a family is real-world, including its DELETEs and cancellations.
Every other DELETE is destructive. Three operations outside the families are real-world by
hand:

- `get_single_use_token`: it mints a key for client-side use;
- `replicate_voice_to_isolated_environment`: it copies a voice into a workspace in another
  data residency;
- `public_submit_order`: it submits a Productions order, which charges the workspace.

Tests hold the table to these rules and to the exact list of real-world operations.

Billable operations are every `generate` operation, plus the calls, the batch calls and a
submitted Productions order.

Eleven operations return a credential. They were found by walking every 2xx response schema in
the spec, and a test walks those schemas again:

| What | Operations |
|---|---|
| A new service-account key | `create_service_account_api_key` |
| A webhook signing secret | `create_workspace_webhook_route` |
| Single-use and LiveKit tokens | `get_single_use_token`, `get_livekit_token` |
| Conversation signed URLs and links | `get_conversation_signed_link`, `get_signed_url_deprecated`, `get_agent_link_route` |
| An agent's shareable token | `get_agent_route`, `patch_agent_settings_route`, `merge_preview_route`, `rebase_preview_route` |

`ElevenLabsRedaction.redactCredentials(in:for:)` replaces exactly those fields. It also always
removes the key preview in `GET /v1/user`, and any `sk_…` string. Signed download URLs for the
owner's own files (Studio assets, knowledge-base sources, Productions deliverables) are not
credentials to the account, so they are not listed. JSON answers keep 64-hex strings, because
ElevenLabs' public user and owner ids look like that. Error text loses those as well.

### The client

`ElevenLabsClient` is an actor. There is one per linked key and region, and it reaches every
catalog operation through `call(_:arguments:files:)`.

Arguments are one flat dictionary:

- path, query and header parameters by name;
- then the body's fields by name. A JSON body can also be given whole as `body`, unless the
  body has a field of that name;
- multipart files separately, by field name, as files on disk.

Before anything is sent, the client checks:

- required parameters and fields;
- the type, enum and const of each top-level value;
- unknown names;
- file fields, whether a field takes one file or several, and file sizes against the upload
  limit.

It reports every problem at once, as `ElevenLabsError.invalidArguments`. An invalid call sends
nothing and does not read the key. `validate` returns the same list without calling. `describe`
returns what would be sent, for Show API call, with the key shown as `‹redacted›`, and with the
secrets the owner typed masked too: a secret's value, provider tokens (Twilio, Exotel), SIP
passwords, and plain-string header values such as a literal `Authorization` (references to
secrets stay). Which request fields are masked is checked against every request schema in the
pinned spec, so a spec refresh that adds a secret-looking field fails a test until it is
classified. Answers get the same header rule: a tool, MCP server or webhook whose header holds a
literal token comes back with the token masked.

How a call goes out:

- Path segments are percent-encoded, so an id cannot climb into another route.
- A query array repeats its name (form style, exploded).
- JSON bodies are sent with sorted keys.
- Multipart bodies are written to a temporary file a megabyte at a time, streamed from there,
  and removed when the call ends.
- The key goes only in the `xi-api-key` header.
- Timeouts depend on the kind of call: 60 s for reads and edits, 10 min for generations, and
  30 min for uploads and dubbing.

What comes back:

| Answer | Result |
|---|---|
| JSON | `.json` (`.null` for a 204) |
| JSON with base64 audio inside (timestamps, voice design previews) | `.parts`: the JSON with each audio field replaced by `<field>_bytes`, then one file per clip |
| Audio, zip, video, CSV, PLS | `.file`. The body is downloaded to a temporary file and moved through the sink, never held whole in memory |
| HTML or plain text | `.text` |
| Server-sent events, or streamed JSON chunks (`…/stream/with-timestamps`, simulations) | Parsed as the body arrives. With audio: `.parts`, the audio joined into one file plus the events. Without audio: `.events` |
| `multipart/mixed` (music `compose_detailed`) | `.parts`: the JSON part, then the song as a file |

`stream(_:arguments:files:)` first yields `.started` with the status and the allowlisted headers
(request id, `character-cost`, rate-limit headers, song id and so on). Then it yields `.audio`,
`.event` or `.bytes` chunks as they arrive. Cancelling the consuming task cancels the request.

Errors:

- ElevenLabs' error shapes all become one `ElevenLabsError.api` with a status, a code and a
  message: `{"detail": "…"}`, `{"detail": {"status", "message"}}`, and FastAPI validation lists.
- A 401 on a residency region adds that the key may belong to another region.
- A redirect is an error that says it was not followed.
- The key, and anything shaped like one (`sk_…`, or a run of 32 or more hex digits), is
  redacted from every message.

At most as many requests run at once as the plan allows: free 2, starter 3, creator and up 5.
The client starts at 2 until it has read the account.

Retries:

- A read is retried after a 429, a 5xx or a lost connection, up to three times. `Retry-After`
  is honoured, with each wait capped at 20 s.
- A 429 on a non-billable edit is retried too, because a 429 means ElevenLabs refused the
  request before doing any work.
- A billable request is never sent twice. After a lost connection the first attempt may already
  have been billed.

The typed helpers in `ElevenLabsClient+Helpers.swift` wrap `call` for the operations the app uses
most: models, voices, text to speech (whole, with timestamps, streamed), sound effects, music and
music plans, speech to text, audio isolation, and history. Their argument labels are the spec's
own names.

### The transport

`URLSessionTransport` uses an ephemeral session:

- no cookie storage, no cache and no credential storage;
- no redirects. A 3xx is returned as the answer, so the key never follows a `Location`;
- the system's TLS evaluation, left untouched.

Before it opens a connection, it refuses any URL that is not https to one of the five
ElevenLabs hosts on the default port. The five hosts:

| Region | Host |
|---|---|
| Global (default) | `api.elevenlabs.io` |
| US only | `api.us.elevenlabs.io` |
| EU residency | `api.eu.residency.elevenlabs.io` |
| India residency | `api.in.residency.elevenlabs.io` |
| Singapore residency | `api.sg.residency.elevenlabs.io` |

"US only" uses the same account and key as the default. The residency regions are isolated
workspaces with keys of their own.

Bodies arrive through the session delegate as they come in. A download goes to disk, an inline
answer stops at its size limit, and a stream is forwarded chunk by chunk.

`loopbackForTesting(port:)` also allows plain http to one port on 127.0.0.1. The wire-level tests
use it and nothing else does. It is internal to the module and compiled into debug builds only.

### The key

The key is stored in the Keychain: service `dev.siliconoptimizer.credentials`, account
`elevenlabs-api-key`. It is never in Settings, files, logs, `/events`, error text, MCP output or
the repository.

`ElevenLabsCredential` reads the key on a GCD thread, never on the main actor or any other actor.
A freshly built app's first read waits on the Keychain's consent dialog, and an actor blocked
there would stall everything queued behind it. After the first read, the answer is kept for the
session. A locked Keychain is reported, and the Keychain is asked again the next time. There is
no "is a key stored?" query: Settings' `elevenLabsLinked` answers that.

Connect, `linkElevenLabs(key:region:)`, works like this:

1. It trims the key and holds it in memory only.
2. It verifies the key with the two free calls, `GET /v1/user` and `GET /v1/user/subscription`,
   against the chosen region's host.
3. Only if both succeed does it store the key, the region and the linked flag.

If ElevenLabs rejects the key, nothing is stored and any key already linked stays as it was. The
same is true when the network fails, and the error says what went wrong.

Remove, `unlinkElevenLabs()`, clears the linked flag, the client and the account at once. It then
deletes the key off the main actor.

At launch nothing is read. The client is built the first time it is used, without reading the
key. The account is verified the first time something calls `refreshElevenLabsAccount()`.

Outputs go to `<voice output folder>/ElevenLabs/<yyyy-MM-dd>/`, named after the operation and
never written over an existing file. Each one is registered with the media table (only for that
folder) and listed in `elevenLabsRecentOutputs`.

The owner's switch, "Let agents run destructive and real-world ElevenLabs actions", is
`elevenLabsAllowRiskyForAgents`. It is off by default.

### Tests

Every test is hermetic:

- The client tests use `FakeElevenLabsTransport`, `FakeCredentialSource` and
  `TemporaryFileSink`. `TemporaryFileSink` removes only the scratch directory it created.
- An `AppModel` built with injected settings holds an in-memory key store, a transport that
  refuses everything, a scratch output folder and an in-memory media table.
- The Keychain credential is tested through a fake `Access`.
- The wire tests talk to a loopback server on an ephemeral port.

No test reaches ElevenLabs, the Keychain, the owner's Music folder or Application Support.

`CoreConformanceTests` does this for all 403 operations:

1. It builds each one's arguments from its own schemas.
2. It sends each through the client to the in-memory transport.
3. It checks the method, path, query, headers and body against the raw spec, not the catalog,
   so a mistake in the generator shows up there too.

## Control API and MCP

Agents reach ElevenLabs through the app, never directly: the MCP bridge (`silicon-mcp`) talks only
to the app's control API on loopback, and the app holds the key. Everything below goes through one
handler in the app (`Sources/SiliconUI/AppModel+ElevenLabsControl.swift`), so the same rules apply
to a script with `curl` and to Claude or ChatGPT.

### Who may call it

Only this Mac's own control token, on the loopback listener. ElevenLabs spends the owner's credits
and some operations place real phone calls, so every other caller is refused with one sentence —
"ElevenLabs spends the owner's credits, so only this Mac's own control token can use it." — and
that includes a phone paired with **full** control, a chat-only phone, and swarm peers, on either
listener. The refusal is decided on the request's headers, before its body is read, and before
the app is asked anything. On loopback a phone's token is not a credential at all (401), and on the
tailnet the control token is not one either (401). A browser's `Host` or `Origin` on loopback is
refused too.

### Routes

| Route | What it answers |
|---|---|
| `GET /elevenlabs/status` | `linked`, `region`, `regionName`, `agentsMayRunRiskyActions`, `riskySwitch`, `operations`, the last `account` balance the app checked (never fetched by this route), and a `note` |
| `GET /elevenlabs/operations?q=&group=&risk=&limit=` | `total`, `returned`, `operations` (id, method, path, group, summary, risk, billable, returnsCredential, requiresConfirmation, deprecated, supportsStreaming, fileFields), and every `group` with its count. `q`: every word must appear in the id, path, method, summary or group. `limit`: 1–500, default 50. A bad filter is a 400 naming every problem |
| `GET /elevenlabs/operations/{id}` | Everything needed to call it: `parameters` (name, in, required, description, schema, default), `body` (contentType, required, schema, fileFields, multipleFileFields), `response` (kind and what the call returns), `risk` and `riskDescription`, `costNote`, `credentialNote`, `confirmationNote`, an `example` call with placeholders, and `vendorDescription` — ElevenLabs's own text, returned as data and labelled so. `elevenlabs_describe_operation` prints every piece of ElevenLabs's text — summary, description, parameter descriptions and schemas, the body schema with its field and enum descriptions — inside one fence whose boundary is random per call and whose every line starts with `│`, so no text in the spec can close it early. Unknown id: 404 with `closeMatches` |
| `POST /elevenlabs/call` | Runs one operation: `{"operation": id, "arguments": {…}, "files": [{"field", "path"}], "confirm": false}` |

Every refusal is `{"error": "…"}` — what every control client already reads — plus, where they
apply, `operation`, `risk`, `summary`, `setting`, `closeMatches`, `problems`, `upstreamStatus`,
`requestID`, `retryAfterSeconds`.

### What a call goes through, in order

1. **The request.** Every problem is named at once; unknown fields are refused (`argumnets` is an
   error, not a call without its arguments).
2. **The operation.** Unknown: 404 with close matches.
3. **The risk gate.** `read`, `generate` and `modify` run. `destructive` and `realWorld` run only
   with `confirm: true` **and** the owner's Settings switch **"Let agents run destructive and
   real-world ElevenLabs actions"** (Settings → ElevenLabs, off by default). Otherwise 403, naming
   the operation, its method and path, what it does, its class, the switch, and which of the two
   is missing. Nothing is read or sent.
4. **The link.** No key linked: 409 "ElevenLabs is not connected."
5. **Uploads.** Each `files` entry must name one of the operation's multipart file fields (one file
   where the schema takes one). Nothing under `/dev` is accepted, by any spelling that resolves
   there (`/dev/fd/N` would open a descriptor the app already holds). Each path is opened on the
   Mac without following a final symbolic link or waiting on a pipe, must be the same file the
   path named a moment before (device and inode), must be a regular file of this user's, and all
   of a call's uploads together must fit in 3 GiB (413 past it). It is copied through that same descriptor into a
   private folder — a clone where the volume allows — and the copy is what is sent, under the
   file's own name; the folder is removed when the call ends. Problems are named by position and
   field (`files[1] (audio)`), never by path, and no path ever appears in an answer.
6. **The call**, through the same client the pane uses.

Client errors become statuses a caller can act on: invalid arguments 400 with every problem;
ElevenLabs's 404/409/413 as they are and 422 as 400; a refused key, a permission error or an
ElevenLabs outage 502 with `upstreamStatus`; rate limits 429 with `retryAfterSeconds`; an unreadable
Keychain 503; a call cut short because its caller went away 499, saying ElevenLabs may have done
(and billed) the work anyway. Every message is redacted of anything key-shaped and of every upload
path. A value an earlier answer masked (`‹redacted›`) is refused if an agent sends it back.

### What a call answers

`operation`, `method`, `path`, `risk`, `status`, `requestID`, `characterCost` (when ElevenLabs sends
`character-cost`), the allowlisted `headers`, and for billable operations a `costNote` saying what
was spent and that the balance is one free call away (`get_user_subscription_info`). Then, by
`kind`:

- `json`: the answer in `json`.
- `file`: `file` (its path on this Mac, in `<voice output folder>/ElevenLabs/<date>/`),
  `contentType`, `bytes`. Streamed answers are collected into a file.
- `text`, `events`: inline.
- `parts`: `multipart/mixed` answers, and JSON whose base64 audio the client moved into files.

JSON, text and events past 256 KB come back shortened — lists cut to their first items and long
strings cut, by the gentlest step that fits — with `truncated: true`, a `note` saying what was cut,
and the whole answer saved as `fullResult` `{file, contentType, bytes}`.

**Redaction.** Always, whatever the switch: the key preview `GET /v1/user` carries, any `sk_…`
string, and every plain-string header value (a webhook tool's `request_headers`, custom headers)
are masked — the owner's own key typed into an agent's tool never reaches another agent. While the
owner's switch is off, the credential fields of the operations that return one (webhook secrets,
single-use tokens, signed conversation URLs, shareable agent tokens) are masked too, and so is any
string under a field whose name says it is a secret (`api_key`, `*token*`, `*secret*`, `signature`,
`password`, `signed_url` — but not a pagination cursor like `next_page_token`). Turning the switch
on reveals exactly those named credential fields of that one operation, and nothing else; a key
shaped like `sk_…` stays masked even there. A masked answer says so in `redacted` and
`redactionNote`; the saved `fullResult` is the masked answer too. The app's own pane shows
everything.

`confirm: true` is the agent's own statement that the user agreed; nothing can check it. The
owner's switch, off by default, is the real lock.

### MCP tools

| Tool | Operation | Cost |
|---|---|---|
| `elevenlabs_account` | `GET /elevenlabs/status`, then `get_user_subscription_info` when connected | free |
| `elevenlabs_list_voices` | `get_user_voices_v2` | free |
| `elevenlabs_speak` | `text_to_speech_full` | credits, per character |
| `elevenlabs_sound_effect` | `sound_generation` | credits |
| `elevenlabs_music` | `generate` (`POST /v1/music`) | credits |
| `elevenlabs_transcribe` | `speech_to_text` (`model_id` defaults to `scribe_v2`, the spec's example) | credits, per minute |
| `elevenlabs_isolate_audio` | `audio_isolation` | credits, per minute |
| `elevenlabs_change_voice` | `speech_to_speech_full` | credits, per minute |
| `elevenlabs_dub` | `create_dubbing` (then `get_dubbed_metadata`, `get_dubbed_file` through `elevenlabs_call`) | credits, per minute |
| `elevenlabs_clone_voice` | `add_voice` | a voice slot |
| `elevenlabs_design_voice` | `text_to_voice_design` (keep one with `create_voice`) | credits |
| `elevenlabs_search_operations` | `GET /elevenlabs/operations` | free |
| `elevenlabs_describe_operation` | `GET /elevenlabs/operations/{id}` | free |
| `elevenlabs_call` | `POST /elevenlabs/call`, any operation | per operation |

Argument names are the spec's, and so are their JSON types: `elevenlabs_change_voice`'s
`voice_settings` is JSON text because the spec's multipart field is a string (an object is encoded
into one). Upload arguments (`file`, `audio`, `files`) take absolute paths on this Mac. The bridge checks arguments before sending anything — types, the spec's ranges, whole
numbers without overflow, absolute paths, unknown arguments — and names every problem at once.
None of the curated tools maps to a gated operation; if one ever were refused by the gate, the tool
error says to use `elevenlabs_call` with `confirm: true` once the user agrees.

### From search to call

An agent asked to "list my dubbing projects and delete the test one" goes:

1. `elevenlabs_search_operations {"query": "dubbing"}` — the ids, each with its class:
   `list_dubs … [read]`, `delete_dubbing … [destructive; needs confirm]`.
2. `elevenlabs_describe_operation {"operation": "delete_dubbing"}` — its `dubbing_id` path
   parameter, that it is destructive, and the call to start from.
3. `elevenlabs_call {"operation": "list_dubs"}` — runs; it is a read.
4. `elevenlabs_call {"operation": "delete_dubbing", "arguments": {"dubbing_id": "…"}}` — refused:
   no `confirm`, and (by default) the switch is off. The agent asks the user; the owner turns the
   switch on in Settings → ElevenLabs if they want agents to do this at all.
5. `elevenlabs_call {"operation": "delete_dubbing", "arguments": {"dubbing_id": "…"}, "confirm": true}`.

The same over HTTP, from this Mac only:

```sh
T=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/Library/Application Support/SiliconOptimizer/control.json")))["token"])')
P=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/Library/Application Support/SiliconOptimizer/control.json")))["port"])')
curl -s -H "Authorization: Bearer $T" "http://127.0.0.1:$P/elevenlabs/operations?q=dubbing&limit=5"
curl -s -H "Authorization: Bearer $T" -H 'Content-Type: application/json' \
  -d '{"operation":"text_to_speech_full","arguments":{"voice_id":"<voice_id>","text":"Hello."}}' \
  "http://127.0.0.1:$P/elevenlabs/call"
```

### What is refused, and why

| Refused | Status | Why |
|---|---|---|
| Any caller but this Mac's control token on loopback — full-scope and chat phones, swarm peers | 403 (401 where the token is not a credential on that listener) | Credits and phone calls are the owner's decision at the Mac |
| A browser `Host`/`Origin` on loopback | 403 | A page that rebinds its name to 127.0.0.1 is still a page |
| `destructive` / `realWorld` without `confirm: true` and the switch | 403 | Deleting, calling, inviting, minting keys need the user's yes and the owner's leave |
| Nothing linked | 409 | |
| An upload that is not a regular file of this user's, anything under `/dev`, a relative path, an unknown file field | 400 | The Mac reads the owner's disk only for what the call is meant to send |
| Uploads over 3 GiB in all | 413 | |

### Tests

`Tests/SiliconTests/ElevenLabs/ElevenLabsControl*` and `Tests/SiliconMCPTests/ElevenLabsToolsTests.swift`,
all hermetic (the in-memory transport, a fake credential with a planted key, temporary folders):

- the caller policy: every caller class on both listeners on every route, the one sentence, and a
  phone or peer refused before its declared body arrives, with the app never asked;
- the routes and the envelope; the handler's status, search, describe, gate (five classes ×
  confirm × switch), order of checks, error mapping, redaction and a planted key; big answers;
  uploads (symlinks, folders, a pipe, `/dev/null`, caps, cleanup, scrubbed errors);
- the MCP tools' schemas, what they send, what they refuse, and how answers read;
- end to end — MCP tool, HTTP, the real server and policy, the handler, the real client, the
  in-memory transport — for **every one of the 403 operations** through `elevenlabs_call`, and
  `elevenlabs_describe_operation` returning the body schema of every operation that has one.

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
(SHA-256 `0b2f5145d7e6d04db439123076de5780da7402bc7e763ba49783c918323f942b`). It holds 403
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
| `modify` | 88 | Edits to the owner's own resources that cost nothing by themselves | Nothing extra |
| `destructive` | 34 | Deletes, the knowledge-base bulk delete (a POST), and cancelling a knowledge-base crawl (it removes the documents the crawl made) | In the app, a confirmation. Over MCP or control, `confirm: true` and the owner's switch |
| `realWorld` | 58 | Reaches outside the account or changes who can get into it — including agent tools, environment variables and speech engines, because a webhook tool or a speech engine points ElevenLabs at an outside URL with the owner's headers, as an MCP server does | Same as destructive |

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
ElevenLabs' public user and owner ids look like that. Text answers in the app keep them too
(`redactAnswerText`): they lose `sk_…` keys and a lone run of exactly 32 hex digits, the legacy key's
shape. Error text loses any run of 32 or more.

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
passwords, plain-string header values such as a literal `Authorization` (references to secrets
stay), and a phone transfer's post-dial digits and SIP UUI payload (a dynamic post-dial value
names a variable and stays). Which request fields are masked is checked against every request
schema in the pinned spec, so a spec refresh that adds a secret-looking field fails a test until
it is classified.

The URL is masked as well: the values of the credential query parameters (`token`,
`conversation_signature`, however the name is cased or percent-encoded), any `sk_…` key typed into
another value or a path, and any fragment. A URL that cannot be taken apart is shown without
anything after its path. The request itself keeps the real URL.

Answers get a header rule too: a tool, MCP server or webhook whose header holds a literal token
comes back with the token masked by default. That follows the owner's switch over MCP and the
control API (see below), and the app's own results keep header values real, because the owner's
editor writes them back. An `sk_…` key is masked everywhere, whatever the switch says.

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

## The pane, Settings and the Explorer

The app's side of ElevenLabs lives under `Sources/SiliconUI/ElevenLabs/`: `Shell/` holds the
pane, Settings, the shared parts every section builds with, and `Explorer/` the screen that
reaches every operation. Each curated section is one file in `Sections/`.

### Settings → ElevenLabs

Settings has an ElevenLabs pane of its own.

- **Connect** checks the key with the free account calls on the chosen region before anything is
  stored. A refused key stores nothing; a network failure leaves an already linked key linked. The
  text shown never contains the key, even one that does not look like one. The stored key is never
  read back into the field, and a half-typed key survives a trip to another Settings pane.
- **Region** lists every allowlisted host. Global and US only share one account and key. Each
  data-residency region (EU, India, Singapore) is a workspace with its own key, so switching to or
  from one while linked offers only "Remove key and enter a new one".
- **Let agents run destructive and real-world ElevenLabs actions** is off by default. It governs
  MCP and the control API only; the app itself always asks first.

### The pane

`AppModel.Tab.elevenLabs` is listed in the sidebar and the menu bar only while a key is linked.
Nothing selects it otherwise, whether a restored launch or a route that names it. Removing the key
while the pane is on screen moves the window to Settings.

The pane lists its places on the left: the curated sections in five groups, each with how many
operations it is built on, then the Explorer and this session's results. The search box filters
the places and lists matching operations one click from the Explorer. The header shows the plan,
the credits left, the reset date and the region, with Disconnect. Banners say when the key was
refused (with Reconnect), when ElevenLabs cannot be reached, or when the Keychain would not hand
the key over.

Which operations a section is built on is decided by spec path prefix, and the longest match
wins. Eleven operations belong to no section and are reached through the Explorer only: assets,
speech engines, the single-use token and `/docs`.

### The Explorer

All 403 operations are listed by group, with search and filters for risk, credit use and
deprecation. Each one gets a form built from its schema:

- path, query and header parameters
- typed editors for nested objects, lists, unions and choices
- file pickers for uploads, including several files at once
- a JSON editor per field, or for the whole body

Required fields are marked, and the problems the form or the client finds appear under the field
they name. **Run** asks first for destructive and real-world operations. Streaming operations can
play as they arrive or be collected. **Copy as curl** leaves the key to `$ELEVENLABS_API_KEY`.

Secrets are never typed in the clear:
- Password, token, client-secret and key fields are secure fields.
- Header maps take a name and a hidden value per row.
- "Show API call" and curl mask what was typed, because they come from the client's description.

Path fields take an id, not a path. A "/", "\", "." or ".." there, or a value that still holds the
`‹redacted›` mask from an answer, is named beside its field before anything is sent.

In the app's own results, header values stay real (the owner's editor writes them back). The
shown-once card lists only the credential fields the risk table names for that operation.

### What every section builds with

- **`ElevenLabsRunner`** runs one operation. It checks the arguments and asks for confirmation
  (naming what the section says it acts on). It runs or streams with Cancel, and keeps the result
  and the call it sent, without the key, for "Show API call". A secret in the answer is shown once
  and never kept. Every result except a secret goes to the session's recent list.
- **A runner does one run at a time.** A section's own busy guard is a second layer.
  - **Reads** are replaced: a run started while a read is in flight cancels the old one and
    starts clean, because restarting costs nothing.
  - **Anything else** (generate, modify, destructive, real world) is refused while a run is in
    flight or waiting for its confirmation. Nothing is sent, and `refusal` reads "A run is
    already in progress — cancel it first, and note it may already have been billed." The
    request in flight may already have been billed or acted on, and a second one would do it
    again.
  - **Cancel, then run again** is allowed for everything. Once a request that is not a read has
    gone to the client, `cancellationNote` says it "may already have been billed or
    performed".
  - A cancelled or replaced run never touches the next run's state, even when its request
    completes late. Each run and each Cancel takes a generation number, and only the current
    one may change what the runner shows.
  - **A failed run keeps ElevenLabs' HTTP status** (`ElevenLabsRunnerFailure.api(status:message:)`),
    and `provesNothingWasDone` says whether the failure proves nothing happened: never sent, or
    refused with a 401, 403, 429 or another 4xx. A 408, a 5xx, a lost answer and a cancel after
    sending do not, so a section that spends or reaches the outside world (voices & studio's
    spending holds, the agents' real-world send guard) asks the owner to check before the next
    try.
- **Views:** `ElevenLabsRunButton`, `ElevenLabsRunnerOutput`, `ElevenLabsResultView`,
  `ElevenLabsVoicePicker` (one voices list shared by every picker), `ElevenLabsCreditsHeader`,
  `ElevenLabsOperationForm` and `ElevenLabsSectionPage`.
- **Result views** show JSON as a tree, audio as a player with a scrubber, images and video as
  previews, and other files with Save… and Reveal in Finder.
- **Streamed audio** plays as it arrives. MP3 is decoded packet by packet and `pcm_<rate>`
  sample by sample, off the main thread, and the file is kept in the dated output folder.

### Tests and pictures

The shell's tests use the core's fakes only. They cover:

- a form for every one of the 403 operations, with its required fields marked (drawing every
  form is opt-in with `ELEVENLABS_DRAW=1`, like the snapshots)
- the runner's confirmation, cancel, error sorting and show-once secrets
- tab gating
- Connect and region changes
- the stream decoders, which open no audio device

`ElevenLabsSnapshot` draws views light and dark, narrow and wide. Set
`ELEVENLABS_SNAPSHOT_DIR` to a scratch folder outside the repository to get the PNGs.

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
Keychain 503; a call the app itself cancelled before it finished 499, saying ElevenLabs may have
done (and billed) the work anyway — a caller going away does not cancel one (below). Every message
is redacted of anything key-shaped and of every upload path. A value an earlier answer masked
(`‹redacted›`) is refused if an agent sends it back.

**Hanging up does not stop a call.** The control server watches for a caller going away only on
`/video/generate` and the agent conversation. A `POST /elevenlabs/call` whose caller hangs up — an
MCP client cancelling the tool call, or quitting — runs to its end in the app: ElevenLabs does the
work and bills it if it costs anything, and a file answer is saved under `ElevenLabs/<date>/` as
usual. Only the answer is lost, so check the history (or the resource) before asking again. The
paid curated tools and `elevenlabs_call` say so in their descriptions.

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

**Redaction.** Always, whatever the switch: the key preview `GET /v1/user` carries and any `sk_…`
string are masked — the owner's own key typed into an agent's tool never reaches another agent.
**A newly created API key is never shown over MCP or the control API, even with the switch on:
make it in the app.** While the owner's switch is off, the credential fields of the operations
that return one (webhook secrets, single-use tokens, signed conversation URLs, shareable agent
tokens), every plain-string header value (a webhook tool's `request_headers`, custom headers),
and any string under a field whose name says it is a secret (`api_key`, `*token*`, `*secret*`,
`signature`, `password`, `signed_url` — but not a pagination cursor like `next_page_token` or an
identifier like `secret_id`) are masked. Turning the switch on reveals exactly what it is for:
that one operation's named credential fields, and header values (so an agent allowed to edit a
tool can send its config back), where they are strings. A `password` or `client_secret` anywhere
else stays masked, including inside a named field that holds an object rather than a string. A
masked answer says so in `redacted` and `redactionNote`; the saved `fullResult` is the masked
answer too. The app's own pane shows everything.

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

## Realtime: live speech, live transcription and talking to agents

ElevenLabs' WebSocket APIs are not in the OpenAPI spec. They are built from the AsyncAPI documents
ElevenLabs publishes on its API-reference pages (pinned under `Scripts/elevenlabs/asyncapi/`) and
checked against the official SDKs. The protocol layer is `Sources/SiliconElevenLabs/Realtime/`
(Foundation only); the three live screens are `Sources/SiliconUI/ElevenLabs/Live/`.

### The four sockets

| Socket | Address | Auth | What it does |
|---|---|---|---|
| Speech, one context | `wss://<region>/v1/text-to-speech/{voice_id}/stream-input` | `xi-api-key` on the upgrade request | Text in (pieces ending in a space, `flush`, end with `""`), audio and character timings out |
| Speech, several contexts | `…/multi-stream-input` | the same | Up to five contexts on one socket, each named by `context_id` |
| Realtime transcription | `wss://<region>/v1/speech-to-text/realtime` | the same | Mono PCM (8–48 kHz) or 8 kHz μ-law in; partial and committed text, timings, entities, edits out |
| An agent conversation | `wss://<region>/v1/convai/conversation` | **never the key**: `?agent_id=` for a public agent, otherwise a signed URL minted with `get_conversation_signed_link` and used once | Initiation data, then audio and text both ways, tools, approvals |

`ElevenLabsRealtime(client:connector:)` opens each on the client's own region and credential
source. The production connector (`URLSessionWebSocketConnector`) opens only `wss` to the five
region hosts, puts headers on the upgrade request (the key never goes in a URL or a message),
raises `maximumMessageSize` to 16 MiB before the task starts, refuses a redirected upgrade, and
reads close codes by number (4300, the agent call-queue timeout, has no Foundation name). A signed
URL is opaque: it is checked (wss, a region host, the conversation path) and connected to as given;
it is never logged, shown, stored or returned over MCP. Request descriptions mask every query
value that is not a known setting. Tests use `FakeElevenLabsSocketConnector`, or for wire-level
checks a loopback WebSocket server behind a debug-only allowance.

Decoding is tolerant: both spellings of every key the sources disagree on (`isFinal`/`is_final`,
`contextId`/`context_id`, both alignment styles, `event_id` as a number or a string, `error` and
`client_error`), and anything unknown is surfaced as data, never fatal.

### Session policy

- One socket per session, and **nothing reconnects on its own**: a second connection is a second
  billed session and would replay audio. A socket that ends ends the session, with its code and
  reason; a new one is the owner's (or the caller's) choice.
- Every session keeps a usage record — characters sent, audio sent and received, messages,
  commits, duration — which the screens show as they go.
- An agent's `ping` is answered at once, ahead of queued audio. Audio of an interrupted answer is
  dropped (`event_id` at or below the interrupted one, as the Python and Node clients do; if `≤` is
  wrong, an interrupted agent's whole next answer is silent — see the live check, step 5). An MCP
  tool approval is answered at most once, only while ElevenLabs still waits, only an explicit
  approval approves, and ending the conversation sends a decline for every approval still waiting.
  A client tool call is answered at most once.

### The live screens

Three sections in the pane: **Live speech** (after Speech), **Live transcription** (after
Transcription) and **Talk to an agent** (after Agents; the Agents editor's "Talk to it live…"
opens it with that agent chosen). On all three:

- one session per screen: Start, Speak or Return pressed twice opens one; Return never starts a
  session (it only sends a typed message in a conversation already open); the settings — voice,
  model, agent — are the ones captured when it opened, and are locked while it is open;
- the microphone is off until Start, and a red indicator shows while it is on; Mute keeps sending
  silence (ElevenLabs closes a socket that hears nothing) so nothing said leaves the Mac — but the
  muted time is still billed (transcription by the audio's length, agents by the minute), and the
  indicator and the button's help say so;
- a session that drops, or is cancelled while it starts, says it may have been billed, and is
  not reconnected; leaving the screen ends it; a new key, another region or Disconnect ends it at
  once (the pane's reset, and the screen's own check of the client), and while a session is open
  Settings refuses a new key or region, as it does for a billable run;
- the three screens share one set of devices, and each session lets go of them only under its own
  claim: a stream's last audio playing out, a transcription waiting for its last text or a
  conversation waiting on its socket cannot stop the microphone, voice processing or the engine of a
  session started since on another screen; leaving Live speech while its last audio plays silences
  the rest and lets go then;
- every line shown is redacted of anything key-shaped.

Talk to an agent asks before starting an agent that can act on ElevenLabs' side — webhooks (named
with their host), transfers, keypad tones, MCP servers, workspace tools — naming each, because those
run without asking per call. Every MCP tool approval is a card naming the tool, its server and host,
and its parameters; it is answered for the conversation and tool call it was asked with, and
declined — the decline is sent — when it times out, when the conversation ends, or when the account
changes. The app runs no client tools: a client tool call is answered that nothing ran. Images and
PDFs can go with a typed message (uploaded to the conversation with `upload_file_route`; removing one
uses `cancel_file_upload_route`, which asks first). When the conversation ends its transcript is
saved to the output folder; ElevenLabs keeps it too (Conversations).

Live transcription's Stop commits what is left and waits for **the text of that commit** — the
last stretch was sent and billed, so it must reach the screen and the export. Committing by hand
(always for a file), every commit is answered by one committed transcript, in order, so Stop waits
for the answer to its own commit, the last one, and then 0.75 s of quiet (a duplicate answer, or
one sent unasked, cannot stand in for it) — not the first text after it, which can be the
late answer to an earlier commit. A file, and the microphone when committing by hand, commit as they
go: at the first quiet moment (the last 100 ms sent below about −34 dBFS) once 20 s of audio have
gone since the last commit, so a word is not cut where that can be helped, and at 28 s at the latest,
so a loud room still commits before ElevenLabs commits on its own (~36 s). The commit picker says so:
"When I press Stop, and every 20–28 s at a quiet moment". Committing at
pauses, ElevenLabs' own commits cannot be counted: Stop waits for the first text after its commit
and then for 0.75 s of quiet, so an automatic commit's text landing just before Stop's does not end
the wait. Either way the wait is 4 s at most; if it runs out with text still owed, the outcome says
"The last words may be missing — they were sent and billed".

### Audio

Microphone buffers (any rate, one or two channels) are converted to the socket's format —
16-bit little-endian mono PCM at its rate, or 8 kHz μ-law — in 100 ms chunks. The agent's audio
format is the one its `conversation_initiation_metadata` names. Playback decodes PCM, μ-law, A-law
and MP3, holds 150 ms in a jitter buffer, and an interruption silences it at once. **Echo:** the
WebSocket path has none of the acoustic echo cancellation a browser or WebRTC gives, so the agent
screen runs capture and playback on one `AVAudioEngine` with macOS voice processing on the input
(`setVoiceProcessingEnabled(true)`), the agent's voice being its echo reference. Without it, an agent
on the speakers hears itself and interrupts itself.

**Device changes:** plugging in headphones or switching the default microphone stops the engine
(`AVAudioEngineConfigurationChange`). A session holding the microphone (live transcription, a voice
conversation) is then **ended with a message**, not restarted: the new device needs its format and,
for an agent, voice processing set up again, and a session that silently switched microphones while
billing is worse than one more Start. Live speech only plays, and the next audio starts the engine
again on the new output.

**Bounds:** a session's events wait in a queue of at most 2,048; a reader that falls behind (or a
server that floods) ends the session with 1011 "This app fell behind reading the session". Microphone
audio waiting for a socket that has stopped taking it is capped at thirty seconds; then the session
ends — audio is never dropped from the middle, which would leave a hole in a transcript.

### Over MCP: `elevenlabs_agent_converse`

MCP is request/response, so the realtime APIs reach a model as one tool: a short **text-only**
conversation with one of the owner's agents.

| Tool | Route | Cost |
|---|---|---|
| `elevenlabs_agent_converse` | `POST /elevenlabs/agents/converse` `{agent_id, messages: [...], overrides?, dynamic_variables?, max_turns?, confirm}` | credits: ElevenLabs bills agent conversations by length and LLM use |

- It is **real-world**: an agent can run its server tools during the conversation. It needs
  `confirm: true` and the owner's switch ("Let agents run destructive and real-world ElevenLabs
  actions"); otherwise 403, and nothing is read or opened. Only this Mac's control token reaches it.
- The agent must allow text-only (or be text-only); otherwise 409 before anything opens.
- The app sends the messages one by one, waiting for each answer. MCP tool approvals are declined
  (the owner approves those in the app) and client tool calls are told nothing ran.
- **Limits, because the conversation bills by length:** at most 20 messages; 90 s for each answer;
  **300 s for the whole conversation**, after which the app ends it and the answer says
  `"ended": "time limit"`; and **one conversation at a time** — a second call while one runs is
  refused (409) before anything is read or opened. Only what the agent says or does keeps a turn
  open; pings, VAD scores and context-usage events do not. **A caller that hangs up ends the
  conversation:** the control server keeps a read pending on the request's connection (as for
  `/video/generate`), and its closing cancels the route, which ends the conversation at once. A
  caller that keeps its connection open and stops reading is bounded by the 300 s cap, and holds
  the one-at-a-time lane until then — do not retry into it. An MCP client that cancels the call
  (`notifications/cancelled`) or quits hangs up this way: the bridge closes the call's request, so
  the conversation ends at once, and answers nothing for it.
- The answer: the transcript, the tools used (server tools marked "ran on ElevenLabs' side"; client
  and MCP tools with their parameters, masked), errors, how it ended, the duration and a cost note —
  never a signed URL, a token or anything key-shaped. The bridge prints the agent's words inside a
  fence with a random boundary, quoted as data.
- Streaming speech and live transcription are not MCP tools: the REST operations already serve them
  (`elevenlabs_speak`, `elevenlabs_transcribe`, and `text_to_speech_stream` through `elevenlabs_call`).

### Spec snapshots and drift

`Scripts/elevenlabs/asyncapi/{tts-stream-input,tts-multi-stream-input,stt-realtime,agents-conversation}.yaml`
are the AsyncAPI blocks of the four reference pages. `Scripts/check-elevenlabs-spec.sh` compares them
with the live pages on a live run (`--only-asyncapi` for just these, `--asyncapi-against DIR` for local
files); `Scripts/elevenlabs-asyncapi.py` extracts, outlines and diffs them without a YAML library.
Tests hold the sessions to the pins: every query parameter sent is one the spec names for its socket,
the transcription formats are the spec's list, and every message type the specs name is decoded or
sent.

### Tests

All hermetic: `Realtime*` (sessions on the fake socket; the production socket against a loopback
server — the key in the upgrade header only, a 3 MiB message, close codes 1000/1008/1011/4300,
refused and redirected upgrades, cancellation; the drift diff on local files; the converse route and
its gate), `Live*` (the audio pipeline on synthetic buffers; the three screens' models on the fake
socket, transport and devices; opt-in drawings), and the MCP tool. No test opens a socket to
ElevenLabs, touches the microphone or speakers, or reads the Keychain.

### The owner's live check (once, with the real key)

What only a real account can settle, cheapest first. Note the credit balance (Settings → ElevenLabs,
or the ElevenLabs dashboard) before step 1 and after the last step you run.

1. **Live speech** — *costs about 30 characters of text-to-speech.* Choose a voice, type "Hello from
   the live stream." and press Speak. It should play within a second or two, show the words with
   timings, and end cleanly (Finish). *Settles:* the header auth and spellings on the speech socket,
   the PCM format, and whether ElevenLabs closes an idle socket with 1000.
2. **Live transcription** — *costs about 10 seconds of realtime speech-to-text.* Start listening, say
   a sentence for about ten seconds, press Stop. Partial text should turn into a committed line; with
   Word timings on, times appear. *Settles:* the transcription socket's header auth, chunking, commit
   and the `warning`/error shapes. **Watch for:** the menu-bar microphone indicator (the orange dot)
   goes out within a second of Stop; the last words you said are on screen; and Stop pressed after a
   pause (nothing left to commit) does not say "The last words may be missing" — if it does,
   ElevenLabs sends nothing for an empty commit, and the app should not wait for one.
3. **Talk to an agent, text only** — *costs about a minute of agent time plus the agent's LLM use.*
   With a public test agent that allows text-only (or is text-only), start a text conversation, send
   one message, read the answer, End. *Settles:* bare `agent_id` for a public agent, the initiation and
   metadata, `error` vs `client_error`, the ping cadence. **Watch for:** the agent's Conversations
   (Agents → the agent → Conversations, or the ElevenLabs dashboard) shows **exactly one** new
   conversation, ended. Note how it records the End — "ended" or "disconnected"/"failed": the app
   always asks to close with 1000, but under load macOS can drop the connection without sending
   that close frame, and ElevenLabs then sees a disconnect (the conversation still ends and stops
   billing). Then start one more and press Cancel while it says Connecting: Conversations should
   still show only that one more at most, ended — never one left running.
4. **The MCP tool** — *costs about the same as step 3: a minute of agent time plus LLM.* With the
   switch on, call `elevenlabs_agent_converse` with that agent, one message and `confirm: true`. The
   answer should carry the transcript, `"ended"` and a `duration_seconds` of a few seconds; Conversations
   should show exactly one more. *Settles:* the same socket from the control route.
5. Optional, **voice** — *costs a few minutes of a voice agent plus LLM.* Talk to the agent through
   the speakers, and talk over it once while it answers. *Settles:* echo cancellation, a signed URL for
   an agent with authentication on, and **the interruption rule**. ElevenLabs gives every audio chunk
   of one answer the same `event_id`, and the app drops audio at or below the interrupted `event_id`
   (`ElevenLabsAgentConversation.dropsAudioAtTheInterruptedEvent = true`, as the Python and Node
   clients do; the browser client drops only below it). If that is wrong for this API, the symptom is
   unmistakable: after you talk over the agent, **its whole next answer is silent — its text appears
   but no voice plays**, not merely a clipped first word. To flip it, set
   `dropsAudioAtTheInterruptedEvent` to `false` in
   `Sources/SiliconElevenLabs/Realtime/ElevenLabsAgentConversation.swift` and turn round the
   expectations of `RealtimeSessionTests.audioOfAnInterruptedResponseIsDropped` (with `<`, the
   interrupted chunk is dropped only below its id). **Watch for:** the conversation must **not end
   within a second of Start with "The audio device changed"** — that would be voice processing's
   own reconfiguration taken for a device change (plugging headphones in mid-conversation should
   end it with that message; nothing else should). After End, the microphone indicator goes out and
   music in other apps is no longer quieter (voice processing is off). Then play a long Live speech
   text, press Finish and, while it is still playing, go to Live transcription and Start: leaving
   Live speech silences the rest of its audio, and the transcription keeps the microphone (the
   indicator stays on) and keeps transcribing.

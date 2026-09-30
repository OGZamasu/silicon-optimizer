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
- **Views:** `ElevenLabsRunButton`, `ElevenLabsRunnerOutput`, `ElevenLabsResultView`,
  `ElevenLabsVoicePicker` (one voices list shared by every picker), `ElevenLabsCreditsHeader`,
  `ElevenLabsOperationForm` and `ElevenLabsSectionPage`.
- **Result views** show JSON as a tree, audio as a player with a scrubber, images and video as
  previews, and other files with Save… and Reveal in Finder.
- **Streamed audio** plays as it arrives. MP3 is decoded packet by packet and `pcm_<rate>`
  sample by sample, off the main thread, and the file is kept in the dated output folder.

### Tests and pictures

The shell's tests use the core's fakes only. They cover:

- a form for every one of the 403 operations, with its required fields marked, and every form
  drawing
- the runner's confirmation, cancel, error sorting and show-once secrets
- tab gating
- Connect and region changes
- the stream decoders, which open no audio device

`ElevenLabsSnapshot` draws views light and dark, narrow and wide. Set
`ELEVENLABS_SNAPSHOT_DIR` to a scratch folder outside the repository to get the PNGs.

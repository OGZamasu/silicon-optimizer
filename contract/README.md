# The Mac↔node wire contract

These JSON files are the *shape* of every payload that crosses machines
between silicon-node and Silicon Optimizer. They exist because the two
halves of this product are written in different languages, live in
different repositories, and are deployed independently: a key renamed
here used to show up as a blank swarm tile on someone's Mac, three weeks
later, with nothing failing anywhere in between.

Now both sides read these files in their tests:

- **silicon-node** (`tests/test_contract.py`) asserts the live FastAPI
  responses still carry every key in the fixture, with the same types.
  Add a field freely; rename or drop one and the suite fails here.
- **silicon-optimizer** (`Tests/SiliconTests/ContractFixtureTests.swift`)
  parses these exact files through the client code that reads a peer, so
  the Mac's lenient parsers are pinned against real node output rather
  than against a hand-typed dictionary that drifts.

`silicon-node` is canonical. The copy in `silicon-optimizer/contract/` is
kept byte-identical; both suites check the checksum in `VERSION.sha256`
so a one-sided edit cannot pass review quietly.

## Files

| File | Endpoint |
| --- | --- |
| `health.json` | `GET /health` — the unauthenticated probe |
| `node.json` | `GET /v1/node` — the advertisement the Mac's swarm page ranks on |
| `job-queued.json` | `GET /v1/jobs/{id}` for a job waiting on the card |
| `job-running.json` | …mid-render, with progress/step/ETA |
| `job-done.json` | …finished, with `result_urls` |
| `job-failed.json` | …failed, with a human-readable `error` |

## Known asymmetry

A waiting job is reported as `status: "running"` with no `progress`, so
the Mac's `NodeJobProgress.isQueued` — which looks for a literal
`"queued"`/`"pending"` — never fires for a silicon-node peer. The absent
`progress` is the only signal that the job has not started, and both
suites pin that. Fixing it properly means the node reporting `"queued"`
and every Mac caller treating that as in-flight; worth doing, but it is a
change to both halves at once, not a fixture edit.

## Rules the fixtures encode

- A queued job reports `status: "running"` with **no** `progress`. The
  Mac shows "waiting for the card", not a 0% bar.
- `status` collapses the node's four internal states into three:
  `running` (queued or running), `done`, `failed`.
- `progress` is 0–1, not 0–100.
- `result_urls` are node-relative paths, resolved against the peer's
  base URL by the caller.
- `metrics.headroom_gb` is the one cross-platform ranking field: each
  platform computes it its own way (VRAM here, unified memory on the
  Mac), and the router only ever compares this number.
- Values that may legitimately be absent are `null` in the fixtures;
  both suites treat a `null` in the fixture as "key optional, type
  unchecked", and a `null` in a response as satisfying any type — most of
  these fields are hardware probes with no answer on a machine that has
  no card, or no chat model loaded.

# Security review — 2026-09-21

Reviewed revision: `121d87e870fc17262937bc347f941aa6fbe5da3d`.

This source review focused on control API authentication and caller privileges,
media upload/registry boundaries, rendering and video queue requests, model
and runtime downloads, binary metadata parsing, embedded chat, and CI exposure.
It is not an exhaustive audit of every source file or third-party runtime.

## Findings and changes

### Medium: swarm credentials inherited authority over Mac file paths

`ControlServer.mayNamePaths` accepted every caller without a device ID, which
included the shared swarm credential. `resolvedMesh`, `resolvedImage`, and
`resolvedVideo` consequently accepted paths chosen by a peer on another machine.
A peer's access to its own filesystem does not grant access to this Mac's files.

One concrete consequence is the video path: `AppModel.generateVideo` carries
`imagePath` into `VideoBatchQueue`, which accepts a nonempty regular file up to
20 MiB as a reference image. `VideoRequest.nodeBody` reads those bytes and sends
them as `image_b64` to the selected configured renderer. A compromised swarm peer
that is also selected as that renderer can obtain Mac-readable file contents
before attempting image decoding. This requires a valid swarm credential,
reachability of an enabled listener, a supported image-input video model, and
selection of an attacker-controlled renderer. It is not an unauthenticated
Internet attack. The app's existing restriction against swarm access to agent
sessions confirms that a peer is not intended to have general Mac authority.

The patch grants raw-path authority only to the per-launch local control bearer.
Peers use `POST /uploads` followed by `uploadID` or permitted `mediaID` values.
The same restriction covers image/mesh planning and generation, and video
generation, on both listeners. Local control clients retain path support.

As related boundary hardening, `POST /install` now permits an explicit download
`directory` only with the local control credential. Paired devices and swarm
clients can still install models into the configured library by omitting it.
The previous behavior permitted remote selection of the destination for catalog
model downloads; this review does not claim arbitrary-content file writes.

### Low: video variation count could trap before validation

`AppModel.enqueueVideos` multiplied `prompts.count` by the untrusted `variations`
integer before calling the queue's validation. Two prompts with an extreme
integer variation count can overflow Swift's checked arithmetic and terminate
the app. The existing safe range check in `VideoBatchQueue.append` occurred too
late to protect this calculation.

The route requires authentication and a caller allowed to enqueue video, which
limits severity. The patch validates variation and prompt counts before routing
or arithmetic and retains the queue's existing persistence-time checks.

## Regression coverage

- `SwarmFileBoundaryTests`: reject raw paths for swarm callers on both listeners;
  preserve local-control paths; accept swarm-owned uploads/media IDs; reject
  another device's uploads; enforce local-only download destinations while
  preserving default-library installation.
- `ControlBoundaryTests`: reject extreme and invalid variation counts, empty
  batches, and excessive prompt counts before routing or multiplication.
- Existing queue tests continue to cover valid queue behavior and storage limits.

`git diff --check` passed. The Python video-node suite passed all 45 tests with
`python3 -m unittest discover -s Resources/video-node -p 'test_*.py' -q`.
These Python tests do not validate the Swift changes. This Linux environment has
no Swift toolchain or macOS frameworks, so the Swift regression tests and full
macOS build remain unrun. Before merging, run `swift test` on the supported Mac
build environment, including `SwarmFileBoundaryTests`, `ControlBoundaryTests`,
`BuddyMediaRoutesTests`, and `VideoBatchQueueTests`.

## Remaining review work

The embedded web view's navigation policy and privileged bridge should receive
a dedicated origin-confinement review. Runtime download authenticity and
resource limits for model downloads also merit separate review; this assessment
has not established a concrete exploit in those areas. Platform-dependent
listener behavior and the end-to-end renderer flow need macOS validation.

A future structural improvement is an explicit caller-capability policy shared
by all routes, with tests for each credential class. That would make filesystem,
model-management, rendering, and agent-session authority easier to audit as
routes are added.

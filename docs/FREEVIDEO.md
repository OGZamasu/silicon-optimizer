# FreeVideo in the Video tab

The **FreeVideo** panel connects Silicon Optimizer to an existing
[FreeVideo](https://github.com/FlashML-org/FreeVideo) installation in ComfyUI.
It generates MiniMax H3 video with audio on your NVIDIA computer and downloads
the completed MP4 to the Mac's normal video destination. No cloud API key or
per-generation cloud charge is involved.

## Prepare the renderer

FreeVideo currently supports NVIDIA CUDA on Windows or Linux, not Apple's
Metal/MPS GPU. Its published minimum is 8 GB of VRAM and 16 GB of system RAM;
engine setup also needs substantial disk space for models and the environment.
Use its supported launcher or custom-node installation and finish **FreeVideo
Settings → Install / repair** on that computer. The code and model have separate
licenses: obtain required model access/authorization through the distributor's
normal workflow and review the [model terms](https://huggingface.co/OpenVDN/vdn-minimax-h3-edge/blob/main/LICENSE).

Silicon Optimizer does not install ComfyUI, change an existing engine, download
weights, or accept model terms. Phosphene/MLX remains the Apple Silicon option.

## Connect and make a clip

1. Start ComfyUI with the FreeVideo custom node installed. Make it reachable
   from the Mac through your private network or an SSH port forward. Its usual
   address is `http://127.0.0.1:8188`; on the Mac that points to the Mac itself,
   unless a tunnel forwards it to the NVIDIA computer.
2. In **Video → FreeVideo**, enter the ComfyUI address and click **Check
   connection**. The app verifies the plugin, generation node and prepared
   engine. A reachable web page alone does not enable generation. **Open
   workspace** opens ComfyUI for setup and diagnostics.
3. Describe the shot, including dialogue, sound or music. Choose a canvas,
   3/5/10/15-second duration, optional fixed seed, and two-pass sampling.
   The lighter 768 × 448 canvas is the default. Larger canvases use more memory.
   H3 runs at 24 fps and rounds duration up to its frame grid.
4. Optionally add first and/or last frames. PNG, JPEG, WebP, BMP and TIFF files
   up to 32 MiB each are uploaded to this server for the request.
5. Click **Generate video**. The app follows the accepted job, downloads its
   MP4, and offers playback, Finder and saved local clip history.

Experimental reference video/audio, LoRAs, longer durations and custom workflows
remain available in the FreeVideo workspace.

## Recovery and cancellation

An accepted receipt saves its original ComfyUI address, unique generation node
ID and output destination. Changing the connection does not redirect that job.
Relaunching restores state without sending requests: **Resume saved job** follows
the original receipt and never submits the prompt again. Download/connection
failures retain the receipt for that same operation.

**Cancel job** uses FreeVideo's request-specific cancellation endpoint. A queued
job is removed directly; an active render remains followed until cancellation
is confirmed. The app never calls ComfyUI's global interrupt endpoint. A job
that has left the queue is checked for a completed result.

If submission times out or returns no usable receipt, its outcome is unknown.
The app holds further submissions until you inspect the workspace queue/history
and choose **I checked the workspace**. If ComfyUI has lost an old receipt,
inspect the workspace before explicitly forgetting it. This only forgets the
Mac's receipt; it does not stop an existing renderer.

State is private JSON at
`~/Library/Application Support/SiliconOptimizer/FreeVideo/studio.json`. No API
credentials are stored. A malformed file is preserved; **Retry loading saved
state** reads it again after repair rather than silently replacing it.

Connection URLs cannot embed credentials, query parameters or fragments. Polls,
uploads and downloads stay on the exact configured HTTP/HTTPS origin. Output
paths are checked; downloads are bounded and published atomically. Use a private
connection/tunnel to ComfyUI; the integration does not configure authentication
or public exposure.

## Protocol and validation

Checked against FreeVideo commit `90683b3ae834693fefa175e3f9e6ea8b99329d12`:

- Read-only probes: `/freevideo/launcher`, `/object_info/FreeVideoGenerate`,
  `/freevideo/setup`.
- `/prompt` with `FreeVideoGenerate` and optional `FreeVideoMedia`;
  first/last uploads use `/freevideo/media/upload`.
- Follow `/history/{prompt_id}`, `/queue` and `/freevideo/progress`. Unique
  generator node IDs prevent another client's progress replacing this job's.
- Native VIDEO previews use `outputs[node_id].images` with `type: output`;
  `/view` serves the checked MP4. This is not a `videos` array.
- `/freevideo/cancel` receives both the prompt and node IDs.

`swift test -j 2 --filter FreeVideo` checks the HTTP contract with fixtures and
Studio state with injected clients/private temporary storage: setup gating,
graph/media fields, structured errors, progress ownership, result paths/downloads,
targeted cancellation, recovery and persistence races. Fixtures do not run a
model or validate GPU quality/performance. A real generation test requires a
prepared, authorized NVIDIA FreeVideo installation.

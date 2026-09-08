# Silicon Optimizer Skill

## When to Use

Use the `silicon_*` tools whenever the production can run on hardware the user
already owns. They cost nothing per call, send nothing to a vendor, and need no
API key. Prefer them by default; reach for a cloud provider when a specific
model or capability is only available there, and say so in the decision log.

The tools are thin clients for the Silicon Optimizer app on this Mac. The app
does the work — images on the Mac's GPU, video through a model-aware node (a
paired GPU machine or a local Phosphene adapter), meshes on whichever can — and
shows its own progress bars while it does. If the app is not running, every tool
reports `unavailable` with a one-line reason; there is no key to configure and
nothing to install here.

## Tools

| Tool | Capability | Where it runs | Cost |
|------|-----------|---------------|------|
| `silicon_image` | `image_generation` — text-to-image, image-to-image | This Mac | $0 |
| `silicon_video` | `video_generation` — text-to-video, image-to-video | A paired GPU node or this Mac through a loopback adapter | $0 |
| `silicon_3d` | `3d_asset_generation` — image-to-3D (textured GLB, clean OBJ) | This Mac or the node | $0 |

## How It Works

1. The app publishes its port and a per-launch token to
   `~/Library/Application Support/SiliconOptimizer/control.json`. The tools read
   that file; nothing is configured by hand.
2. Each call is one blocking HTTP request. The app answers when the file is
   written, and the tool copies it to `output_path` when one was given.
3. Refusals arrive in the app's own words — "this model will not fit in 32 GB",
   "no node currently offers video" — and are returned as the tool's `error`.
   Read them; they name the fix.

## Key Patterns

### Video needs an exact model capability

`silicon_video.get_status()` asks the app whether any video model is *available
right now*. Each model publishes its own supported clip lengths; use the app's
model listing rather than assuming every video node can run every model. A node
that is switched off or has that model disabled is `unavailable`, not a render
that fails minutes in. When it is unavailable, do not silently fall back to a
paid provider: present the choice. The user may prefer to start the paired PC or
the local adapter.

### No text-to-3D

`silicon_3d` is image-to-3D only. For a mesh from a description, render the
still with `silicon_image` first — pick the strongest image model the app
offers, front-on, plain background — then hand that file to `silicon_3d`.
Two calls, both free, and the still is a reviewable checkpoint.

### Negative prompts

`silicon_image` accepts `negative_prompt` for schema compatibility and ignores
it: the FLUX-family models the app runs take none. Put what to avoid into the
prompt itself.

### Memory warnings are not failures

The app predicts memory before it renders and *warns* rather than refuses when a
run looks tight. That warning comes back in `data.warning`. Log it; a warned
render usually completes, just slower.

## Checking What Is Available

```bash
python -c "from tools.tool_registry import registry; registry.discover(); \
print({t.name: t.get_status().value for t in registry.get_by_provider('silicon_optimizer')})"
```

## Reaching a Mac Elsewhere on the Network

Silicon Optimizer is a Mac app. From Windows or Linux, or from a second Mac, point
the tools at the Mac running it:

```bash
SILICON_OPTIMIZER_URL=http://<that-mac>:8791
SILICON_OPTIMIZER_TOKEN=<its swarm token, from Settings → Swarm>
```

The control server refuses every call without that token, by design.

#!/usr/bin/env python3
"""Qwen-Image 2.1 with a few-step LoRA adapter merged in, rendered through MFLUX.

Silicon Optimizer runs this with the Python of its own hash-locked MFLUX environment
(mflux 0.20.0). That release runs Qwen-Image 2.1 but has no LoRA mapping for it and no way to
hand its sampler a sigma list, which is what Pruna's few-step adapters need. So this script
does exactly those two things itself, and uses mflux's own classes for everything else:

1. It builds mflux's QwenImage21 the way Qwen21Initializer does, with one step added between
   loading the full-precision weights and quantizing them: the adapter is merged,
   W <- W + scale * B @ A, into each of the 224 modules it targets (7 per block, 32 blocks).
   Every key in the adapter file has to name one of those modules, every module needs both
   halves, and every shape has to agree with the weight it is merged into; anything else stops
   the run before a step is taken. The file's digest is checked first, and its PEFT metadata
   has to say plain LoRA with lora_alpha / r equal to the scale the app expects.

2. It samples on the adapter's own sigma list — the terminal 0 appended, nothing shifted —
   through mflux's scheduler extension point (a BaseScheduler registered by name), with
   guidance 1.0 and no negative prompt, so there is no second, unconditional pass.

The prompt is encoded first and the text encoder released before the transformer is
materialised, so the two largest components are never resident together. Progress is mflux's
own tqdm bar on stderr; stages are lines starting "silicon-stage: "; the last line is mflux's
own "Peak MLX memory: N GB" — all things the app already reads.

The functions above `main` import nothing beyond the standard library, so the key mapping and
the merge can be tested with no MLX, no mflux and no weights (test_silicon_qwen21.py).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import struct
import sys
import time

BLOCKS = 32
# The modules the adapters train, in mflux's own naming — which for these seven is also the
# diffusers naming the PEFT keys use, so the mapping is the key minus its prefix and suffix.
TARGET_MODULES = (
    "attn.to_q",
    "attn.to_k",
    "attn.to_v",
    "attn.to_out.0",
    "img_mlp.gate_layer",
    "img_mlp.proj",
    "img_mlp.out",
)
_KEY = re.compile(
    r"^transformer\.transformer_blocks\.(\d+)\.("
    + "|".join(re.escape(module) for module in TARGET_MODULES)
    + r")\.lora_([AB])\.weight$"
)
STAGE = "silicon-stage: "
EXPECTED_MFLUX = "0.20."


class AdapterError(Exception):
    """The adapter cannot be merged as it is. Always fatal: a partly merged adapter renders."""


# MARK: - The adapter file


def read_safetensors_header(path):
    """(tensors, metadata) from a safetensors file: name -> {dtype, shape, data_offsets}."""
    with open(path, "rb") as handle:
        prefix = handle.read(8)
        if len(prefix) != 8:
            raise AdapterError(f"{path} is not a safetensors file")
        (length,) = struct.unpack("<Q", prefix)
        if length <= 0 or length > 100_000_000:
            raise AdapterError(f"{path} has an implausible header ({length} bytes)")
        header = json.loads(handle.read(length))
    metadata = header.pop("__metadata__", None) or {}
    return header, metadata


def lora_scale(metadata):
    """lora_alpha / r from PEFT's metadata, after checking the adapter is plain LoRA.

    Anything this merge does not implement — DoRA, rsLoRA, per-module ranks or alphas, a
    transposed layout, biases — is refused rather than approximated.
    """
    raw = metadata.get("lora_adapter_metadata")
    if not raw:
        raise AdapterError("the adapter carries no PEFT metadata, so its scale is unknown")
    config = json.loads(raw)
    value = lambda name, default=None: config.get(f"transformer.{name}", config.get(name, default))
    if value("peft_type", "LORA") != "LORA":
        raise AdapterError(f"not a LoRA adapter ({value('peft_type')})")
    for flag in ("use_dora", "use_rslora", "fan_in_fan_out", "lora_bias"):
        if value(flag, False):
            raise AdapterError(f"{flag} adapters are not supported")
    for pattern in ("rank_pattern", "alpha_pattern"):
        if value(pattern):
            raise AdapterError(f"per-module {pattern} is not supported")
    if value("bias", "none") != "none":
        raise AdapterError(f"bias={value('bias')} adapters are not supported")
    rank, alpha = value("r"), value("lora_alpha")
    if not isinstance(rank, int) or rank <= 0 or not isinstance(alpha, (int, float)):
        raise AdapterError(f"unreadable rank ({rank!r}) or alpha ({alpha!r})")
    return rank, float(alpha) / rank


def module_for_key(key):
    """(block, module) for a PEFT key, e.g. ('transformer_blocks.3.attn.to_out.0', 'A')."""
    match = _KEY.match(key)
    if not match:
        raise AdapterError(f"{key} does not name a module this adapter merge knows")
    block = int(match.group(1))
    if block >= BLOCKS:
        raise AdapterError(f"{key} names block {block}; Qwen-Image 2.1 has {BLOCKS}")
    return f"transformer_blocks.{block}.{match.group(2)}", match.group(3)


def plan_merge(tensors, rank, weight_shape, blocks=BLOCKS):
    """The (module, key_A, key_B) pairs to merge, after checking every key and every shape.

    `weight_shape(module)` is the shape of `<module>.weight` in the loaded transformer, or
    None when there is no such weight. A module targeted by half an adapter, a shape that does
    not fit its weight, or a module count other than blocks x 7 all stop the merge — each
    means the file is not the adapter this was written for.
    """
    halves = {}
    problems = []
    for key in sorted(tensors):
        try:
            module, half = module_for_key(key)
        except AdapterError as error:
            problems.append(str(error))
            continue
        halves.setdefault(module, {})[half] = key

    pairs = []
    for module in sorted(halves):
        found = halves[module]
        if set(found) != {"A", "B"}:
            problems.append(f"{module} has lora_{''.join(sorted(found))} without its other half")
            continue
        down = list(tensors[found["A"]]["shape"])
        up = list(tensors[found["B"]]["shape"])
        weight = weight_shape(module)
        if weight is None:
            problems.append(f"{module}.weight is not in the loaded transformer")
            continue
        weight = list(weight)
        if len(down) != 2 or len(up) != 2 or len(weight) != 2:
            problems.append(f"{module}: not two-dimensional ({down}, {up}, {weight})")
        elif down[0] != rank or up[1] != rank:
            problems.append(f"{module}: rank {down[0]}/{up[1]}, expected {rank}")
        elif [up[0], down[1]] != weight:
            problems.append(f"{module}: B@A is {[up[0], down[1]]}, the weight is {weight}")
        else:
            pairs.append((module, found["A"], found["B"]))

    expected = blocks * len(TARGET_MODULES)
    if not problems and len(pairs) != expected:
        problems.append(f"{len(pairs)} modules, expected {expected} ({blocks} blocks x {len(TARGET_MODULES)})")
    if problems:
        shown = "; ".join(problems[:8]) + (f"; and {len(problems) - 8} more" if len(problems) > 8 else "")
        raise AdapterError(f"the adapter does not fit Qwen-Image 2.1's transformer: {shown}")
    return pairs


def _step(node, part):
    if isinstance(node, list):
        if not part.isdigit() or int(part) >= len(node):
            return None
        return node[int(part)]
    if isinstance(node, dict):
        return node.get(part)
    return None


def tree_get(tree, path):
    """A leaf of mflux's nested weights (dicts, with lists where a key is an index)."""
    node = tree
    for part in path.split("."):
        node = _step(node, part)
        if node is None:
            return None
    return node


def tree_set(tree, path, value):
    *parents, last = path.split(".")
    node = tree
    for part in parents:
        node = _step(node, part)
        if node is None:
            raise AdapterError(f"{path} is not in the loaded transformer")
    if isinstance(node, list):
        node[int(last)] = value
    else:
        node[last] = value


def merge(tree, pairs, arrays, scale, merge_one):
    """Replaces each `<module>.weight` in `tree` with merge_one(W, A, B, scale). Returns the
    number merged, which plan_merge has already required to be all of them."""
    for module, key_a, key_b in pairs:
        path = f"{module}.weight"
        weight = tree_get(tree, path)
        if weight is None:
            raise AdapterError(f"{path} is not in the loaded transformer")
        tree_set(tree, path, merge_one(weight, arrays[key_a], arrays[key_b], scale))
    return len(pairs)


def parse_sigmas(text, steps):
    """The adapter's sigma list: `steps` values, from 1 down, strictly decreasing, above 0."""
    try:
        sigmas = [float(part) for part in text.split(",")]
    except ValueError:
        raise AdapterError(f"unreadable sigmas: {text!r}") from None
    if len(sigmas) != steps:
        raise AdapterError(f"{len(sigmas)} sigmas for {steps} steps")
    if not all(math.isfinite(sigma) and 0 < sigma <= 1 for sigma in sigmas):
        raise AdapterError(f"sigmas must lie in (0, 1]: {sigmas}")
    if sigmas[0] != 1.0 or any(later >= earlier for earlier, later in zip(sigmas, sigmas[1:])):
        raise AdapterError(f"sigmas must start at 1 and strictly decrease: {sigmas}")
    return sigmas


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def stage(text):
    print(STAGE + text, file=sys.stderr, flush=True)


# MARK: - The run


def build_parser():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--model-path", required=True, help="Qwen-Image 2.1 snapshot directory")
    parser.add_argument("--adapter", required=True, help="the adapter .safetensors file")
    parser.add_argument("--adapter-sha256", required=True)
    parser.add_argument("--adapter-scale", type=float, required=True, help="lora_alpha / r")
    parser.add_argument("--sigmas", required=True, help="comma-separated, one per step")
    parser.add_argument("--steps", type=int, required=True)
    parser.add_argument("--prompt", required=True)
    parser.add_argument("--width", type=int, default=1024)
    parser.add_argument("--height", type=int, default=1024)
    parser.add_argument("--seed", type=int, default=None)
    parser.add_argument("--quantize", type=int, choices=[3, 4, 5, 6, 8], default=None)
    parser.add_argument("--image", nargs=2, metavar=("PATH", "STRENGTH"), default=None)
    parser.add_argument("--low-ram", action="store_true")
    parser.add_argument("--output", required=True)
    return parser


def check_mflux():
    from importlib.metadata import PackageNotFoundError, version

    try:
        found = version("mflux")
    except PackageNotFoundError:
        raise SystemExit("mflux is not installed in this environment.") from None
    if not found.startswith(EXPECTED_MFLUX):
        raise SystemExit(
            f"This needs MFLUX {EXPECTED_MFLUX}x (found {found}): its Qwen-Image 2.1 loader is "
            "what the adapter is merged into. Update MFLUX from the Images tab."
        )


def load_model(model_path, adapter_path, expected_scale, quantize):
    """QwenImage21 exactly as Qwen21Initializer.init builds it, with the adapter merged into
    the full-precision transformer weights before WeightApplier quantizes them."""
    import mlx.core as mx
    from mlx import nn
    from mflux.models.common.config import ModelConfig
    from mflux.models.qwen21.qwen21_initializer import Qwen21Initializer
    from mflux.models.qwen21.variants.txt2img.qwen_image_21 import QwenImage21

    tensors, metadata = read_safetensors_header(adapter_path)
    rank, scale = lora_scale(metadata)
    if abs(scale - expected_scale) > 1e-9:
        raise AdapterError(f"the file's lora_alpha / r is {scale}, the app expects {expected_scale}")

    model = QwenImage21.__new__(QwenImage21)
    nn.Module.__init__(model)
    Qwen21Initializer._init_config(model, ModelConfig.qwen_image_21())
    weights = Qwen21Initializer._load_weights(model_path)
    transformer = weights.components["transformer"]

    def shape(module):
        leaf = tree_get(transformer, f"{module}.weight")
        return None if leaf is None else tuple(leaf.shape)

    pairs = plan_merge(tensors, rank, shape)
    arrays = mx.load(adapter_path)

    def merge_one(weight, down, up, factor):
        delta = up.astype(mx.float32) @ down.astype(mx.float32)
        return (weight.astype(mx.float32) + factor * delta).astype(weight.dtype)

    merged = merge(transformer, pairs, arrays, scale, merge_one)
    del arrays
    Qwen21Initializer._init_tokenizers(model, model_path)
    Qwen21Initializer._init_models(model)
    Qwen21Initializer._apply_weights(model, weights, quantize)
    del weights, transformer
    return model, merged, rank, scale


def fixed_sigma_scheduler(sigmas):
    """A BaseScheduler class sampling on exactly `sigmas`, then 0 — the Euler step mflux's
    LinearScheduler takes, minus its schedule and its resolution-dependent shift."""
    import mlx.core as mx
    from mflux.models.common.schedulers.base_scheduler import BaseScheduler

    class FixedSigmaScheduler(BaseScheduler):
        def __init__(self, config):
            if config.num_inference_steps != len(sigmas):
                raise AdapterError(f"{config.num_inference_steps} steps for {len(sigmas)} sigmas")
            self.config = config
            self._sigmas = mx.array(list(sigmas) + [0.0], dtype=mx.float32)
            self._timesteps = mx.arange(len(sigmas), dtype=mx.float32)

        @property
        def sigmas(self):
            return self._sigmas

        @property
        def timesteps(self):
            return self._timesteps

        def step(self, noise, timestep, latents, **kwargs):
            dt = (self._sigmas[timestep + 1] - self._sigmas[timestep]).astype(latents.dtype)
            return latents + noise.astype(latents.dtype) * dt

    return FixedSigmaScheduler


def main(argv=None):
    arguments = build_parser().parse_args(argv)
    try:
        sigmas = parse_sigmas(arguments.sigmas, arguments.steps)
        stage("Checking the adapter")
        found = sha256_of(arguments.adapter)
        if found != arguments.adapter_sha256.lower():
            raise AdapterError(
                f"{arguments.adapter} is not the reviewed file (SHA-256 {found}); remove the model "
                "and install it again"
            )
        check_mflux()

        import gc

        import mlx.core as mx
        from mflux.models.common.schedulers import register_contrib
        from mflux.models.common.vae.tiling_config import TilingConfig
        from mflux.models.qwen21.model.qwen21_text_encoder.qwen21_prompt_encoder import (
            Qwen21PromptEncoder,
        )

        started = time.monotonic()
        stage("Loading Qwen-Image 2.1 and merging the adapter")
        model, merged, rank, scale = load_model(
            arguments.model_path, arguments.adapter, arguments.adapter_scale, arguments.quantize
        )
        print(f"Merged the adapter into {merged} modules (rank {rank}, scale {scale:g}).",
              file=sys.stderr, flush=True)

        # Encode first, then let the text encoder go, before the transformer is read: mflux's
        # own loop evicts it too, but only after the transformer has joined it in memory.
        stage("Encoding the prompt")
        embeds, mask = Qwen21PromptEncoder.encode_prompt(
            prompt=arguments.prompt,
            prompt_cache=model.prompt_cache,
            tokenizer=model.tokenizers["qwen21"],
            text_encoder=model.text_encoder,
        )
        mx.eval(embeds, mask)
        model.text_encoder = None
        gc.collect()
        mx.clear_cache()

        # One block at a time: each block's full-precision weights are read, merged and
        # quantized, then released, rather than the whole transformer at once.
        stage("Preparing the transformer")
        for block in model.transformer.transformer_blocks:
            mx.eval(block.parameters())
        mx.eval(model.transformer.parameters())
        gc.collect()
        mx.clear_cache()
        if arguments.low_ram and TilingConfig.may_tile_implicitly(model):
            model.tiling_config = TilingConfig()
            mx.set_cache_limit(1000**3)

        name = f"silicon_fixed_sigmas_{arguments.steps}"
        register_contrib(fixed_sigma_scheduler(sigmas), name)
        stage(f"Denoising in {arguments.steps} steps")
        image = model.generate_image(
            seed=arguments.seed if arguments.seed is not None else int(time.time()),
            prompt=arguments.prompt,
            num_inference_steps=arguments.steps,
            height=arguments.height,
            width=arguments.width,
            guidance=1.0,
            image_path=arguments.image[0] if arguments.image else None,
            image_strength=float(arguments.image[1]) if arguments.image else None,
            scheduler=name,
            negative_prompt=None,
        )
        image.save(path=arguments.output, overwrite=True)
        print(f"Rendered in {time.monotonic() - started:.1f} s.", file=sys.stderr, flush=True)
        print(f"Peak MLX memory: {mx.get_peak_memory() / 10**9:.2f} GB", file=sys.stderr, flush=True)
        return 0
    except AdapterError as error:
        print(f"Adapter refused: {error}", file=sys.stderr, flush=True)
        return 3


if __name__ == "__main__":
    sys.exit(main())

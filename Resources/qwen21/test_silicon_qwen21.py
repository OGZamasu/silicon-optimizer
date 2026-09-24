#!/usr/bin/env python3
"""The adapter merge in silicon_qwen21.py, with no MLX, no mflux and no real weights.

A synthetic safetensors file carries the adapter's real key names and PEFT metadata at tiny
shapes (width 4, MLP 6, rank 2, two blocks), in bf16 like the real files, and is merged into a
fake set of layers laid out the way mflux's weight mapping nests Qwen-Image 2.1's transformer.
Plain Python lists stand in for arrays, so the system python3 runs it; the Swift suite does,
through QwenImage21RunnerTests. Everything written goes to a temporary directory.
"""

from __future__ import annotations

import hashlib
import json
import os
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import silicon_qwen21 as runner  # noqa: E402

WIDTH, MLP, RANK, BLOCKS = 4, 6, 2, 2
ALPHA = 4  # lora_alpha / r = 2.0, the real adapters' ratio at a smaller rank

# The real files' PEFT metadata, trimmed to the fields the runner reads.
METADATA = {
    "transformer.bias": "none",
    "transformer.fan_in_fan_out": False,
    "transformer.lora_alpha": ALPHA,
    "transformer.lora_bias": False,
    "transformer.peft_type": "LORA",
    "transformer.r": RANK,
    "transformer.rank_pattern": {},
    "transformer.alpha_pattern": {},
    "transformer.use_dora": False,
    "transformer.use_rslora": False,
}


def shapes(module):
    """(out, in) of each target module's weight at the test's widths."""
    if module in ("img_mlp.gate_layer", "img_mlp.proj"):
        return MLP, WIDTH
    if module == "img_mlp.out":
        return WIDTH, MLP
    return WIDTH, WIDTH


def matrix(rows, columns, seed):
    """Small values exact in bf16 (multiples of 1/8 below 2), different per seed."""
    return [[((seed * 7 + r * 5 + c * 3) % 13 - 6) / 8 for c in range(columns)] for r in range(rows)]


def bf16(value):
    bits = struct.unpack("<I", struct.pack("<f", value))[0]
    assert bits & 0xFFFF == 0, f"{value} is not exact in bf16"
    return struct.pack("<H", bits >> 16)


def from_bf16(raw, rows, columns):
    values = [struct.unpack("<f", struct.pack("<I", struct.unpack("<H", raw[i:i + 2])[0] << 16))[0]
              for i in range(0, len(raw), 2)]
    return [values[r * columns:(r + 1) * columns] for r in range(rows)]


def write_safetensors(path, tensors, metadata):
    """Writes {name: nested list} as BF16 in the safetensors layout."""
    header, blobs, offset = {}, [], 0
    for name in sorted(tensors):
        rows = tensors[name]
        data = b"".join(bf16(v) for row in rows for v in row)
        header[name] = {"dtype": "BF16", "shape": [len(rows), len(rows[0])],
                        "data_offsets": [offset, offset + len(data)]}
        blobs.append(data)
        offset += len(data)
    if metadata is not None:
        header["__metadata__"] = {"format": "pt", "lora_adapter_metadata": json.dumps(metadata)}
    encoded = json.dumps(header).encode()
    encoded += b" " * (-len(encoded) % 8)
    with open(path, "wb") as handle:
        handle.write(struct.pack("<Q", len(encoded)) + encoded + b"".join(blobs))


def read_tensors(path):
    tensors, _ = runner.read_safetensors_header(path)
    with open(path, "rb") as handle:
        (length,) = struct.unpack("<Q", handle.read(8))
        start = 8 + length
        out = {}
        for name, info in tensors.items():
            handle.seek(start + info["data_offsets"][0])
            raw = handle.read(info["data_offsets"][1] - info["data_offsets"][0])
            out[name] = from_bf16(raw, *info["shape"])
        return out


def adapter_tensors(blocks=BLOCKS, skip=()):
    tensors = {}
    seed = 1
    for block in range(blocks):
        for module in runner.TARGET_MODULES:
            out, inp = shapes(module)
            prefix = f"transformer.transformer_blocks.{block}.{module}"
            if f"{block}.{module}.A" not in skip:
                tensors[f"{prefix}.lora_A.weight"] = matrix(RANK, inp, seed)
            if f"{block}.{module}.B" not in skip:
                tensors[f"{prefix}.lora_B.weight"] = matrix(out, RANK, seed + 1)
            seed += 2
    return tensors


def fake_transformer(blocks=BLOCKS):
    """mflux's nesting: dicts, and lists where a path component is an index."""
    def linear(module, seed):
        out, inp = shapes(module)
        return {"weight": matrix(out, inp, seed)}

    layers = []
    for block in range(blocks):
        base = 100 + block * 10
        layers.append({
            "attn": {
                "to_q": linear("attn.to_q", base), "to_k": linear("attn.to_k", base + 1),
                "to_v": linear("attn.to_v", base + 2),
                "to_out": [linear("attn.to_out.0", base + 3)],
                "norm_q": {"weight": [1.0] * WIDTH}, "norm_k": {"weight": [1.0] * WIDTH},
            },
            "img_mlp": {
                "gate_layer": linear("img_mlp.gate_layer", base + 4),
                "proj": linear("img_mlp.proj", base + 5), "out": linear("img_mlp.out", base + 6),
            },
        })
    return {"transformer_blocks": layers, "img_in": {"weight": matrix(WIDTH, 64, 3)}}


def shape_of(tree):
    def shape(module):
        leaf = runner.tree_get(tree, f"{module}.weight")
        return None if leaf is None else (len(leaf), len(leaf[0]))
    return shape


def merge_lists(weight, down, up, scale):
    """W + scale * B @ A on nested lists: the arithmetic the MLX merge does."""
    rank = len(down)
    return [[weight[r][c] + scale * sum(up[r][k] * down[k][c] for k in range(rank))
             for c in range(len(weight[0]))] for r in range(len(weight))]


class Scratch:
    def __enter__(self):
        self.directory = tempfile.TemporaryDirectory(prefix="silicon-qwen21-test-")
        return self.directory.name

    def __exit__(self, *exc):
        self.directory.cleanup()


class KeyMappingTests(unittest.TestCase):
    def test_real_key_names_map_onto_mfluxs_module_paths(self):
        cases = {
            "transformer.transformer_blocks.0.attn.to_k.lora_A.weight": ("transformer_blocks.0.attn.to_k", "A"),
            "transformer.transformer_blocks.31.attn.to_out.0.lora_B.weight": ("transformer_blocks.31.attn.to_out.0", "B"),
            "transformer.transformer_blocks.7.img_mlp.gate_layer.lora_A.weight": ("transformer_blocks.7.img_mlp.gate_layer", "A"),
            "transformer.transformer_blocks.12.img_mlp.proj.lora_B.weight": ("transformer_blocks.12.img_mlp.proj", "B"),
            "transformer.transformer_blocks.3.img_mlp.out.lora_A.weight": ("transformer_blocks.3.img_mlp.out", "A"),
        }
        for key, expected in cases.items():
            self.assertEqual(runner.module_for_key(key), expected)

    def test_anything_else_is_refused(self):
        for key in (
            "transformer.transformer_blocks.32.attn.to_q.lora_A.weight",  # no block 32
            "transformer.transformer_blocks.0.attn.add_q_proj.lora_A.weight",
            "transformer.transformer_blocks.0.attn.to_q.lora_magnitude_vector",  # DoRA
            "transformer.norm_out.linear.lora_A.weight",
            "transformer_blocks.0.attn.to_q.lora_A.weight",  # no prefix
            "transformer.transformer_blocks.0.attn.to_out.1.lora_A.weight",
            "text_encoder.layers.0.q_proj.lora_A.weight",
        ):
            with self.subTest(key=key), self.assertRaises(runner.AdapterError):
                runner.module_for_key(key)

    def test_the_real_metadata_gives_rank_64_and_scale_2(self):
        real = dict(METADATA, **{"transformer.r": 64, "transformer.lora_alpha": 128,
                                 "transformer.target_modules": ["img_mlp.gate_layer", "to_q", "to_v",
                                                                "img_mlp.proj", "to_out.0", "img_mlp.out", "to_k"]})
        self.assertEqual(runner.lora_scale({"lora_adapter_metadata": json.dumps(real)}), (64, 2.0))

    def test_adapters_this_merge_does_not_implement_are_refused(self):
        for change in ({"transformer.use_dora": True}, {"transformer.use_rslora": True},
                       {"transformer.rank_pattern": {"to_q": 8}}, {"transformer.alpha_pattern": {"to_q": 8}},
                       {"transformer.fan_in_fan_out": True}, {"transformer.bias": "all"},
                       {"transformer.peft_type": "LOHA"}, {"transformer.r": 0}):
            with self.subTest(change=change), self.assertRaises(runner.AdapterError):
                runner.lora_scale({"lora_adapter_metadata": json.dumps(dict(METADATA, **change))})
        with self.assertRaises(runner.AdapterError):
            runner.lora_scale({})


class MergeTests(unittest.TestCase):
    def test_a_synthetic_adapter_merges_into_every_target_and_nothing_else(self):
        with Scratch() as directory:
            path = os.path.join(directory, "adapter.safetensors")
            write_safetensors(path, adapter_tensors(), METADATA)
            tensors, metadata = runner.read_safetensors_header(path)
            rank, scale = runner.lora_scale(metadata)
            self.assertEqual((rank, scale), (RANK, 2.0))
            arrays = read_tensors(path)

        tree = fake_transformer()
        before = json.loads(json.dumps(tree))
        pairs = runner.plan_merge(tensors, rank, shape_of(tree), blocks=BLOCKS)
        self.assertEqual(len(pairs), BLOCKS * 7)
        self.assertEqual(runner.merge(tree, pairs, arrays, scale, merge_lists), BLOCKS * 7)

        for block in range(BLOCKS):
            for module in runner.TARGET_MODULES:
                path = f"transformer_blocks.{block}.{module}.weight"
                prefix = f"transformer.transformer_blocks.{block}.{module}"
                down, up = arrays[f"{prefix}.lora_A.weight"], arrays[f"{prefix}.lora_B.weight"]
                original = runner.tree_get(before, path)
                merged = runner.tree_get(tree, path)
                self.assertEqual((len(merged), len(merged[0])), shapes(module))
                for r in range(len(original)):
                    for c in range(len(original[0])):
                        delta = sum(up[r][k] * down[k][c] for k in range(RANK))
                        self.assertAlmostEqual(merged[r][c], original[r][c] + 2.0 * delta, places=9)
                self.assertNotEqual(merged, original, path)
        # Untargeted weights are untouched.
        for path in ("transformer_blocks.0.attn.norm_q.weight", "img_in.weight"):
            self.assertEqual(runner.tree_get(tree, path), runner.tree_get(before, path))

    def test_a_shape_that_does_not_fit_stops_the_merge(self):
        tree = fake_transformer()
        tree["transformer_blocks"][1]["img_mlp"]["out"]["weight"] = matrix(MLP, WIDTH, 1)  # transposed
        tensors = {k: {"shape": [len(v), len(v[0])]} for k, v in adapter_tensors().items()}
        with self.assertRaisesRegex(runner.AdapterError, r"transformer_blocks\.1\.img_mlp\.out"):
            runner.plan_merge(tensors, RANK, shape_of(tree), blocks=BLOCKS)

    def test_a_wrong_rank_stops_the_merge(self):
        tensors = {k: {"shape": [len(v), len(v[0])]} for k, v in adapter_tensors().items()}
        with self.assertRaisesRegex(runner.AdapterError, "rank"):
            runner.plan_merge(tensors, RANK + 1, shape_of(fake_transformer()), blocks=BLOCKS)

    def test_half_an_adapter_or_a_missing_module_stops_the_merge(self):
        tree = fake_transformer()
        half = {k: {"shape": [len(v), len(v[0])]} for k, v in adapter_tensors(skip={"1.attn.to_v.B"}).items()}
        with self.assertRaisesRegex(runner.AdapterError, "without its other half"):
            runner.plan_merge(half, RANK, shape_of(tree), blocks=BLOCKS)
        missing = {k: v for k, v in adapter_tensors().items() if ".1.img_mlp.proj." not in k}
        missing = {k: {"shape": [len(v), len(v[0])]} for k, v in missing.items()}
        with self.assertRaisesRegex(runner.AdapterError, "13 modules, expected 14"):
            runner.plan_merge(missing, RANK, shape_of(tree), blocks=BLOCKS)

    def test_an_unmapped_key_or_a_module_the_model_lacks_stops_the_merge(self):
        tensors = {k: {"shape": [len(v), len(v[0])]} for k, v in adapter_tensors().items()}
        tensors["transformer.transformer_blocks.0.attn.add_k_proj.lora_A.weight"] = {"shape": [RANK, WIDTH]}
        with self.assertRaisesRegex(runner.AdapterError, "add_k_proj"):
            runner.plan_merge(tensors, RANK, shape_of(fake_transformer()), blocks=BLOCKS)
        tensors = {k: {"shape": [len(v), len(v[0])]} for k, v in adapter_tensors().items()}
        tree = fake_transformer()
        del tree["transformer_blocks"][0]["attn"]["to_k"]
        with self.assertRaisesRegex(runner.AdapterError, "to_k.weight is not in the loaded transformer"):
            runner.plan_merge(tensors, RANK, shape_of(tree), blocks=BLOCKS)

    def test_the_real_file_layout_needs_all_224_modules(self):
        # The header of p_qwen_image_2.1_8step_v0.1 at its real shapes, merged against a model
        # of the real widths — shapes only, nothing allocated.
        tensors = {}
        widths = {"attn.to_q": (4096, 4096), "attn.to_k": (4096, 4096), "attn.to_v": (4096, 4096),
                  "attn.to_out.0": (4096, 4096), "img_mlp.gate_layer": (12288, 4096),
                  "img_mlp.proj": (12288, 4096), "img_mlp.out": (4096, 12288)}
        for block in range(32):
            for module, (out, inp) in widths.items():
                prefix = f"transformer.transformer_blocks.{block}.{module}"
                tensors[f"{prefix}.lora_A.weight"] = {"shape": [64, inp]}
                tensors[f"{prefix}.lora_B.weight"] = {"shape": [out, 64]}
        shape = lambda module: widths[module.split(".", 2)[2]]
        self.assertEqual(len(runner.plan_merge(tensors, 64, shape)), 224)
        del tensors["transformer.transformer_blocks.31.img_mlp.out.lora_A.weight"]
        with self.assertRaises(runner.AdapterError):
            runner.plan_merge(tensors, 64, shape)


class ScheduleTests(unittest.TestCase):
    EIGHT = [1.0, 14 / 15, 6 / 7, 10 / 13, 2 / 3, 6 / 11, 0.4, 2 / 9]
    FIVE = [1.0, 0.94, 6 / 7, 2 / 3, 0.4]

    def test_the_lists_the_app_passes_are_read_back_exactly(self):
        for sigmas in (self.EIGHT, self.FIVE):
            text = ",".join(repr(sigma) for sigma in sigmas)
            self.assertEqual(runner.parse_sigmas(text, len(sigmas)), sigmas)

    def test_a_schedule_that_is_not_an_adapters_is_refused(self):
        for text, steps in (("1.0,0.5", 3), ("0.9,0.5", 2), ("1.0,0.5,0.6", 3), ("1.0,1.2", 2),
                            ("1.0,0.0", 2), ("1.0,nan", 2), ("1.0,x", 2)):
            with self.subTest(text=text), self.assertRaises(runner.AdapterError):
                runner.parse_sigmas(text, steps)


class ArgumentTests(unittest.TestCase):
    BASE = ["--model-path", "/s", "--steps", "40", "--prompt", "p", "--output", "/o.png"]
    ADAPTER = ["--adapter", "/a", "--adapter-sha256", "0" * 64, "--adapter-scale", "2.0"]

    def check(self, extra):
        runner.check_arguments(runner.build_parser().parse_args(self.BASE + extra))

    def test_the_base_needs_no_adapter_and_no_schedule(self):
        self.check([])

    def test_an_adapter_comes_whole_and_with_its_schedule(self):
        self.check(self.ADAPTER + ["--sigmas", "1.0,0.5"])
        for extra in (self.ADAPTER, self.ADAPTER[:2], self.ADAPTER[2:] + ["--sigmas", "1.0"]):
            with self.subTest(extra=extra), self.assertRaises(runner.AdapterError):
                self.check(extra)


class FileTests(unittest.TestCase):
    def test_the_digest_is_the_files(self):
        with Scratch() as directory:
            path = os.path.join(directory, "adapter.safetensors")
            with open(path, "wb") as handle:
                handle.write(b"reviewed bytes" * 1000)
            self.assertEqual(runner.sha256_of(path), hashlib.sha256(b"reviewed bytes" * 1000).hexdigest())

    def test_a_file_that_is_not_safetensors_is_refused(self):
        with Scratch() as directory:
            path = os.path.join(directory, "adapter.safetensors")
            with open(path, "wb") as handle:
                handle.write(b"\x00")
            with self.assertRaises(runner.AdapterError):
                runner.read_safetensors_header(path)

    def test_a_wrong_digest_stops_before_anything_is_loaded(self):
        with Scratch() as directory:
            path = os.path.join(directory, "adapter.safetensors")
            write_safetensors(path, adapter_tensors(), METADATA)
            status = runner.main([
                "--model-path", directory, "--adapter", path, "--adapter-sha256", "0" * 64,
                "--adapter-scale", "2.0", "--sigmas", "1.0,0.5", "--steps", "2",
                "--prompt", "p", "--output", os.path.join(directory, "out.png"),
            ])
            self.assertEqual(status, 3)
            self.assertFalse(os.path.exists(os.path.join(directory, "out.png")))


if __name__ == "__main__":
    unittest.main()

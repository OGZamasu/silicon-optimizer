#!/bin/bash
# Regenerates the pinned manifests of the Hugging Face repositories the voice models read at
# run time (Resources/pinned-installs/models). The voice runtimes — mlx-audio, mlx-speech and
# LuxTTS — name their repositories without a revision, and some of them (Kokoro's voices,
# CSM's tokenizer and codec, LuxTTS's transcriber) are hardcoded inside the libraries. So the
# app puts exactly these files, at these commits and digests, into the Hub cache itself and
# runs the models offline: what they load is what is listed here.
#
# Each manifest is every file the library's own download would ask for at that commit (its
# allow patterns, so an offline run finds the snapshot complete) plus any file its code reads
# by name. Bumping a revision is a review: read what changed in the repository, run this,
# then read the manifest diff — a changed digest is a changed model.
#
# Needs curl and python3. LFS files are recorded by the digest the Hub publishes for them;
# small files are downloaded and checked against the git blob id the Hub lists for them at
# that commit before their SHA-256 is recorded.
#
# Also the Qwen-Image 2.1 few-step adapters: the app downloads the chosen adapter file itself
# and merges it into the transformer, so what it merges is exactly the file listed here.
#
#   Scripts/pin-hub-models.sh                                   # every repository
#   Scripts/pin-hub-models.sh PrunaAI/Pruna-Qwen-Image-2.1      # only these

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Resources/pinned-installs/models"
mkdir -p "$OUT"

/usr/bin/env python3 - "$OUT" "$@" <<'PY'
import fnmatch, hashlib, json, sys, urllib.request

out = sys.argv[1]
only = set(sys.argv[2:])
# mlx_audio.utils.DEFAULT_ALLOW_PATTERNS (0.5.0) and mlx_speech._hub._DEFAULT_ALLOW_PATTERNS
# (0.5.2); fnmatch's * crosses "/", as it does in huggingface_hub.
MLX_AUDIO = ["*.json", "*.safetensors", "*.py", "*.model", "*.tiktoken", "*.txt", "*.jinja",
             "*.jsonl", "*.yaml", "*.npz", "*.pth"]
MLX_SPEECH = ["*.json", "*.safetensors", "*.py", "*.model", "*.tiktoken", "*.txt", "*.jsonl",
              "*.yaml", "*.jinja"]
KOKORO_VOICES = ["af_heart", "af_bella", "af_nicole", "af_sky", "am_adam", "am_michael",
                 "bf_emma", "bm_george"]

# repository, commit, what to take (patterns, or exact paths)
PINS = [
    # Kokoro: the model, and the voices mlx-audio loads from prince-canuma's repository — the
    # app's eight, each by name.
    ("mlx-community/Kokoro-82M-bf16", "a71e4d38b236d968966a2002c4c895dbd12b1c3c", MLX_AUDIO, []),
    ("prince-canuma/Kokoro-82M", "e02c9eada7ce7416798af36b190a8a2dd2ecd566", [],
     [f"voices/{v}.safetensors" for v in KOKORO_VOICES]),
    # CSM: the model, its speaker prompt (used as the reference when the user gives none, in
    # place of the gated sesame/csm-1b copy), the Llama tokenizer and the Mimi codec.
    ("mlx-community/csm-1b", "5bf5ec118cf45fecc7b51198fd9f1a20a5aab65a", MLX_AUDIO,
     ["prompts/conversational_a.wav"]),
    ("unsloth/Llama-3.2-1B", "9535bd9b1d1dea6acafbdc4813b728796aeb28da", [],
     ["config.json", "tokenizer.json", "tokenizer_config.json", "special_tokens_map.json"]),
    ("kyutai/moshiko-pytorch-bf16", "2bfc9ae6e89079a5cc7ed2a68436010d91a3d289", [],
     ["tokenizer-e351c8d8-checkpoint125.safetensors"]),
    ("mlx-community/whisper-large-v3-turbo-asr-fp16", "624c19c9af5603fa73b83bce14d4aeea96156d18",
     MLX_AUDIO, []),
    ("mlx-community/parakeet-tdt-0.6b-v3", "ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15", MLX_AUDIO, []),
    ("mlx-community/MiniMax-Music3-4bit", "c7ea32923b245fe5afc22d740a1936ad2ac590f3", MLX_AUDIO, []),
    # MOSS SoundEffect through mlx-speech: the model its alias names and its codec.
    ("appautomaton/openmoss-sound-effect-mlx", "e789d108839132af5c49259f6933939edceec303",
     MLX_SPEECH, []),
    ("appautomaton/openmoss-audio-tokenizer-mlx", "3b22b5958c15f807e3ca8faae2cc3b7cc4b74552",
     MLX_SPEECH, []),
    # LuxTTS on the GPU path: its model, vocoder and tokens (not the ONNX files the CPU path
    # uses), and the Whisper it transcribes the reference with.
    ("YatharthS/LuxTTS", "527f245a276a0eb42ea103a7a512bcfd771eb9b6", [],
     ["config.json", "model.pt", "tokens.txt", "vocoder/config.yaml", "vocoder/vocos.bin"]),
    ("openai/whisper-base", "e37978b90ca9030d5170a5c07aadb050351a65bb", [],
     ["added_tokens.json", "config.json", "generation_config.json", "merges.txt",
      "model.safetensors", "normalizer.json", "preprocessor_config.json",
      "special_tokens_map.json", "tokenizer.json", "tokenizer_config.json", "vocab.json"]),
    # Pruna's few-step LoRA adapters for Qwen-Image 2.1: the two adapter files and nothing
    # else. The base model is pinned by revision in DiffusionCatalog.
    ("PrunaAI/Pruna-Qwen-Image-2.1", "113e63bb993001b3411eb3470b84fc444040cd7e", [],
     ["p_qwen_image_2.1_8step_v0.1.safetensors", "p_qwen_image_2.1_5step_v0.1.safetensors"]),
]
unknown = only - {repository for repository, *_ in PINS}
if unknown:
    sys.exit(f"not pinned here: {', '.join(sorted(unknown))}")

def get(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "pin-hub-models"})) as r:
        return r.read()

for repository, commit, patterns, paths in PINS:
    if only and repository not in only:
        continue
    tree = json.loads(get(f"https://huggingface.co/api/models/{repository}/tree/{commit}?recursive=1"))
    files = {entry["path"]: entry for entry in tree if entry["type"] == "file"}
    chosen = sorted({p for p in files if any(fnmatch.fnmatch(p, pattern) for pattern in patterns)}
                    | set(paths))
    records = []
    for path in chosen:
        if path not in files:
            sys.exit(f"{repository}@{commit} has no {path}")
        entry = files[path]
        if entry.get("lfs"):
            sha256 = entry["lfs"]["oid"]
            size = entry["lfs"]["size"]
        else:
            data = get(f"https://huggingface.co/{repository}/resolve/{commit}/{path}")
            blob = hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()
            if blob != entry["oid"] or len(data) != entry["size"]:
                sys.exit(f"{repository}@{commit}/{path} is not the blob the tree lists")
            sha256 = hashlib.sha256(data).hexdigest()
            size = len(data)
        records.append({"path": path, "sha256": sha256, "size": size})
    manifest = {"repository": repository, "revision": commit, "files": records}
    name = repository.replace("/", "--") + ".json"
    with open(f"{out}/{name}", "w") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")
    print(f"{name}: {len(records)} files, {sum(r['size'] for r in records):,} bytes")
PY

#!/bin/bash
# Regenerates the hash-locked Python dependency sets the optional installers use, from each
# project's requirements at the commit the app pins (OpenMontage, LivePortrait, Deep-Live-Cam,
# LuxTTS) or from the app's own package list held to the versions in Scripts/lock-inputs
# (MFLUX and the voice tools, face tracking, Laya). Every artifact pip or uv may install is
# named here by SHA-256, so a changed wheel is refused before any of its code runs.
#
#   Scripts/lock-media-installers.sh                 # everything
#   Scripts/lock-media-installers.sh luxtts laya     # only these
#
# Tools: openmontage liveportrait deep-live-cam silicon-mlx luxtts tracker laya
#
# The commits below must match PinnedInstall in Sources/SiliconControl/PinnedInstall.swift;
# PinnedInstallTests fails when a lock's Source line and the Swift pin disagree. Bumping a
# pin is a review: read the upstream diff, run this, then read the lock diff before
# committing — every added or changed hash is code the app will run.
#
# Needs git and uv. Nothing is built: the source-only packages (insightface, imageio-ffmpeg,
# docopt, jieba, encodec) have their dependencies declared below instead of by running
# setup.py.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Resources/pinned-installs"
# Only packages published by this moment are considered, so a rerun is reproducible.
EXCLUDE_NEWER="${EXCLUDE_NEWER:-$(date -u +%Y-%m-%dT00:00:00Z)}"

OPENMONTAGE_REPOSITORY=https://github.com/calesthio/OpenMontage.git
OPENMONTAGE_COMMIT=08e2151fa02de28a5d6a312b3d575692bf147ad7
LIVEPORTRAIT_REPOSITORY=https://github.com/KwaiVGI/LivePortrait.git
LIVEPORTRAIT_COMMIT=9b294b3d0536135442ea73cb01e6cb3ca7029dd3
DEEPLIVECAM_REPOSITORY=https://github.com/hacksider/Deep-Live-Cam.git
DEEPLIVECAM_COMMIT=d759e31b11d9432afdfddce698c0f7c9a715e086
LUXTTS_REPOSITORY=https://github.com/ysharma3501/LuxTTS.git
LUXTTS_COMMIT=28ae6a61151684fffc9d1a7aa15eafa02286fe0b
LINACODEC_REPOSITORY=https://github.com/ysharma3501/LinaCodec.git
LINACODEC_COMMIT=c0ae7c7285e121475c27592cfbb600624b714290
# Wheels that are not on PyPI, by exact URL; the lock records their SHA-256 like any other.
SPACY_MODEL=https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl
PIPER_PHONEMIZE=https://github.com/csukuangfj/piper-phonemize/releases/download/v1.4.7
INPUTS="$ROOT/Scripts/lock-inputs"

ALL_TOOLS=(openmontage liveportrait deep-live-cam silicon-mlx luxtts tracker laya)
TOOLS=("$@")
[[ ${#TOOLS[@]} -gt 0 ]] || TOOLS=("${ALL_TOOLS[@]}")
for tool in "${TOOLS[@]}"; do
    [[ " ${ALL_TOOLS[*]} " == *" $tool "* ]] || { echo "ERROR: unknown tool $tool" >&2; exit 1; }
done
want() { [[ " ${TOOLS[*]} " == *" $1 "* ]]; }

die() { echo "ERROR: $*" >&2; exit 1; }
command -v uv >/dev/null || die "uv is required (brew install uv)"

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT HUP INT TERM

cat > "$WORK/uv.toml" <<'EOF'
# Static metadata for the source-only packages, read from their setup.py, so resolving never
# runs a build.
[[dependency-metadata]]
name = "insightface"
version = "0.7.3"
requires-dist = ["numpy", "onnx", "tqdm", "requests", "matplotlib", "Pillow", "scipy", "scikit-learn", "scikit-image", "easydict", "cython", "albumentations", "prettytable"]

[[dependency-metadata]]
name = "imageio-ffmpeg"
version = "0.5.1"
requires-python = ">=3.5"
requires-dist = ["setuptools"]

[[dependency-metadata]]
name = "docopt"
version = "0.6.2"
requires-dist = []

[[dependency-metadata]]
name = "jieba"
version = "0.42.1"
requires-dist = []

[[dependency-metadata]]
name = "encodec"
version = "0.1.1"
requires-python = ">=3.8.0"
requires-dist = ["numpy", "torch", "torchaudio", "einops"]
EOF

fetch() {  # repository commit directory
    git init --quiet "$3"
    git -C "$3" fetch --quiet --depth 1 "$1" "$2"
    git -C "$3" -c advice.detachedHead=false checkout --quiet --detach "$2"
    [[ "$(git -C "$3" rev-parse HEAD)" == "$2" ]] || die "$1 did not check out at $2"
}

# compile <output> <python> <title> <repository> <commit> <from> -- <uv pip compile arguments>
compile() {
    local output="$1" python="$2" title="$3" repository="$4" commit="$5" from="$6"
    shift 7
    # Apple Silicon only, like the app; macOS 14 is the app's floor and the first release
    # some of these wheels (onnxruntime-silicon) are built for.
    (cd "$WORK" && MACOSX_DEPLOYMENT_TARGET=14.0 UV_PYTHON_DOWNLOADS=never uv pip compile \
        --config-file "$WORK/uv.toml" --no-build-isolation \
        --python-platform aarch64-apple-darwin --python-version "$python" \
        --generate-hashes --no-header --exclude-newer "$EXCLUDE_NEWER" --quiet \
        -o "$WORK/lock.txt" "$@")
    {
        echo "# $title for Python $python on Apple Silicon (macOS 14+)."
        echo "# Every artifact is hash-pinned: pip and uv refuse anything else."
        echo "# Resolved from: $from"
        echo "# Published by: $EXCLUDE_NEWER"
        echo "# Regenerate with Scripts/lock-media-installers.sh and review the diff."
        # The app's own package lists have no upstream commit to name.
        [[ -z "$repository" ]] || echo "# Source: $repository $commit"
        # Relative paths only: the annotations must not carry this machine's temp folder.
        sed -e "s#$WORK/##g" "$WORK/lock.txt"
    } > "$output"
    if grep -Eq '/(Users|Volumes|private|var/folders|tmp)/' "$output"; then
        die "$output mentions a local path"
    fi
}

# The requirement lines of a lock, without hashes, to hold a later lock to its versions.
pins() { grep -E '^[A-Za-z0-9]' "$1" | sed -e 's/ \\$//'; }

if want openmontage; then
mkdir -p "$OUT/openmontage"
fetch "$OPENMONTAGE_REPOSITORY" "$OPENMONTAGE_COMMIT" "$WORK/openmontage"
cp "$WORK/openmontage/requirements.txt" "$WORK/openmontage-requirements.txt"
echo "piper-tts" > "$WORK/piper.in"
for python in 3.10 3.11 3.12 3.13; do
    compile "$OUT/openmontage/requirements-py$python.txt" "$python" \
        "OpenMontage's dependencies" "$OPENMONTAGE_REPOSITORY" "$OPENMONTAGE_COMMIT" \
        requirements.txt -- openmontage-requirements.txt
    # Piper shares the environment, so it is held to the versions already locked there.
    grep -E '^[A-Za-z0-9]' "$OUT/openmontage/requirements-py$python.txt" \
        | sed -e 's/ \\$//' > "$WORK/openmontage-constraints.txt"
    compile "$OUT/openmontage/piper-py$python.txt" "$python" \
        "Piper, OpenMontage's offline voice" "$OPENMONTAGE_REPOSITORY" "$OPENMONTAGE_COMMIT" \
        "piper-tts within requirements.txt's versions" \
        -- piper.in -c openmontage-constraints.txt
done
fi

if want liveportrait; then
mkdir -p "$OUT/liveportrait"
fetch "$LIVEPORTRAIT_REPOSITORY" "$LIVEPORTRAIT_COMMIT" "$WORK/liveportrait"
cp "$WORK/liveportrait/requirements_base.txt" "$WORK/requirements_base.txt"
cp "$WORK/liveportrait/requirements_macOS.txt" "$WORK/requirements_macOS.txt"
# LivePortrait's vendored insightface imports requests without declaring it.
echo "requests" > "$WORK/liveportrait-extras.in"
compile "$OUT/liveportrait/requirements-py3.11.txt" 3.11 \
    "LivePortrait's dependencies" "$LIVEPORTRAIT_REPOSITORY" "$LIVEPORTRAIT_COMMIT" \
    "requirements_macOS.txt plus requests" \
    -- requirements_macOS.txt liveportrait-extras.in \
    --index-strategy unsafe-best-match --emit-index-url
# imageio-ffmpeg has no Apple Silicon wheel; it is built from its hashed source with this
# setuptools, installed first, instead of whatever an isolated build would download.
grep -E '^[A-Za-z0-9]' "$OUT/liveportrait/requirements-py3.11.txt" \
    | sed -e 's/ \\$//' > "$WORK/liveportrait-constraints.txt"
echo "setuptools" > "$WORK/liveportrait-build.in"
compile "$OUT/liveportrait/build-py3.11.txt" 3.11 \
    "LivePortrait's build tools" "$LIVEPORTRAIT_REPOSITORY" "$LIVEPORTRAIT_COMMIT" \
    "the build requirements of its source-only dependencies" \
    -- liveportrait-build.in -c liveportrait-constraints.txt
fi

if want deep-live-cam; then
mkdir -p "$OUT/deep-live-cam"
fetch "$DEEPLIVECAM_REPOSITORY" "$DEEPLIVECAM_COMMIT" "$WORK/deep-live-cam"
cp "$WORK/deep-live-cam/requirements.txt" "$WORK/deep-live-cam-requirements.txt"
# insightface is source-only; its pyproject builds with these, installed first.
printf 'setuptools\ncython\nnumpy\n' > "$WORK/deep-live-cam-build.in"
for python in 3.12 3.13; do
    compile "$OUT/deep-live-cam/requirements-py$python.txt" "$python" \
        "Deep-Live-Cam's dependencies" "$DEEPLIVECAM_REPOSITORY" "$DEEPLIVECAM_COMMIT" \
        requirements.txt -- deep-live-cam-requirements.txt
    grep -E '^[A-Za-z0-9]' "$OUT/deep-live-cam/requirements-py$python.txt" \
        | sed -e 's/ \\$//' > "$WORK/deep-live-cam-constraints.txt"
    compile "$OUT/deep-live-cam/build-py$python.txt" "$python" \
        "Deep-Live-Cam's build tools" "$DEEPLIVECAM_REPOSITORY" "$DEEPLIVECAM_COMMIT" \
        "the build requirements of its source-only dependencies" \
        -- deep-live-cam-build.in -c deep-live-cam-constraints.txt
done
fi

# MFLUX and the voice tools share ~/.silicon-mlx, so the voice lock is held to MFLUX's
# versions and either can be installed over the other without moving a package. mlx-speech
# needs Python 3.13, so the voice tools start there.
if want silicon-mlx; then
mkdir -p "$OUT/silicon-mlx"
cp "$INPUTS/silicon-mlx-tested.txt" "$WORK/silicon-mlx-tested.txt"
echo "mflux==0.18.1" > "$WORK/mflux.in"
cat > "$WORK/voice.in" <<EOF
mlx-audio==0.5.0
mlx-speech==0.5.2
misaki==0.7.4
num2words==0.5.14
spacy==3.8.13
phonemizer==3.4.0
espeakng-loader==0.2.4
en_core_web_sm @ $SPACY_MODEL
EOF
# docopt (num2words') is source-only; it builds with this setuptools, installed first.
echo "setuptools" > "$WORK/voice-build.in"
for python in 3.12 3.13 3.14; do
    compile "$OUT/silicon-mlx/mflux-py$python.txt" "$python" \
        "MFLUX" "" "" "mflux==0.18.1 within Scripts/lock-inputs/silicon-mlx-tested.txt" \
        -- mflux.in -c silicon-mlx-tested.txt
    [[ "$python" == 3.12 ]] && continue
    pins "$OUT/silicon-mlx/mflux-py$python.txt" > "$WORK/mflux-constraints.txt"
    compile "$OUT/silicon-mlx/voice-py$python.txt" "$python" \
        "The voice tools" "" "" "the app's voice package list within MFLUX's and the tested versions" \
        -- voice.in -c silicon-mlx-tested.txt -c mflux-constraints.txt
    pins "$OUT/silicon-mlx/voice-py$python.txt" > "$WORK/voice-constraints.txt"
    compile "$OUT/silicon-mlx/build-py$python.txt" "$python" \
        "The voice tools' build tools" "" "" "the build requirements of their source-only dependencies" \
        -- voice-build.in -c voice-constraints.txt
done
fi

# LuxTTS's requirements, less the two lines pip cannot hash-check: its LinaCodec is a git
# dependency, fetched by commit and verified like any pinned source and installed without
# its dependencies, which are declared here instead; and piper_phonemize comes from a
# third-party wheel page, replaced by the exact release wheel for each Python.
if want luxtts; then
mkdir -p "$OUT/luxtts"
cp "$INPUTS/luxtts-tested.txt" "$WORK/luxtts-tested.txt"
fetch "$LUXTTS_REPOSITORY" "$LUXTTS_COMMIT" "$WORK/luxtts"
fetch "$LINACODEC_REPOSITORY" "$LINACODEC_COMMIT" "$WORK/linacodec"
grep -q '^git+https://github.com/ysharma3501/LinaCodec.git$' "$WORK/luxtts/requirements.txt" \
    || die "LuxTTS no longer names LinaCodec the way this script expects"
grep -vE '^(--find-links|git\+)' "$WORK/luxtts/requirements.txt" > "$WORK/luxtts-requirements.txt"
# LinaCodec's own dependencies, from its pyproject at the pinned commit.
sed -n '/^dependencies = \[/,/^\]/p' "$WORK/linacodec/pyproject.toml" \
    | sed -n 's/^ *"\(.*\)",*$/\1/p' > "$WORK/linacodec-dependencies.in"
[[ -s "$WORK/linacodec-dependencies.in" ]] || die "could not read LinaCodec's dependencies"
# LinaCodec builds with uv_build; jieba and encodec are source-only and build with setuptools.
sed -n 's/^requires = \["\(uv_build[^"]*\)"\]$/\1/p' "$WORK/linacodec/pyproject.toml" > "$WORK/luxtts-build.in"
[[ -s "$WORK/luxtts-build.in" ]] || die "could not read LinaCodec's build backend"
echo "setuptools" >> "$WORK/luxtts-build.in"
for python in 3.12 3.13 3.14; do
    tag="cp${python/./}"
    echo "piper_phonemize @ $PIPER_PHONEMIZE/piper_phonemize-1.4.7-$tag-$tag-macosx_11_0_arm64.whl" \
        > "$WORK/piper-phonemize.in"
    compile "$OUT/luxtts/requirements-py$python.txt" "$python" \
        "LuxTTS's dependencies" "$LUXTTS_REPOSITORY" "$LUXTTS_COMMIT" \
        "requirements.txt, LinaCodec $LINACODEC_COMMIT's dependencies and piper_phonemize 1.4.7, within Scripts/lock-inputs/luxtts-tested.txt" \
        -- luxtts-requirements.txt linacodec-dependencies.in piper-phonemize.in -c luxtts-tested.txt
    pins "$OUT/luxtts/requirements-py$python.txt" > "$WORK/luxtts-constraints.txt"
    compile "$OUT/luxtts/build-py$python.txt" "$python" \
        "LuxTTS's build tools" "$LUXTTS_REPOSITORY" "$LUXTTS_COMMIT" \
        "LinaCodec's build backend and the build requirements of the source-only dependencies" \
        -- luxtts-build.in -c luxtts-constraints.txt
done
fi

if want tracker; then
mkdir -p "$OUT/tracker"
cp "$INPUTS/tracker-tested.txt" "$WORK/tracker-tested.txt"
# The 1.x MediaPipe wheels abort inside the landmarker graph on Apple Silicon.
printf 'mediapipe==0.10.35\npython-osc==1.10.2\nopencv-python==5.0.0.93\n' > "$WORK/tracker.in"
for python in 3.12 3.13 3.14; do
    compile "$OUT/tracker/requirements-py$python.txt" "$python" \
        "Face tracking's dependencies" "" "" "the app's tracker package list within the tested versions" \
        -- tracker.in -c tracker-tested.txt
done
fi

if want laya; then
mkdir -p "$OUT/laya"
cp "$INPUTS/laya-tested.txt" "$WORK/laya-tested.txt"
echo "laya-mlx==0.1.0" > "$WORK/laya.in"
for python in 3.11 3.12 3.13 3.14; do
    # The tested NumPy needs 3.12; 3.11 takes the newest one that still supports it.
    if [[ "$python" == 3.11 ]]; then
        grep -v '^numpy==' "$WORK/laya-tested.txt" > "$WORK/laya-constraints.txt"
    else
        cp "$WORK/laya-tested.txt" "$WORK/laya-constraints.txt"
    fi
    compile "$OUT/laya/requirements-py$python.txt" "$python" \
        "Laya's dependencies" "" "" "laya-mlx==0.1.0 within the tested versions" \
        -- laya.in -c laya-constraints.txt
done
fi

echo "Wrote $(find "$OUT" -name '*.txt' | wc -l | tr -d ' ') locks to Resources/pinned-installs."

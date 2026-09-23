#!/bin/bash
# Regenerates the hash-locked Python dependency sets the optional media installers use
# (OpenMontage, LivePortrait, Deep-Live-Cam), from each project's requirements at the
# commit the app pins. Every artifact pip or uv may install is named here by SHA-256, so a
# changed wheel is refused before any of its code runs.
#
# The commits below must match PinnedInstall in Sources/SiliconControl/PinnedInstall.swift;
# PinnedInstallTests fails when a lock's Source line and the Swift pin disagree. Bumping a
# pin is a review: read the upstream diff, run this, then read the lock diff before
# committing — every added or changed hash is code the app will run.
#
# Needs git and uv. Nothing is built: the two source-only packages (insightface and
# imageio-ffmpeg) have their dependencies declared below instead of by running setup.py.

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
        echo "# Source: $repository $commit"
        # Relative paths only: the annotations must not carry this machine's temp folder.
        sed -e "s#$WORK/##g" "$WORK/lock.txt"
    } > "$output"
    if grep -Eq '/(Users|Volumes|private|var/folders|tmp)/' "$output"; then
        die "$output mentions a local path"
    fi
}

mkdir -p "$OUT/openmontage" "$OUT/liveportrait" "$OUT/deep-live-cam"

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

echo "Wrote $(find "$OUT" -name '*.txt' | wc -l | tr -d ' ') locks to Resources/pinned-installs."

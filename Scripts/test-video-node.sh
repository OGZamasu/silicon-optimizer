#!/bin/bash
# Runs the local video node's Python tests: the adapter and its installer, then the batch and
# gallery example. They use temporary directories, fake renderers and loopback-only servers —
# no weights, no GPU, no network, and no real LaunchAgent is touched.
#
# Run it before pushing a change under Resources/video-node/. python3 is whatever this Mac
# has; the node itself uses only the standard library.

set -euo pipefail

cd "$(dirname "$0")/.."

python3 --version
python3 -m unittest discover -s Resources/video-node -p 'test_*.py' -v
python3 -m unittest discover -s Resources/video-node/examples -p 'test_*.py' -v

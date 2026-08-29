#!/usr/bin/env bash
# Verify this repository's copy of the Mac<->node wire contract.
#
# contract/ is a copy of silicon-node's canonical fixtures. Editing them here
# without copying the directory over there is how one contract quietly becomes
# two, so the digest both repositories record has to match what is on disk.
#
# Run it before pushing a change that touches contract/. The Swift half of the
# checking — the real parsers reading these same files — is
# Tests/SiliconTests/ContractFixtureTests.swift, run by `swift test`.
set -euo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import hashlib, json, pathlib, sys

directory = pathlib.Path("contract")
files = sorted(directory.glob("*.json"))
if len(files) != 6:
    sys.exit(f"expected 6 fixtures in contract/, found {len(files)}")

digest = hashlib.sha256()
for path in files:
    json.loads(path.read_text())  # a fixture that is not JSON is not a contract
    digest.update(path.name.encode())
    digest.update(path.read_bytes())

recorded = (directory / "VERSION.sha256").read_text().split()[0]
if digest.hexdigest() != recorded:
    sys.exit(
        "contract/ does not match VERSION.sha256\n"
        f"  on disk:   {digest.hexdigest()}\n"
        f"  recorded:  {recorded}\n"
        "Copy the directory from silicon-node (or to it) and update both digests."
    )
print(f"contract/ matches {recorded}")
PY

test -f Tests/SiliconTests/ContractFixtureTests.swift \
    || { echo "Tests/SiliconTests/ContractFixtureTests.swift is missing: the fixtures" \
              "would be checksum-checked and nothing else." >&2; exit 1; }

echo "Contract copy verified."

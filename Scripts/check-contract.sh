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
import hashlib, json, pathlib, re, sys

directory = pathlib.Path("contract")
files = sorted(directory.glob("*.json"))

# The digest covers whatever *.json is on disk, so a fixture dropped or added with the
# digest recomputed would still match it. The README's Files table is the list of what the
# contract holds, and it travels with the fixtures from silicon-node, so the set on disk has
# to be the set it documents — rather than a count edited by hand each time a fixture lands.
readme = (directory / "README.md").read_text(encoding="utf-8")
documented = sorted(set(re.findall(r"^\| `([^`/]+\.json)` \|", readme, re.MULTILINE)))
if not documented:
    sys.exit("contract/README.md lists no fixtures in its Files table")
on_disk = [path.name for path in files]
if on_disk != documented:
    missing = sorted(set(documented) - set(on_disk))
    unlisted = sorted(set(on_disk) - set(documented))
    sys.exit(
        "contract/ does not hold the fixtures its README lists\n"
        f"  listed but missing:  {', '.join(missing) or '-'}\n"
        f"  on disk but unlisted: {', '.join(unlisted) or '-'}"
    )

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

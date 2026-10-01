#!/usr/bin/env python3
"""ElevenLabs' WebSocket APIs, as pinned AsyncAPI documents: extract, outline, diff.

The WebSocket APIs are not in the OpenAPI spec. ElevenLabs publishes each socket's AsyncAPI 2.6
YAML inside the `.md` form of its API-reference page. This script needs no YAML library: it reads
the generated YAML's structure by indentation (keys, lists, block scalars), which is all a drift
report needs.

  elevenlabs-asyncapi.py extract PAGE.md            # the ```yaml block of a docs page, to stdout
  elevenlabs-asyncapi.py outline FILE.yaml          # one line per key path: path = value
  elevenlabs-asyncapi.py diff PINNED LIVE           # added / removed / changed; exit 3 on drift

`diff` takes a `.yaml` file or a `.md` page on either side. Descriptions and titles are prose: a
change there is listed under "wording" and still counts as drift.
"""
import re
import sys

PROSE_KEYS = {"description", "title", "summary"}
BLOCK = re.compile(r"^[>|][+-]?\d*$")
KEY = re.compile(r"^((?:'[^']*'|\"[^\"]*\"|[^:#'\"\s][^:#]*?)):(?:\s+(.*))?$")


def extract(text):
    match = re.search(r"```yaml\n(.*?)\n```", text, re.S)
    if not match:
        raise SystemExit("no ```yaml block in the page")
    return match.group(1) + "\n"


def load(path):
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    return extract(text) if path.endswith(".md") else text


def unquote(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
        return value[1:-1]
    return value


def outline(text):
    """Every leaf as (path, value). Lists of scalars become `path[] = item` lines, lists of maps
    `path[i].key`. Block scalars and multi-line plain scalars are joined into one value."""
    entries = []
    stack = []  # (indent, path) of the open mappings and list items
    lines = text.splitlines()
    counters = {}

    def parent(indent):
        while stack and stack[-1][0] >= indent:
            stack.pop()
        return stack[-1][1] if stack else ""

    def continuation(start, owner_indent):
        """The lines after `start - 1` indented deeper than the owner, joined; and where they end."""
        parts = []
        cursor = start
        while cursor < len(lines):
            line = lines[cursor]
            if line.strip() and (len(line) - len(line.lstrip(" "))) <= owner_indent:
                break
            if line.strip():
                parts.append(line.strip())
            cursor += 1
        return " ".join(parts), cursor

    index = 0
    while index < len(lines):
        raw = lines[index]
        content = raw.strip()
        if not content or content.startswith("#"):
            index += 1
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        if content == "-" or content.startswith("- "):
            base = parent(indent)
            position = counters.get((base, indent), -1) + 1
            counters[(base, indent)] = position
            item = content[1:].strip()
            if not item or KEY.match(item):
                # A map in the list: its first key sits on the dash's line.
                stack.append((indent, f"{base}[{position}]"))
                if item:
                    lines[index] = " " * (indent + 2) + item
                else:
                    index += 1
                continue
            rest, index = continuation(index + 1, indent)
            entries.append((f"{base}[]", unquote(item + (" " + rest if rest else ""))))
            continue
        match = KEY.match(content)
        if not match:
            index += 1
            continue
        key = unquote(match.group(1))
        value = (match.group(2) or "").strip()
        base = parent(indent)
        path = f"{base}.{key}" if base else key
        for counter in [c for c in counters if c[0] == path or c[0].startswith(path + ".") or c[0].startswith(path + "[")]:
            del counters[counter]
        if value:
            rest, index = continuation(index + 1, indent)
            if BLOCK.match(value):
                entries.append((path, rest))
            else:
                entries.append((path, unquote(value + (" " + rest if rest else ""))))
            continue
        stack.append((indent, path))
        index += 1
    return entries


def keyed(entries):
    """Paths to values; a list of scalars becomes one sorted value, so order changes are noise."""
    result = {}
    for path, value in entries:
        if path.endswith("[]"):
            result.setdefault(path, [])
            result[path].append(value)
        else:
            result[path] = value
    return {path: (", ".join(sorted(v)) if isinstance(v, list) else v) for path, v in result.items()}


def is_prose(path):
    last = re.sub(r"\[\d*\]$", "", path.rsplit(".", 1)[-1])
    return last in PROSE_KEYS


def diff(pinned, live):
    old, new = keyed(outline(pinned)), keyed(outline(live))
    added = sorted(p for p in new if p not in old)
    removed = sorted(p for p in old if p not in new)
    changed = sorted(p for p in old if p in new and old[p] != new[p])
    structural = [p for p in added + removed + changed if not is_prose(p)]
    wording = [p for p in added + removed + changed if is_prose(p)]
    for path in added:
        if not is_prose(path):
            print(f"+ {path} = {short(new[path])}")
    for path in removed:
        if not is_prose(path):
            print(f"- {path} = {short(old[path])}")
    for path in changed:
        if not is_prose(path):
            print(f"~ {path}: {short(old[path])} -> {short(new[path])}")
    if wording:
        print(f"wording changed at {len(wording)} place(s):")
        for path in wording[:40]:
            print(f"  ~ {path}")
        if len(wording) > 40:
            print(f"  … and {len(wording) - 40} more")
    return 3 if structural or wording else 0


def short(value, limit=160):
    return value if len(value) <= limit else value[:limit] + "…"


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        print(__doc__)
        return 0
    command = argv[1]
    if command == "extract" and len(argv) == 3:
        with open(argv[2], encoding="utf-8") as handle:
            sys.stdout.write(extract(handle.read()))
        return 0
    if command == "outline" and len(argv) == 3:
        for path, value in outline(load(argv[2])):
            print(f"{path} = {value}")
        return 0
    if command == "diff" and len(argv) == 4:
        return diff(load(argv[2]), load(argv[3]))
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))

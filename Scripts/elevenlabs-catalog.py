#!/usr/bin/env python3
"""Turns the pinned ElevenLabs OpenAPI snapshot into the catalog the app ships.

    Scripts/elevenlabs-catalog.py                 # regenerate the catalog from the snapshot
    Scripts/elevenlabs-catalog.py --check         # fail if the committed catalog is stale
    Scripts/elevenlabs-catalog.py diff OLD NEW    # added / removed / changed operations

The snapshot is Scripts/elevenlabs/openapi.json. The catalog is a Swift file with the compact
catalog as one JSON array (one operation per line, so a refresh reads as a diff), embedded in
the SiliconElevenLabs module rather than shipped as a SwiftPM resource: the app bundle is
assembled by Scripts/build-app.sh, which carries no resource bundles.

What is kept per operation: id, method, path, a display group, summary, description
(truncated), deprecated, the path/query/header parameters without `xi-api-key` (the client
adds it), the request body (JSON or multipart, with its file fields), the response kind and
whether the operation streams. `$ref`s are resolved inline to a bounded depth with a cycle
guard; what is cut off keeps its name, type and enum. Risk, billability and credential
handling are not here: they come from the reviewed table in ElevenLabsRiskTable.swift.

Standard library only. No network: refreshing the snapshot is Scripts/check-elevenlabs-spec.sh.
"""

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SPEC = ROOT / "Scripts" / "elevenlabs" / "openapi.json"
OUT = ROOT / "Sources" / "SiliconElevenLabs" / "Generated" / "ElevenLabsCatalogData.swift"

METHODS = ("get", "post", "put", "patch", "delete")

# How deep inline schemas go (object and array levels). Deeper than this, a `$ref` is kept
# by name with its type and enum; the explorer edits such a value as JSON.
MAX_DEPTH = 5
OPERATION_DESCRIPTION_LIMIT = 1500
PARAMETER_DESCRIPTION_LIMIT = 500
SCHEMA_DESCRIPTION_LIMIT = (400, 200)  # at the top two levels, below them
EXAMPLE_LIMIT = 200

SCHEMA_KEYS = {
    "type", "format", "enum", "const", "default", "required", "properties", "items",
    "anyOf", "oneOf", "allOf", "description", "title", "minimum", "maximum",
    "exclusiveMinimum", "exclusiveMaximum", "minLength", "maxLength", "minItems", "maxItems",
    "pattern", "additionalProperties", "nullable", "examples", "discriminator", "deprecated",
}

# Display groups: the first rule whose pattern matches the path wins. Operations no rule
# names (a spec refresh can add any) fall back to their tag, then their first path segment.
GROUP_RULES = [
    (r"^/v1/(user|usage)(/|$)|^/v1/single-use-token/|^/v1/workspace/analytics/", "Account and usage"),
    (r"^/v1/text-to-speech/", "Text to speech"),
    (r"^/v1/text-to-dialogue(/|$)", "Text to dialogue"),
    (r"^/v1/speech-to-speech/", "Voice changer"),
    (r"^/v1/sound-generation$", "Sound effects"),
    (r"^/v1/music/finetunes", "Music finetunes"),
    (r"^/v1/music(/|$)", "Music"),
    (r"^/v1/audio-isolation(/|$)", "Audio isolation"),
    (r"^/v1/speech-to-text(/|$)", "Speech to text"),
    (r"^/v1/forced-alignment$", "Forced alignment"),
    (r"^/v1/history(/|$)", "History"),
    (r"^/v1/models$", "Models"),
    (r"^/v1/text-to-voice(/|$)", "Voice design"),
    (r"^/v1/voices/pvc(/|$)", "Professional voice cloning"),
    (r"^/v1/(shared-voices|similar-voices)$|^/v1/voices/add/\{public_user_id\}/", "Voice library"),
    (r"^/v[12]/voices(/|$)", "Voices"),
    (r"^/v1/dubbing/resource/", "Dubbing resources (deprecated)"),
    (r"^/v1/dubbing/project(/|$)", "Dubbing projects"),
    (r"^/v1/dubbing(/|$)", "Dubbing"),
    (r"^/v1/studio/", "Studio"),
    (r"^/v1/productions/", "Productions"),
    (r"^/v1/flows/", "Flows"),
    (r"^/v1/assets(/|$)", "Assets"),
    (r"^/v1/pronunciation-dictionaries(/|$)", "Pronunciation dictionaries"),
    (r"^/v1/audio-native(/|$)", "Audio Native"),
    (r"^/v1/speech-engine(/|$)", "Speech engine"),
    (r"^/v1/convai/(twilio|exotel|whatsapp|sip-trunk)/", "Agent calls and messages"),
    (r"^/v1/convai/batch-calling/", "Batch calling"),
    (r"^/v1/convai/(v2/)?phone-numbers|^/v1/convai/whatsapp-accounts", "Phone numbers"),
    (r"^/v1/convai/knowledge-base|^/v1/convai/agents?/\{agent_id\}/knowledge-base/", "Knowledge base"),
    (r"^/v1/convai/tools(/|$)", "Agent tools"),
    (r"^/v1/convai/mcp-servers(/|$)", "MCP servers"),
    (r"^/v1/convai/secrets(/|$)", "Secrets"),
    (r"^/v1/convai/environment-variables(/|$)", "Environment variables"),
    (r"^/v1/convai/settings(/|$)", "Agent settings"),
    (r"^/v1/convai/(agent-testing|test-invocations)(/|$)"
     r"|^/v1/convai/agents/\{agent_id\}/(run-tests|simulate-conversation)", "Agent testing"),
    (r"^/v1/convai/triage-tickets(/|$)|^/v1/convai/agents/\{agent_id\}/triage-tickets", "Triage tickets"),
    (r"^/v1/convai/(conversations|conversation|users|tags)(/|$)", "Conversations"),
    (r"^/v1/convai/(analytics|llm-usage|llm)/|^/v1/convai/agent/\{agent_id\}/llm-usage/", "Agent analytics and LLMs"),
    (r"^/v1/convai/agents?(/|$)", "Agents"),
    (r"^/v1/workspace/webhooks(/|$)", "Webhooks"),
    (r"^/v1/service-accounts(/|$)|^/v1/workspaces/api-keys/", "Service accounts and API keys"),
    (r"^/v1/workspace(/|$)", "Workspace"),
    (r"^/docs$", "Documentation"),
]

GROUP_ORDER = [
    "Account and usage", "Text to speech", "Text to dialogue", "Voice changer", "Sound effects",
    "Music", "Music finetunes", "Audio isolation", "Speech to text", "Forced alignment",
    "History", "Models", "Voices", "Voice design", "Voice library", "Professional voice cloning",
    "Dubbing", "Dubbing projects", "Dubbing resources (deprecated)", "Studio", "Productions",
    "Flows", "Assets", "Pronunciation dictionaries", "Audio Native", "Speech engine", "Agents",
    "Conversations", "Knowledge base", "Agent tools", "Agent testing", "Triage tickets",
    "Phone numbers", "Agent calls and messages", "Batch calling", "MCP servers", "Secrets",
    "Environment variables", "Agent settings", "Agent analytics and LLMs", "Workspace",
    "Webhooks", "Service accounts and API keys", "Documentation",
]

# Responses the spec leaves without a content type, named from the operation's description.
RESPONSE_OVERRIDES = {
    # "Stream the audio from a Studio project snapshot."
    "stream_project_snapshot_audio_endpoint": ("audio", None),
}


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def truncate(text, limit):
    text = (text or "").strip()
    return text if len(text) <= limit else text[: limit - 1].rstrip() + "…"


class Resolver:
    def __init__(self, schemas):
        self.schemas = schemas

    def resolve(self, node, depth=0, stack=()):
        if isinstance(node, list):
            return [self.resolve(item, depth, stack) for item in node]
        if not isinstance(node, dict):
            return node
        if "$ref" in node:
            name = node["$ref"].rsplit("/", 1)[-1]
            target = self.schemas.get(name, {})
            siblings = {k: v for k, v in node.items() if k != "$ref"}
            if name in stack or depth >= MAX_DEPTH:
                cut = {"x-ref": name, "x-truncated": True}
                for key in ("type", "enum", "title", "const"):
                    if key in target:
                        cut[key] = target[key]
                description = siblings.get("description") or target.get("description")
                if description:
                    cut["description"] = truncate(description, SCHEMA_DESCRIPTION_LIMIT[1])
                return cut
            resolved = self.resolve(target, depth, stack + (name,))
            # A reference's own description and default describe this use of the type.
            for key, value in self.resolve(siblings, depth, stack).items():
                resolved[key] = value
            return resolved
        out = {}
        for key, value in node.items():
            if key not in SCHEMA_KEYS:
                continue
            if key == "properties":
                out[key] = {name: self.resolve(inner, depth + 1, stack) for name, inner in value.items()}
            elif key in ("items", "additionalProperties") and isinstance(value, dict):
                out[key] = self.resolve(value, depth + 1, stack)
            elif key in ("anyOf", "oneOf", "allOf"):
                out[key] = [self.resolve(item, depth, stack) for item in value]
            elif key == "description":
                limit = SCHEMA_DESCRIPTION_LIMIT[0] if depth < 2 else SCHEMA_DESCRIPTION_LIMIT[1]
                out[key] = truncate(value, limit)
            elif key == "examples":
                if isinstance(value, list) and value:
                    example = value[0]
                    if len(json.dumps(example)) <= EXAMPLE_LIMIT:
                        out[key] = [example]
            elif key == "discriminator":
                out[key] = {"propertyName": value.get("propertyName")}
            else:
                out[key] = value
        # `allOf` with one member is how the spec attaches a description to a reference.
        if "allOf" in out and len(out["allOf"]) == 1 and isinstance(out["allOf"][0], dict):
            merged = dict(out.pop("allOf")[0])
            merged.update(out)
            out = merged
        return out


def unwrap_nullable(schema):
    variants = schema.get("anyOf")
    if isinstance(variants, list):
        concrete = [v for v in variants if v.get("type") != "null"]
        if len(concrete) == 1:
            return concrete[0]
    return schema


def is_file(schema):
    schema = unwrap_nullable(schema)
    if schema.get("format") == "binary":
        return True
    if schema.get("type") == "array" and isinstance(schema.get("items"), dict):
        return is_file(schema["items"])
    return False


def group_for(path, tags):
    for pattern, name in GROUP_RULES:
        if re.search(pattern, path):
            return name
    if tags:
        return tags[0].replace("-", " ").replace("_", " ").strip().capitalize()
    segments = [s for s in path.split("/") if s and not s.startswith("v")]
    return segments[0].replace("-", " ").capitalize() if segments else "Other"


def response_kind(operation):
    override = RESPONSE_OVERRIDES.get(operation["operationId"])
    if override:
        return {"kind": override[0], "contentType": override[1]}
    for code, response in operation.get("responses", {}).items():
        if not code.startswith("2"):
            continue
        content = response.get("content") or {}
        if not content:
            continue
        first, schema = next(iter(content.items()))
        schema = schema.get("schema") or {}
        if first == "application/json":
            return {"kind": "json"}
        if first == "text/event-stream":
            return {"kind": "events"}
        if first == "multipart/mixed":
            return {"kind": "multipartMixed"}
        if first.startswith("audio/"):
            return {"kind": "audio"}
        if first in ("text/html", "text/plain") and schema.get("format") != "binary":
            return {"kind": "text"}
        return {"kind": "binary", "contentType": first}
    return {"kind": "json"}


def supports_streaming(path, operation):
    if operation.get("x-fern-streaming") is True or operation.get("x-fern-sdk-streaming") is True:
        return True
    return "stream" in path.split("/")


def build(spec):
    resolver = Resolver(spec.get("components", {}).get("schemas", {}))
    operations = []
    for path, item in spec["paths"].items():
        shared = item.get("parameters", [])
        for method in METHODS:
            operation = item.get(method)
            if operation is None:
                continue
            parameters = []
            for parameter in shared + operation.get("parameters", []):
                if "$ref" in parameter:
                    parameter = resolver.resolve(parameter)
                if parameter.get("in") == "header" and parameter.get("name", "").lower() == "xi-api-key":
                    continue
                if parameter.get("in") not in ("path", "query", "header"):
                    continue
                schema = resolver.resolve(parameter.get("schema", {}))
                entry = {
                    "name": parameter["name"],
                    "location": parameter["in"],
                    "required": bool(parameter.get("required", parameter["in"] == "path")),
                    "description": truncate(
                        parameter.get("description") or schema.get("description", ""),
                        PARAMETER_DESCRIPTION_LIMIT,
                    ),
                    "schema": schema,
                }
                if "default" in schema:
                    entry["defaultValue"] = schema["default"]
                parameters.append(entry)
            body = None
            request = operation.get("requestBody")
            if request:
                content = request.get("content", {})
                if "multipart/form-data" in content:
                    kind, media = "multipart", content["multipart/form-data"]
                else:
                    kind, media = "json", content.get("application/json", next(iter(content.values())))
                schema = resolver.resolve(media.get("schema", {}))
                files = [name for name, prop in (schema.get("properties") or {}).items() if is_file(prop)]
                body = {
                    "contentType": kind,
                    "required": bool(request.get("required", False)),
                    "schema": schema,
                    "fileFields": files,
                }
            operations.append({
                "id": operation["operationId"],
                "method": method.upper(),
                "path": path,
                "group": group_for(path, operation.get("tags") or []),
                "summary": truncate(operation.get("summary", ""), 200),
                "details": truncate(operation.get("description", ""), OPERATION_DESCRIPTION_LIMIT),
                "deprecated": bool(operation.get("deprecated", False)),
                "parameters": parameters,
                "body": body,
                "response": response_kind(operation),
                "supportsStreaming": supports_streaming(path, operation),
            })
    order = {name: index for index, name in enumerate(GROUP_ORDER)}
    indexed = list(enumerate(operations))
    indexed.sort(key=lambda pair: (order.get(pair[1]["group"], len(order)), pair[1]["group"], pair[0]))
    return [operation for _, operation in indexed]


def render(operations, digest):
    lines = [json.dumps(op, sort_keys=True, ensure_ascii=False, separators=(",", ":")) for op in operations]
    payload = "[\n" + ",\n".join(lines) + "\n]"
    if '"""#' in payload:
        raise SystemExit("the catalog contains a raw-string terminator; bump the delimiter")
    groups = []
    for op in operations:
        if op["group"] not in groups:
            groups.append(op["group"])
    return (
        "// Generated by Scripts/elevenlabs-catalog.py from Scripts/elevenlabs/openapi.json.\n"
        "// Do not edit: change the script or the snapshot and run it again.\n"
        "// swiftlint:disable all\n\n"
        "extension ElevenLabsCatalog {\n"
        f'    static let generatedSpecSHA256 = "{digest}"\n'
        f"    static let generatedOperationCount = {len(operations)}\n"
        f"    static let generatedGroupCount = {len(groups)}\n"
        "    static let generatedJSON = #\"\"\"\n"
        f"{payload}\n"
        "\"\"\"#\n"
        "}\n"
    )


# MARK: - Diff

def signature(spec):
    """Per operation id: what a client depends on."""
    result = {}
    for path, item in spec.get("paths", {}).items():
        for method in METHODS:
            operation = item.get(method)
            if not operation:
                continue
            params = sorted(
                (p.get("in", "?"), p.get("name", p.get("$ref", "?")), bool(p.get("required", False)))
                for p in operation.get("parameters", [])
            )
            request = operation.get("requestBody") or {}
            content = request.get("content") or {}
            body = None
            if content:
                media_type, media = next(iter(content.items()))
                schema = media.get("schema", {})
                ref = schema.get("$ref", "")
                name = ref.rsplit("/", 1)[-1] if ref else None
                target = spec.get("components", {}).get("schemas", {}).get(name, schema) if name else schema
                body = {
                    "contentType": media_type,
                    "required": sorted(target.get("required", [])),
                    "properties": sorted((target.get("properties") or {}).keys()),
                }
            responses = sorted(
                (code, tuple(sorted((r.get("content") or {}).keys())))
                for code, r in operation.get("responses", {}).items() if code.startswith("2")
            )
            result[operation.get("operationId", f"{method.upper()} {path}")] = {
                "method": method.upper(), "path": path, "parameters": params, "body": body,
                "responses": responses, "deprecated": bool(operation.get("deprecated", False)),
            }
    return result


def diff(old_path, new_path, out=sys.stdout):
    old = signature(json.loads(Path(old_path).read_text()))
    new = signature(json.loads(Path(new_path).read_text()))
    added = sorted(set(new) - set(old))
    removed = sorted(set(old) - set(new))
    changed = []
    for op_id in sorted(set(old) & set(new)):
        aspects = [key for key in ("method", "path", "parameters", "body", "responses", "deprecated")
                   if old[op_id][key] != new[op_id][key]]
        if aspects:
            changed.append((op_id, aspects))
    print(f"operations: {len(old)} pinned, {len(new)} live", file=out)
    print(f"added: {len(added)}", file=out)
    for op_id in added:
        print(f"  + {op_id}  {new[op_id]['method']} {new[op_id]['path']}", file=out)
    print(f"removed: {len(removed)}", file=out)
    for op_id in removed:
        print(f"  - {op_id}  {old[op_id]['method']} {old[op_id]['path']}", file=out)
    print(f"changed: {len(changed)}", file=out)
    for op_id, aspects in changed:
        print(f"  ~ {op_id}  ({', '.join(aspects)})", file=out)
    return 0 if not (added or removed or changed) else 3


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", nargs="?", default="generate", choices=["generate", "diff"])
    parser.add_argument("files", nargs="*")
    parser.add_argument("--spec", type=Path, default=SPEC)
    parser.add_argument("--out", type=Path, default=OUT)
    parser.add_argument("--check", action="store_true", help="fail if the committed catalog differs")
    args = parser.parse_args()

    if args.command == "diff":
        if len(args.files) != 2:
            parser.error("diff takes two spec files: OLD NEW")
        return diff(*args.files)

    spec = json.loads(args.spec.read_text())
    digest = sha256(args.spec)
    operations = build(spec)
    ids = [op["id"] for op in operations]
    if len(ids) != len(set(ids)):
        raise SystemExit("duplicate operationId in the spec")
    text = render(operations, digest)
    if args.check:
        current = args.out.read_text() if args.out.exists() else ""
        if current != text:
            print(f"{args.out} is stale: run Scripts/elevenlabs-catalog.py", file=sys.stderr)
            return 1
        print(f"catalog up to date: {len(operations)} operations, spec sha256 {digest}")
        return 0
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(text)
    groups = sorted({op["group"] for op in operations})
    print(f"spec sha256 {digest}")
    print(f"{len(operations)} operations in {len(groups)} groups -> {args.out.relative_to(ROOT)} "
          f"({len(text.encode()) // 1024} KiB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

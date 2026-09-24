#!/usr/bin/env python3
"""A long-lived Laya decision process, spoken to over a pipe.

laya-mlx is a library, not a server: `laya_mlx.load(...)` builds an Agent and
`agent.system_one(state, questions)` answers with a dict.  There is a `laya-mlx predict`
CLI, but it loads the checkpoint, answers once and exits — about a second of model load
for thirteen milliseconds of work.  So the app keeps one of these alive instead and feeds
it questions.

**stdin and stdout only.**  No socket, no port, no bind of any kind — there is nothing here
for anything else on the machine to connect to, which is a stronger promise than binding
loopback and checking who called.  One JSON object per line in, one JSON object per line
out, ids echoed so the reader can match them.

Everything this prints is a *shape*: ids, probabilities, counts, milliseconds.  The state
and the question text are never echoed, never logged, and never appear in an error string
— an error the app shows the owner may well end up in a screenshot, and the state is the
thing most likely to be private.
"""

from __future__ import annotations

import json
import sys
import time
import traceback

PROTOCOL = 1


def _out(payload: dict) -> None:
    """One JSON object, one line, flushed.

    `default=str` so an unexpected numpy scalar becomes a string instead of taking the
    whole process down with a TypeError at the last step.
    """
    sys.stdout.write(json.dumps(payload, default=str, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def _fail(request_id, kind: str, message: str) -> None:
    _out({"id": request_id, "ok": False, "kind": kind, "error": message})


def _peak_memory_bytes():
    """What MLX says it has peaked at, when it will say.

    The API moved between MLX versions and this is a status line, not a contract, so a
    missing one is None rather than an error.
    """
    try:
        import mlx.core as mx
    except Exception:
        return None
    for name in ("get_peak_memory", "peak_memory"):
        getter = getattr(mx, name, None) or getattr(getattr(mx, "metal", None), name, None)
        if callable(getter):
            try:
                return int(getter())
            except Exception:
                continue
    return None


class Sidecar:
    def __init__(self, model_id: str, revision: str | None, batch_size: int,
                 cache_prompts: bool, dtype: str) -> None:
        self.model_id = model_id
        self.revision = revision
        self.batch_size = batch_size
        self.cache_prompts = cache_prompts
        self.dtype = dtype
        self.agent = None

    def load(self) -> dict:
        """Builds the Agent once.

        `model_id_or_path` is passed explicitly and is never allowed to default: laya-mlx's
        own default is `convaiinnovations/laya`, which is the upstream *PyTorch* checkpoint
        rather than an MLX one, so a missing argument here would quietly fetch the wrong
        weights over the network.
        """
        import laya_mlx

        started = time.monotonic()
        kwargs = {
            "batch_size": self.batch_size,
            "cache_prompts": self.cache_prompts,
            "dtype": self.dtype,
        }
        # Pinned to a commit, not to a branch: `main` moves, and a lane whose thresholds
        # were measured against one revision is not a promise about the next.
        if self.revision:
            kwargs["revision"] = self.revision
        self.agent = laya_mlx.load(self.model_id, **kwargs)
        return {
            "load_ms": (time.monotonic() - started) * 1000.0,
            "version": getattr(laya_mlx, "__version__", None),
        }

    def overflow(self, state, questions: dict):
        """`(tokens, room)` when the state is longer than the encoder will read, else None.

        laya-mlx cuts a long state to fit without a word: the tail goes — and with it
        whatever happened to be serialised last — and the answer about what is left comes
        back as confident as any other.  So the length is checked first, with the library's
        own arithmetic from `PrefixCache.prepare`: the state's tokens against what each
        question's prefix leaves of `max_len`, the tightest question deciding.  Counts only;
        the state itself is never repeated.
        """
        from laya_mlx.common import build_prefix, serialize_state

        agent = self.agent
        tok = agent.tok
        max_len = agent.cfg.get("max_len", 512)
        head_len = agent.cfg.get("head_max_len", 192)
        text = serialize_state(state).replace(tok.mask_token, " ")
        tokens = len(tok(text, add_special_tokens=False)["input_ids"])
        room = min(
            max(0, max_len - len(build_prefix(tok, agent._to_internal(q), head_len)[0]) - 1)
            for q in questions.values()
        )
        return (tokens, room) if tokens > room else None

    def decide(self, state, questions: dict) -> dict:
        """One request, however many questions, and how long it took.

        Timed here rather than in the app because the app's figure includes the pipe and
        whatever the scheduler did in between; this one is the model's.  laya-mlx returns
        no timing of its own, so if this does not measure it nothing does.
        """
        started = time.monotonic()
        result = self.agent.system_one(state, questions)
        elapsed = (time.monotonic() - started) * 1000.0
        answers = result.get("answers", {}) if isinstance(result, dict) else {}
        return {
            "model": result.get("model") if isinstance(result, dict) else None,
            "answers": answers,
            "usage": result.get("usage") if isinstance(result, dict) else None,
            "latency_ms": elapsed,
            # Per question, which is the number the published benchmarks quote and the
            # only one comparable across request sizes.
            "per_question_ms": elapsed / max(1, len(answers)),
            "peak_memory_bytes": _peak_memory_bytes(),
        }


def main() -> int:
    raw = sys.stdin.readline()
    if not raw:
        return 0
    try:
        hello = json.loads(raw)
    except json.JSONDecodeError:
        _fail(None, "protocol", "The first line was not JSON.")
        return 2

    sidecar = Sidecar(
        model_id=hello.get("model") or "",
        revision=hello.get("revision"),
        batch_size=int(hello.get("batch_size") or 16),
        cache_prompts=bool(hello.get("cache_prompts", True)),
        dtype=hello.get("dtype") or "float16",
    )
    if not sidecar.model_id:
        _fail(hello.get("id"), "protocol", "No checkpoint was named.")
        return 2

    try:
        loaded = sidecar.load()
    except ImportError as error:
        # The one failure with a specific cure, so the app can say what to do rather than
        # showing a stack trace: the environment exists but the package is not in it.
        _fail(hello.get("id"), "not_installed", str(error))
        return 3
    except Exception as error:
        _fail(hello.get("id"), "load_failed", f"{type(error).__name__}: {error}")
        return 4

    _out({
        "id": hello.get("id"),
        "ok": True,
        "op": "ready",
        "protocol": PROTOCOL,
        "model": sidecar.model_id,
        "revision": sidecar.revision,
        "peak_memory_bytes": _peak_memory_bytes(),
        **loaded,
    })

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except json.JSONDecodeError:
            _fail(None, "protocol", "Not JSON.")
            continue

        request_id = request.get("id")
        op = request.get("op") or "decide"
        if op == "shutdown":
            _out({"id": request_id, "ok": True, "op": "shutdown"})
            return 0
        if op == "ping":
            _out({
                "id": request_id, "ok": True, "op": "ping",
                "peak_memory_bytes": _peak_memory_bytes(),
            })
            continue
        if op != "decide":
            _fail(request_id, "protocol", f"Unknown op {op!r}.")
            continue

        questions = request.get("questions")
        if not isinstance(questions, dict) or not questions:
            _fail(request_id, "protocol", "A request needs at least one question.")
            continue

        try:
            too_long = sidecar.overflow(request.get("state"), questions)
            if too_long:
                tokens, room = too_long
                _out({
                    "id": request_id, "ok": False, "kind": "state_too_long",
                    "error": f"The state is {tokens} tokens and the checkpoint reads {room}.",
                    "tokens": tokens, "room": room,
                })
                continue
            answer = sidecar.decide(request.get("state"), questions)
        except Exception as error:
            # The type and the message, never the traceback and never the state. A
            # traceback on stdout would also break the one-object-per-line contract.
            print(traceback.format_exc(limit=3), file=sys.stderr)
            _fail(request_id, "failed", f"{type(error).__name__}: {error}")
            continue
        _out({"id": request_id, "ok": True, **answer})

    return 0


if __name__ == "__main__":
    sys.exit(main())

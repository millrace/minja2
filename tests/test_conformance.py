"""Byte-equality conformance: minja2 (Mojo) vs the reference jinja2 engine.

The reference here mirrors `transformers.apply_chat_template`'s real jinja2
configuration — that is minja2's stated target (requirements §1), not vanilla
jinja2. Two settings matter and both diverge from a default `Environment`:

  * `tojson` preserves **insertion order** (`sort_keys=False`). transformers
    installs its own `tojson` filter with `sort_keys=False`; jinja2's default
    policy is `sort_keys=True`. Tool definitions are rendered byte-exact only
    with insertion order.
  * Undefined is **chainable + falsy** (lenient boolean context) but still
    **raises on emission**. This matches minja2's hybrid: `not message.tool_calls`
    on a plain assistant turn is `True` (undefined is falsy), while actually
    printing an undefined value aborts. transformers uses jinja2's default
    `Undefined` (lenient everywhere); minja2 keeps StrictUndefined's
    raise-on-emit, so we mirror exactly that with a `ChainableUndefined`
    subclass whose `__str__` fails.

For every (template, context) pair we render twice — once through this
reference env with the three globals `transformers` injects (`raise_exception`,
`strftime_now`, `namespace`), once through the compiled `minja2` CLI — and
assert the bytes match. When the reference renders, minja2 must produce
identical bytes; when the reference aborts via `raise_exception`, minja2 must
surface the same message (exit 3).

Contexts the reference rejects for structural reasons (e.g. printing an
undefined value, raising `UndefinedError`) are not meaningful comparisons and
are reported as SKIP, not failures.

Run:  pixi run python tests/test_conformance.py
"""

from __future__ import annotations

import datetime
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from jinja2 import ChainableUndefined, Environment
from jinja2.utils import Namespace

import fetch_reference_templates as fx  # sibling loader API

ROOT = Path(__file__).resolve().parent.parent
BIN = ROOT / "build" / "minja2"
MAIN = ROOT / "src" / "main.mojo"

# Fixed UTC instant so strftime_now is deterministic on both sides.
NOW_EPOCH = 1721966400  # 2024-07-26 08:00:00 UTC


class RaiseExc(Exception):
    pass


class ChatTemplateUndefined(ChainableUndefined):
    """minja2's hybrid undefined: chainable attribute/item access and falsy in
    boolean context (so `not message.tool_calls` works on a plain turn), but
    printing it aborts — matching minja2's `to_output()` raise on VUNDEF."""

    __slots__ = ()

    def __str__(self):
        self._fail_with_undefined_error()

    __html__ = __str__


def make_env() -> Environment:
    env = Environment(undefined=ChatTemplateUndefined)
    # transformers installs tojson with sort_keys=False; jinja2's default policy
    # is sort_keys=True. Insertion order is what makes tool defs byte-exact.
    env.policies["json.dumps_kwargs"] = {"sort_keys": False}
    env.globals["raise_exception"] = _raise_exception
    env.globals["strftime_now"] = _strftime_now
    env.globals["namespace"] = Namespace
    return env


def _raise_exception(msg):
    raise RaiseExc(msg)


def _strftime_now(fmt):
    return datetime.datetime.fromtimestamp(
        NOW_EPOCH, datetime.timezone.utc
    ).strftime(fmt)


def tok(cfg: dict, key: str) -> str:
    v = cfg.get(key)
    if isinstance(v, dict):
        return v.get("content", "")
    return v if isinstance(v, str) else ""


# ── Context corpus ────────────────────────────────────────────────────────────
WEATHER_TOOL = {
    "type": "function",
    "function": {
        "name": "get_current_weather",
        "description": "Get the current weather in a given location",
        "parameters": {
            "type": "object",
            "properties": {
                "location": {
                    "type": "string",
                    "description": "The city and state, e.g. San Francisco, CA",
                },
                "unit": {"type": "string", "enum": ["celsius", "fahrenheit"]},
            },
            "required": ["location"],
        },
    },
}

U = lambda c: {"role": "user", "content": c}
A = lambda c: {"role": "assistant", "content": c}
S = lambda c: {"role": "system", "content": c}


def _qwen_assistant(c):
    # Qwen reads message.tool_calls for every assistant turn under
    # StrictUndefined, so a plain assistant turn must carry an (empty) list.
    return {"role": "assistant", "content": c, "tool_calls": []}


# General contexts applied to every template (classified by reference outcome).
GENERAL = [
    ("simple_user", [U("Hello, how are you?")]),
    ("system_user", [S("You are a helpful assistant."), U("Hi there!")]),
    (
        "multi_turn",
        [U("What is 2+2?"), A("It is 4."), U("And 3+3?")],
    ),
    (
        "multi_turn_qwen",  # assistant carries tool_calls=[] for Qwen
        [U("What is 2+2?"), _qwen_assistant("It is 4."), U("And 3+3?")],
    ),
    (
        "five_turn",
        [
            U("One"),
            A("Two"),
            U("Three"),
            A("Four"),
            U("Five"),
        ],
    ),
    (
        "five_turn_qwen",
        [
            U("One"),
            _qwen_assistant("Two"),
            U("Three"),
            _qwen_assistant("Four"),
            U("Five"),
        ],
    ),
    ("unicode", [U("Héllo — café ☕ 日本語 emoji 😀")]),
    ("whitespace", [U("  leading and trailing spaces  \n\n")]),
]

# Template-specific tool-use contexts (message shapes differ per family).
TOOL_CONTEXTS = {
    "Qwen__Qwen2.5-0.5B-Instruct": [
        (
            "qwen_tools",
            {
                "tools": [WEATHER_TOOL],
                "messages": [
                    U("What's the weather in SF?"),
                    {
                        "role": "assistant",
                        "content": "",
                        "tool_calls": [
                            {
                                "function": {
                                    "name": "get_current_weather",
                                    "arguments": {"location": "San Francisco, CA"},
                                }
                            }
                        ],
                    },
                    {"role": "tool", "content": '{"temperature": 20}'},
                    _qwen_assistant("It is 20 degrees."),
                ],
            },
        ),
    ],
    "meta-llama__Llama-3.2-1B-Instruct": [
        (
            "llama_tools",
            {
                "tools": [WEATHER_TOOL],
                "messages": [
                    U("What's the weather in SF?"),
                    {
                        "role": "assistant",
                        "tool_calls": [
                            {
                                "function": {
                                    "name": "get_current_weather",
                                    "arguments": {"location": "San Francisco, CA"},
                                }
                            }
                        ],
                    },
                    {"role": "ipython", "content": '{"temperature": 20}'},
                ],
            },
        ),
        (
            "llama_tools_sys",
            {
                "tools": [WEATHER_TOOL],
                "messages": [
                    S("You are a weather bot."),
                    U("Weather in SF?"),
                ],
            },
        ),
        (
            "llama_date_string",  # exercises the non-strftime_now branch
            {"date_string": "01 Jan 2020", "messages": [U("Hi")]},
        ),
        (
            "llama_tools_not_in_user",  # tools rendered in system block
            {
                "tools": [WEATHER_TOOL],
                "tools_in_user_message": False,
                "messages": [U("Weather in SF?")],
            },
        ),
    ],
    "mistralai__Mistral-7B-Instruct-v0.3": [
        (
            "mistral_tools",
            {
                "tools": [WEATHER_TOOL],
                "messages": [
                    U("What's the weather in SF?"),
                    {
                        "role": "assistant",
                        "content": "",
                        "tool_calls": [
                            {
                                "function": {
                                    "name": "get_current_weather",
                                    "arguments": {"location": "San Francisco, CA"},
                                },
                                "id": "abcdefghi",
                            }
                        ],
                    },
                    {
                        "role": "tool",
                        "content": '{"temperature": 20}',
                        "tool_call_id": "abcdefghi",
                    },
                ],
            },
        ),
    ],
}

# Explicit negative tests: the reference must raise_exception with this message.
NEGATIVE = {
    "google__gemma-2-2b-it": [
        (
            "gemma_system",
            [S("sys"), U("hi")],
            "System role not supported",
        ),
        (
            "gemma_bad_alternation",
            [U("a"), U("b")],
            "Conversation roles must alternate user/assistant/user/assistant/...",
        ),
    ],
    "mistralai__Mistral-7B-Instruct-v0.3": [
        (
            "mistral_bad_alternation",
            [U("a"), U("b")],
            "After the optional system message, conversation roles must "
            "alternate user/assistant/user/assistant/...",
        ),
    ],
}


# ── Runner ────────────────────────────────────────────────────────────────────
class Stats:
    def __init__(self):
        self.passed = 0
        self.failed = 0
        self.skipped = 0
        self.failures: list[str] = []
        self.skips: list[str] = []


def run_mojo(template: str, context: dict, now_epoch: int):
    """Return (exit_code, output_bytes)."""
    with tempfile.TemporaryDirectory() as d:
        job = os.path.join(d, "job.json")
        out = os.path.join(d, "out")
        with open(job, "w") as f:
            json.dump(
                {"template": template, "context": context, "now_epoch": now_epoch},
                f,
                ensure_ascii=False,
            )
        proc = subprocess.run([str(BIN), job, out], capture_output=True)
        data = b""
        if os.path.exists(out):
            with open(out, "rb") as f:
                data = f.read()
        return proc.returncode, data


def build_context(slug: str, base_vars: dict) -> dict:
    cfg = fx.load_config(slug)
    ctx = {"tools": None}  # default: tools defined-but-none (Qwen requires it)
    ctx.update(base_vars)
    ctx.setdefault("bos_token", tok(cfg, "bos_token"))
    ctx.setdefault("eos_token", tok(cfg, "eos_token"))
    return ctx


def check_positive(stats, env, src, slug, label, base_vars):
    ctx = build_context(slug, base_vars)
    if "add_generation_prompt" not in ctx:
        agps = [True, False]
    else:
        agps = [ctx["add_generation_prompt"]]
    for agp in agps:
        c = dict(ctx)
        c["add_generation_prompt"] = agp
        name = f"{slug} :: {label} agp={agp}"
        try:
            expected = env.from_string(src).render(**c)
        except RaiseExc as e:
            # Reference aborts via raise_exception -> treat as negative.
            code, data = run_mojo(src, c, NOW_EPOCH)
            if code == 3 and data.decode("utf-8", "replace") == str(e):
                stats.passed += 1
            else:
                stats.failed += 1
                stats.failures.append(
                    f"{name}: expected raise {str(e)!r} (exit3), "
                    f"got exit={code} data={data[:80]!r}"
                )
            continue
        except Exception as e:
            # Context not valid for this template under StrictUndefined.
            stats.skipped += 1
            stats.skips.append(f"{name}: {type(e).__name__}: {str(e)[:50]}")
            continue
        code, data = run_mojo(src, c, NOW_EPOCH)
        if code == 0 and data == expected.encode("utf-8"):
            stats.passed += 1
        else:
            stats.failed += 1
            stats.failures.append(
                f"{name}: MISMATCH exit={code}\n"
                f"   expected: {expected.encode('utf-8')!r}\n"
                f"   got:      {data!r}"
            )


def check_negative(stats, env, src, slug, label, messages, expected_msg):
    ctx = build_context(slug, {"messages": messages})
    ctx["add_generation_prompt"] = True
    name = f"{slug} :: {label} (negative)"
    try:
        env.from_string(src).render(**ctx)
        stats.failed += 1
        stats.failures.append(f"{name}: reference did NOT raise")
        return
    except RaiseExc as e:
        ref_msg = str(e)
    except Exception as e:
        stats.failed += 1
        stats.failures.append(f"{name}: reference raised {type(e).__name__}: {e}")
        return
    if ref_msg != expected_msg:
        stats.failed += 1
        stats.failures.append(
            f"{name}: reference msg {ref_msg!r} != expected {expected_msg!r}"
        )
        return
    code, data = run_mojo(src, ctx, NOW_EPOCH)
    if code == 3 and data.decode("utf-8", "replace") == ref_msg:
        stats.passed += 1
    else:
        stats.failed += 1
        stats.failures.append(
            f"{name}: expected exit3 {ref_msg!r}, got exit={code} {data[:80]!r}"
        )


def ensure_built():
    print("building minja2 ...", flush=True)
    r = subprocess.run(
        ["mojo", "build", str(MAIN), "-o", str(BIN)],
        cwd=str(ROOT),
        capture_output=True,
        text=True,
    )
    if r.returncode != 0:
        print(r.stdout)
        print(r.stderr)
        raise SystemExit("build failed")


def main() -> int:
    ensure_built()
    env = make_env()
    stats = Stats()

    for path in fx.cached_templates():
        slug = path.stem
        src = fx.load_template(slug)

        for label, messages in GENERAL:
            check_positive(stats, env, src, slug, label, {"messages": messages})

        for label, base_vars in TOOL_CONTEXTS.get(slug, []):
            check_positive(stats, env, src, slug, label, base_vars)

        for label, messages, msg in NEGATIVE.get(slug, []):
            check_negative(stats, env, src, slug, label, messages, msg)

    print(f"\n{'='*70}")
    print(f"PASS={stats.passed}  FAIL={stats.failed}  SKIP={stats.skipped}")
    if stats.skips:
        print("\nSKIPPED (reference rejects context under StrictUndefined):")
        for s in stats.skips:
            print("  - " + s)
    if stats.failures:
        print("\nFAILURES:")
        for f in stats.failures:
            print("  - " + f)
    return 1 if stats.failed else 0


if __name__ == "__main__":
    raise SystemExit(main())

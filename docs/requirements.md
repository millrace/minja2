# minja2 — Requirements

A Mojo implementation of the Jinja2 subset needed to **render the chat templates
shipped in modern instruct-tuned LLM tokenizer configs**, byte-identically to
`transformers`'s reference Jinja2 engine.

This document is grounded in real templates. Every required feature below cites
a fixture file under `tests/fixtures/chat_templates/` (created by
`tests/fetch_reference_templates.py`) where that feature is actually used —
nothing is speculative.

## 1. Purpose and scope

### What minja2 is

A focused Jinja2 implementation in Mojo whose **only** job is to take

- a chat-template source string (the `chat_template` field of an HF
  `tokenizer_config.json`),
- a `messages` list and an `add_generation_prompt` flag,
- the model's special-token strings (`bos_token`, `eos_token`),
- optional context (`tools`, `custom_tools`, `tools_in_user_message`,
  `date_string`),

and produce the exact prompt string the model was trained to receive — the same
bytes `transformers.PreTrainedTokenizer.apply_chat_template(...)` produces.

### What it is not

A general-purpose Jinja2 engine. The chat-template surface is a tiny, precise
slice of full Jinja2: no template inheritance, no includes, no macros, no i18n,
no auto-escape, no sandboxing. Implementing those would multiply the surface
without enabling any real chat template (see §10).

### Why a Mojo port

Today millrace calls `transformers.AutoTokenizer.apply_chat_template`, which
pulls in the entire Python ML runtime tail (`transformers` + `tokenizers` +
`torch` references) just to evaluate a template. A pure-Mojo templater is a
prerequisite to removing the Python interop boundary from the request path
(ARCHITECTURE.md §3 design stance, §8 #3 dependency tail).

## 2. Conformance corpus

The corpus is the fixtures fetched by `tests/fetch_reference_templates.py`:

| Fixture (`tests/fixtures/chat_templates/...`)   | Source repo                            | Size |
|---|---|---:|
| `Qwen__Qwen2.5-0.5B-Instruct.jinja`             | Qwen/Qwen2.5-0.5B-Instruct             | 2507 B |
| `meta-llama__Llama-3.2-1B-Instruct.jinja`       | meta-llama/Llama-3.2-1B-Instruct       | 3827 B |
| `mistralai__Mistral-7B-Instruct-v0.3.jinja`     | mistralai/Mistral-7B-Instruct-v0.3     | 3959 B |
| `google__gemma-2-2b-it.jinja`                   | google/gemma-2-2b-it                    | 591 B |
| `microsoft__Phi-3-mini-4k-instruct.jinja`       | microsoft/Phi-3-mini-4k-instruct       | 407 B |

These five span a deliberately broad set of features: tiny one-pass templates
(Gemma, Phi) and long multi-block templates with tool-use logic (Qwen, Llama,
Mistral). Every required feature in §4 / §5 / §6 is used by at least one of
them. The byte-equality test (§9) is the only authoritative correctness signal.

References below use `<short-id>:<line>` — e.g. `Llama-3.2:67`. Citations were
extracted directly from the fixture files; "size" is the source length in
bytes, not the rendered output.

## 3. Reference semantics

Behavior is defined as **"whatever `jinja2.Environment` (the library
`transformers` uses) does with the same template, the same globals, and the
same context."** Where the formal Jinja2 spec and the Python `jinja2`
implementation diverge, follow `jinja2` — that's what's actually deployed.

Specifically:

- Whitespace handling: `jinja2`'s `lstrip_blocks=False, trim_blocks=False`
  defaults, plus the per-tag `-` markers documented in §6.
- Undefined behavior: `StrictUndefined` (what `transformers` configures the env
  with). Accessing an undefined name or attribute raises immediately.
- Truthiness: Python rules (`None`, `False`, `0`, `""`, `[]`, `{}` are falsy).
- Operator semantics: Python (integer arithmetic, string `+` concatenation,
  `==` deep equality).

## 4. Required language features

Every feature here is required for at least one fixture.

### 4.1 Delimiters and comments

- **Expression output**: `{{ expr }}` (Gemma:1, Phi:1).
- **Statement**: `{% stmt %}` (Gemma:1, Phi:1).
- **Whitespace-stripping variants**: `{{- expr -}}`, `{%- stmt -%}` — used
  almost exclusively by Llama / Mistral / Qwen (Llama-3.2 uses `{%-` 51 times;
  Mistral 60; Qwen 30). Required (§6).
- **Comments**: `{# … #}` and the strip variants `{#- … -#}` — used by Llama
  and Mistral for documentation inside the template (Llama-3.2:19, 27, 46;
  Mistral:12). Must be parsed and discarded; must not emit any output.

### 4.2 Statements

- **`if` / `elif` / `else` / `endif`** — every fixture. Nested ≥ 4 levels
  deep in tools-bearing templates (Mistral:25–55).
- **`for x in seq` / `endfor`** — every fixture. Iterates `messages`,
  `tools`, `loop_messages`, message `tool_calls`, etc.
- **`for k, v in mapping.items()`** — tuple-unpacking in `for` (Mistral:32:
  `{%- for key, val in tool.items() if key != "return" %}`).
- **`for ... if cond`** — loop filter (Mistral:32 again). The trailing `if`
  filters items, not a separate `if` statement.
- **`set name = expr`** — every fixture except Phi. Plain rebinding
  (Llama-3.2:3, 6, 12, 16, 21, 22, 24; Mistral:2, 3, 5, 8, 13–14, 17, 20; …),
  including **reassigning to slices**: `{%- set messages = messages[1:] %}`
  (Llama-3.2:22, 51; Mistral:3, 5).
- **`set ns.attr = value`** — assignment to a `namespace()` attribute
  (Mistral:14, 20). The Jinja idiom for mutating state from inside a loop body
  (loop-local `set` doesn't escape).

### 4.3 Expressions

- **Variables**: bare names and attribute access (`message.role`,
  `message.content`, `tool_call.function.name`, `tool.items`) — every fixture.
- **Subscript access**: `messages[0]`, `message['role']`, `tool_call.arguments`
  — every fixture. Both `obj.x` and `obj['x']` must resolve from mappings.
- **Negative indexing**: `user_messages[-1]` (Mistral:27).
- **Slicing**: `messages[1:]` (Llama-3.2:22, 51; Mistral:3, 5). Step and lower
  bounds beyond `0`/omitted are **not** observed in the corpus — `[start:]` is
  the only slice form that needs to work.
- **Method calls**: `tool.items()` (Mistral:32). One call form is enough; the
  corpus has no chained calls.
- **Function calls**: `raise_exception(...)`, `strftime_now(...)`,
  `namespace()` — see §5.2. Calls take positional and keyword args: `tojson` is
  used as `tojson(indent=4)` (Llama-3.2:39, 61), so the parser must handle
  `name=value` arguments.
- **String concatenation with `+`**: `'<|im_start|>' + role + '\n'`
  (Gemma:1; Qwen:16; Mistral:34, 36; etc.). Required.
- **String literals**: both single (`'role'`) and double quotes (`"role"`) —
  templates mix them freely. Escape sequences observed: `\n`, `\"`, `\'`.
- **Arithmetic**: integer `+`, `-`, `%` — `loop.index0 - 1` (Qwen:41),
  `loop.index0 + 1` (Qwen:47), `loop.index0 % 2` (Gemma:1, Mistral:17),
  `ns.index + 1` (Mistral:20).
- **Comparisons**: `==` (43 occurrences), `!=` (8), used on strings and ints.
  Required.
- **Boolean operators**: `and`, `or`, `not` (heavily used). Short-circuit
  semantics required (templates rely on `tools is not none and ...` not
  raising when `tools` is `None`).
- **Parenthesized grouping**: `(loop.index0 == 0) or (messages[loop.index0 -
  1].role != "tool")` (Qwen:41).
- **`in` operator**: `'tool_calls' in message` (Llama-3.2:68, 70).
  Membership test against mapping keys (and lists, though only the mapping form
  is in the corpus).
- **Literals**: integer literals (`0`, `1`, `4`, `9`, …), string literals,
  the keywords `none`, `true`, `false`.

### 4.4 Tests (`is X`)

Verified in real expression contexts (string-literal false positives excluded):

| Test          | First used at                | Notes                                       |
|---|---|---|
| `is defined`  | Llama-3.2:2 (`custom_tools is defined`) | The most common — guards optional context.   |
| `is none` / `is not none` | Llama-3.2:29 (`tools is not none`) | Used everywhere tools logic branches.      |
| `is mapping`  | Llama-3.2:83 (`message.content is mapping`) | True for dict-like values.           |
| `is iterable` | Llama-3.2:83 (`... or message.content is iterable`) | True for non-string sequences.     |
| `is string`   | Mistral:33 (`val is string`)              | True only for strings (not bytes).          |

Tests with `not` form (`is not defined`, `is not none`) must also work.

### 4.5 Filters (`| X`) — confirmed real usages

| Filter        | First used at                                | Notes                                |
|---|---|---|
| `tojson`      | Qwen:36 (`tool_call.arguments \| tojson`)     | JSON-encode the value.               |
| `tojson(indent=4)` | Llama-3.2:39, 61                         | With keyword arg.                    |
| `trim`        | Gemma:1; Llama-3.2:21 (`messages[0]['content']\|trim`) | Strip leading/trailing whitespace. |
| `length`      | Llama-3.2:49 (`messages \| length`); Mistral:61, 80 | Sequence/string length.            |
| `list`        | Mistral:10 (`... \| list`)                   | Materialize a generator into a list. |
| `selectattr(name, op, value)` | Mistral:10 (`selectattr("role", "equalto", "user")`) | Filter a sequence of mappings/objects by a comparison; takes string args. |
| `string`      | Mistral:79 (`content\|string`)               | Coerce to string (and a test, §4.4). |

Whether the parser internally distinguishes filters from method calls is up to
the implementer; what matters is the externally observed behavior.

### 4.6 Loop variables

Inside `for`, `loop` is bound to a loop-state object. The following attributes
are observed:

- `loop.first` (Qwen:22 — `... and not loop.first`)
- `loop.last` (Qwen:38, 47; Mistral:38, 43, 51; …)
- `loop.index0` (Gemma:1; Qwen:41, 47; Mistral:17)

`loop.index`, `loop.length`, `loop.cycle()`, etc. — not used in the corpus,
not required.

### 4.6.1 The `namespace()` builtin

Mistral uses `{%- set ns = namespace() %}` (line 13) and then assigns
`{%- set ns.index = 0 %}` (14) and `{%- set ns.index = ns.index + 1 %}` (20)
inside a `for` loop. Jinja's loop-local `set` doesn't escape the loop body,
so `namespace()` is the idiom for "writable from inside a loop." Required as
a host-injected zero-argument constructor returning a mutable attribute bag.

## 5. Required template context

### 5.1 Pre-populated variables (passed by the host)

The conformance runner (and the eventual Mojo caller) provides these:

| Name                      | Type         | Required when                              | Cited at |
|---|---|---|---|
| `messages`                | list of dicts | always                                    | every fixture |
| `add_generation_prompt`   | bool         | always                                     | Qwen:52, Gemma:3, Llama-3.2 (end), Phi:7 |
| `bos_token`               | string       | Llama-3.2:1, Mistral:24, Gemma:1            | shipped in `tokenizer_config.json` |
| `eos_token`               | string       | Phi:8 (`else` branch)                       | shipped in `tokenizer_config.json` |
| `tools`                   | list \| none | when caller passes tool definitions         | Qwen:1, Mistral:7, Llama-3.2:15 |
| `custom_tools`            | list         | optional alias for `tools` (Llama)         | Llama-3.2:2 |
| `tools_in_user_message`   | bool         | optional (defaults set inside template)    | Llama-3.2:5 |
| `date_string`             | string       | optional (template synthesizes via `strftime_now`) | Llama-3.2:8 |

Templates frequently `is defined`-guard these — minja2 must distinguish
**"name not bound at all"** from **"name bound to `none`"**.

Note that mapping keys may legitimately be missing on individual messages
(e.g. a user turn has no `tool_calls` key). Both attribute access
(`message.tool_calls`) and subscript (`message['tool_calls']`) are used; the
host's value type must support `is defined`-style probing without raising —
i.e. these expressions return `Undefined` (which `is defined` reports as
False), they don't error.

### 5.2 Host-injected globals (callable from templates)

These are *not* part of Jinja2 proper — they are functions `transformers`
installs into the env. Templates depend on them existing:

- **`raise_exception(msg: string) -> never`** — abort rendering with `msg`.
  Used at Gemma:1 (`'System role not supported'`,
  `'Conversation roles must alternate ...'`), Llama-3.2:52, 72, Mistral:18,
  62, 81. minja2 must surface this as an error to the Mojo caller, carrying
  the message.
- **`strftime_now(fmt: string) -> string`** — current UTC time formatted with
  `strftime` codes (Llama-3.2:10 uses `"%d %b %Y"`). Hostable as a callable;
  templates do `if strftime_now is defined` first (Llama-3.2:9), so if the
  host doesn't provide it the template falls back to a literal date.
- **`namespace()`** — see §4.6.1.

### 5.3 Value & type model

The engine needs first-class internal representations of:

- **String** — UTF-8.
- **Integer** — at least 64-bit signed; used for indices and modulo.
- **Boolean** — distinct from int (for `if x` / `is none` semantics).
- **None** — the `none` literal; output as `None` (Python's behavior — though
  this is never visibly emitted in the corpus, it must compare correctly).
- **List** — ordered sequence, indexable, sliceable, iterable, supports
  `| length`, `| list`, `| selectattr`.
- **Mapping** — string-keyed, supports `obj.key` and `obj['key']`, `.items()`,
  `in` (membership against keys), `is defined`-probe on missing keys.
- **Undefined sentinel** — what an unbound name or missing attribute resolves
  to. `is defined` returns False on it; **any other use raises** (`StrictUndefined`).

Templates pass Python-shaped data through; minja2's host API must accept Mojo
values that round-trip cleanly into and out of these.

## 6. Whitespace handling

The single biggest correctness pitfall and the primary reason byte-equality
matters. Jinja's whitespace control:

- `{%-` strips whitespace **before** the tag (back to and including the
  preceding newline).
- `-%}` strips whitespace **after** the tag.
- Same applies to `{{-` / `-}}` and `{#-` / `-#}`.

Per-fixture counts (from the corpus):

| Fixture        | `{%-` count | `{%` count | `-%}` count | `%}` count |
|---|---:|---:|---:|---:|
| Gemma          | 0  | 13 | 0  | 13 |
| Phi-3          | 0  | 9  | 0  | 9  |
| Qwen           | 30 | 0  | 0  | 30 |
| Llama-3.2      | 51 | 0  | 0  | 51 |
| Mistral        | 60 | 0  | 0  | 60 |

Two patterns coexist: the dense one-liner templates (Gemma, Phi) use neither
form and rely on the literal newlines they emit, while the long block-style
templates use `{%-` heavily on the opening side. **Both must round-trip
correctly.** The trailing `-%}` form is not observed in the corpus, but must
still parse (it appears in many other templates in the wild).

Get this wrong and the rendered prompt picks up stray spaces or newlines that
shift away from what the model was trained on — silently degrading output.

## 7. Error semantics

- **Undefined name or attribute** → raise (StrictUndefined). The Mojo caller
  sees a descriptive error with the offending name.
- **`raise_exception("msg")` invoked** → render aborts; the message is
  surfaced verbatim to the caller. Distinguishable from internal errors (this
  is templates voicing user-facing input validation — e.g. Gemma rejecting a
  system role).
- **Parse errors** → raise during compile with line and column.
- **Runtime errors** (e.g. type mismatch on `+`) → raise during render with
  line and column.

The Mojo error API needs to carry both message and source position so a
millrace operator can debug a bad template fast.

## 8. Public Mojo API (proposed)

A minimal surface — the rest is internal:

```mojo
struct Template:
    """A compiled chat template, reusable across renders."""

    @staticmethod
    fn compile(source: String, *, name: String = "") raises -> Template:
        ...

    fn render(self, context: Dict[String, Value]) raises -> String:
        ...
```

Where `Value` is a tagged union covering the §5.3 type model. The host
populates the context dict with `messages`, `add_generation_prompt`,
`bos_token`, `eos_token`, etc., plus any globals it wants injected (
`raise_exception`, `strftime_now`).

Open design questions to settle during implementation, not in this doc:

- Whether `Value` is a struct enum, an opaque pointer, or backed by JSON-style
  parser output.
- How to register host callables (free functions vs. closures vs. a registry).
- Whether to expose a streaming render API (templates are short — not
  necessary for v1).
- Caching strategy for compiled templates (caller's responsibility, probably —
  millrace already keeps a per-model dict).

## 9. Conformance methodology

The byte-equality test is the only signal that minja2 is correct. Methodology:

1. **Corpus**: every `.jinja` under `tests/fixtures/chat_templates/`. New
   model families are added by running `tests/fetch_reference_templates.py
   --model <new-repo-id>` and committing the new fixture.

2. **Reference**: Python `jinja2.Environment(loader=None,
   undefined=StrictUndefined)` with these globals injected:
   - `raise_exception` (raises a known exception type)
   - `strftime_now` (returns `datetime.utcnow().strftime(fmt)`)
   - `namespace` (the `jinja2.utils.Namespace` class)

3. **Under test**: `minja2.Template.compile(source).render(context)`.

4. **Context corpus** — for every template, render at least:
   - one-shot user (`[{role: user, content: ...}]`)
   - system + user
   - multi-turn alternation (user/assistant ≥ 2 rounds)
   - same as above with `add_generation_prompt=False`
   - `bos_token` / `eos_token` plumbed from each template's
     `tokenizer_config.json`
   - where the template supports it: assistant turn with `tool_calls`, tool
     response turn, `tools` list passed in

5. **Assertion**: `reference_bytes == minja2_bytes` for every (template,
   context) pair. Any mismatch is a bug — investigate, fix, add a focused
   unit test.

6. **Negative tests**: contexts that should `raise_exception` (Gemma with a
   system role; conversation roles that don't alternate). Both implementations
   must error; the message must match.

The implementation of this runner lives in a sibling file
(`tests/test_conformance.py`, not yet written). `tests/fetch_reference_templates.py`
already exposes the loader API (`cached_templates`, `load_template`,
`load_config`) that runner will consume.

## 10. Non-goals

These Jinja2 features are **explicitly out of scope.** No fixture in the
corpus uses any of them, and none has been observed in chat templates in the
wild as of the corpus date. If a future model template needs one, revisit —
don't add speculatively.

- Template inheritance: `{% extends %}`, `{% block %}`, `{% endblock %}`,
  `super()`.
- Template composition: `{% include %}`, `{% import %}`, `{% from %}`.
- Macros: `{% macro %}`, `{% endmacro %}`, `{% call %}`.
- Internationalization: `{% trans %}` / `{% pluralize %}`.
- Auto-escaping (HTML / XML). Chat templates emit special tokens that look
  HTML-like (`<|im_start|>`) but must pass through verbatim.
- Sandboxing / security policy.
- Async / generator rendering.
- Custom expression operators or syntax extensions beyond §5.2's three
  callables.
- The `{% with %}` / `{% endwith %}` block.
- `do`, `with`, `autoescape`, `filter` blocks.
- Line-based statement syntax (`# ...`).
- Loop control statements `{% break %}` / `{% continue %}` (jinja2.ext.loopcontrols).

## 11. Performance considerations (advisory)

Templates are tiny (≤ 4 KB source, ≤ ~16 KB rendered output) and renders are
per-request. A single-user millrace serves at most a few requests per second.
So:

- **Compile once, render many.** The caller (millrace) already caches a
  per-model tokenizer; minja2 should let callers cache a per-model compiled
  `Template`. No internal cache needed.
- **Allocations** are not the bottleneck at this scale; emphasize
  correctness and clear errors over raw throughput.
- **No need for SIMD-accelerated parsing or compiled-bytecode evaluation** in
  v1. A clean tree-walk evaluator is fine.

If minja2 later gets used for something other than chat templates (e.g.
high-throughput log formatting), revisit. Until then, optimize for getting
byte-equality right and shipping.

## 12. Open questions

These are flagged for the implementer; they affect API shape but not feature
coverage:

1. **Mojo's string story for emit-buffering.** `String` concatenation
   patterns in current Mojo aren't the cheapest; a `StringBuilder`-like
   accumulator is likely worth writing.

2. **How to plumb host callables.** Templates need `raise_exception` etc. as
   first-class callables in expressions. Mojo's function-pointer / trait-based
   dispatch may shape what the public `Template.render` signature looks like.

3. **Encoding of `Value`.** Either a Mojo struct enum (clean, compile-checked,
   but Mojo's enum-variant support is evolving) or an opaque pointer with a
   tag (more flexible, less safe). Recommend struct enum if Mojo's support is
   solid by the time work begins.

4. **`tojson` deterministic order.** `transformers` uses Python `json.dumps`
   which preserves insertion order. The Mojo serializer must do the same for
   byte-equality on the (rare) `| tojson` outputs in the corpus.

## 13. References

- The corpus: `tests/fixtures/chat_templates/` (regenerated by
  `tests/fetch_reference_templates.py`).
- Jinja2 reference behavior: <https://jinja.palletsprojects.com/en/stable/templates/>
  (use the `Stable` docs, not `Latest`, to match `transformers`'s pinned
  version surface).
- `transformers` chat-template integration: the `apply_chat_template` method
  on `PreTrainedTokenizer`. Reading its source is the fastest way to learn
  which extensions it injects.
- millrace's use site (motivating consumer):
  `/Users/mseritan/dev/millrace/millrace/millrace_max.py`,
  `_render_chat` / `chat_prompt` / `anthropic_prompt`. The Mojo-side handlers
  pass through `millrace_max.chat_prompt(model, body)` and consume the
  rendered string verbatim.

"""Fetch reference chat templates from HuggingFace — minja2's conformance corpus.

minja2's primary correctness target is "render byte-identically vs `transformers`'s
Jinja2 engine on the chat templates of mainstream instruct models." This script
downloads each target model's `tokenizer_config.json`, extracts its
`chat_template` field, and caches both to `tests/fixtures/chat_templates/` so
the test suite can run offline once the fixtures exist.

Layout produced::

    tests/fixtures/chat_templates/
        manifest.json                              # repo + sha + fetch date
        Qwen__Qwen2.5-0.5B-Instruct.jinja          # the template, verbatim
        Qwen__Qwen2.5-0.5B-Instruct.config.json    # full tokenizer_config.json
        ...

Why both files: the `.jinja` is the test input; the `.config.json` carries
`bos_token` / `eos_token` / `pad_token` strings that several templates reference
(Llama 3.2's `{{- bos_token }}`, for example), and those need to be passed in as
template variables alongside `messages` / `add_generation_prompt`.

Usage::

    python tests/fetch_reference_templates.py              # idempotent fetch
    python tests/fetch_reference_templates.py --force      # re-download
    python tests/fetch_reference_templates.py --model X    # additionally fetch X
    python tests/fetch_reference_templates.py --only X     # fetch only X
    python tests/fetch_reference_templates.py --list       # show cached fixtures

Gated repos (`meta-llama/*`, `google/gemma-*`) require `huggingface-cli login`
or `HF_TOKEN`. Without auth the script skips them with a clear warning instead
of failing the whole run — the cached entries we do have remain valid.

How this fits the test procedure
--------------------------------
A future conformance runner (not in this file) will:

  1. List every `*.jinja` under `tests/fixtures/chat_templates/` via
     `cached_templates()` below.
  2. For each, load it through both `transformers`/Jinja2 (the reference) and
     minja2 (under test) with a fixed corpus of message arrays — at minimum:
     a one-shot user, system + user, multi-turn user/assistant alternation,
     and (where the template supports them) tool-call / tool-response cases.
  3. Assert byte equality of every render. Any divergence is a minja2 bug.

The reference Jinja2 needs two `transformers`-specific injections to evaluate
real templates: `raise_exception(msg)` (Llama 3 / Mistral / Gemma use it for
role-alternation checks) and `strftime_now(fmt)` (Llama 3 uses it for the
"Today Date" line). Don't omit these — the templates will error before
producing output.

Requirements
------------
This is a Python helper, not Mojo. Install once::

    pip install huggingface_hub
    # or, if the repo gains a pixi env:
    pixi add huggingface_hub
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Optional

# The conformance corpus. Each entry is the *instruct* variant of a major
# open-weights family, smallest available so downloads stay tiny — we only need
# the tokenizer config, not weights. Add IDs here to expand coverage.
DEFAULT_MODELS: tuple[str, ...] = (
    "Qwen/Qwen2.5-0.5B-Instruct",
    "meta-llama/Llama-3.2-1B-Instruct",
    "mistralai/Mistral-7B-Instruct-v0.3",
    "google/gemma-2-2b-it",
    "microsoft/Phi-3-mini-4k-instruct",
)

# Default output dir, resolved relative to *this script's* location so the
# layout holds regardless of CWD when invoked.
FIXTURES_DIR: Path = Path(__file__).resolve().parent / "fixtures" / "chat_templates"


@dataclass
class FetchedTemplate:
    """One cached template + provenance, recorded in manifest.json."""

    repo_id: str
    revision: str  # HF commit sha the template was pulled from (empty if unknown)
    template_path: str  # path to the .jinja
    config_path: str  # path to the .config.json
    template_bytes: int
    fetched_at: str  # ISO-8601 UTC


def _slug(repo_id: str) -> str:
    """`org/name` -> `org__name`, safe as a filename without losing readability."""
    return repo_id.replace("/", "__")


def _extract_template(cfg: dict) -> str:
    """Pull the chat_template out of a `tokenizer_config.json` dict.

    The field is usually a string. A few repos (e.g. mistral-community) ship it
    as a list of `{name, template}` objects — we take the first entry.
    """
    tpl = cfg.get("chat_template", "")
    if isinstance(tpl, list) and tpl:
        first = tpl[0]
        if isinstance(first, dict):
            tpl = first.get("template", "")
    return tpl if isinstance(tpl, str) else ""


def _revision_from_cache_path(path: str) -> str:
    """HF cache lays files out as `.../snapshots/<sha>/<filename>` — pull the sha.

    Use the path as-returned (a symlink); resolving it follows through to the
    deduped `blobs/<blob_hash>` storage and loses the snapshot sha.
    """
    p = Path(path)
    if p.parent.parent.name == "snapshots":
        return p.parent.name
    return ""


def _auth_hint(err: Exception) -> str:
    """Append a clear next step when an error looks gated/auth-shaped."""
    msg = str(err).lower()
    if "401" in msg or "403" in msg or "gated" in msg or "restricted" in msg:
        return " (looks gated — `huggingface-cli login` or set HF_TOKEN)"
    if "404" in msg or "not found" in msg:
        return " (repo not found — typo or moved?)"
    return ""


def fetch_template(
    repo_id: str,
    dest_dir: Path = FIXTURES_DIR,
    *,
    force: bool = False,
) -> Optional[FetchedTemplate]:
    """Cache one model's chat_template + tokenizer_config under `dest_dir`.

    Returns the metadata for the cached entry, or None if the fetch failed
    (gated, missing, network) — the caller logs the warning and continues so
    one inaccessible repo doesn't kill the whole conformance corpus.
    """
    from huggingface_hub import hf_hub_download  # local import: optional dep

    dest_dir.mkdir(parents=True, exist_ok=True)
    slug = _slug(repo_id)
    cfg_path = dest_dir / f"{slug}.config.json"
    tpl_path = dest_dir / f"{slug}.jinja"

    # Idempotency: if both files exist and `--force` wasn't passed, return the
    # cached entry without touching the network. Revision comes from the
    # manifest written by the last successful fetch_all().
    if not force and cfg_path.exists() and tpl_path.exists():
        revision = _revision_from_manifest(dest_dir, repo_id)
        return FetchedTemplate(
            repo_id=repo_id,
            revision=revision,
            template_path=str(tpl_path),
            config_path=str(cfg_path),
            template_bytes=tpl_path.stat().st_size,
            fetched_at=_iso_utc(),
        )

    try:
        local = hf_hub_download(repo_id, "tokenizer_config.json")
    except Exception as e:  # noqa: BLE001 — bubble up via warning + None
        print(f"!!! skip {repo_id}: {type(e).__name__}: {str(e).splitlines()[0]}{_auth_hint(e)}",
              file=sys.stderr)
        return None

    with open(local) as f:
        cfg = json.load(f)

    tpl = _extract_template(cfg)
    if not tpl:
        print(f"!!! skip {repo_id}: no chat_template in tokenizer_config.json",
              file=sys.stderr)
        return None

    cfg_path.write_text(json.dumps(cfg, indent=2) + "\n")
    tpl_path.write_text(tpl if tpl.endswith("\n") else tpl + "\n")

    return FetchedTemplate(
        repo_id=repo_id,
        revision=_revision_from_cache_path(local),
        template_path=str(tpl_path),
        config_path=str(cfg_path),
        template_bytes=len(tpl.encode("utf-8")),
        fetched_at=_iso_utc(),
    )


def fetch_all(
    models: Iterable[str] = DEFAULT_MODELS,
    *,
    force: bool = False,
    fixtures_dir: Path = FIXTURES_DIR,
) -> list[FetchedTemplate]:
    """Fetch each `models` entry; write a manifest of successes; return them."""
    results: list[FetchedTemplate] = []
    for repo in models:
        out = fetch_template(repo, fixtures_dir, force=force)
        if out is not None:
            results.append(out)
            short = (out.revision[:12] + "…") if out.revision else "(no-rev)"
            print(f"ok   {repo:<45}  {out.template_bytes:>5}B  {short}")
    manifest = fixtures_dir / "manifest.json"
    manifest.write_text(json.dumps([asdict(r) for r in results], indent=2) + "\n")
    return results


# ── Test-runner API ──────────────────────────────────────────────────────────


def cached_templates(fixtures_dir: Path = FIXTURES_DIR) -> list[Path]:
    """All `.jinja` fixtures currently on disk. For the conformance runner to iterate."""
    if not fixtures_dir.exists():
        return []
    return sorted(fixtures_dir.glob("*.jinja"))


def load_template(slug_or_repo: str, fixtures_dir: Path = FIXTURES_DIR) -> str:
    """Read one cached template by slug (`org__name`) or full `org/name` id."""
    slug = _slug(slug_or_repo) if "/" in slug_or_repo else slug_or_repo
    path = fixtures_dir / f"{slug}.jinja"
    if not path.exists():
        raise FileNotFoundError(
            f"{path} not present — run `python tests/fetch_reference_templates.py` first."
        )
    return path.read_text()


def load_config(slug_or_repo: str, fixtures_dir: Path = FIXTURES_DIR) -> dict:
    """The full tokenizer_config.json for one cached entry.

    Templates reference `bos_token` / `eos_token` (sometimes as objects with a
    `content` field, sometimes as bare strings); the conformance runner uses
    this to populate those template variables faithfully.
    """
    slug = _slug(slug_or_repo) if "/" in slug_or_repo else slug_or_repo
    path = fixtures_dir / f"{slug}.config.json"
    if not path.exists():
        raise FileNotFoundError(f"{path} not present")
    return json.loads(path.read_text())


# ── Helpers ──────────────────────────────────────────────────────────────────


def _iso_utc() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def _revision_from_manifest(fixtures_dir: Path, repo_id: str) -> str:
    """Best-effort: look up the recorded revision from a previous fetch_all."""
    manifest = fixtures_dir / "manifest.json"
    if not manifest.exists():
        return ""
    try:
        for entry in json.loads(manifest.read_text()):
            if entry.get("repo_id") == repo_id:
                return entry.get("revision", "") or ""
    except (OSError, ValueError):
        pass
    return ""


# ── CLI ──────────────────────────────────────────────────────────────────────


def _parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Cache HF chat_template fixtures for minja2's conformance corpus.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--force", action="store_true",
                   help="re-fetch even if a cached fixture exists")
    p.add_argument("--model", action="append", default=None, metavar="REPO_ID",
                   help="add another repo id to the fetch set (repeatable)")
    p.add_argument("--only", action="store_true",
                   help="with --model: fetch ONLY the named models (skip the defaults)")
    p.add_argument("--list", action="store_true",
                   help="list cached fixtures and exit (no network)")
    p.add_argument("--fixtures-dir", default=str(FIXTURES_DIR), metavar="PATH",
                   help=f"output directory (default: {FIXTURES_DIR})")
    return p.parse_args(argv)


def main(argv: Optional[list[str]] = None) -> int:
    args = _parse_args(sys.argv[1:] if argv is None else argv)
    fixtures_dir = Path(args.fixtures_dir)

    if args.list:
        cached = cached_templates(fixtures_dir)
        if not cached:
            print(f"(no fixtures at {fixtures_dir})")
            return 0
        for p in cached:
            print(f"{p.name:<45}  {p.stat().st_size:>5}B")
        return 0

    if args.only and args.model:
        models: list[str] = list(args.model)
    else:
        models = list(DEFAULT_MODELS) + list(args.model or ())

    print(f"fetching {len(models)} model(s) -> {fixtures_dir}")
    results = fetch_all(models, force=args.force, fixtures_dir=fixtures_dir)
    manifest = fixtures_dir / "manifest.json"
    print(f"\n{len(results)}/{len(models)} fetched. manifest -> {manifest}")
    return 0 if results else 1


if __name__ == "__main__":
    raise SystemExit(main())

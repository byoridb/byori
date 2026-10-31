#!/usr/bin/env python3
"""Read-only evaluation reader; preparation writes only a new disposable fixture."""

import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile


PROJECT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("dependency_context", PROJECT / "cli/dependency_context.py")
CONTEXT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CONTEXT)
DOCS = {"byori": "docs/engine-contract.md", "byoridb": "book/src/reference/api.md"}


def git(root, *args):
    return subprocess.run(["git", "-C", str(root), *args], check=True,
                          capture_output=True, timeout=30).stdout


def prepare(roots):
    manifest = json.loads((Path(__file__).parent / "session-recovery.json").read_text())
    CONTEXT._validate(manifest)
    session = Path(tempfile.mkdtemp(prefix="byori-dependency-pilot-"))
    snapshots, allowed = {}, {}
    for name, spec in manifest["repositories"].items():
        original = roots[name].resolve(strict=True)
        # A disposable local clone only: no source checkout/index/ref mutations.
        destination = session / name
        subprocess.run(["git", "clone", "--shared", "--no-checkout", "--",
                        str(original), str(destination)], check=True,
                       capture_output=True, timeout=30)
        git(destination, "update-ref", "HEAD", spec["revision"])
        paths = sorted({s["path"] for s in manifest["sources"] if s["repo"] == name} | {DOCS[name]})
        allowed[name] = paths
        for path in paths:
            body = CONTEXT._blob(destination, spec["revision"], path)
            target = destination / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(body)
        snapshots[name] = str(destination)
    report = CONTEXT.inspect_context(manifest, {k: Path(v) for k, v in snapshots.items()})
    if report["status"] != "ready":
        raise RuntimeError("Immutable source fixture was not ready")
    (session / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (session / "config.json").write_text(json.dumps({"roots": snapshots, "allowed": allowed}, indent=2) + "\n")
    (session / "brief.md").write_text(CONTEXT.render_context(report))
    print(json.dumps({"session": str(session), "status": report["status"],
                      "metrics": report["metrics"], "allowed_sources": allowed}, indent=2))


def tokenized_size(text):
    try:
        import tiktoken
        return len(tiktoken.get_encoding("o200k_base").encode(text, disallowed_special=()))
    except (ImportError, OSError):
        return None


def summarize(session):
    result = {}
    for arm in ("source", "docs", "context"):
        rows = [json.loads(line) for line in (session / f"{arm}.reads.jsonl").read_text().splitlines()]
        token_counts = [row["payload_tokens_o200k_base"] for row in rows]
        result[arm] = {
            "reads": len(rows), "payload_bytes": sum(row["payload_bytes"] for row in rows),
            "payload_tokens_o200k_base": sum(token_counts) if all(x is not None for x in token_counts) else None,
            "actual_model_tokens": None,
            "note": "Payload-only o200k_base encoding; excludes prompts, tool wrappers, model output, reasoning, caching, curation and update costs.",
        }
    return result


def read(args):
    session = args.session.resolve(strict=True)
    config = json.loads((session / "config.json").read_text())
    manifest = json.loads((session / "manifest.json").read_text())
    roots = {k: Path(v) for k, v in config["roots"].items()}
    parts = []
    if args.action == "brief":
        if args.arm != "context":
            raise ValueError("The brief belongs only to the context arm")
        parts.append(CONTEXT.render_context(CONTEXT.inspect_context(manifest, roots)))
    elif args.action == "index":
        parts.append(json.dumps({"revisions": manifest["repositories"],
                                "sources": config["allowed"]}, indent=2))
    else:
        repo = args.repo
        path = DOCS.get(repo) if args.action == "docs" else args.path
        if repo not in roots or path not in config["allowed"][repo]:
            raise ValueError("Use an indexed source")
        revision = manifest["repositories"][repo]["revision"]
        lines = CONTEXT._blob(roots[repo], revision, path).decode("utf-8").splitlines()
        parts.append(f"Source: {repo}@{revision}:{path}\n")
        if args.action == "search":
            if not args.term or len(args.term) > 100:
                raise ValueError("Use a short literal search term")
            hits = [(i, line) for i, line in enumerate(lines, 1) if args.term.lower() in line.lower()]
            parts.extend(f"{i}: {line[:500]}" for i, line in hits[:40])
            if len(hits) > 40:
                parts.append("Additional matches omitted; narrow the search.")
        elif args.action == "docs":
            parts.extend(f"{i}: {line}" for i, line in enumerate(lines, 1))
        else:
            if not 1 <= args.start <= args.end <= len(lines) or args.end - args.start >= 120:
                raise ValueError("Read 1-120 existing lines per request")
            parts.extend(f"{i}: {lines[i-1]}" for i in range(args.start, args.end + 1))
    output = "\n".join(parts) + "\n"
    record = {"action": args.action, "repo": args.repo, "path": args.path,
              "start": args.start, "end": args.end, "term": args.term,
              "payload_bytes": len(output.encode("utf-8")),
              "payload_tokens_o200k_base": tokenized_size(output),
              "actual_model_tokens": None}
    # Reader accounting is instrumentation, not a security boundary or billing API.
    with (session / f"{args.arm}.reads.jsonl").open("a", encoding="utf-8") as log:
        log.write(json.dumps(record) + "\n")
    print(output, end="")
    print("\nREAD_METRICS " + json.dumps(record))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prep = commands.add_parser("prepare")
    prep.add_argument("--byori", type=Path, required=True)
    prep.add_argument("--byoridb", type=Path, required=True)
    reader = commands.add_parser("read")
    reader.add_argument("--session", type=Path, required=True)
    reader.add_argument("--arm", choices=("source", "docs", "context"), required=True)
    reader.add_argument("action", choices=("index", "docs", "brief", "search", "source"))
    reader.add_argument("--repo")
    reader.add_argument("--path")
    reader.add_argument("--term")
    reader.add_argument("--start", type=int, default=1)
    reader.add_argument("--end", type=int, default=1)
    summary = commands.add_parser("summary")
    summary.add_argument("--session", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "prepare":
        prepare({"byori": args.byori, "byoridb": args.byoridb})
    elif args.command == "summary":
        print(json.dumps(summarize(args.session), indent=2))
    else:
        read(args)


if __name__ == "__main__":
    main()

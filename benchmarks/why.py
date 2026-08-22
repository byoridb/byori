#!/usr/bin/env python3
"""Ask a repository's own history the questions its code cannot answer.

The claim Byori makes is narrow and checkable: there are facts about a codebase
that are not in the codebase, and this graph puts them a question away. The way to
support that claim is not a screenshot — it is a fixed set of questions whose
answers can be verified against the repository, run the same way every time.

    benchmarks/why.py --repository /tmp/redis --suite benchmarks/redis.json

Each case names a question and the evidence a correct answer has to cite: a commit,
a pull request, an issue, a document path. The run scores a case as passed only when
that evidence appears in an answer the server returned — not when the answer merely
sounds plausible. There is no model in the loop, so the number measures retrieval
and not a model's prose.

Deliberately unforgiving in two directions:
  - a case whose evidence is missing fails, even if the right memory ranked first
  - `--baseline` runs the same suite against an empty space, which is what an agent
    has without this graph; a suite where the baseline also scores is a bad suite,
    because the answer was inferable from the question
"""
import argparse
import contextlib
import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import time
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]


def load_mcp(space):
    """Import the MCP server bound to one space, as a host would connect to it."""
    home = pathlib.Path(os.environ.get("BYORIDB_HOME", "~/.byoridb")).expanduser()
    env_file = home / "env"
    if env_file.exists():
        for line in env_file.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                if key.startswith("BYORIDB_"):
                    os.environ.setdefault(key, value)
    os.environ["BYORIDB_MEMORY_SPACE"] = space
    os.environ["BYORIDB_MCP_PROFILE"] = "safe"
    # This repository's server, not the installed one: the benchmark measures the
    # code in the checkout it ships with, and an older install would silently score
    # a version nobody is changing.
    source = ROOT / "mcp" / "byoridb_mcp.py"
    if not source.is_file():
        source = home / "byoridb_mcp.py"
    spec = importlib.util.spec_from_file_location(
        "byoridb_mcp_benchmark_%s" % uuid.uuid4().hex, source
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def ingest(repository, space, limit):
    """Run `byori init` into `space`, the way a new user would."""
    started = time.time()
    result = subprocess.run(
        [
            sys.executable, str(ROOT / "cli" / "byori.py"), "init", str(repository),
            "--space", space, "--limit", str(limit),
        ],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=3_600,
    )
    if result.returncode != 0:
        raise SystemExit("byori init failed:\n" + result.stdout)
    return result.stdout, time.time() - started


def evaluate(module, suite, limit):
    cases = []
    for case in suite["cases"]:
        answer = module.tool_why({"question": case["question"], "limit": limit})
        haystack = json.dumps(answer, ensure_ascii=False).lower()
        missing = [
            token for token in case["evidence"]
            if token.lower() not in haystack
        ]
        top = answer["answers"][0]["name"] if answer["answers"] else None
        cases.append({
            "question": case["question"],
            "passed": not missing,
            "missing": missing,
            "top_answer": top,
            "answer_count": len(answer["answers"]),
            "evidence_backed": [
                a["name"] for a in answer["answers"] if a["confidence"] == "evidence-backed"
            ],
        })
    return cases


def report(name, cases):
    passed = sum(1 for case in cases if case["passed"])
    print("\n%s: %d/%d" % (name, passed, len(cases)))
    for case in cases:
        mark = "pass" if case["passed"] else "FAIL"
        print("  [%s] %s" % (mark, case["question"]))
        if case["top_answer"]:
            print("         top: %s" % case["top_answer"])
        if case["missing"]:
            print("         missing evidence: %s" % ", ".join(case["missing"]))
    return passed


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repository", required=True)
    parser.add_argument("--suite", required=True)
    parser.add_argument("--space", help="space to ingest into (default: derived from the suite)")
    parser.add_argument("--limit", type=int, default=20_000, help="commits to read")
    parser.add_argument("--answers", type=int, default=3, help="answers per question")
    parser.add_argument(
        "--baseline", action="store_true",
        help="also score an empty space, which is what an agent has without this graph",
    )
    parser.add_argument("--json", action="store_true")
    parser.add_argument(
        "--keep", action="store_true",
        help="leave the ingested space behind instead of dropping it",
    )
    args = parser.parse_args()

    suite = json.loads(pathlib.Path(args.suite).read_text(encoding="utf-8"))
    space = args.space or suite.get("space") or "byori_bench_%s" % uuid.uuid4().hex[:8]

    print("suite: %s (%d cases)" % (suite.get("name", args.suite), len(suite["cases"])))
    output, seconds = ingest(args.repository, space, args.limit)
    print(output.strip().splitlines()[-1])
    print("ingest: %.1fs" % seconds)

    results = {"suite": suite.get("name"), "space": space, "ingest_seconds": round(seconds, 1)}
    module = load_mcp(space)
    results["with_memory"] = evaluate(module, suite, args.answers)
    passed = report("with the project graph", results["with_memory"])

    if args.baseline:
        empty = "byori_bench_empty_%s" % uuid.uuid4().hex[:8]
        baseline_module = load_mcp(empty)
        results["baseline"] = evaluate(baseline_module, suite, args.answers)
        report("with an empty graph (what an agent has otherwise)", results["baseline"])
        with contextlib.suppress(Exception):
            baseline_module._raw_query("DROP SPACE %s" % empty)

    if not args.keep:
        with contextlib.suppress(Exception):
            module._raw_query("DROP SPACE %s" % space)
            print("\ndropped %s" % space)

    if args.json:
        print(json.dumps(results, ensure_ascii=False, indent=2))
    return 0 if passed == len(results["with_memory"]) else 1


if __name__ == "__main__":
    raise SystemExit(main())

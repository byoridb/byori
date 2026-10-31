# Dependency context reuse — bounded pilot

Authorized experiment: 2026-09-12. The owner reopened product strategy from first
principles and described three failures: agents interpreting different documents,
consumers missing changes in another repository, and repeatedly reading that
repository at high token cost. This pilot tests reusable, version-bound consumer
knowledge. It is not approval of a personal-memory platform or a new release.

## One task

Explain how Byori's Python MCP client should recover from ByoriDB HTTP session
loss without retrying permission failures or failed fresh logins. Distinguish
the inspected source commits from installed/released engine behavior.

The two repositories are read-only inputs. No engine restart, login, installation,
credential access, configuration edit, remote service, API model call, or upstream
checkout mutation is required. Existing uncommitted handbook work is preserved
and paused, not deleted or declared complete. PRODUCT.md's earlier app-first
plan is historical context, not a constraint on this experiment.

## Small implementation contract

`cli/dependency_context.py` is a standalone stdlib-only experimental module,
not yet wired into the installer, app, or MCP. Its public Python API is:

```python
inspect_context(manifest: dict, roots: dict[str, pathlib.Path]) -> dict
render_context(report: dict) -> str
```

CLI: `python3 cli/dependency_context.py --manifest FILE --repo NAME=PATH`
with repeatable `--repo` and optional `--format json` (default Markdown).
Exit 0 means source bindings match; exit 1 means review is needed; malformed
input exits 2. CLI reads only; generated context goes to stdout.

Manifest schema 1:

```json
{
  "schema_version": 1,
  "title": "Consumer-specific subject",
  "task": "The bounded question this material helps answer",
  "repositories": {"producer": {"revision": "FULL_GIT_COMMIT_HASH"}},
  "sources": [
    {"id": "api", "repo": "producer", "path": "src/api.py",
     "sha256": "SHA256_OF_ENTIRE_COMMITTED_FILE"}
  ],
  "claims": [
    {"id": "recover", "kind": "consumer_policy", "text": "Curated claim",
     "evidence": [{"source": "api", "start": 1, "end": 3}]}
  ]
}
```

Kinds: `contract`, `consumer_policy`, `limitation`. Claims are manually curated
for this pilot; hashes do not establish semantic correctness, test execution,
release inclusion, or runtime compatibility. The report must explicitly say so.

Inputs are closed and bounded: up to 4 repositories, 12 sources, 20 claims;
1 MiB per committed source and 4 MiB total; 100 lines per evidence range.
IDs are `[a-z][a-z0-9_-]{0,63}`; revisions are full 40- or 64-character lowercase
hex hashes. Paths are relative, cannot traverse or name sensitive `.env`/key
files, and must refer to normal Git blobs, never symlinks or submodules. Duplicate
IDs, unknown fields, missing evidence, invalid ranges and invalid hashes fail.

The module reads exact Git objects, not a moving file as its evidence. It checks
HEAD matches the declared revision and checks each selected working-tree file
against its committed blob. A missing repository/source, changed revision,
selected dirty/deleted/symlink file, or hash mismatch yields `needs_review` and
withholds ALL claim bodies. Revision changes outside the selected sources also
require review in v1; no automatic semantic revalidation is claimed. Unrelated
uncommitted files do not invalidate a selected-source binding.

Report keys include `schema_version`, `status` (`ready`/`needs_review`), `title`,
`task`, `repositories`, `diagnostics`, `claims`, `evidence`, `metrics`, and
`limitations`. Ready claims retain id/kind/text/evidence; rendered citations
include repo, full commit, path and one-based lines. A needs-review report keeps
claims/evidence empty. Diagnostic entries have `code` and optional repo/source
IDs, but no raw source, credentials, absolute paths or subprocess stderr.

Required diagnostic codes: `revision_mismatch`, `source_missing`,
`source_hash_mismatch`, `working_tree_changed`, `repository_unavailable`.
Malformed manifest raises `ContextError` (a ValueError subclass).

Metrics count bytes checked and context/evidence size, NOT actual model tokens.
Reading a file inside this local tool does not put that entire file into the LLM
context. Source validity must be rechecked each time a brief is served; a copied
Markdown brief is only a dated snapshot and cannot perform this check by itself.

## Evaluation

Compare (A) source exploration, (B) the existing maintained compatibility docs,
and (C) the version-bound consumer brief. Every arm may request additional
source evidence; do not force baseline agents to read an entire repository.
Use the same question and model settings, separate fresh contexts, source
citations and a common correctness rubric. Record what was read. One run per
arm is a plumbing pilot, not a statistically meaningful performance result.

Correctness covers query 401 recovery order/bound, 403 and fresh-login behavior,
400 legacy boundary, endpoint-specific rules, ID precision, and the distinction
between inspected source and installed/released versions. Refusing an unsupported
inference is correct. A matching source hash alone cannot make a claim correct.

Real savings require measured input/output/cached tokens, exploration and repair
work, plus initial curation/build and update costs. If the current evaluation
surface does not expose token counts, report them unavailable; never rename
characters, bytes or file-count reductions as token savings.

Tests must also mutate a temporary producer fixture and confirm stale claims
are withheld, exercise conflicting/invalid inputs, and verify no runtime/network
or source-repository writes. This pilot does not complete the Claude/Codex
cross-provider evaluation or prove superiority over maintained Markdown.

## Execution record

First plumbing pilot completed on 2026-09-12; product-value gate NOT passed.
See [recorded results](../benchmarks/dependency-context/results/2026-09-12/README.md)
for answers, read logs, metrics, and blind grading. Three fresh native agents of
the same model/settings compared source-first, existing-docs-first and brief-first
access. This was not a Claude/Codex cross-provider run.

The curated brief checked five committed blobs (196,823 bytes locally) and emitted
7,421 Markdown bytes. All three agents found the selected source/documentation
conflict; brief-first still made 18 reader calls versus 19 in each baseline.
Payload-only o200k_base counts were 14,462 / 14,237 / 12,243. This excludes prompt,
tool-wrapper, reasoning/output, caching and curation/update costs. It is NOT an
actual provider usage or net-savings measurement.

The strict prewritten rubric over-penalized missing supplemental details and
was unsuitable as a headline quality score; raw grading is retained rather than
retuned after seeing the answers. No material implementation error was established
by the blind reviewer, but this is not runtime correctness certification.

The live worktrees correctly returned needs_review and withheld every claim
because selected Byori files had uncommitted changes. Temporary source fixtures
were used for the ready-brief experiment without altering either original checkout.

Next hypothesis, NOT yet proven: attach reusable executable contract evidence and
explicit change invalidation, then test whether an agent can safely avoid repeated
source review. Do not add app/plugin/tunnel/DB infrastructure to explain away this
pilot's modest result. First improve the task and preregister a core-behavior rubric
on another dependency case, including ordinary maintained documentation as a baseline.

## Reproduce the inspection

```sh
python3 cli/dependency_context.py \
  --manifest benchmarks/dependency-context/session-recovery.json \
  --repo byori=/path/to/byori --repo byoridb=/path/to/byoridb --format json
python3 -m unittest discover -s tests -p 'test_dependency_context*.py' -v
```

The declared commits and selected files must match. A needs_review result is an
expected safety outcome, not permission to clean or reset the user's checkout.
For an explicit, disposable evaluation fixture, `evaluate.py prepare --byori PATH
--byoridb PATH` creates local shared clones and materializes only committed selected
files. It does not switch or modify the originals. Its returned session path can be
passed to `evaluate.py read --session PATH --arm source|docs|context ...`.

`evaluate.py summary --session benchmarks/dependency-context/results/2026-09-12`
recomputes the retained payload metrics. The optional benchmark tokenizer is
`tiktoken` with `o200k_base`; the product inspector itself is stdlib-only.

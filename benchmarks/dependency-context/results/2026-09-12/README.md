# First dependency-context pilot: modest reuse, not proven token savings

## Outcome

The version/source guard works, and a curated brief made the relevant contradiction
explicit. However, brief-first still performed almost as many reads as both
baselines. This run does not justify building a platform or claiming large savings.

| Arm | Reader calls | Emitted payload bytes | Payload encoded with o200k_base |
|---|---:|---:|---:|
| Source-first | 19 | 56,293 | 14,462 |
| Existing-docs-first | 19 | 54,356 | 14,237 |
| Version-bound brief-first | 18 | 45,210 | 12,243 |

The last column is a reproducible encoding of the reader's emitted payload, NOT
actual input/output usage reported by the model provider. Brief-first is 15.3%
below source-first and 14.0% below docs-first on that narrow metric. Tool wrappers,
metering text, prompts, model output/reasoning, cached-input treatment, source
curation, preparation, updates and repairs are excluded. Host-side truncation or
compaction is not observable through this meter. **Actual and net token savings
are unavailable.** Initial curation cost has not been recovered or amortized here.

## Method and scope

- Three fresh native subagents, no inherited conversation, each `gpt-5.6-sol`,
  reasoning effort `high`; one run per arm. No Claude/Codex cross-provider test.
- Same implementation-advice question about session-loss recovery, permission
  failures, failed login, pinning/bootstrap exceptions, ID precision and endpoint
  differences. This was not an end-to-end code-change or live-runtime task.
- Same six-file relevant-source index, chosen before the runs. All arms could
  search and read additional indexed evidence. Baselines were NOT forced to read
  whole repositories or whole documents. Broad repository discovery was excluded.
- The docs arm started from the existing consumer compatibility document and
  producer API document; these are real existing docs, not an artificially empty
  baseline. Their disagreements are part of the selected case. A freshly corrected
  ordinary document is still a necessary future baseline.
- Same 20-invocation cap, source windows up to 120 lines, and answer ceiling of
  900 words. Calls ended near the cap, so the cap may affect exploration patterns.
- The brief was manually curated for this question, not automatically generated
  knowledge extraction. It contained nine claims from five source files, with
  full-blob SHA256 and exact source spans. The measured local inspection read
  196,823 source bytes internally and rendered 7,421 Markdown bytes.
- Source snapshots: Byori `566b8b355f12e8db271e43f2e203555daccbaed5`, ByoriDB
  `a5c6223a4fd9346dc94860580e4bd1c95961ef5c`. Temporary local shared clones
  materialized selected committed files; original checkouts were not changed.
- Original Byori's selected MCP/test files were dirty. The real-root inspector
  returned `needs_review`, two `working_tree_changed` diagnostics, and no claim
  bodies/evidence. It did not silently certify HEAD against different working code.
- `tiktoken` 0.12.0 / `o200k_base` was used only for payload accounting; it is not
  asserted to be the evaluator model's tokenizer or a billing measurement.

## What the agents found

All three answers recognized a source/documentation discrepancy: the selected
Byori documentation/docstring describes query permission failure as
403/PERMISSION_DENIED, but the pinned ByoriDB query handler maps SessionNotFound
to 401/SESSION_EXPIRED and other service errors to 400/QUERY_ERROR. The service's
live permission denial is AuthFailed. The producer API document agrees with that
source implementation. This does not identify the installed engine or establish
behavior of any released binary.

All three provided bounded recovery and endpoint-specific guidance. A blind
reviewer found no established material implementation error against the supplied
rubric. This is a textual assessment, not execution, proof of equal accuracy, or
validation of every additional assertion in the answers.

## Rubric failure, preserved rather than hidden

The rubric was authored before the evaluator runs, with eight all-or-nothing
criteria. Each bundled core behavior with many mandatory supplemental citations
and caveats. Strict scores were source **0/8**, docs **1/8**, brief **3/8**.
The blind grader explicitly warned that these are exhaustive-coverage scores,
not implementation-correctness rankings: omission of a provenance aside could
zero a largely correct answer. They are **not used as headline quality evidence**.

The anonymized grading map is X=docs, Y=context, Z=source. Raw answers, grading,
and read logs are retained. Do not rewrite the rubric after seeing these answers
and present the new score as preregistered success.

## Next experimental question

Can reusable executable contract evidence, bound to source versions and explicit
change invalidation, reduce reinspection without losing correctness? The present
manually curated prose did not eliminate reinspection. This is a hypothesis, not
a proven causal explanation for the agents' choices.

Choose another real dependency task, preregister a smaller core-behavior rubric,
include a freshly maintained ordinary-doc baseline, and count first-build and
update costs as well as repeated use. A user-visible product, automatic extraction,
graph storage, plugins and distribution remain undecided.

## Reproduce accounting

From the Byori repository:

```sh
python3 benchmarks/dependency-context/evaluate.py summary \
  --session benchmarks/dependency-context/results/2026-09-12
python3 -m unittest discover -s tests -p 'test_dependency_context*.py' -v
```

`metrics.json` is generated from the three `*.reads.jsonl` files, which record
operation, selected range, emitted byte count and optional payload-token count.
The meter is instrumentation, not a sandbox that prevents out-of-band reads.
The preserved answers are `source-answer.md`, `docs-answer.md` and
`context-answer.md`; detailed assessment is `blind-grading.json`.

Validation for this slice: 40 inspector/reader-accounting tests, targeted Ruff,
and Git whitespace checks. Earlier interrupted handbook work was neither fixed
nor certified by these tests. Nothing was installed, merged, pushed or released.

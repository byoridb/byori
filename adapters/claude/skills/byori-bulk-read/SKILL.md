---
name: byori-bulk-read
description: >-
  Protect the expensive model's context by delegating bulk reading to the cheap
  byori-bulk-reader agent. Use BEFORE reading any file larger than about 32 KB
  (~800 lines), before sweeping several files just to understand them, and when a
  summary of a file is enough ("이 파일 뭐하는 거야", "구조 파악해줘", "summarize
  this module"). The delegate returns a structural digest with line ranges and
  caches it in the ByoriDB graph, so an unchanged file costs nothing to ask about
  twice. Not for files you are about to edit — read those sections yourself with
  a ranged Read.
---

# Bulk reading through the cheap delegate

Reading a large file into your own context spends the most expensive tokens in
the session on I/O. The `byori-bulk-reader` agent (a cheap model) reads instead,
returns a **digest** — purpose, structure with line ranges, public surface,
warnings — and stores it in this project's ByoriDB graph as a `file-digest`
note named `digest:<repository-relative-path>`.

The cache is content-addressed: the note records the file's `content-sha256:`,
so an unchanged file is answered from the graph with no model reading it at
all, across sessions and across agents. A changed file is re-digested and the
note updated in place (history kept).

## When to delegate

- Any file over about **32 KB (~800 lines)** that you have not been asked to edit.
- Several files at once when what you need is understanding, not exact text.
- Output-heavy survey work: documentation passes, review orientation, i18n sweeps.

Delegate with one Agent call and name the files and the question:

```
Agent(subagent_type="byori-bulk-reader",
      prompt="Digest mcp/byoridb_mcp.py and tests/smoke_mcp.py.
              I need the MCP dispatch flow and where profiles are enforced.")
```

## When NOT to delegate

- **You are about to edit the file.** The digest gives you line ranges; use them
  for a targeted `Read` with `offset`/`limit` and read the real text you will
  change. Never edit on the strength of a summary.
- **Small files.** Under the threshold, reading it yourself is faster than the
  round trip.
- **Safety-critical judgement** — debugging a subtle failure, security review,
  architecture decisions. A digest orients you; the judgement needs the source.

## Trust rule

Every delegate answer ends with `worker-generated — verify before editing`.
Treat it exactly like recalled memory: good enough to navigate by, not good
enough to edit by. The digest tells you **where** to look; the ranged read tells
you **what is there**.

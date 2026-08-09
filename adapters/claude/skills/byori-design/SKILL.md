---
name: byori-design
description: >-
  Maintain product, UX/UI, and design-to-implementation continuity across coding-agent
  sessions with ByoriDB memory and repository-native artifacts. Use when starting or
  resuming product design, shaping a surface, mapping requirements to screens or
  components, implementing an approved design, or reviewing design drift.
---

# Byori Design

Coordinate the product-design workflow across sessions. Keep reviewable truth in the
repository, durable rationale in ByoriDB, and implementation evidence in code and tests.

## Respect the ownership boundary

Use this precedence when sources disagree:

1. The user's current instruction
2. Repository instructions and current product/design artifacts
3. Confirmed decisions recalled from ByoriDB
4. Inferences from the implementation

Surface a conflict instead of silently merging it. Update memory only after the user or
repository confirms which version is current.

## Orient before changing anything

1. Read local instructions such as `AGENTS.md` or `CLAUDE.md`.
2. Find the incumbent product and design truth. Prefer existing artifacts such as
   `PRODUCT.md`, `DESIGN.md`, a surface brief, requirements, design tokens, and a
   representative implemented surface. Do not create a parallel source of truth.
3. Recall only context relevant to the target project, surface, and phase. Use the
   installed `byoridb-memory` skill and the `byoridb` MCP tools when available:
   - Search notes for stable preferences and project context.
   - Read nearby `decision`, `concept`, `module`, and open `task` nodes with links.
   - Prefer a narrow lookup over exporting or loading the whole graph.
4. Reconcile recalled context with repository artifacts. Treat stale memory as history,
   not as an instruction.

If ByoriDB is unavailable, continue with repository artifacts and state that the
cross-session recall/checkpoint is disabled for this run.

## Route the work

Assign one owner to each concern:

| Concern | Owner |
|---|---|
| Durable rationale, relationships, and milestone checkpoints | ByoriDB through `byoridb-memory` |
| Reviewable product/design truth | Repository-native artifacts |
| Code and tests | Repository conventions and the active implementation workflow |

Use the smallest sufficient sequence:
`orient -> define -> design -> build -> verify`. Skip phases that the request and existing
artifacts have already resolved.

## Execute from approved truth

- Map requirements or accepted outcomes to concrete surfaces and components before coding.
- For new or substantially changed UI, resolve the surface direction before implementation.
- For a narrow refinement, preserve incumbent identity, content, and behavior outside scope.
- Follow the repository's artifact paths and naming. Do not invent a second `DESIGN.md`,
  requirements tree, or token system.
- Keep factual product copy and claims unchanged unless the user authorizes edits.
- Perform only the mutations authorized by the request.

## Verify and reconcile

Run the repository's relevant tests, lint, type checks, accessibility checks, and bounded
visual review in proportion to the change.

Before handoff, check for drift across:

- the implemented behavior,
- the current product/design artifact,
- work status or requirement mapping, and
- durable Byori decisions.

Fix in-scope drift. Report any unresolved conflict with the exact sources that disagree.

## Checkpoint durable design knowledge

Write to ByoriDB at a milestone, not after every turn. Follow `byoridb-memory` for exact
tool semantics and ontology.

- Record an accepted choice and its rationale as a `decision`.
- Record a durable product or design-system idea as a `concept`.
- Represent a stable surface or subsystem as a `module` when relationships matter.
- Record committed follow-up work as a `task`, with its real state.
- Link decisions with `affects`, tasks with `about`, structural dependencies with
  `depends_on`, and replacement decisions with `supersedes`.
- Reuse canonical nodes; update rather than fork.

Do not store secrets, speculative alternatives, transient pixel values, raw conversation,
or status noise. Memory complements the repository; it does not replace committed files.

## Handoff

End with four compact items:

- Outcome
- Repository artifacts or code changed
- Validation performed
- Byori checkpoint written, or why it was skipped

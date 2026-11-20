# Byori Workspace Surface Brief

## Approved refinement — 2026-11-20

This refinement supersedes the historical composition and visible inventory below where they
disagree. Preserve the native project workbench and the real terminal; reduce repeated choices
and visual scanning rather than introduce a new visual identity.

- Compact collapsed project rows without separator-only list rows. Keep task/session identity
  on two lines. User-pinned projects retain stable ordering above other projects; an explicit
  all/open-session filter and search never change the selected terminal.
- Search project, task, branch and session names. Command-K opens a keyboard-accessible quick
  switcher with lineage in each result. The status-bar open-session action uses the same switcher.
- New Session prioritizes task title, agent/model, then the recommended work location. Keep the
  selected strategy, destination branch and consequential confirmations visible. Put the optional
  alias, procedure, Context depth and CLI arguments behind a native advanced disclosure.
  Remember only successful project-scoped agent/model choices; never restore elevated execution
  flags or dirty-checkout consent. Cancel creates no task, checkout or session.
- Agent settings provide inventory search and ownership filters. Rows lead with name and honest
  state; paths and maintenance actions live in disclosure/menu details. Unknown or failed MCP
  inventory has no fabricated zero count and offers a local retry action. Registration is not a
  verified live connection or authentication result.
- Use consistent Korean labels for the changed workspace flows. Recoverable task removal is
  called archive and offers Undo after success, preserving the archived task identity. Existing
  managed-worktree deletion remains a separate explicitly destructive operation.
- The status bar exposes open-session navigation and project-memory access. Elapsed time remains
  available as detail, and the displayed launch model never claims to observe in-CLI changes.

Acceptance: verify narrow and wide native windows, light/dark semantic colors, keyboard search,
filtering without terminal replacement, session defaults and advanced safety controls, inventory
failure/empty distinctions, and archive/Undo including partial failure. No user data is archived
or provider configuration changed merely to demonstrate these controls.

- Scope/mode: native macOS workspace, Operate mode.
- Audience/job: a local developer selects a project and source tree, then works in a real interactive coding-agent terminal without losing project knowledge.
- Primary task: create or open a trusted local project, navigate Project → SourceTree/Worktree → Task → Session, create a session with one recorded launch agent/model, interact with it, and inspect Files, Git, or ByoriDB Context.
- Constraints: no automatic prompt fan-out, no multi-terminal comparison, no Byori agent/model switcher inside a running session, no invented remote/team capabilities, and Settings stays outside primary navigation.
- Approved direction: C is the composition authority; A contributes only the richer ByoriDB Context treatment. Approved comp: `.impeccable/mocks/byori-workspace-c-sourcetree-first.png`. Supporting reference: `.impeccable/mocks/byori-workspace-a-balanced.png`.
- Memorable moment: a selected session reveals one uninterrupted terminal canvas while its source-tree lineage stays visible at left and durable project knowledge stays one inspector tab away.
- Not literal: generated terminal output, dates, paths, filenames, exact widths, and generated card copy are illustrative; runtime truth and native controls replace them.
- Unresolved: persistence across full application termination is not promised in this slice; sessions remain owned by the app-level broker while Byori is running, including when its window closes.

## Implementation grammar

- Component language: standard SwiftUI split views, outline/list rows, toolbar controls, tabs, disclosures, and sheets; no dashboard card grid.
- Corners/elevation: terminal and main panes are edge-bound; native controls keep system radii; Context records may use a restrained 12pt grouped surface with either separator or subtle fill, never stacked border plus shadow.
- Lines/type: 1px semantic separators; system UI type for chrome, system monospaced type only inside the terminal; hierarchy comes from weight and spacing rather than decorative labels.
- Color: neutral light macOS chrome, near-black terminal, restrained teal selection/running accent, semantic amber/red/green only for real states.

## Visible inventory

| Ingredient | Commitment | Medium |
|---|---|---|
| Project bootstrap | Create a named local project or open any folder; show the destination and confirm before initializing Git in an existing folder | Native `Menu`, sheet, `NSOpenPanel`, and confirmation dialog |
| Project/source tree/task/session hierarchy | 280–300pt left outline; nesting is always visible | Semantic SwiftUI `List`/`DisclosureGroup` |
| New Session action | Small `+` on every eligible source-tree/task row plus toolbar/shortcut; exact clicked target survives sheet presentation | Native `Button` and sheet |
| Session identity | Editable generated two-word name; recorded launch provider/model remains secondary identity and legacy fallback | Semantic text + SF Symbols |
| Interactive terminal | Dominant center region, one visible session at a time | PTY-backed AppKit terminal host with semantic accessibility label |
| Terminal input helpers | Clipboard images become private temporary PNG paths; installed Skill/plugin commands insert without execution | SwiftTerm paste override + native `Menu` |
| Session controls | Running state, Stop, terminal focus/resize | Native toolbar controls |
| Files/Git/Context | 300–320pt right inspector with one selected tab | SwiftUI segmented/tab navigation and outline/list content |
| ByoriDB Context | Decision/module/task checkpoint rows with provenance and empty/error states | SwiftUI list/grouped rows fed by project space |
| Truthful status bar | 28pt bottom row for verified ByoriDB, checkout, session, Context, elapsed-time, and operation state; no invented provider quota | Semantic text, dots, dividers, progress, and Cancel |
| Settings | Bottom-left entry plus one retained native Settings window; per-agent MCP/Skill inventory is bounded and secret-redacted | SF Symbol + native Settings window |

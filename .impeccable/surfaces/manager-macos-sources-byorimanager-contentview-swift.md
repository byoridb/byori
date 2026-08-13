---
version: 1
slug: "manager-macos-sources-byorimanager-contentview-swift"
primary_target: "manager/macos/Sources/ByoriManager/ContentView.swift"
related_targets: ["manager/macos/Sources/ByoriManager/ByoriManagerApp.swift","manager/macos/Sources/ByoriManager/WorkspaceView.swift","manager/macos/Sources/ByoriManager/WorkspaceViewModel.swift"]
---

# Byori Workspace Surface Brief

- Scope/mode: native macOS workspace, Operate mode.
- Audience/job: a local developer selects a project and checkout, then works directly in a real coding-agent terminal without losing project context.
- Primary task: navigate Project → Checkout/Worktree → Task → Session, create a session with one recorded launch agent/model, interact with its terminal, insert an installed command when useful, and inspect Files, Git, or ByoriDB Context.
- Constraints: Byori never interprets terminal output or executes a suggested command on selection. No automatic prompt fan-out, multi-terminal comparison, in-session Byori agent/model switcher, invented remote/team capabilities, or Settings in primary navigation.
- Approved direction: C is the composition authority; A contributes only the richer ByoriDB Context treatment. Approved comp: `.impeccable/mocks/byori-workspace-c-sourcetree-first.png`. Supporting reference: `.impeccable/mocks/byori-workspace-a-balanced.png`.
- Memorable moment: a selected session opens directly on one uninterrupted terminal, with installed commands in a compact menu and durable project knowledge one inspector tab away.
- Not literal: generated terminal output, dates, paths, filenames, exact widths, and generated card copy are illustrative; runtime truth and native controls replace them.
- Unresolved: provider adapters do not yet expose structured choice payloads, so the terminal remains the truthful interaction surface.

## Implementation grammar

- Component language: standard SwiftUI split views, outline/list rows, toolbar controls, native menus, segmented inspector tabs, disclosures, and sheets; no dashboard card grid.
- Corners/elevation: the terminal pane is edge-bound; native controls keep system radii; Context records may use a restrained 12pt grouped surface, never stacked border plus shadow.
- Lines/type: 1px semantic separators; system UI type for chrome, with system monospaced type reserved for terminal output, filesystem paths, and elapsed-time measurements; hierarchy comes from weight and spacing rather than decorative labels.
- Color: neutral light macOS chrome, near-black terminal, restrained teal selection/running accent, semantic amber/red/green only for real states.

## Visible inventory

| Ingredient | Commitment | Medium |
|---|---|---|
| Project/checkout/task/session hierarchy | 280–300pt left outline; nesting and checkout kind are always visible | Semantic SwiftUI `List`/`DisclosureGroup` |
| New Session action | Small `+` on every eligible checkout/task row plus toolbar/shortcut; exact clicked target survives sheet presentation | Native `Button` and sheet |
| Checkout identity | Launch sheet names Primary, Byori worktree, or External and shows the exact working directory before launch | Native `Picker`, `LabeledContent`, selectable path text |
| Session identity | Editable generated two-word name; recorded launch provider/model remains secondary identity and legacy fallback | Semantic text + SF Symbols |
| Interactive terminal | One real PTY session at a time, visible immediately when its session is selected | PTY-backed AppKit terminal host with semantic accessibility label |
| Terminal input helpers | Clipboard images become private temporary PNG paths; installed Skill/plugin commands insert without Return | SwiftTerm paste override + native `Menu` |
| User attention | Provider choices remain in the actual terminal; Byori does not infer or duplicate them | Provider-owned TUI |
| Session controls | Running state, Stop, reattach, command insertion, terminal focus/resize | Native toolbar and menu controls |
| Claude model API | Optional official Upstage Solar or Anthropic-compatible gateway configuration under Claude settings; secrets stay undisclosed in Keychain and one action restores Claude defaults for future sessions | Native `GroupBox`, secure field, disclosure, semantic notice and reversible actions |
| Files/Git/Context | 300–320pt right inspector with one selected tab | SwiftUI segmented/tab navigation and outline/list content |
| ByoriDB Context | Decision/module/task checkpoint rows with provenance and empty/error states | SwiftUI list/grouped rows fed by project space |
| Truthful status bar | 28pt bottom row for verified ByoriDB, checkout, session, Context, elapsed-time, and operation state; no invented provider quota | Semantic text, dots, dividers, progress, and Cancel |
| Settings | Bottom-left entry plus one retained native Settings window; per-agent MCP/Skill inventory is bounded and secret-redacted | SF Symbol + native Settings window |

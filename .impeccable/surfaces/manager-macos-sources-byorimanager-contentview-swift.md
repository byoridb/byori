---
version: 1
slug: "manager-macos-sources-byorimanager-contentview-swift"
primary_target: "manager/macos/Sources/ByoriManager/ContentView.swift"
related_targets: ["manager/macos/Sources/ByoriManager/ByoriManagerApp.swift","manager/macos/Sources/ByoriManager/WorkspaceView.swift","manager/macos/Sources/ByoriManager/WorkspaceViewModel.swift"]
---

# Byori Workspace Surface Brief

- Scope/mode: native macOS workspace, Operate mode.
- Audience/job: a local developer selects a project and checkout, then works directly in a real coding-agent terminal without losing project context.
- Primary task: create or open a trusted local project, choose a task/session from its work list with checkout metadata, create a session with one recorded launch agent/model, interact with its terminal, insert an installed command when useful, and inspect Files, Git, or ByoriDB Context.
- Constraints: Byori never interprets terminal output or executes a suggested command on selection. No automatic prompt fan-out, multi-terminal comparison, in-session Byori agent/model switcher, invented remote/team capabilities, or Settings in primary navigation.
- Approved direction: the 2026-11-17 user-approved refinement keeps the native Project Workbench identity with quieter spacing/tone from [Conductor](https://www.conductor.build/docs/first-workspace), visual emphasis from [Linear](https://linear.app/now/behind-the-latest-design-refresh), and compact work lists from [Zed](https://zed.dev/blog/parallel-agents). Project-grouped rows, a single session header, and an inspector collapsed by default are the current composition contract.
- Historical comps: the 2026-08-06 direction used `.impeccable/mocks/byori-workspace-c-sourcetree-first.png` with Context treatment from `.impeccable/mocks/byori-workspace-a-balanced.png`. These preserve the earlier rationale; their deep outline and always-visible inspector no longer govern this refinement.
- Memorable moment: a selected session opens directly on one uninterrupted terminal, with installed commands in a compact menu and durable project knowledge one inspector tab away.
- Not literal: generated terminal output, dates, paths, filenames, exact widths, and generated card copy are illustrative; runtime truth and native controls replace them.
- Unresolved: provider adapters do not yet expose structured choice payloads, so the terminal remains the truthful interaction surface.

## Implementation grammar

- Component language: standard SwiftUI split views, outline/list rows, toolbar controls, native menus, segmented inspector tabs, disclosures, and sheets; no dashboard card grid.
- Corners/elevation: the terminal pane is edge-bound; native controls keep system radii; Context records may use a restrained 12pt grouped surface, never stacked border plus shadow.
- Lines/type: 1px semantic separators; system UI type for chrome, with system monospaced type reserved for terminal output, filesystem paths, and elapsed-time measurements; hierarchy comes from weight and spacing rather than decorative labels.
- Color: dynamic neutral macOS light/dark chrome, near-black terminal, native selection, and restrained semantic accents for real states. Sidebar and chrome use the existing native window background; the refinement adds no fixed color tokens.

## Visible inventory

| Ingredient | Commitment | Medium |
|---|---|---|
| Project bootstrap | Create a named local project or open any folder; show the destination and confirm before initializing Git in an existing folder | Native `Menu`, sheet, `NSOpenPanel`, and confirmation dialog |
| Project work list | Project-name search at the top of a 280–300pt sidebar; two-line task/session rows grouped by project, with checkout/branch metadata instead of a separate checkout level | Semantic SwiftUI `List`/`DisclosureGroup`, native text field |
| New Session action | Small `+` and overflow actions on eligible project/task rows; project `+` starts a new task, task/session `+` preserves the exact target | Native `Button`, `Menu`, and sheet |
| Archive and cleanup | Footer `보관함 · 정리` opens the existing preview/restore sheet; archive only explicit selections after rechecking session state | Native button, sheet, and selection controls |
| Checkout identity | Launch sheet names Primary, Byori worktree, or External and shows the exact working directory before launch | Native `Picker`, `LabeledContent`, selectable path text |
| Session identity | Editable generated two-word name; recorded launch provider/model remains secondary identity and legacy fallback | Semantic text + SF Symbols |
| Interactive terminal | One real PTY session at a time, visible immediately when its session is selected | PTY-backed AppKit terminal host with semantic accessibility label |
| Terminal input helpers | Clipboard images become private temporary PNG paths; installed Skill/plugin commands insert without Return | SwiftTerm paste override + native `Menu` |
| User attention | Provider choices remain in the actual terminal; Byori does not infer or duplicate them | Provider-owned TUI |
| Session controls | One 50pt header for project/task title, real state, Stop/reattach or New Session, and shell; optional short branch, long-title help, overflow for command insertion, procedure/verification, and launch details; fits a 460pt center pane | Native compact buttons, `ViewThatFits`, and menu controls |
| Claude model API | Optional official Upstage Solar or Anthropic-compatible gateway configuration under Claude settings, collapsed behind a disclosure whose label states the active configuration; secrets stay undisclosed in Keychain and one action restores Claude defaults for future sessions | Native `DisclosureGroup`, secure field, nested disclosure, semantic notice and reversible actions |
| Files/Git/Context | On-demand 300–320pt inspector, initially collapsed; toolbar/Command-Option-I toggles it, Git/Context status shortcuts open their tab, and project registration still opens Context | SwiftUI segmented/tab navigation and outline/list content |
| ByoriDB Context | Decision/module/task checkpoint rows with provenance and empty/error states | SwiftUI list/grouped rows fed by project space |
| Truthful status bar | 28pt bottom row for verified ByoriDB, Git/Context shortcuts, active sessions, launch selection, elapsed time, and operation state; no duplicate project name, vertical separators, refresh button, or invented quota | Semantic text, state dots, native buttons, progress, and Cancel |
| Settings | Bottom-left entry plus one retained native Settings window; per-agent MCP/Skill inventory is bounded and secret-redacted | SF Symbol + native Settings window |
| Local requirements | Setup Overview states ByoriDB, tmux, and Python 3 as compact rows with verified state, consequence, and at most one action; tmux is installed or upgraded through Homebrew and the requirement is only stated when Homebrew is absent | Titled `GroupBox`, semantic SF Symbol state, native buttons and confirmation |

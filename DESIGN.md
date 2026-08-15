---
name: Byori
description: A project-first native macOS coding workspace for user-selected agents and durable ByoriDB context.
colors:
  terminal-canvas: "#0E1011"
  terminal-pty-canvas: "#0E1113"
  terminal-text: "#E0E8EB"
typography:
  ui:
    fontFamily: "-apple-system, BlinkMacSystemFont, sans-serif"
    fontWeight: 400
    lineHeight: 1.2
  terminal:
    fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.2
rounded:
  context-record: "12px"
spacing:
  tight: "8px"
  record: "12px"
  inspector: "14px"
  pane: "16px"
  sheet: "20px"
  empty-state: "28px"
components:
  terminal-surface:
    backgroundColor: "{colors.terminal-canvas}"
    textColor: "{colors.terminal-text}"
    typography: "{typography.terminal}"
  context-record:
    rounded: "{rounded.context-record}"
    padding: "{spacing.record}"
---

# Design System: Byori

## Overview

**Creative North Star: "The Project Workbench"**

Byori should feel like a calm native workbench wrapped around real developer processes. The project is the stable frame; source trees or worktrees, tasks, and sessions reveal increasing detail without displacing that frame. The user chooses Claude Code or Codex for each session. One real terminal owns attention while Files, Git, and ByoriDB knowledge remain immediately reachable.

The world is precise, durable, and operational. Native macOS controls carry familiarity, crisp dividers carry structure, and restrained semantic color carries state. Byori does not decorate work with dashboards, fake activity, or simulated terminal content.

The public product and app name is **Byori**. **ByoriDB** names only the integrated knowledge engine and its Context. **`byori`** names the supporting CLI. Settings is an administration surface within Byori, not a second product or the center of the experience.

**Key Characteristics:**

- Project-first hierarchy with one dominant working surface.
- Native dynamic chrome surrounding a fixed near-black terminal canvas.
- Compact spacing, semantic state, and honest loading, empty, error, and unavailable states.
- Project-scoped knowledge presented as supporting context, never as a competing administration dashboard.

`assets/byori-app-icon.png` is the canonical Byori app icon asset. Its connected nodes represent
distinct coding agents linked through shared project knowledge: the workspace is Byori, and the
knowledge substrate connecting sessions is ByoriDB. Packaging and product documentation should
derive their icon from this asset rather than redraw or reinterpret it.

## Colors

The fixed palette is intentionally small. The frontmatter defines only colors that the app fixes in code; macOS system colors remain dynamic production tokens.

### Primary

- **Workbench Teal:** Use `NSColor.systemTeal` or SwiftUI `.teal` for running state and the terminal caret. Preserve its dynamic platform behavior instead of replacing it with a fixed approximation.

### Neutral

- **Terminal Canvas:** The edge-bound center surface behind a selected PTY.
- **PTY Canvas:** The retained SwiftTerm view's closely matched native background.
- **Terminal Text:** High-contrast terminal foreground used by SwiftTerm.
- **Native Chrome:** Use `windowBackgroundColor`, `controlBackgroundColor`, `.primary`, `.secondary`, and semantic dividers. Their appearance-dependent values are normative and must not be copied into fixed hex tokens.

### Named Rules

**The State Earns Color Rule.** Teal, blue, green, orange, and red appear only for real running, preparing, success, dirty, failure, timeout, or unavailable states. A clean working tree is the default rather than a state and takes no accent, which keeps teal reserved for running: one status column must not answer two different questions depending on the row it sits in.

**One Mapping Per Fact Rule.** Every surface that reports the same state reads it from the same mapping in code. While the outline and the status bar each owned their own, a clean checkout was teal in one and green in the other.

**The Terminal Stays Fixed Rule.** The terminal remains near-black in every system appearance so the coding surface retains visual authority.

**The PTY Owns ANSI Color Rule.** Preserve provider-emitted 16-color, 256-color, and truecolor output. Embedded interactive sessions advertise `xterm-256color`/`truecolor` and do not inherit host variables that suppress color; Byori still does not recolor or fabricate provider output.

## Typography

**Display Font:** None; this Operate world has no decorative display voice.

**Body Font:** macOS system UI with native SwiftUI semantic styles.

**Label/Mono Font:** System monospaced at 13pt for the terminal; monospaced variants only for Git status, revisions, paths, and measurements.

**Character:** The UI is compact and neutral, with hierarchy created by semantic size, weight, and spacing. Monospaced type signals literal developer data rather than supplying a technical costume.

### Hierarchy

- **Title:** `.title2` or `.title3` with semibold weight for settings page headers, focused sheet headings, and terminal-unavailable headings. Settings is administration inside Byori, so it never uses a display-sized heading.
- **Headline:** `.headline` for project, task, and Context record titles.
- **Body:** `.body` for outline rows and ordinary actions.
- **Callout:** `.callout` for status and Context summaries.
- **Label:** `.caption` and `.caption2` for provenance, timestamps, status detail, and bounded metadata.
- **Terminal:** 13pt regular system monospace for the interactive PTY.

### Named Rules

**The Literal Mono Rule.** Use monospaced type only when alignment or literal identity matters: terminal text, branch status, revisions, paths, and counts.

## Layout

The primary workspace uses a native three-pane split: hierarchy at left, one flexible working surface in the center, and a tabbed inspector at right. A compact 28pt status bar spans the bottom edge. Exact pane widths belong to the workspace surface brief; other screens should reuse the hierarchy and density, not blindly copy those dimensions.

The left outline keeps Project → Source Tree/Worktree → Task → Session nesting visible. The center either mounts one real terminal or presents a centered, actionable, state-honest empty/error view. The right inspector exposes one of Files, Git, or Context at a time. Administration opens in a separately retained native Settings window.

Spacing follows tight functional groups at 8–12pt, inspector and row insets at 12–14pt, pane headers at 16pt, sheets at 20pt, and centered empty states at 28pt. Wide separators and arbitrary card grids are not part of the grammar.

## Elevation & Depth

Byori is flat by default. Pane hierarchy comes from native background levels and crisp semantic dividers, not decorative shadows. The window and system sheets own platform elevation; content inside them does not add another shadow vocabulary.

**The Divider Carries Structure Rule.** Use one native divider or one tonal surface change at a boundary. Do not stack border and shadow to restate the same depth.

## Shapes

Main panes and the terminal are edge-bound. Buttons, pickers, sheets, lists, disclosures, and focus rings keep their native macOS geometry. Context records are the deliberate exception: a restrained 12pt rounded tonal surface groups one durable knowledge record without becoming a dashboard card.

Status dots stay small and circular. Pills are reserved for compact system controls; hierarchy labels and metadata are ordinary text, not decorative badges.

## Components

### Project Outline

- Use native disclosures and list rows for every hierarchy level.
- Offer `Create New Project…` and `Open Folder…` from the outline header and actionable empty
  state. Creation shows the resulting path and initializes a local `main` repository without a
  remote or commit.
- Let users select any existing folder. If it is not already in a Git repository, require a
  separate confirmation that names the folder and explains `git init`; never initialize it as a
  side effect of choosing it.
- Keep icons in one SF Symbols family and reserve secondary text for genuinely distinct metadata.
- Show a single semantic status dot for dirty, unavailable, or active state, and leave the slot empty when a checkout is clean; never repeat a long branch as both title and metadata.
- Keep the checkout kind — Primary, Worktree, External — as identity text in secondary tone. It names where the agent works, so state must not tint it; the status dot already carries the working tree.
- Put removal behind a row context or overflow action with an explicit confirmation; do not place an easy-to-misclick trash control beside the session `+` action.
- Removing a project archives its exact registration outside the active list. Re-adding the same canonical repository restores its stable project identity, graph space, and task/session linkage.
- Removing a linked checkout hides that canonical path from the outline until the user restores it. The action must be described as hiding from Byori, not deleting a Git worktree.
- Removing a task archives its exact task/session metadata outside the active outline. State plainly that repository files, its checkout and branch, and ByoriDB records remain.
- Offer actual cleanup only for a Byori-managed worktree, behind a separate destructive confirmation. Disable it until active sessions have stopped, tasks have been removed, and Git reports a clean worktree. Let the user keep the branch or request Git-safe `-d` deletion; report an unmerged branch as retained after the worktree is removed.
- Never offer file deletion for the primary checkout or an externally managed worktree.

### Terminal Session

- Keep the PTY edge-bound and visually dominant.
- Put project/source-tree/task lineage, recorded launch provider/model, real session state, and Stop above the terminal in compact native bars.
- Mount one retained SwiftTerm view at a time. Never simulate output or silently fall back to a shell when an agent CLI is missing.
- Open a selected session directly on its terminal; do not interpose a summary or Activity tab.
- Keep installed Skill and plugin commands in one compact native menu. Choosing one inserts editable text into the running terminal and never executes it.
- When the clipboard contains an image, persist a private session-temporary PNG and insert its shell-quoted path. Preserve SwiftTerm's ordinary text paste behavior.
- Keep one user-selected coding agent per session. Another agent means another explicitly created session, not an automatic fan-out.

### Workspace Status Bar

- Report only local state Byori can verify: ByoriDB health, selected project and branch, working-tree state, active session count, Context availability, selected provider/model, and elapsed session time.
- Keep the bar one compact native row with literal status separators and truncation for long project, branch, and model names.
- Never imitate provider quota percentages or billing windows without a supported provider API.
- While an installation or management command runs, replace ordinary status with one explicit progress label and a real Cancel action.

### Inspector

- Use a native segmented picker for Files, Git, and Context.
- Load local Files/Git independently from ByoriDB Context so an unavailable service cannot block repository inspection.
- Preserve bounded reads and explicit truncation messages.

### Context Record

- Use one 12pt tonal group with 12pt internal padding.
- Present kind, date, title, bounded body summary, provenance, and relation tags in that order.
- System teal may identify the record kind; body and provenance remain semantic primary/secondary text.

### New Session Sheet

- Treat session creation as protected focus: location, task, provider, launch model, dirty-tree confirmation, and Context depth belong in one native sheet.
- Put a small `+` action directly on source-tree and task rows: source-tree `+` starts a new task, while task `+` preserves that exact task target.
- Prefill a short two-word session name, keep it editable, and preserve the provider/model label as the fallback for legacy unnamed sessions.
- State that Byori records the launch selection while provider-side terminal commands remain provider-controlled.
- Disable Start until every required choice is valid and an explicit dirty-tree confirmation is present when needed.

### Settings

- Keep Setup Overview, Agents & Skill, ByoriDB, and Diagnostics outside primary navigation.
- Give each page the same name in the sidebar and in its own header. A page whose heading renames its destination reads as a different screen than the one that was selected.
- Group each page as titled native `GroupBox` sections in the order the work happens: what Byori observed, then what acts on it. Within a group, keep ordinary actions leading and separate a destructive one to the trailing edge; a row of equally weighted buttons hides which of them cannot be undone.
- State local requirements — ByoriDB, tmux, Python 3 — as compact rows carrying name, verified state, consequence, and at most one action. Never restate them as a status-card grid: cards duplicate what the Agents and ByoriDB pages already list, and a card grid is not part of this app's pane grammar.
- Offer an action only where Byori can actually complete it. tmux is installed or upgraded through Homebrew; without Homebrew, state the requirement and name it instead of showing a button whose only outcome is a failure. Say `install` or `upgrade` according to what is really on disk.
- Keep ByoriDB installation separate from explicit per-provider MCP and Memory Skill actions.
- Collapse an optional provider form, such as the Claude model API, behind a disclosure whose label carries its active state. An always-expanded optional form pushes the inventory the page exists for below the fold.
- List each agent's bounded user-scoped MCP and Skill inventory in compact native rows. Never display raw command arguments, environment/header values, or tokens; cloud-owned connectors remain read-only.
- Advanced MCP editing opens the agent's own configuration, while direct removal uses its official CLI and a prior backup. Skill editing opens `SKILL.md`; removal is restricted to validated direct children of known user Skill roots and is backed up first.
- Keep long-running operations responsive with persistent progress, safe cancellation, and a durable Activity result.
- Closing the Settings window must not interrupt an operation. Quitting the app cancels only rollback-safe runtime work; otherwise it waits for the exact operation. It must wait for cleanup or rollback and keep the app open on recovery failure.
- Settings manages services and integrations; project knowledge remains in the workspace Context inspector.

## Do's and Don'ts

### Do:

- **Do** keep the project and source-tree lineage visible while a session is selected.
- **Do** use real runtime state and explicit recovery actions for loading, empty, missing, unavailable, dirty, stopping, and failed conditions.
- **Do** let native controls, system typography, SF Symbols, and semantic colors provide familiarity and accessibility.
- **Do** keep ByoriDB knowledge project-scoped, bounded, provenance-bearing, and one inspector tab away.
- **Do** preserve one uninterrupted terminal as the visual and interaction focus.
- **Do** make project archive and linked-checkout visibility effects explicit and reversible.
- **Do** keep one user-selected coding agent per session; another agent starts in another explicitly created session.

### Don't:

- **Don't** add automatic prompt fan-out, winner ranking, multi-terminal comparison, or merge controls to the Byori macOS app.
- **Don't** make a workspace removal control imply or perform repository, worktree, branch, task/session, or ByoriDB deletion.
- **Don't** move service administration or a global graph dashboard into the workspace hierarchy.
- **Don't** fabricate terminal output, agent activity, metrics, or claims to fill an empty state.
- **Don't** repeat equivalent branch metadata, overuse badges, or use monospaced type as decoration.
- **Don't** add gradients, glass decoration, ornamental shadows, or rounded card grids to native panes.

**English** | [한국어](ko/manager-macos.md)

# Byori for macOS

The Byori macOS app is a native SwiftUI multi-agent coding workspace for running Claude
Code or Codex in local Git checkouts. Its primary surface is the workspace; Settings
supports installation, integration, and diagnostics. ByoriDB provides the project-scoped
shared knowledge graph beneath that workspace. ByoriDB continues to run as the existing
launchd user service after you quit the app. With tmux 3.2 or later, interactive coding
sessions stay detached and reattach on the next launch; without a supported tmux they end
with the app. The app supports macOS 13 or later and ships as one universal build for
Apple Silicon and Intel.

## Installing

Download `Byori-<version>-universal.dmg` from the
[latest release](https://github.com/byoridb/byori/releases/latest), open it, and drag
**Byori** into Applications. The release DMG is signed with a Developer ID Application
certificate, notarized by Apple, and stapled, so Gatekeeper opens it without an exception:

```bash
spctl -a -vvv -t open --context context:primary-signature ~/Downloads/Byori-*-universal.dmg
# accepted
# source=Notarized Developer ID
```

**Settings → Setup Overview** then reports the installed version and installs later
releases itself, verifying the Developer ID signature and Apple notarization of a candidate
before replacing the bundle and refusing the update when either check fails. The check runs
every six hours and only reports; nothing is downloaded until you ask for it. Because the
swap quits the app, it refuses while a session that is not backed by tmux is running.

ByoriDB is installed separately, from **Settings → ByoriDB** or with the
[shell installer](install.md). To build the app yourself, see
[Building the .app and DMG](#building-the-app-and-dmg).

## Workspace model

The underlying data relationships are:

```text
Project
└── Source Tree or Worktree
    └── Task
        └── Session (one user-selected coding agent + one model choice)
```

The sidebar presents these as a project-grouped task/session list. Checkout and branch are
supporting metadata, so navigating the UI does not require opening every level of this model.

- A project is an explicitly registered and trusted local Git repository. **Create New Project…**
  creates a named folder, initializes a `main` repository, and registers it without adding a
  remote. Initialization also makes one empty root commit, because `git init` names `main`
  without creating it: until something is committed there is no branch to list, to start another
  branch from, or to cut a worktree from, so the project would register and then refuse the next
  action. The commit adds no files — what the project contains stays the user's decision — and it
  uses the user's configured Git identity, falling back to Byori's own only when Git has none.
  **Open Folder…** accepts any existing folder; if it is not already a Git repository, Byori asks
  for confirmation before running `git init` and keeps existing files in place, uncommitted.
- A source tree or worktree identifies the checkout in which the coding CLI runs. The
  app can create a Byori-managed worktree for an existing or new local branch.
- A task groups related sessions for that checkout.
- Each session records exactly one user-selected coding agent—Claude Code or Codex—and one
  model choice: either that agent CLI's default or an exact custom model identifier. Byori
  does not mutate that launch selection; vendor-side model changes inside the interactive
  CLI are outside Byori's observation. Starting another agent through Byori requires a new
  session.
- The prompt and all follow-up input are typed directly into the interactive terminal.
  Byori does not persist prompts or terminal transcripts.

Byori does not send the same prompt to several agents, compare their output, choose
a winner, merge branches, or clean up worktrees automatically. Managed-worktree cleanup is
always an explicit confirmed action. The foreground `byori run`
fan-out command documented in [multi-CLI orchestration](orchestration.md) remains a separate
prototype and compatibility path.

## Main window

- The left sidebar starts with project-name search, then groups compact two-line task/session
  rows by project. A task and its single visible session share a row; branch and agent appear as
  distinct secondary metadata instead of a separate checkout nesting level. Clearing search
  restores the full list and its expanded/collapsed rows without switching the active terminal.
  The heading's `+` menu creates a project or opens a folder. A project row's `+` opens setup for
  a new task with a recommended checkout; a task/session `+` preserves that exact task and
  checkout. Rows expose `+` and overflow actions. The sheet proposes an editable two-word session
  name, while legacy unnamed sessions retain the provider/model fallback.
- A task row's **More Actions → 작업 보관…** moves its task/session metadata to
  `~/.byori/archived-tasks` after every session has ended. It does not change repository files,
  the worktree or branch, or ByoriDB context.
- A clean Byori-managed worktree with no tasks can be removed through
  **More Actions → Delete Managed Worktree…**. The confirmation can keep its local branch or ask
  Git to delete it with safe `-d` semantics; unmerged branches are retained. Primary and externally
  managed checkouts never expose this deletion action.
- The center opens directly on the selected session's real interactive PTY rendered by
  SwiftTerm. One 50pt header shows project/task identity and real state, with direct Stop,
  reattach, shell, or New Session controls as appropriate. Long titles have help text; a short
  branch appears only when space allows. The overflow menu contains session/checkout/recorded
  launch details and **작업 절차·검증**. Claude Code or Codex runs in that checkout and handles its own login. Pasting a
  clipboard image writes a private temporary PNG and inserts its quoted path into the current
  terminal input; ordinary text paste is unchanged. **세션 메뉴 → 명령 삽입** reads installed
  Claude plugins and user Skills or Codex plugin Skills and user Skills, then inserts the chosen
  invocation without pressing Return. Sessions
  advertise 256-color and truecolor support and discard inherited color-suppression variables
  such as `NO_COLOR`, so provider-emitted ANSI color remains visible.
- The right inspector starts collapsed. The toolbar button or **Command-Option-I** toggles it;
  the bottom Git/Context shortcuts open their respective tab. Adding a project still opens
  Context for initial memory setup, while ordinary selection preserves the current visibility.
  The inspector provides bounded **Files** metadata, read-only **Git** status, and
  project-scoped ByoriDB **Context**. All source trees/worktrees, tasks, sessions, and agent
  choices in a project use the same shared project knowledge graph. Focused/Related/Broad rank
  task and source-tree matches plus zero/one/two-hop graph neighbors before recent project
  records. Context loads independently, so a slow or unavailable ByoriDB does not block Files
  or Git.
- The **Issues** inspector tab shows the GitHub issues of the selected project's repository,
  resolved from its primary checkout's git remote. Byori runs the user's own `gh` and never
  reads or stores a GitHub token; without `gh`, a `gh auth login`, or a GitHub remote, the tab
  names the requirement and the command that resolves it. The list filters open, closed, or
  all issues and searches with GitHub's search syntax (the most recent 100 are shown). An issue
  shows its body and comments as inline Markdown, and can be closed as completed or not
  planned, reopened, commented on, and have its labels and assignees edited; **+** creates
  one. Every change is shown only after gh has made it and the issue has been read back.
  **이 이슈로 작업 시작** opens the new-session sheet with a new task named `#<number> <title>`,
  so the suggested branch carries the issue number; the prompt stays the user's to type, and
  the agent can read the issue with `gh` itself.
- The 28pt bottom status bar shows verified ByoriDB readiness, branch and working-tree state,
  active sessions, Context availability, recorded session launch selection, and elapsed time.
  Git and Context open the inspector; ByoriDB health opens Settings. The row omits a repeated
  project name, vertical separators, and refresh button. It does not invent quota or billing percentages.
- Settings is a supporting administration surface, not the main workspace or a separate
  global graph browser. ByoriDB and agent administration are organized in
  **Settings → Setup Overview, Agents & Skill, ByoriDB, Diagnostics**. The workspace gear,
  menu bar action, and **Command-,** all reopen the same retained Settings window.
  **Settings → Setup Overview** states the local requirements — ByoriDB, tmux, and Python 3 —
  as one row each with the state Byori verified and at most one action.
  **Settings → ByoriDB** is for service installation and maintenance; shared project
  knowledge belongs in the Context inspector.

## Suggested work location

New Session puts task title and agent/model before the work-location summary. **고급 설정**
contains the generated editable session alias, optional procedure, Context depth and CLI options.
The project remembers its last successfully launched agent/model when still available; execution
flags and dirty-checkout consent are never remembered. Launch errors stay beside the Start button.

The New Session sheet fills in a work strategy before launch and explains its recommendation:

- **New branch** for new work on an idle, clean `main` or `master`; it uses the same folder.
- **New worktree** when another writing session is using the selected checkout, or when it has
  uncommitted changes; it creates a separate folder and branch from a committed ref, leaving those
  changes untouched in the original folder.
- **Work directly** to continue an existing task, use an existing feature branch, or review code in
  an idle checkout. The label names the actual current branch. Working directly in a checkout with
  uncommitted changes remains available but must be confirmed; an existing task bound to such a
  checkout can start elsewhere only as a **New Task**.

The branch name follows the task title and avoids existing names. Strategy and branch name remain
editable for a new task, and a worktree's base can be selected. A new branch in the current folder
starts from that checkout's HEAD. Later suggestions preserve manual edits. **추천 다시 적용** resets
them to the recommendation. Existing tasks remain in their original checkout. No branch or folder
is created until **Start Session**, which checks the chosen location again before changing Git.

## Session lifetime

**터미널** opens a shell in the target checkout. If that checkout already has a running shell,
the button selects it; a detached shell is reconnected. After a shell ends, the button starts a
new session in its eligible shell task. Opening it from an agent's task uses the same checkout
and keeps the shell in a separate task.

Closing the workspace window detaches it from the terminal view without ending active sessions.
With tmux 3.2 or later, Byori uses its private tmux server so sessions can also survive a full app
quit. Existing sessions created by older Byori builds on the default tmux server remain
reattachable. Without a supported tmux, retention is limited to the current Byori process and the
workspace surfaces that limitation before launch. **Settings → Setup Overview** reports the same
requirement and can install or upgrade tmux with Homebrew; when Homebrew is absent it states the
requirement rather than offering an action it cannot complete. The same holds when Homebrew has no
tmux bottle for the Mac (currently macOS 14 and earlier, and Intel Macs): `brew install tmux` would
compile tmux and its build tools from source, which runs far past what a Settings action waits for,
so Settings names the command to run in a terminal instead. A successful install applies to the
next session without relaunching Byori:

- **Quit Byori** detaches tmux-backed sessions and stops only non-persistent fallback sessions.
- A later app launch discovers retained sessions and offers to reattach to their existing PTYs.
- An ended session offers **New Session** for the same task. An active session cannot be
  closed and must be stopped first.
- Ended sessions are omitted from the outline unless currently selected; their parent task remains.
- When the selected session finishes or is stopped, the window returns to its project and the
  session's row disappears. A session that fails stays open with its exit code, **New Session**,
  and **Close** in place of the emptied terminal.
- ByoriDB itself is separate and continues running as a launchd user service.

The sidebar footer's **보관함 · 정리** opens **지난 세션 정리**. It lists tasks whose sessions
have all ended, using the most recent recorded end time (not last keyboard activity). Choose
7, 30, or 90 days, or all ended tasks, and optionally narrow to one project. No rows are selected
initially. Select rows and choose **보관** to move complete task/session metadata out of the active
list; project files, branches, worktrees and ByoriDB records stay in place. Running, starting and
detached sessions, including shells, are excluded. State is checked again before each archive;
partial failures are reported without undoing successful entries.

The **보관함** tab lists archived tasks and restores selected records without starting sessions.
Restoration requires the original project and checkout and refuses an existing task with the same
ID. An incomplete bounded listing is shown as partial, rather than implying all history was read.
Both lists can be searched by task or project name. Successful archives offer **실행 취소**;
the receipt remains available after closing the sheet. A failed undo keeps its remaining records
available for retry and never starts a session.

Workspace search also matches task, branch and session names. Pin a project from its row menu,
or choose **열린 세션** to focus the sidebar without changing the active terminal. **Command-K**
opens a keyboard-accessible quick switcher; the bottom **열린 세션 N개** button opens its session
view. **프로젝트 기억 N개** opens the currently loaded Context records. Elapsed time is available
in session details/help rather than taking permanent status-bar space.

## Settings and administration

- Search agent MCP/Skill inventories by name and filter by ownership. Expand a row for its path
  or maintenance actions. A failed inventory shows an unknown count with a retry action, not zero
  registrations. A verified registration does not mean that a live connection or login was checked.
- Install or repair the bundled MCP and Skill assets and a downloaded compatible
  ByoriDB engine; update to the latest release; and check authenticated readiness and launchd status
- Report the installed engine build next to the newest published engine release, so
  "up to date" is a verified statement rather than an assumption. When the release lookup
  fails, the page says so instead of implying the installed engine is current
- Start, stop, and restart ByoriDB, and read the end of its server or error log inside the
  app, with the log folder still one click away
- Detect Claude Code, Codex, Antigravity CLI, Cursor CLI, and OpenCode, and install or update them
  through each vendor's official installation command
- Register any other coding CLI by its executable path, with optional default arguments that are
  passed as `argv` without a shell. A registered CLI is launch-only, and Settings says so: Byori
  neither installs it, connects MCP for it, nor syncs a Skill to it, because none of that can be
  verified for a CLI it has never seen. Unregistering removes it from Byori's list and leaves the
  executable and existing session history untouched
- Configure the `byoridb` stdio MCP integration through each CLI's official
  `mcp add/remove` commands
- Synchronize the Memory Skill to Claude's `~/.claude/skills`, Codex's
  `~/.agents/skills`, and Antigravity's `~/.gemini/config/skills`
- Inspect a bounded, Settings-only list of each agent's user MCP registrations and Skills;
  edit configuration/`SKILL.md` at its source or remove a validated item after backup
- Optionally launch new Claude Code sessions through Upstage Solar or another
  Anthropic-compatible model API; keep its credential in macOS Keychain and restore the ordinary
  Claude environment without rewriting `~/.claude`
- Keep secret-bearing MCP command arguments, headers, environment values, and tokens out of
  the inventory UI and Activity history; Claude.ai-owned connectors are shown read-only
- Keep ByoriDB installation separate from agent wiring: database install/update does not
  implicitly change any agent's MCP and Skill configuration
- Back up MCP configuration and Skill changes automatically under
  `~/.byori-manager/backups`
- Take a runtime snapshot before installation or updates and automatically restore the
  files and previous launchd state if the operation fails
- Use the menu bar item to check ByoriDB and active-session status, refresh, open logs,
  reopen the workspace, or start a new session
- Keep long-running installation and maintenance work visible in Settings and the workspace
  status bar, with a Cancel action that terminates the spawned process group
- Let work continue when the Settings window closes; app quit cancels only snapshot-backed
  runtime work, otherwise waits for the exact operation, and always waits for cleanup or
  rollback before terminating

Vendor CLI installation buttons ask for confirmation before running and invoke only the official
vendor installation command. Each CLI handles its own login. Byori reads no existing
vendor credential; the optional Claude model API setting stores only a credential the user enters
explicitly and never presents it again.

Antigravity CLI (`agy`) replaces Gemini CLI in the built-in provider list. Byori uses
[Google's official installer](https://antigravity.google/docs/getting-started/) when it is
missing and runs `agy update` for an installed CLI. Its user MCP registrations live in
`~/.gemini/config/mcp_config.json`; authentication and importing prior settings remain owned
by the vendor CLI. Google [ended Gemini CLI access for individual accounts on June 18, 2026](https://developers.googleblog.com/an-important-update-transitioning-gemini-cli-to-antigravity-cli/).
Existing Gemini session records and settings remain intact and are never relabeled as
Antigravity sessions. Start a new Antigravity session to use the replacement.

## Development and verification

Xcode Command Line Tools or Xcode is required.
The `manager/macos` source path, SwiftPM targets `ByoriManager` and
`ByoriManagerCore` remain internal compatibility identifiers. Packaging maps the
executable target to the public `Byori` executable inside `Byori.app`.
The canonical icon source is `assets/byori-app-icon.png`; the packaging script
converts it to `Byori.icns` in the app's `Contents/Resources` directory.

```bash
swift build --package-path manager/macos --product ByoriManager
swift test --package-path manager/macos
swift run --package-path manager/macos ByoriManagerSelfTest
```

On machines where the Command Line Tools compiler and default SDK do not match, you can
specify a compatible SDK. For example, if the alternative SDK available on the machine
is `MacOSX15.4.sdk`:

```bash
SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk \
  scripts/build-macos-dmg.sh --version 0.2.0
```

## Building the .app and DMG

Create a development package for the current architecture with:

```bash
VERSION=0.2.0 scripts/build-macos-dmg.sh
```

To include both Apple Silicon and Intel:

```bash
VERSION=0.2.0 scripts/build-macos-dmg.sh --universal
```

The public artifacts are written to `dist/Byori.app` and
`dist/Byori-<version>-<arch>.dmg`. The app bundle's executable is
`Byori`. The DMG includes an Applications shortcut
so you can install the app by dragging it into Applications.

By default, the build uses an ad-hoc signature for local verification. For a
distribution build, provide a Developer ID Application certificate:

```bash
scripts/build-macos-dmg.sh \
  --version 0.2.0 \
  --universal \
  --sign "Developer ID Application: Example Corp (TEAMID)"
```

Before distributing the app externally, complete Apple notarization and DMG stapling as
well. Do not commit certificates or notary credentials to the repository. If you have a
Keychain profile created with `notarytool store-credentials`, the build can submit and
staple the DMG:

```bash
scripts/build-macos-dmg.sh \
  --version 0.2.0 \
  --universal \
  --sign "Developer ID Application: Example Corp (TEAMID)" \
  --notary-profile byori-notary
```

After every successful CI run for a new `main` commit, GitHub Actions creates the next stable
patch tag (starting with `v0.8.3`) and dispatches the release workflows. Both release workflows
verify that the tag's commit is contained in `origin/main`; a `v*` tag made from an unmerged
branch cannot publish a release. A repository tag ruleset reserves `v*` tag creation for GitHub
Actions. The macOS release workflow then attaches a signed and notarized universal DMG to the
release. It requires these repository secrets:

- `MACOS_CERTIFICATE_P12_BASE64`, `MACOS_CERTIFICATE_PASSWORD`
- `MACOS_SIGN_IDENTITY`
- `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`

The regular tag release workflow does not publish an ad-hoc DMG without these
credentials.

## Bundle layout

```text
Byori.app/
└── Contents/
    ├── Info.plist
    ├── PkgInfo
    ├── MacOS/
    │   └── Byori
    └── Resources/
        ├── Byori.icns
        ├── SwiftTerm_SwiftTerm.bundle/
        ├── LICENSE
        ├── VERSION
        ├── THIRD_PARTY_NOTICES.md
        └── runtime/
            ├── install.sh
            ├── cli/byori.py
            ├── mcp/byoridb_mcp.py
            ├── templates/
            └── adapters/claude/
                ├── hooks.snippet.json
                └── skills/byoridb-memory/SKILL.md
```

The packaging script generates `Contents/Resources/Byori.icns` from the canonical
`assets/byori-app-icon.png` source and copies SwiftPM resource bundles to the signed
app's standard `Contents/Resources` directory. SwiftTerm 1.15 resolves its Metal resources there.
The Byori macOS app currently pins SwiftTerm 1.15.0, which is MIT-licensed; its license
text is included in `Contents/Resources/THIRD_PARTY_NOTICES.md`. Byori's Apache-2.0
license is included in `Contents/Resources/LICENSE`.

The app copies bundled resources to stable paths under `~/.byoridb` and connects MCP
to those paths. Moving or updating the app therefore does not break the command path
used by a running MCP integration. Even when launched from Finder without inherited
shell environment variables, the app inspects the existing launchd plist and rendered
`run-server.sh` to rediscover a custom home, port, and service label.

## Operational notes

- The current Python MCP runtime requires `python3` before ByoriDB can be installed;
  the app diagnoses this prerequisite.
- Configuration changes and installation run in the user scope and require neither
  administrator privileges nor vendor tokens.
- Installing ByoriDB is one action, not a choice between two. It uses the MCP, CLI, Skill,
  and service assets carried in the app bundle — the ones this build was tested with, replaced
  by the app updater — and always fetches the newest ByoriDB engine release, falling back to
  the version validated with this build when that lookup fails. Existing data and the root
  password are preserved. The engine tag comes from the release check the ByoriDB page already
  displayed; the installer resolves it itself only when the app could not. Otherwise a
  rate-limited lookup inside the installer would quietly land its pinned tag while the page
  reported a newer release. Health and authenticated session creation must both succeed; this
  prevents a different process on the same port from being reported as ready. On failure, the
  app restores the runtime files and re-verifies a previously working connection.
- Failure details appear under **Settings → Diagnostics** as the app's activity log.
  Database contents and credentials are never recorded there.

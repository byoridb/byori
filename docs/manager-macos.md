**English** | [한국어](ko/manager-macos.md)

# Byori for macOS

The Byori macOS app is a native SwiftUI multi-agent coding workspace for running Claude
Code or Codex in local Git checkouts. Its primary surface is the workspace; Settings
supports installation, integration, and diagnostics. ByoriDB provides the project-scoped
shared knowledge graph beneath that workspace. ByoriDB continues to run as the existing
launchd user service after you quit the app; interactive coding sessions do not. The app
supports macOS 13 or later and can be built for both Apple Silicon and Intel.

## Workspace model

The main hierarchy is:

```text
Project
└── Source Tree or Worktree
    └── Task
        └── Session (one user-selected coding agent + one model choice)
```

- A project is an explicitly registered and trusted local Git repository.
- A source tree or worktree identifies the checkout in which the coding CLI runs. The
  app can display registered worktrees, but this release does not create them.
- A task groups related sessions for that checkout.
- Each session records exactly one user-selected coding agent—Claude Code or Codex—and one
  model choice: either that agent CLI's default or an exact custom model identifier. Byori
  does not mutate that launch selection; vendor-side model changes inside the interactive
  CLI are outside Byori's observation. Starting another agent through Byori requires a new
  session.
- The prompt and all follow-up input are typed directly into the interactive terminal.
  Byori does not persist prompts or terminal transcripts.

Byori does not send the same prompt to several agents, compare their output, choose
a winner, merge branches, or clean up worktrees automatically. The foreground `byori run`
fan-out command documented in [multi-CLI orchestration](orchestration.md) remains a separate
prototype and compatibility path.

## Main window

- The left sidebar shows the **Project → Source Tree/Worktree → Task → Session**
  outline and makes the selected checkout explicit. A source-tree `+` opens a session sheet
  for a new task; a task `+` targets that exact task. The sheet proposes an editable two-word
  session name, while legacy unnamed sessions retain the provider/model fallback. An ended
  session can be hidden with **Close** and restored from its Task row's
  **More Actions → Closed Sessions** menu.
- The center opens directly on the selected session's real interactive PTY rendered by
  SwiftTerm. Claude Code or Codex runs in that checkout and handles its own login. Pasting a
  clipboard image writes a private temporary PNG and inserts its quoted path into the current
  terminal input; ordinary text paste is unchanged. The **Commands** menu reads installed
  Claude plugins and user Skills or Codex plugin Skills and user Skills, then inserts the chosen
  invocation without pressing Return. Sessions
  advertise 256-color and truecolor support and discard inherited color-suppression variables
  such as `NO_COLOR`, so provider-emitted ANSI color remains visible.
- The right inspector provides bounded **Files** metadata, read-only **Git** status, and
  project-scoped ByoriDB **Context**. All source trees/worktrees, tasks, sessions, and agent
  choices in a project use the same shared project knowledge graph. Focused/Related/Broad rank
  task and source-tree matches plus zero/one/two-hop graph neighbors before recent project
  records. Context loads independently, so a slow or unavailable ByoriDB does not block Files
  or Git.
- The compact bottom status bar shows verified local state: authenticated ByoriDB readiness, selected project
  and branch, clean/dirty state, active sessions, Context availability, and selected-session
  elapsed time. It does not invent provider quota or billing percentages.
- Settings is a supporting administration surface, not the main workspace or a separate
  global graph browser. ByoriDB and agent administration are organized in
  **Settings → Setup Overview, Agents & Skill, ByoriDB, Diagnostics**. The workspace gear,
  menu bar action, and **Command-,** all reopen the same retained Settings window.
  **Settings → ByoriDB** is for service installation and maintenance; shared project
  knowledge belongs in the Context inspector.

## Session lifetime

Closing the workspace window detaches it from the terminal view without ending active sessions.
With tmux 3.2 or later, Byori uses its private tmux server so sessions can also survive a full app
quit. Existing sessions created by older Byori builds on the default tmux server remain
reattachable. Without a supported tmux, retention is limited to the current Byori process and the
workspace surfaces that limitation before launch:

- **Quit Byori** detaches tmux-backed sessions and stops only non-persistent fallback sessions.
- A later app launch discovers retained sessions and offers to reattach to their existing PTYs.
- An ended session offers **New Session** for the same task. An active session cannot be
  closed and must be stopped first.
- **Close** persistently hides the ended session from the sidebar without deleting its task
  or session history. Restore it from the parent Task row's
  **More Actions → Closed Sessions** menu.
- ByoriDB itself is separate and continues running as a launchd user service.

## Settings and administration

- Install or repair the bundled MCP and Skill assets and a downloaded compatible
  ByoriDB engine; update to the latest release; and check authenticated readiness and launchd status
- Start, stop, and restart ByoriDB, and open server logs
- Detect the Claude Code/Codex CLIs and install or update them through their official
  installation scripts
- Configure the `byoridb` stdio MCP integration through each CLI's official
  `mcp add/remove` commands
- Synchronize the Memory Skill to Claude's `~/.claude/skills` and Codex's
  `~/.agents/skills`
- Inspect a bounded, Settings-only list of each agent's user MCP registrations and Skills;
  edit configuration/`SKILL.md` at its source or remove a validated item after backup
- Optionally launch new Claude Code sessions through Upstage Solar or another
  Anthropic-compatible model API; keep its credential in macOS Keychain and restore the ordinary
  Claude environment without rewriting `~/.claude`
- Keep secret-bearing MCP command arguments, headers, environment values, and tokens out of
  the inventory UI and Activity history; Claude.ai-owned connectors are shown read-only
- Keep ByoriDB installation separate from agent wiring: database install/update does not
  implicitly change Claude or Codex MCP and Skill configuration
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
Anthropic/OpenAI installation scripts. Each CLI handles its own login. Byori reads no existing
vendor credential; the optional Claude model API setting stores only a credential the user enters
explicitly and never presents it again.

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

The GitHub macOS release workflow attaches a signed and notarized universal DMG to an
existing `v<version>` release. It requires these repository secrets:

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
- Online updates use the installer from the latest GitHub release and preserve existing
  data and the root password. Health and authenticated session creation must both succeed;
  this prevents a different process on the same port from being reported as ready. On failure,
  the app restores the runtime files and re-verifies a previously working connection.
- Failure details appear under **Settings → Diagnostics** in the app's **작업 기록**
  (Activity Log). Database contents and credentials are never recorded there.

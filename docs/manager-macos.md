**English** | [한국어](ko/manager-macos.md)

# Byori Manager for macOS

Byori Manager is a SwiftUI app for managing ByoriDB and its Claude Code/Codex
connections from Finder. ByoriDB continues to run as the existing launchd user service
after you quit the app. The app supports macOS 13 or later and can be built for both
Apple Silicon and Intel.

## Features

- Install or repair the bundled MCP and Skill assets and a downloaded compatible
  ByoriDB engine; update to the latest release; and check health and launchd status
- Start, stop, and restart ByoriDB, and open server logs
- Detect the Claude Code/Codex CLIs and install or update them through their official
  installation scripts
- Configure the `byoridb` stdio MCP integration through each CLI's official
  `mcp add/remove` commands
- Synchronize the Memory Skill to Claude's `~/.claude/skills` and Codex's
  `~/.agents/skills`
- Back up MCP configuration and Skill changes automatically under
  `~/.byori-manager/backups`
- Take a runtime snapshot before installation or updates and automatically restore the
  files and previous launchd state if the operation fails
- Provide both a window and a menu bar item, allowing you to check status, refresh,
  open logs, and reopen the Manager window after closing it
- Browse `note` plus typed-wiki nodes and `rel` plus typed edges in a read-only
  knowledge graph

Vendor CLI installation buttons ask for confirmation before running and invoke only the
official Anthropic/OpenAI installation scripts. Each CLI handles its own authentication
and login; Byori does not read or store tokens.

The initial knowledge-graph query displays at most 200 nodes and 500 edges and does not modify the
database. Node bodies are omitted from the initial projection and loaded only when a
node is selected. **Byori Manager 종료** (Quit Byori Manager) in the menu bar quits only
the Manager app; ByoriDB continues to run as a separate launchd service.

## Development and verification

Xcode Command Line Tools or Xcode is required.

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

The artifacts are written to `dist/Byori Manager.app` and
`dist/ByoriManager-<version>-<arch>.dmg`. The DMG includes an Applications shortcut
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

The GitHub **Release macOS Manager** workflow attaches a signed and notarized universal
DMG to an existing `v<version>` release. It requires these repository secrets:

- `MACOS_CERTIFICATE_P12_BASE64`, `MACOS_CERTIFICATE_PASSWORD`
- `MACOS_SIGN_IDENTITY`
- `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`

The regular tag release workflow does not publish an ad-hoc DMG without these
credentials.

## Bundle layout

```text
Byori Manager.app/Contents/
├── MacOS/ByoriManager
├── Resources/ByoriManager.icns
└── Resources/runtime/
    ├── install.sh
    ├── mcp/byoridb_mcp.py
    ├── templates/
    └── adapters/claude/skills/byoridb-memory/SKILL.md
```

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
  data and the root password. On failure, the app restores the runtime files and, if
  the previous service was healthy, checks health again after restoring it.
- Failure details appear in the app's **작업 기록** (Activity Log). Database contents and
  credentials are never recorded there.

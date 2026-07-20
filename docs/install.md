# Byori — 설치와 관리

Claude Code와 MCP 클라이언트의 **영속 기억**으로 쓸 로컬 ByoriDB를 설치한다.
서버·MCP 서버·skill을 한 번에 세팅한다. `claude`/`codex` CLI가 있으면 각각 자동으로
MCP를 등록하고 skill을 설치한다(`--no-claude`/`--no-codex`로 건너뜀).

## 한 줄 설치

```sh
curl -fsSL https://github.com/byoridb/byori/releases/latest/download/install.sh | bash
```

> macOS(Apple Silicon/Intel) · Linux x86_64 지원. Windows 미지원.
> 요구: `curl`, `tar`, `python3`(MCP 서버 실행용). Claude Code CLI가 있으면 MCP 서버를 자동 등록한다.

## 무엇을 설치하나

| 구성 | 위치 | 역할 |
|---|---|---|
| `byoridb-server` (+`byoridb-cli`) | `~/.byoridb/bin/` | 로컬 ByoriDB (gRPC 9669 / HTTP 19669, `127.0.0.1` 바인딩) |
| `byoridb_mcp.py` | `~/.byoridb/` | `memory_remember`/`memory_recall`/`memory_query` 도구를 stdio로 노출. 시작 시 `claude_memory` schema를 현재 버전(v2: `note`/`rel` + typed wiki)으로 자동 부트스트랩·migration |
| 상시 실행 서비스 | launchd `com.byoridb.local`(macOS) / systemd --user(Linux) | 부팅 시 자동 기동 + KeepAlive |
| `env` | `~/.byoridb/env` (chmod 600) | 랜덤 생성된 root 비밀번호 |
| 스킬 | `~/.claude/skills/byoridb-memory/SKILL.md` | 언제/무엇을 기억·회수할지의 정책 |
| 데이터 | `~/.byoridb/data/` | redb 파일 (로컬 전용) |

## 옵션

```sh
install.sh [--with-hooks] [--tag vX.Y.Z] [--engine-tag vX.Y.Z] [--uninstall]
           [--binary PATH] [--assets DIR] [--no-service] [--no-claude] [--no-codex]
```

- `--with-hooks` — 체크포인트 reminder 훅을 `~/.claude/settings.json`에 추가(기본은 안 함).
  기존 `SessionStart`/`PreToolUse` 배열에 append하며 이미 같은 hook이 있으면 건너뛴다
  (재실행 idempotent). 변경 전 `settings.json.bak.<timestamp>` 백업을 자동 생성한다. `jq` 필요.
- `--tag` — byori 자산(MCP/스킬/템플릿) 버전 고정(기본: 최신 byori 릴리스).
- `--engine-tag` — ByoriDB 엔진 릴리스 override(기본: 이 byori 버전과 함께 검증된 고정 태그).
- `--uninstall` — 서비스 중지·해제, Claude/Codex MCP 등록 해제, skill 제거.
  **데이터는 확인 후 보존/삭제 선택.**
- `--binary PATH` — 다운로드 대신 로컬 `byoridb-server` 바이너리 사용.
- `--assets DIR` — 다운로드 대신 로컬 repo 체크아웃(`DIR`)에서 mcp.py/템플릿/스킬을 가져옴.
- `--no-service` — launchd/systemd 등록 없이 현재 세션의 background process로 실행.
- `--no-claude` — Claude MCP 등록, skill, hook 설치를 건너뜀.
- `--no-codex` — Codex MCP 등록과 skill 설치를 건너뜀.

환경변수: `BYORIDB_HOME`(기본 `~/.byoridb`), `BYORIDB_HTTP_PORT`(기본 19669), `BYORIDB_GRAPH_PORT`(기본 9669).
격리 테스트: `BYORIDB_HOME=/tmp/bt BYORIDB_HTTP_PORT=29669 BYORIDB_GRAPH_PORT=29670 ./install.sh --binary … --assets …`

## 관리

```sh
curl -s localhost:19669/health          # 상태
claude mcp list                         # byoridb ✔ Connected 확인
tail -f ~/.byoridb/logs/server.err      # 로그
# macOS 중지/시작
launchctl unload -w ~/Library/LaunchAgents/com.byoridb.local.plist
launchctl load -w ~/Library/LaunchAgents/com.byoridb.local.plist
# Linux (기본 BYORIDB_LABEL 사용 시)
systemctl --user stop com.byoridb.local.service
systemctl --user start com.byoridb.local.service
```

## Codex 연결

설치기가 `codex` CLI를 감지하면 stdio MCP 등록과 skill 설치(`~/.agents/skills/`)를
자동으로 수행하고, `--uninstall` 시 함께 제거한다(`--no-codex`로 건너뜀).
Codex 재시작 후 `codex mcp list`로 확인한다. Claude용 hook은 Codex에 설치되지 않는다.

`--no-codex`로 건너뛰었거나 나중에 연결하려면 수동으로 등록한다.

```sh
codex mcp add byoridb -- "$HOME/.byoridb/bin/run-mcp.sh"
mkdir -p "$HOME/.agents/skills/byoridb-memory"
cp "$HOME/.claude/skills/byoridb-memory/SKILL.md" \
  "$HOME/.agents/skills/byoridb-memory/SKILL.md"
codex mcp list
```

수동 제거는 다음과 같다.

```sh
codex mcp remove byoridb
rm -rf "$HOME/.agents/skills/byoridb-memory"
```

## 한계

- MCP 서버는 리마인더가 아니라 실제 데이터 도구다. **기억할지 말지의 정책은 스킬**(`byoridb-memory`)에 있다.
- schema 부트스트랩(v2: `note`/`rel` + typed wiki)은 additive migration이다. 적용 버전은
  `byori:schema-version` note로 확인한다.
- hook은 capture를 직접 실행하지 않고 에이전트에게 체크포인트를 상기시킨다.
- current/history dual-write는 비원자적이며 같은 millisecond 재기록은 history key 충돌 위험(bitemporal v1 제약).
- 로컬 단일 노드 전용. 분산/프로덕션 배포와 무관.

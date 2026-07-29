[English](../install.md) | **한국어**

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
| `byoridb_mcp.py` | `~/.byoridb/` | 호환 note tool + 검증된 typed-wiki CRUD/export/read-only query tool을 stdio로 노출. 기본 `legacy` profile은 unrestricted `memory_query`도 제공. 시작 시 설정된 space를 schema v2(`note`/`rel` + typed wiki)로 자동 bootstrap·migration |
| 상시 실행 서비스 | launchd `com.byoridb.local`(macOS) / systemd --user(Linux) | launchd는 `RunAtLoad` + `KeepAlive`; systemd user unit은 `default.target` 연결 + `Restart=always` |
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

설치기 환경변수: `BYORIDB_HOME`(기본 `~/.byoridb`), `BYORIDB_HTTP_PORT`(기본 19669),
`BYORIDB_GRAPH_PORT`(기본 9669), `BYORIDB_LABEL`(기본 `com.byoridb.local`),
`BYORI_ENGINE_TAG`(기본: 고정 호환 엔진 태그).
격리 테스트: `BYORIDB_HOME=/tmp/bt BYORIDB_HTTP_PORT=29669 BYORIDB_GRAPH_PORT=29670 ./install.sh --binary … --assets …`

## MCP profile과 memory space

자동 등록되는 Claude/Codex 연동은 profile을 지정하지 않아
`BYORIDB_MCP_PROFILE=legacy`를 사용한다. 하위 호환성을 위해 unrestricted raw-nGQL
`memory_query`를 포함한 9개 tool을 모두 노출한다. `BYORIDB_MCP_PROFILE=safe`는 이 tool
하나만 discovery와 dispatch에서 제거한다. reduced raw-query surface이지 **read-only
server가 아니다**. `memory_remember`, `memory_wiki_upsert`, `memory_link`,
`memory_delete`는 계속 write할 수 있다.

`BYORIDB_MEMORY_SPACE`는 논리 memory namespace를 선택하며(기본 `claude_memory`),
`^[A-Za-z_][A-Za-z0-9_]{0,63}$`을 만족해야 한다. 프로젝트가 우연히 섞이지 않게 할 뿐
모든 space가 같은 엔진 credential을 쓰므로 authorization/tenant 경계가 아니다. 신뢰 영역이
다르면 별도 instance와 credential을 사용한다.

두 변수는 MCP client별 process 설정에 전달한다. `~/.byoridb/env`를 편집해 영속화하지
말 것. 재설치·upgrade 시 설치기가 해당 파일을 다시 쓰며 `BYORIDB_ROOT_PASSWORD`만 보존한다.

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

## NaraeClaw 또는 기타 수동 MCP host 연결

설치기와 Manager는 현재 Claude Code/Codex만 설정한다. NaraeClaw 전용 설정 형식이나
skill 경로는 가정하지 않는다. 호환 host의 MCP process 설정에 아래 runner를 사용하고,
`adapters/naraeclaw/skills/byoridb-memory/SKILL.md` 참조 정책은 해당 host가 문서화한
방식으로 설치한다.

```sh
env BYORIDB_MCP_PROFILE=safe \
  BYORIDB_MEMORY_SPACE=my_project \
  "$HOME/.byoridb/bin/run-mcp.sh"
```

NaraeClaw 전용 hook은 제공하지 않는다. process별 space도 현재 Manager가 알지 못해
Manager 자체 환경의 space만 표시한다. release 전에 source tree를 테스트할 때는 먼저
`./install.sh --assets .`로 설치한다.

## 한계

- MCP 서버는 리마인더가 아니라 실제 데이터 도구다. **기억할지 말지의 정책은 스킬**(`byoridb-memory`)에 있다.
- `safe`는 unrestricted raw nGQL만 차단한다. structured delete/link도 write이므로
  `legacy`와 같은 사용자 의도 확인이 필요하다.
- schema 부트스트랩(v2: `note`/`rel` + typed wiki)은 additive migration이다. 적용 버전은
  `byori:schema-version` note로 확인한다.
- `memory_export`는 제한된 inspection API이지 transactional backup snapshot이 아니다.
  동시 write가 없어도 deep page는 이동할 수 있으므로 완전한 restore source로 사용하지 않는다.
- hook은 capture를 직접 실행하지 않고 에이전트에게 체크포인트를 상기시킨다.
- current/history dual-write는 비원자적이며 같은 millisecond 재기록은 history key 충돌 위험(bitemporal v1 제약).
- 로컬 단일 노드 전용. 분산/프로덕션 배포와 무관.

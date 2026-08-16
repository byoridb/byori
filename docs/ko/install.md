[English](../install.md) | **한국어**

# Byori — 설치와 관리

Claude Code, Codex와 다른 MCP 호환 세션이 Byori 프로젝트의 **지속 가능한 지식 그래프**를
공유하도록 로컬 runtime을 설치한다. 서버·MCP 서버·호환 멀티 CLI coordinator·Byori Skill들을
한 번에 세팅한다. `claude`/`codex` CLI가
있으면 각각 자동으로
MCP를 등록하고 Skill들을 설치한다(`--no-claude`/`--no-codex`로 건너뜀).

## 한 줄 설치

```sh
curl -fsSL https://github.com/byoridb/byori/releases/latest/download/install.sh | bash
```

> macOS(Apple Silicon/Intel) · Linux x86_64 지원. Windows 미지원.
> 요구: `curl`, `tar`, `python3`(MCP 서버 실행용). Claude Code CLI가 있으면 MCP 서버를 자동 등록한다.

## Byori macOS 앱

아래 shell 설치기는 ByoriDB, MCP 자산, 호환 CLI를 설치하며 `/Applications`에 앱을
복사하지는 않는다. 앱은 [최신 릴리스](https://github.com/byoridb/byori/releases/latest)에서
설치한다. `Byori-<version>-universal.dmg`를 열고 **Byori**를 Applications로 끌어다 놓으면 된다.
이 DMG는 Developer ID Application 인증서로 서명하고 Apple 공증과 staple을 마쳤으므로 Gatekeeper
우회 없이 열린다. universal 빌드 하나가 Apple Silicon과 Intel을 지원하며 macOS 13 이상이
필요하다. 이후 업데이트는 앱이 **Settings → 설정 개요**에서 각 릴리스의 서명과 공증을 확인한
뒤 설치한다.

ByoriDB는 앱의 **Settings → ByoriDB**에서도 설치할 수 있다. 앱에 포함된 자산을 사용하고
호환되는 엔진 릴리스를 내려받는다.

저장소에서 빌드하면 같은 공개 산출물 `dist/Byori.app`과
`dist/Byori-<version>-<arch>.dmg`를 만들며 앱 번들의 executable은 `Byori`다.

앱의 메인 workspace는 **Project → Source Tree/Worktree → Task → Session** 순서다.
사용자는 Session마다 코딩 agent 하나와 model을 고른다. Settings는 agent, Skill, MCP,
ByoriDB, 진단 관리를 보조하며 메인 workspace가 아니다. 한 프로젝트의 모든 Source
Tree/Worktree, Task, Session, agent 선택은 Context inspector를 통해 같은 프로젝트
ByoriDB 지식 그래프를 공유한다.

## 무엇을 설치하나

| 구성 | 위치 | 역할 |
|---|---|---|
| `byoridb-server` (+`byoridb-cli`) | `~/.byoridb/bin/` | 로컬 ByoriDB (gRPC 9669 / HTTP 19669, `127.0.0.1` 바인딩) |
| `byori` + `byori.py` | `~/.byoridb/bin/` | provider 탐색, 신뢰 프로젝트 등록, Claude/Codex 병렬 실행, 로컬 run 조회용 dependency-free coordinator. 설치기는 이 경로를 `PATH`에 추가하지 않음 |
| `byoridb_mcp.py` | `~/.byoridb/` | 호환 note tool + 검증된 typed-wiki CRUD/export/read-only query tool을 stdio로 노출. 기본 `legacy` profile은 unrestricted `memory_query`도 제공. Writer profile은 설정 space를 schema v2(`note`/`rel` + typed wiki)로 bootstrap·migration하고 `readonly`는 그 version만 검증 |
| 상시 실행 서비스 | launchd `com.byoridb.local`(macOS) / systemd --user(Linux) | launchd는 `RunAtLoad` + `KeepAlive`; systemd user unit은 `default.target` 연결 + `Restart=always` |
| `env` | `~/.byoridb/env` (chmod 600) | 랜덤 생성된 root 비밀번호 |
| 기억 스킬 | `~/.claude/skills/byoridb-memory/SKILL.md` | 언제/무엇을 기억·회수할지의 정책 |
| 디자인 스킬 | `~/.claude/skills/byori-design/` | 저장소 산출물과 Byori 기억 사이의 제품·UX/UI 연속성 |
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
- `--uninstall` — 서비스 중지·해제, Claude/Codex MCP 등록 해제, Byori skill 두 개 제거.
  **데이터는 확인 후 보존/삭제 선택.** merge되지 않은 사용자 변경이 있을 수 있어
  `~/.byori`의 오케스트레이션 record와 worktree는 보존한다.
- `--binary PATH` — 다운로드 대신 로컬 `byoridb-server` 바이너리 사용.
- `--assets DIR` — 다운로드 대신 로컬 repo 체크아웃(`DIR`)에서 CLI/mcp.py/템플릿/스킬을 가져옴.
- `--no-service` — launchd/systemd 등록 없이 현재 세션의 background process로 실행.
- `--no-claude` — Claude MCP 등록, skill들, hook 설치를 건너뜀.
- `--no-codex` — Codex MCP 등록과 skill들 설치를 건너뜀.

설치기 환경변수: `BYORIDB_HOME`(기본 `~/.byoridb`), `BYORIDB_HTTP_PORT`(기본 19669),
`BYORIDB_GRAPH_PORT`(기본 9669), `BYORIDB_LABEL`(기본 `com.byoridb.local`),
`BYORI_ENGINE_TAG`(기본: 고정 호환 엔진 태그).
재설치할 때 현재 `BYORIDB_ROOT_PASSWORD` 또는 legacy `BYORIDB_PASSWORD` 값을 보존한다.
설치 완료는 해당 credential로 실제 session 생성까지 성공해야 한다. 오래된 ByoriDB
process가 이미 port를 점유할 수 있으므로 인증 없는 `/health` 응답만으로 성공 처리하지 않는다.
격리 테스트: `BYORIDB_HOME=/tmp/bt BYORIDB_HTTP_PORT=29669 BYORIDB_GRAPH_PORT=29670 ./install.sh --binary … --assets …`

## Foreground 멀티 CLI 호환 경로

설치기는 전역 symlink를 의도적으로 만들지 않는다. 현재 shell의 bin 경로에 추가하거나
전체 경로로 실행한다.

```sh
export PATH="$HOME/.byoridb/bin:$PATH"
byori provider list

cd /path/to/a/git/repository
byori project add .
byori run --agent claude --agent codex "요청한 변경을 구현해"
byori runs list
```

초기 `byori run` coordinator는 별도 prototype/호환 경로다. Prompt 하나를 여러 worker로
fan-out할 수 있지만 macOS 앱의 Session model을 정의하지 않는다. 오케스트레이션에는
Git도 필요하다. MVP는 Claude Code와 Codex를 지원하며 `--agent`를
생략하면 설치된 지원 provider를 모두 사용한다. `byori project add . [--space SPACE]`는
비대화식 worker에 대한 명시적 신뢰 경계다. 기본 run 모드는 dirty 저장소를 거부하고
worker마다 branch와 관리형 worktree를 만든 뒤 결과를 merge하거나 삭제하지 않고 남긴다.
worker 하나는 `--in-place`로 기존 변경을 포함한 현재 working tree를 명시적으로 사용할 수 있다.

운영 JSON, raw prompt, provider log, advisory lock, worktree는 `BYORI_HOME`(기본
`~/.byori`)에 저장한다. 제한된 recall context와 coordinator가 소유한 project/task
checkpoint만 ByoriDB 경계를 넘는다. Coordinator recall 주입과 checkpoint를 생략하려면
`--no-memory`를 사용한다. 전역 등록 MCP가 `legacy`로 fallback하지 않도록 worker에는 계속
project space와 `readonly` profile을 전달한다. 전체 명령,
`--allow-shell`, timeout, run 조회, 데이터 위치, 보안 model은
[멀티 CLI 오케스트레이션](orchestration.md)을 참고한다.

## MCP profile과 memory space

자동 등록되는 Claude/Codex 연동은 profile을 지정하지 않아
`BYORIDB_MCP_PROFILE=legacy`를 사용한다. 하위 호환성을 위해 unrestricted raw-nGQL
`memory_query`를 포함한 9개 tool을 모두 노출한다. `BYORIDB_MCP_PROFILE=safe`는 이 tool
하나만 discovery와 dispatch에서 제거한다. reduced raw-query surface이지 **read-only
server가 아니다**. `memory_remember`, `memory_wiki_upsert`, `memory_link`,
`memory_delete`는 계속 write할 수 있다.
`BYORIDB_MCP_PROFILE=readonly`는 `memory_recall`, `memory_query_read`, `memory_read`,
`memory_export`만 노출한다. 오케스트레이터는 worker에 이 profile을 주고 coordinator가
write를 전담한다.

Profile은 MCP tool을 제한할 뿐 authorization 경계나 process sandbox가 아니다. `readonly`
process는 startup에서 login, `USE <space>`, schema-version read만 수행하며 writer가 현재
version으로 space를 미리 준비하지 않았으면 실패한다. 설정된 engine credential은 계속
가지므로 신뢰 영역이 다르면 instance와 credential을 분리한다.

`BYORIDB_MEMORY_SPACE`는 논리 memory namespace를 선택하며(기본 `claude_memory`),
`^[A-Za-z_][A-Za-z0-9_]{0,63}$`을 만족해야 한다. 프로젝트가 우연히 섞이지 않게 할 뿐
모든 space가 같은 엔진 credential을 쓰므로 authorization/tenant 경계가 아니다. 신뢰 영역이
다르면 별도 instance와 credential을 사용한다.

두 변수는 MCP client별 process 설정에 전달한다. `~/.byoridb/env`를 편집해 영속화하지
말 것. 재설치·upgrade 시 설치기가 해당 파일을 다시 쓰며 `BYORIDB_ROOT_PASSWORD`만 보존한다.

### MCP 서버 수명

서버는 stdin이 닫히면(호스트가 사라졌다는 정상 신호) 종료하고, `SIGTERM`·`SIGHUP`에서도
종료하며 각각 종료 이유를 로그로 남긴다. 종료 시 24시간 TTL에 맡기지 않고
`DELETE /api/v1/session`으로 sign out한다. 종료 로그에 세션과 결과를 남기므로, 실제로 세션이
프로세스보다 오래 남는 경우(엔진이 이미 없거나 그 route가 없는 0.4.0 이전 엔진)에도 어느
프로세스가 들고 있었는지 추적할 수 있다.

일부 호스트는 해당 대화가 끝난 뒤에도 호스트 프로세스가 살아 있는 동안 서버의 stdin을 계속
열어 둔다. 그러면 부모가 살아 있는 채로 서버가 남는다. `BYORIDB_MCP_IDLE_TIMEOUT`에 초를
지정하면(최소 60) 그만큼 요청이 없을 때 서버가 종료한다. 기본값은 미설정이다. 호스트가 유휴
서버를 계속 열어 두는 것은 정상이며, 아직 필요한 서버를 종료하면 회수된 프로세스가 아니라
실패한 MCP 서버로 보고된다.

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

설치기가 `codex` CLI를 감지하면 stdio MCP 등록과 Byori skill 두 개 설치(`~/.agents/skills/`)를
자동으로 수행하고, `--uninstall` 시 함께 제거한다(`--no-codex`로 건너뜀).
Codex 재시작 후 `codex mcp list`로 확인한다. Claude용 hook은 Codex에 설치되지 않는다.

`--no-codex`로 건너뛰었거나 나중에 연결하려면 수동으로 등록한다.

```sh
codex mcp add byoridb -- "$HOME/.byoridb/bin/run-mcp.sh"
mkdir -p "$HOME/.agents/skills/byoridb-memory"
cp "$HOME/.claude/skills/byoridb-memory/SKILL.md" \
  "$HOME/.agents/skills/byoridb-memory/SKILL.md"
mkdir -p "$HOME/.agents/skills/byori-design"
cp -R "$HOME/.claude/skills/byori-design/." \
  "$HOME/.agents/skills/byori-design/"
codex mcp list
```

수동 제거는 다음과 같다.

```sh
codex mcp remove byoridb
rm -rf "$HOME/.agents/skills/byoridb-memory" "$HOME/.agents/skills/byori-design"
```

## NaraeClaw 또는 기타 수동 MCP host 연결

설치기와 Byori macOS 앱은 현재 Claude Code/Codex만 설정한다. NaraeClaw 전용 설정 형식이나
skill 경로는 가정하지 않는다. 호환 host의 MCP process 설정에 아래 runner를 사용하고,
`adapters/naraeclaw/skills/byoridb-memory/SKILL.md` 참조 정책은 해당 host가 문서화한
방식으로 설치한다.

```sh
env BYORIDB_MCP_PROFILE=safe \
  BYORIDB_MEMORY_SPACE=my_project \
  "$HOME/.byoridb/bin/run-mcp.sh"
```

NaraeClaw 전용 hook은 제공하지 않는다. 다른 host에만 설정된 space는 Byori macOS 앱이
자동으로 발견하지 않는다. Context inspector는 선택한 등록 Project의 ByoriDB space를
사용한다. release 전에 source tree를 테스트할 때는 먼저 `./install.sh --assets .`로
설치한다.

## 한계

- MCP 서버는 리마인더가 아니라 실제 데이터 도구다. **기억할지 말지의 정책은 스킬**(`byoridb-memory`)에 있다.
  `byori-design`은 제품/디자인 작업을 조율하지만 저장소 산출물을 대체하지 않는다.
- `safe`는 unrestricted raw nGQL만 차단한다. structured delete/link도 write이므로
  `legacy`와 같은 사용자 의도 확인이 필요하다.
- `readonly`는 mutation tool을 차단하지만 authentication sandbox는 아니다. Startup schema
  check는 read-only이고 stale space를 bootstrap/migration하는 대신 즉시 실패한다.
- schema 부트스트랩(v2: `note`/`rel` + typed wiki)은 additive migration이다. 적용 버전은
  `byori:schema-version` note로 확인한다.
- `memory_export`는 제한된 inspection API이지 transactional backup snapshot이 아니다.
  동시 write가 없어도 deep page는 이동할 수 있으므로 완전한 restore source로 사용하지 않는다.
- hook은 capture를 직접 실행하지 않고 에이전트에게 체크포인트를 상기시킨다.
- current/history dual-write는 비원자적이며 같은 millisecond 재기록은 history key 충돌 위험(bitemporal v1 제약).
- 로컬 단일 노드 전용. 분산/프로덕션 배포와 무관.

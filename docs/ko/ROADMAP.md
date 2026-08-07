[English](../ROADMAP.md) | **한국어**

# Byori 로드맵

byoridb 저장소에서 분리된 2026-07-13에 처음 수립하고 2026-08-07에 갱신한 계획. Byori는
프로젝트 중심 코딩 워크스페이스, ByoriDB는 지식 엔진, `byori`는 CLI다. 원칙은
**의존성이 Byori → ByoriDB 한 방향으로 흐르는 것**이다. Byori가 검증된 엔진 릴리스를
설치·관리하고 엔진은 Byori를 모른다.

## P3 — 엔진 호환성 계약 🟡 (계약·CI 완료)

- ✅ [`docs/engine-contract.md`](engine-contract.md) 작성: MCP가 실제 사용하는 엔진 표면만 명시
  - `/health`, 세션 로그인, 400 `Invalid session` 재로그인 시맨틱, `USE` 재-pin
  - 게이트하는 nGQL 부분집합: `CREATE SPACE/TAG/EDGE`, `USE`, `INSERT`,
    canonical name `WHERE` lookup과 `RETURN`/`ORDER BY`/`LIMIT`/`OFFSET`을 포함한
    `MATCH`, `FETCH`(+`AS OF`), `DELETE EDGE`, `DELETE VERTEX`
  - env 계약: `BYORIDB_ROOT_PASSWORD`, `BYORIDB__*`
- ✅ CI는 고정 `ENGINE_TAG` 릴리스를 내려받아 `install.sh --assets . --no-claude --no-codex` 후
  unit test와 고정 엔진 smoke test로 계약을 검증한다. structured
  upsert/read/link/export/delete, safe profile의 raw query 거부, v0.2.0 typed VID 재사용,
  edge 삭제, cascade vertex 삭제까지 커버한다
- 🟡 hash 63bit 마스킹과 VID 범위 문서화는 완료. 엔진의 음수 VID planner 정식 수정은 남음

## P4 — Byori macOS 앱 + 공용 관리 코어 🟡 (워크스페이스 구현, signed DMG 릴리스 대기)

SwiftUI **Byori macOS 앱**은 구현되어 source build로 사용할 수 있다. 핵심 화면은
Project → Source Tree/Worktree → Task → Session 워크스페이스이며, 사용자가 세션마다
Claude Code 또는 Codex를 골라 실제 대화형 PTY에서 작업한다. signed/notarized `.dmg`
릴리스는 아직 남았다. 공용 코어는 Settings에서 설치·진단·연결·업데이트를 담당한다.
현재 cross-platform `byori` CLI는 foreground 호환 slice
(`provider / project / run / runs`)를 구현하며, 더 넓은 관리 표면은 앱 코어와 수렴해야 한다:
`setup / doctor / connect claude / connect codex / project add . / status /
backup / upgrade --plan / rollback / uninstall`.

- ✅ 앱은 프로젝트 등록을 보존하고 source tree와 linked worktree를 탐색하며 task/session
  metadata를 저장하고, 앱 process가 살아 있는 동안 실제 PTY를 유지한다
- ✅ 세션마다 사용자가 고른 launch provider/model 하나를 기록한다. 앱은 prompt를 자동
  fan-out하거나 winner를 선택하고 agent 작업을 merge·삭제하지 않는다
- 앱은 Claude/Codex를 감지하고 사용자의 명시적 동의 후 각 벤더의 **공식 설치기**를
  실행할 수 있다. 로그인은 벤더 CLI에 맡기며 Byori는 vendor token을 읽거나 저장하지 않는다
- `connect`/`disconnect`는 idempotent, 변경 전 원본 설정 백업
  (shell installer의 `--with-hooks`도 append+백업 방식으로 동작한다)
- ByoriDB는 독립 launchd user service로 유지한다. 설치, agent 연결, 유지관리, 백업, 진단은
  지원 기능인 Settings에 둔다
- 상태 모델은 `byoridb-tray` prototype을 따르되 하드코딩 경로와 동기 process 실행은
  재사용하지 않았다
- 남음: 앱 완전 종료 후 PTY reattach, 앱이 관리하는 worktree 생성, 서명·공증된 공개 배포

## P5 — memory schema versioning + migration 🟡 (additive v2 + structured MCP 완료)

- ✅ `claude_memory` space에 `byori:schema-version` note — MCP 시작 시 버전을 읽고
  부족한 additive migration만 적용
- ✅ typed wiki ontology(`module`/`decision`/`bug`/`incident`/`concept`/`entity`/`task`
  및 causal edge)를 schema v2로 fresh install 자동 bootstrap + 기존 설치 자동 migration
  — [`docs/memory-ontology.md`](memory-ontology.md) 참조
- ✅ 검증된 upsert, read, traversal, link, export, delete를 제공하는 structured MCP 표면과
  `safe`(제한 없는 raw query 제거), `readonly`(read tool 4개, fail-fast schema check) profile
  완료. 정확한 canonical name lookup으로 기존 v0.2.0 typed VID를 보존·재사용해 중복 node
  생성을 방지한다
- 남음: 비-additive(파괴적) migration의 명시적 단계 실행(`byori migrate`) — P4의
  공용 관리 코어/CLI로 수렴

## P6 — `byori` project registry + foreground CLI 프로토타입 🟡 (로컬 MVP 완료)

이 경로는 명시적으로 사용하는 호환 프로토타입이며 네이티브 워크스페이스의 상호작용 모델이
아니다. 사용자가 run에 사용할 provider를 하나 이상 선택한다. 앱에서 task나 session을 만든다고
여러 provider 실행이 자동으로 시작되지 않는다.

- ✅ `byori provider list`: vendor credential을 읽지 않고 Claude Code와 Codex executable을
  감지. Provider adapter가 launch 설정과 provider-native session ID를 정규화
- ✅ `byori project add . [--space SPACE]`와 `project list`: canonical Git root와 안정적인
  graph namespace 등록. 등록은 비대화식 worker에 대한 명시적 신뢰 경계
- ✅ `byori run`: 선택한 provider를 동시에 실행. 기본 모드는 dirty 저장소를 거부하고
  worker마다 `byori/<run-id>/<worker>` branch와 관리형 worktree를 생성. worker 하나의
  `--in-place`는 명시적 escape hatch
- ✅ 운영 JSON, raw prompt, provider log, worktree는 `~/.byori`에 두고 제한된 recall
  context만 주입. Coordinator가 소유한 project/task checkpoint만 ByoriDB로 승격
- ✅ worker에는 read tool 4개뿐인 `readonly` MCP profile을 제공. Project-space advisory
  lock으로 coordinator의 graph 준비와 checkpoint write를 직렬화하고 stale schema에서는
  worker가 즉시 실패
- ✅ `byori runs list/show`: durable local run record 조회. Branch와 worktree는 자동
  merge하거나 삭제하지 않음
- 남음: background/attach/resume 제어, provider adapter 추가, patch 비교, 명시적
  merge/cleanup workflow, 앱 관리 명령과의 수렴

## P7 — 자동 ingestion + ranked recall

- 지식이 확정되는 경계(작업 종료·commit·PR·인시던트 해소)에서만 구조화 capture
- repository의 module, symbol, dependency, document, git change를 project-aware하게
  indexing → canonical name과 merge candidate로 파편화 방지
- traversal + temporal + semantic ranking recall, 읽기 좋은 wiki surface 추가

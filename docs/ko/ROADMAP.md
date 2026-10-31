[English](../ROADMAP.md) | **한국어**

# Byori 로드맵

**2026-09-12 변경:** 제품 방향을 원점에서 재검토합니다. 현재 작업은
[프로젝트 의존 지식 재사용 실험](../dependency-context-pilot.md)이며, 아래 앱 중심
로드맵의 완성이 선행 조건은 아닙니다. 기존 구현은 삭제하지 않고 중단·보존합니다.

**2026-09-11 확정한 방향:** Byori는 AI가 읽는 근거 있는 프로젝트 안내서를 만들고 최신으로
유지합니다. ByoriDB는 내부 지식 빌드 엔진입니다. 제품 통폐합은 가능하지만 기존 사용자 데이터는
보존해야 합니다.

범위·의존성·완료 조건은 [Product](../../PRODUCT.md), [Design](../../DESIGN.md),
[개발 계획](knowledge-compiler-plan.md)을 따릅니다. 아래 목표는 새로 출시된 기능이 아닙니다.

## Now — 첫 효용 확인

| ID | 결과 | 상태 |
|---|---|---|
| KC-00 | 확정 전략과 일치하는 제품·디자인·개발 계획 | 문서화 완료 |
| KC-01 | 프로젝트 하나의 결정론적·근거 연결 안내서 | 초기 구현과 독립 검증 진행 중 |
| KC-02 | Claude Code·Codex 새 세션 실제 전달과 명시적 갱신 | 어댑터 기반 작업 중, 실제 전달 완료 조건 미통과 |

내부 데모 조건: 프로젝트 하나 → 유용한 안내서 → 새 에이전트 세션이 사용 → 원본 변경·명시적
재빌드 → 다음 세션에 대체 내용 전달. 모델 편집이나 DB 전면 재작성은 필요하지 않습니다.

## Next — 신뢰성과 설치 경험 완성

| ID | 결과 | 상태 |
|---|---|---|
| KC-03 | 증분 컴파일·범위 격리·안전한 공개·오프라인 결과 | 동의 기반 갱신과 인증된 실행 간 중간 결과 재사용 구현, 호스트·오프라인·제품 가치 조건은 미통과 |
| KC-04 | 작은 매니저·단일 런타임 관리·복구 가능한 설치와 이전 | 네이티브 UI 초기 구현, 전체 조건은 KC-02/KC-03·복구 검증 필요 |
| KC-06 | 다섯 명 파일럿·공정한 대안 비교·출시 판단 | 미착수, KC-04 필요 |

외부 파일럿에 KC-05는 필수가 아닙니다. 안전·호환성 테스트는 각 변경에 함께 들어갑니다.
유지관리자가 저장소 간 의존성을 책임지고 실제 막히는 요구를 확인한 후 엔진을 수정합니다.
한 번에 한 단계만 진행하고 통합·결함 대응 여유를 둡니다. 첫 구현을 측정하기 전에 날짜를 약속하지 않습니다.

## Later — 효과가 입증될 때 확장

- **KC-05, 선택:** 원본 근거로 수행하는 비용 제한·동의 기반 모델 편집. KC-03 이후 품질 개선을
  확인해야 합니다. 출시 범위에 넣으면 KC-06 전에 완료 조건을 통과해야 합니다.
- 추가 원본 커넥터·팀 기능은 반복 사용 가치가 확인된 다음 검토합니다.
- 기존 코드 정리는 보존·복구 검증 뒤 별도 진행하며 처음부터 전면 재작성하지 않습니다.

우선순위를 내린 것: 새 터미널·워크트리·세션 실행 관리, 그래프 대시보드 꾸미기, 범용 DB 기능 확대,
내부 구성요소별 독립 제품 출시. 새 요구는 낮은 우선순위 작업과 교체하며 1인 개발 범위를 늘리지 않습니다.

## 과거 로드맵 — 2026-08-07 스냅샷, 현재 계획으로 대체됨

아래 P3~P8은 설계 이력으로 보존합니다. 완료 표시와 ‘남음’은 과거 스냅샷이며 **현재 구현 상태나
진행 약속이 아닙니다.** 우선순위는 위 KC 단계로 대체합니다. 과거 이슈는 현재 의존성으로 삼기 전에
재확인합니다. 최초 수립일은 저장소 분리 시점인 2026-07-13입니다.

### P3 — 엔진 호환성 계약 🟡 (계약·CI 완료)

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

### P4 — Byori macOS 앱 + 공용 관리 코어 🟡 (워크스페이스·서명 릴리스 완료, CLI 수렴 남음)

SwiftUI **Byori macOS 앱**은 구현되었고 릴리스마다 서명·공증·staple을 마친 universal DMG로
배포한다. 앱은 새 릴리스의 서명과 공증을 확인한 뒤 스스로 업데이트한다. 핵심 화면은
Project → Source Tree/Worktree → Task → Session 워크스페이스이며, 사용자가 세션마다
Claude Code 또는 Codex를 골라 실제 대화형 PTY에서 작업한다. 공용 코어는 Settings에서
설치·진단·연결·업데이트를 담당한다.
현재 cross-platform `byori` CLI는 foreground 호환 slice
(`provider / project / run / runs`)를 구현하며, 더 넓은 관리 표면은 앱 코어와 수렴해야 한다:
`setup / doctor / connect claude / connect codex / project add . / status /
backup / upgrade --plan / rollback / uninstall`.

- ✅ 앱은 프로젝트 등록을 보존하고 source tree와 linked worktree를 탐색하며, 기존/새 local
  branch로 Byori 관리 worktree를 만들고, task/session metadata를 저장하고 실제 PTY를 유지한다.
  tmux 3.2 이상이면 앱을 완전히 종료해도 세션이 유지되고 다음 실행에서 다시 attach된다
- ✅ 세션마다 사용자가 고른 launch provider/model 하나를 기록한다. 앱은 prompt를 자동
  fan-out하거나 winner를 선택하고 agent 작업을 merge·삭제하지 않는다
- 앱은 Claude Code, Codex, Gemini CLI, Cursor CLI, OpenCode를 감지하고 사용자의 명시적
  동의 후 각 벤더의 **공식 설치 명령**을 실행할 수 있다. 로그인은 벤더 CLI에 맡기며
  Byori는 vendor token을 읽거나 저장하지 않는다
- `connect`/`disconnect`는 idempotent, 변경 전 원본 설정 백업
  (shell installer의 `--with-hooks`도 append+백업 방식으로 동작한다)
- ByoriDB는 독립 launchd user service로 유지한다. 설치, agent 연결, 유지관리, 백업, 진단은
  지원 기능인 Settings에 둔다
- 상태 모델은 `byoridb-tray` prototype을 따르되 하드코딩 경로와 동기 process 실행은
  재사용하지 않았다
- 남음: cross-platform `byori` CLI의 관리 표면을 앱 코어와 수렴

### P5 — memory schema versioning + migration 🟡 (additive v2 + structured MCP 완료)

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

### P6 — `byori` project registry + foreground CLI 프로토타입 🟡 (로컬 MVP 완료)

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

### P7 — 자동 ingestion + ranked recall

- 지식이 확정되는 경계(작업 종료·commit·PR·인시던트 해소)에서만 구조화 capture
- repository의 module, symbol, dependency, document, git change를 project-aware하게
  indexing → canonical name과 merge candidate로 파편화 방지
- traversal + temporal + semantic ranking recall, 읽기 좋은 wiki surface 추가

### P8 — 첫 가치까지의 시간

현재 Byori의 가치는 지연되어 있습니다. 설치 시점의 그래프는 비어 있고, 몇 주간 체크포인트가
쌓여야 쓸모가 생깁니다. 새 프로젝트는 이득을 보기 전에 비용부터 냅니다. 이 단계는 100번째
세션이 아니라 첫 세션을 목표로 합니다.

- 이미 존재하는 근거(Git 히스토리, merge commit, 이슈·PR 참조, 기존 설계 문서)에서 신규
  등록을 seeding 하여 `project add` 직후의 그래프가 비어 있지 않게 한다
- 실제 저장소에서 실행 가능한 데모를 제공해, 몇 주간의 사전 사용 없이도 recall이 코드만으로는
  답할 수 없는 질문에 답하는 장면을 보여 준다
- 세션 종료 후 실제로 무엇이 capture 되었는지 보고하여, 사용자가 그래프가 자란다는 사실을
  믿는 대신 보게 한다
- 현재의 dogfood 단일 실행 대신 재현 가능한 before/after 수치를 측정·공개한다. README의
  벤치마크는 방향을 보여 주는 근거이지 주장(claim)이 아니다

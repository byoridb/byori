[English](../ROADMAP.md) | **한국어**

# Byori 로드맵

byoridb 저장소에서 분리(2026-07-13)된 시점의 계획. 원칙: **의존성은 Byori → ByoriDB
한 방향**. Byori가 검증된 엔진 릴리스를 설치·관리하고, 엔진은 Byori를 모른다.

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

## P4 — Byori Manager + 공용 관리 코어 🟡 (Manager 구현, signed DMG 릴리스 대기)

SwiftUI **Byori Manager**는 구현되어 source build로 사용할 수 있다.
signed/notarized `.dmg` 릴리스는 아직 남았다. 공용 코어가 설치·진단·연결·
업데이트를 담당하고, 이후 같은 코어를 얇은 `byori` CLI에서도 재사용한다:
`setup / doctor / connect claude / connect codex / project add . / status /
backup / upgrade --plan / rollback / uninstall`.

- Manager는 Claude/Codex를 감지하고 사용자의 명시적 동의 후 각 벤더의 **공식 설치기**를
  실행할 수 있다. 로그인은 벤더 CLI에 맡기며 vendor token은 읽거나 저장하지 않는다
- `connect`/`disconnect`는 idempotent, 변경 전 원본 설정 백업
  (shell installer의 `--with-hooks`도 append+백업 방식으로 동작한다)
- macOS 앱은 SwiftUI로 구현되었고 ByoriDB는 독립 launchd user service로 유지된다
- 상태 모델은 `byoridb-tray` prototype을 따르되 하드코딩 경로와 동기 process 실행은
  재사용하지 않았다

## P5 — memory schema versioning + migration 🟡 (additive v2 + structured MCP 완료)

- ✅ `claude_memory` space에 `byori:schema-version` note — MCP 시작 시 버전을 읽고
  부족한 additive migration만 적용
- ✅ typed wiki ontology(`module`/`decision`/`bug`/`incident`/`concept`/`entity`/`task`
  및 causal edge)를 schema v2로 fresh install 자동 bootstrap + 기존 설치 자동 migration
  — [`docs/memory-ontology.md`](memory-ontology.md) 참조
- ✅ 검증된 upsert, read, traversal, link, export, delete를 제공하는 structured MCP 표면과
  제한 없는 raw-query tool을 노출하지 않는 `safe` profile 완료. 정확한 canonical name lookup으로
  기존 v0.2.0 typed VID를 보존·재사용해 중복 node 생성을 방지한다
- 남음: 비-additive(파괴적) migration의 명시적 단계 실행(`byori migrate`) — P4의
  공용 관리 코어/CLI로 수렴

## P6 — project registry + 자동 ingestion

- `byori project add .`: 프로젝트별 namespace(space 또는 name prefix) 등록
- 지식이 확정되는 경계(작업 종료·commit·PR·인시던트 해소)에서만 구조화 capture
- repository의 module, symbol, dependency, document, git change를 project-aware하게
  indexing → canonical name과 merge candidate로 파편화 방지
- 이후: traversal + temporal + semantic ranking recall, 읽기 좋은 wiki surface

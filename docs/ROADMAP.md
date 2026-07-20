# Byori 로드맵

byoridb 저장소에서 분리(2026-07-13)된 시점의 계획. 원칙: **의존성은 Byori → ByoriDB
한 방향**. Byori가 검증된 엔진 릴리스를 설치·관리하고, 엔진은 Byori를 모른다.

## P3 — 엔진 호환성 계약 (다음 단계)

- `docs/engine-contract.md` 작성: MCP가 실제 사용하는 엔진 표면만 명시
  - `/health`, 세션 로그인, 400 `Invalid session` 재로그인 시맨틱, `USE` 재-pin
  - 사용하는 nGQL 부분집합: `CREATE SPACE/TAG/EDGE`, `INSERT`, `FETCH`(+`AS OF`),
    `GO`, `LOOKUP`, `DELETE`
  - env 계약: `BYORIDB_ROOT_PASSWORD`, `BYORIDB__*`
- CI: 고정 `ENGINE_TAG` 릴리스를 내려받아 `install.sh --assets . --no-claude` 후
  MCP roundtrip(remember→recall→query) 스모크
- 음수 VID 버그 처리: 엔진에 planner 수정(정식) + `byoridb_mcp.py`에 hash 63bit
  마스킹(즉시 우회). 계약 문서에 VID 범위 명시

## P4 — Byori Manager + 공용 관리 코어

macOS에서는 `.dmg`로 배포하는 SwiftUI **Byori Manager**를 우선 제공한다. 공용 관리
코어가 설치·진단·연결·업데이트를 담당하고, 이후 같은 코어를 얇은 `byori` CLI에서도
재사용한다: `setup / doctor / connect claude / connect codex / project add . / status /
backup / upgrade --plan / rollback / uninstall`.

- Manager는 Claude/Codex를 감지하고 사용자의 명시적 동의 후 각 벤더의 **공식 설치기**를
  실행할 수 있다. 로그인은 벤더 CLI에 맡기며 vendor token은 읽거나 저장하지 않는다
- `connect`/`disconnect`는 idempotent, 변경 전 원본 설정 백업
  (shell installer의 `--with-hooks`도 append+백업 방식으로 동작한다)
- macOS 앱은 SwiftUI로 구현하고 ByoriDB는 독립 launchd user service로 유지
- `byoridb-tray` prototype의 상태 모델은 참고하되 하드코딩 경로와 동기 process 실행은
  재사용하지 않음

## P5 — memory schema versioning + migration ✅ (v0.2.0)

- ✅ `claude_memory` space에 `byori:schema-version` note — MCP 시작 시 버전을 읽고
  부족한 additive migration만 적용
- ✅ typed wiki ontology(`module`/`decision`/`bug`/`incident`/`concept`/`entity`/`task`
  + causal edge)를 schema v2로 fresh install 자동 bootstrap + 기존 설치 자동 migration
  — `docs/memory-ontology.md` 참조
- 남음: 비-additive(파괴적) migration의 명시적 단계 실행(`byori migrate`) — P4의
  공용 관리 코어/CLI로 수렴

## P6 — project registry + 자동 ingestion

- `byori project add .`: 프로젝트별 namespace(space 또는 name prefix) 등록
- 지식이 확정되는 경계(작업 종료·commit·PR·인시던트 해소)에서만 구조화 capture
- repository의 module, symbol, dependency, document, git change를 project-aware하게
  indexing → canonical name과 merge candidate로 파편화 방지
- 이후: traversal + temporal + semantic ranking recall, 읽기 좋은 wiki surface

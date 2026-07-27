# Byori 로드맵

byoridb 저장소에서 분리(2026-07-13)된 후의 계획과 진행 상태. 원칙: **의존성은
Byori → ByoriDB 한 방향**. Byori가 검증된 엔진 릴리스를 설치·관리하고, 엔진은
Byori를 모른다.

## P3 — 엔진 호환성 계약 ✅ (v0.1.1)

- ✅ `docs/engine-contract.md` 작성: MCP가 실제 사용하는 엔진 표면만 명시
  - `/health`, 세션 로그인, 400 `Invalid session` 재로그인 시맨틱, `USE` 재-pin
  - 사용하는 nGQL 부분집합: `CREATE SPACE/TAG/EDGE`, `INSERT`, `FETCH`(+`AS OF`),
    `GO`, `LOOKUP`, `DELETE`
  - env 계약: `BYORIDB_ROOT_PASSWORD`, `BYORIDB__*`
- ✅ CI: 고정 `ENGINE_TAG` 릴리스를 내려받아 `install.sh --assets . --no-claude` 후
  MCP roundtrip(remember→recall→query) 스모크
- ✅ 음수 VID 버그 처리: 엔진에 planner 수정(정식) + `byoridb_mcp.py`에 hash 63bit
  마스킹(즉시 우회). 계약 문서에 VID 범위 명시

## P4 — Byori Manager + 공용 관리 코어 ✅ (v0.2.0)

SwiftUI **Byori Manager**와 공용 관리 코어, DMG 패키징·CI·릴리스 workflow를
구현했다.

- ✅ Manager는 Claude/Codex를 감지하고 사용자의 명시적 동의 후 각 벤더의 **공식 설치기**를
  실행할 수 있다. 로그인은 벤더 CLI에 맡기며 vendor token은 읽거나 저장하지 않는다
- ✅ `connect`/`disconnect`는 idempotent, 변경 전 원본 설정 백업
  (shell installer의 `--with-hooks`도 append+백업 방식으로 동작한다)
- ✅ ByoriDB를 독립 launchd user service로 유지하며, 상태·로그·백업·롤백을 관리한다
- ✅ 메뉴 막대 상태 UI와 read-only 지식 그래프 뷰를 제공한다

후속 작업:

- 공용 코어를 재사용하는 얇은 `byori` CLI: `setup / doctor / connect claude /
  connect codex / project add . / status / backup / upgrade --plan / rollback / uninstall`
- 서명·공증된 universal DMG를 기존 GitHub Release에 첨부하는 workflow는 있지만,
  Apple 서명·공증 credential이 준비되기 전까지 실제 배포는 보류

## P5 — memory schema versioning + migration ✅ (v0.2.0)

- ✅ `claude_memory` space에 `byori:schema-version` note — MCP 시작 시 버전을 읽고
  부족한 additive migration만 적용
- ✅ typed wiki ontology(`module`/`decision`/`bug`/`incident`/`concept`/`entity`/`task`
  + causal edge)를 schema v2로 fresh install 자동 bootstrap + 기존 설치 자동 migration
  — `docs/memory-ontology.md` 참조
- 후속 작업: 비-additive(파괴적) migration의 명시적 단계 실행(`byori migrate`) — P4의
  공용 관리 코어/CLI로 수렴

## P6 — project registry + 자동 ingestion (다음 단계)

- `byori project add .`: 프로젝트별 namespace(space 또는 name prefix) 등록
- 지식이 확정되는 경계(작업 종료·commit·PR·인시던트 해소)에서만 구조화 capture
- repository의 module, symbol, dependency, document, git change를 project-aware하게
  indexing → canonical name과 merge candidate로 파편화 방지
- 이후: traversal + temporal + semantic ranking recall, 읽기 좋은 wiki surface

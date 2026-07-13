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

## P4 — `byori` 단일 CLI

`install.sh`를 흡수: `byori setup / doctor / connect claude / connect codex /
project add . / status / backup / upgrade --plan / rollback / uninstall`

- Claude/Codex는 **감지 + 공식 설치 안내 + 명시적 동의 후 연결만**. 벤더 CLI의
  설치·업데이트·로그인에는 관여하지 않고, vendor token은 읽지도 저장하지도 않는다
- `connect`/`disconnect`는 idempotent, 변경 전 원본 설정 백업
  (현재 `--with-hooks`의 jq merge가 기존 event 배열을 교체하는 문제를 여기서 해소)
- 구현 언어는 Rust 단일 바이너리 우선 검토 (tray와 상태확인·백업 로직 공유)
- `byoridb-tray`(현재 `~/opensource/byoridb-tray`, 미버전관리)를 `tray/` 모듈로 편입

## P5 — memory schema versioning + migration

- `claude_memory` space에 `schema_version` 노드, `byori migrate`로 단계적 이행
- typed wiki ontology(`module`/`decision`/`bug`/`incident`/`concept`/`task` +
  causal edge)를 fresh install에서 자동 bootstrap — `docs/memory-ontology.md` 참조

## P6 — project registry + 자동 ingestion

- `byori project add .`: 프로젝트별 namespace(space 또는 name prefix) 등록
- 지식이 확정되는 경계(작업 종료·commit·PR·인시던트 해소)에서만 구조화 capture
- repository의 module, symbol, dependency, document, git change를 project-aware하게
  indexing → canonical name과 merge candidate로 파편화 방지
- 이후: traversal + temporal + semantic ranking recall, 읽기 좋은 wiki surface

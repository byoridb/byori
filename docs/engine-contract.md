# ByoriDB 엔진 호환성 계약

Byori가 의존하는 ByoriDB 엔진 표면의 **전부**를 명시한다. 여기 없는 엔진 기능은
Byori 호환성과 무관하게 바뀌어도 된다. 반대로 이 문서의 표면이 바뀌면 엔진 태그를
올리기 전에 Byori 쪽 대응이 필요하다.

- 근거 코드: `mcp/byoridb_mcp.py`, `manager/macos/Sources/ByoriManagerCore/ByoriGraphClient.swift`,
  `install.sh`, `templates/run-server.sh`
- 검증 조합: **byori v0.1.x ↔ engine `v0.3.3`** (`install.sh`의 `ENGINE_TAG_DEFAULT`)
- 검증 방법: CI 스모크(`.github/workflows/ci.yml` → `tests/smoke_mcp.py`) — 고정
  태그 엔진을 내려받아 설치 후 remember→graph projection→typed wiki bootstrap
  →recall→temporal query roundtrip

## 엔진 버전 올리기 체크리스트

1. `install.sh`의 `ENGINE_TAG_DEFAULT` 갱신
2. CI 스모크 통과 확인 (아래 표면 전체를 커버)
3. 이 문서의 표면과 엔진 CHANGELOG diff 대조, 변경 시 문서 갱신
4. byori 패치 릴리스 태그

## 1. HTTP API

| 표면 | 계약 |
|---|---|
| `GET /health` | 서버 준비되면 200. 설치기가 최대 30초 폴링 |
| `POST /api/v1/session` | body `{"username","password"}` → `{"session_id": <decimal string or signed INT64>}` |
| `POST /api/v1/query` | body `{"session_id","query"}` → 아래 결과 JSON. 오류는 4xx + `{"error","code"}` |

- 최신 엔진 표면의 **`session_id`는 decimal string**이다. 다만 기존 v0.3.3 배포
  artifact는 signed INT64 JSON number를 반환하고 query에도 같은 표현을 요구할 수 있다.
  클라이언트는 둘 다 정밀도 손실 없이 받아 응답과 같은 표현으로 다시 보내야 한다.
  특히 JSON number를 IEEE-754 `Double`로 변환하지 말 것.
- 세션은 space에 pin된다: 새 세션은 `USE <space>` 전까지 space 없음
  (`No space selected` 오류).

engine v0.3.3의 query 성공 응답은 다음 형태다.

```json
{
  "results": [
    {
      "vid": 1197758748330275039,
      "name": "test2",
      "kind": "context",
      "ts": 1720000000000
    }
  ],
  "latency_ms": 1,
  "row_count": 1,
  "column_names": ["vid", "name", "kind", "ts"]
}
```

`results`는 alias를 key로 쓰는 row object 배열이고 `column_names`는 projection 순서다.
`row_count`는 `results` 길이이며 `latency_ms`는 0 이상의 정수다. `id()` projection은
**JSON number 형태의 signed INT64**다. VID는 2^53을 넘을 수 있으므로 클라이언트는
IEEE-754 `Double`을 거치지 말고 `Int64`로 decode해야 한다.

### 세션 상실 시맨틱 (재로그인 규칙)

클라이언트는 다음을 "세션 상실"로 판정하고 **재로그인 → `USE <space>` 재-pin →
1회 재시도**한다:

- HTTP `401` / `403`
- HTTP `400` **이면서** 오류 본문(lowercase)에 `session` 또는 `auth` 포함
  (서버 재기동 후 stale session이 `400 "Invalid session"`으로 나타나는 사례)

그 외 400(문법 오류 등)은 재시도하지 않는다. 엔진이 이 오류 문자열 마커를 바꾸면
클라이언트 재로그인이 깨진다 — **`session`/`auth` 단어를 오류 본문에 유지할 것**.

### 로그인 lockout

엔진은 연속 로그인 실패 시 계정을 잠근다. 따라서 클라이언트는 401/403에서
**재시도 없이 즉시 실패**해야 한다 (`byoridb_mcp.py._ensure_ready` 참조).

## 2. nGQL 부분집합

MCP와 Manager 그래프 뷰가 발행하는 문장 전부. 이 문법이 파싱·실행되면 Byori는
동작한다.

```ngql
CREATE SPACE IF NOT EXISTS <space>(vid_type=INT64)
USE <space>
CREATE TAG IF NOT EXISTS note(kind STRING, name STRING, body STRING, ts INT64)
CREATE EDGE IF NOT EXISTS rel(kind STRING)
CREATE TAG IF NOT EXISTS decision(name STRING, body STRING, state STRING, ts INT64)
                                               -- typed wiki tag 7종 동일 패턴 (schema v2)
CREATE EDGE IF NOT EXISTS affects(ts INT64)    -- typed wiki edge 8종 동일 패턴 (schema v2)
INSERT VERTEX note(kind, name, body, ts) VALUES <vid>:('<s>', '<s>', '<s>', <i64>)
INSERT VERTEX decision(name, body, state, ts) VALUES <vid>:('<s>', '<s>', '<s>', <i64>)
INSERT EDGE rel(kind) VALUES <vid>-><vid>:('<s>')
INSERT EDGE affects(ts) VALUES <vid>-><vid>:(<i64>)
MATCH (d:decision)-[:affects]->(m:module)
  RETURN d.decision.name AS decision, m.module.name AS module,
         d.decision.state AS state ORDER BY decision ASC LIMIT <n>
MATCH (n:note) WHERE (n.note.name CONTAINS '<s>' OR n.note.body CONTAINS '<s>')
  AND n.note.kind == '<s>'
  RETURN n.note.name AS name, ... ORDER BY ts DESC LIMIT <n>
FETCH PROP ON note <vid> AS OF <epoch-ms>      -- temporal 읽기 (vertex만)

MATCH (n:note)
  RETURN id(n) AS vid, n.note.name AS name, n.note.kind AS kind, n.note.ts AS ts
  ORDER BY vid ASC LIMIT 201 OFFSET 0
MATCH (a:note)-[e:rel]->(b:note)
  RETURN id(a) AS src, id(b) AS dst, e.rel.kind AS kind
  ORDER BY src ASC, dst ASC LIMIT 501 OFFSET 0
MATCH (n:note) WHERE id(n) == <vid> RETURN n.note.body AS body LIMIT 1
```

마지막 세 문장은 Manager의 read-only graph projection 계약이다. `id(n)`/`id(a)`/`id(b)`는
vertex INT64 VID를 반환하고, `ORDER BY`는 projection alias(`vid`, `src`, `dst`)를 사용할 수
있어야 한다. `LIMIT`과 `OFFSET`은 0 이상의 정수이며 정렬 후 offset만큼 건너뛴 뒤 limit을
적용한다. Manager는 200개 node와 500개 edge까지만 표시하고 각각 한 행을 더 요청해
truncation을 감지한다. 초기 node projection에는 `body`를 넣지 않고 선택된 node만 마지막
쿼리로 lazy-load한다.

typed wiki 문장들은 MCP의 schema v2 bootstrap(`byoridb_mcp.py._migrate`)과 스모크의
typed roundtrip이 발행한다. schema version은 예약 이름 `byori:schema-version`의
`note` vertex로 기록된다(위 note INSERT와 동일 표면).

`memory_query`는 raw nGQL escape hatch이므로 사용자는 `GO`/`LOOKUP` 등 그 이상을
쓸 수 있지만, **계약(스모크 게이트)은 위 부분집합만** 보장한다.

### 문자열 리터럴 escape

MCP는 single-quote 리터럴에 `\\`, `\'`, `\n` 세 가지 escape만 생성한다.
엔진 파서는 이를 해석할 수 있어야 한다.

### VID

- space는 `vid_type=INT64`.
- **Byori는 비음수 VID(`0 ..= 2^63-1`)만 생성한다**: `sha1(name)[:8]`을 unsigned로
  읽고 63bit 마스크(`& 0x7FFF_FFFF_FFFF_FFFF`). 배경: 엔진 v0.3.3의 INSERT
  planner가 음수 vid를 거부하는 버그가 있고, 엔진이 수정되더라도 byori는 계속
  비음수만 발행한다(기존 저장 데이터의 vid 안정성 유지 — 양수였던 해시는 마스크
  전후 값이 동일).

## 3. Temporal 시맨틱 (엔진 v0.3.3 기준)

- `INSERT VERTEX`는 current view를 덮어쓰고 history 버전을 추가한다 — 같은
  `name` 재-remember가 bitemporal 이력이 되는 근거.
- 공개 temporal 읽기는 vertex `FETCH ... AS OF <epoch-ms>`뿐. edge AS OF,
  temporal MATCH/GO, BETWEEN은 미지원.
- current/history dual-write는 **비원자적**이며, 동일 엔티티를 같은 millisecond에
  두 번 쓰면 history key 충돌 위험이 있다. MCP 단일 프로세스 사용에서는 실질
  위험이 낮지만, 병렬 writer를 만들 때는 엔진 측 개선이 선행돼야 한다.

## 4. 환경변수 계약

| 변수 | 소비자 | 의미 |
|---|---|---|
| `BYORIDB_ROOT_PASSWORD` | 서버, MCP | root 비밀번호 (단일 `_` 패턴). `~/.byoridb/env`(chmod 600)에 저장 |
| `BYORIDB__STORAGE__DATA_PATHS` | 서버 | 데이터 경로 (이중 `__` config 패턴) |
| `BYORIDB__SERVER__HTTP_ADDR` / `BYORIDB__SERVER__GRAPH_ADDR` | 서버 | 바인드 주소 |
| `BYORIDB_HTTP` / `BYORIDB_USER` / `BYORIDB_PASSWORD` | MCP | 엔진 접속 (ROOT_PASSWORD가 PASSWORD보다 우선) |
| `BYORIDB_MEMORY_SPACE` | MCP | memory space 이름 (기본 `claude_memory`) |

주의: 단일 `_`(시크릿)와 이중 `__`(config tree) 패턴이 혼재한다 — 엔진 쪽 관례.

## 5. 릴리스 artifact 계약

- 엔진 릴리스 asset 이름: `byoridb-<tag>-<target>.tar.gz`, 내용물에
  `byoridb-server` 필수(+선택 `byoridb-cli`).
- target: `aarch64-apple-darwin`, `x86_64-apple-darwin`, `x86_64-unknown-linux-gnu`.
- 이 규칙이 바뀌면 `install.sh`의 다운로드 URL 조립이 깨진다.

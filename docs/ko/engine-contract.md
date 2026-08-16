[English](../engine-contract.md) | **한국어**

# ByoriDB 엔진 호환성 계약

Byori가 의존하는 ByoriDB 엔진 표면의 **전부**를 명시한다. 여기 없는 엔진 기능은
Byori 호환성과 무관하게 바뀌어도 된다. 반대로 이 문서의 표면이 바뀌면 엔진 태그를
올리기 전에 Byori 쪽 대응이 필요하다.

- 근거 코드: `mcp/byoridb_mcp.py`, `tests/test_mcp_contract.py`,
  `tests/smoke_mcp.py`, `manager/macos/Sources/ByoriManagerCore/ByoriGraphClient.swift`,
  `install.sh`, `templates/run-server.sh`
- 검증 조합: **byori v0.2.x ↔ engine `v0.3.3`** (`install.sh`의 `ENGINE_TAG_DEFAULT`)
- 검증은 두 층으로 구성한다:
  - `python3 -m unittest tests/test_mcp_contract.py`는 엔진 없이 profile, 닫히고 크기가
    제한된 tool schema, read-query gate, canonical identity, relation 규칙, lifecycle 값,
    VID 호환성, decimal-string VID 정규화를 검사한다.
  - CI 스모크(`.github/workflows/ci.yml` → `tests/smoke_mcp.py`)는 고정 태그 엔진을
    내려받아 설치한 뒤 legacy note, graph projection, typed wiki bootstrap과 structured
    upsert/read/link/export/delete, v0.2.0 VID 재사용, 명시적 edge 삭제, 보호된/cascade
    vertex 삭제, temporal read, profile filtering을 검사한다.

제품 모델 경계: Byori macOS 앱은 **Project → Source Tree/Worktree → Task → Session**
구조를 제공하며 사용자는 Session마다 코딩 agent 하나와 model을 고른다. 이 운영 트리는
앱 상태이며 엔진 schema 계약이 아니다. Settings는 설치, 연동, 진단을 보조한다. 이 엔진
계약은 Context inspector가 사용하는 프로젝트 범위 ByoriDB 지식 그래프를 다룬다. 한
Project의 모든 Source Tree/Worktree, Task, Session, agent 선택은 그 graph space를 공유한다.

## 엔진 버전 올리기 체크리스트

1. `install.sh`의 `ENGINE_TAG_DEFAULT` 갱신
2. MCP contract test와 CI 스모크 모두 통과 확인 (둘이 함께 아래 표면 전체를 커버)
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

엔진은 연속 로그인 실패 시 계정을 잠근다. **query** endpoint의 401/403은 위의
단 한 번 session recovery를 시작하지만, 새 **login** 요청이 401/403을 반환하면
로그인을 다시 재시도하지 말고 즉시 실패해야 한다
(`byoridb_mcp.py._ensure_ready` 참조).

## 2. nGQL 부분집합

MCP와 Byori macOS 앱의 Context inspector가 발행하는 문장 전부. 이 문법이
파싱·실행되면 Byori는 동작한다.

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
MATCH (n:<tag>) WHERE n.<tag>.name == '<canonical-name>'
  RETURN id(n) AS vid, n.<tag>.name AS name, ... ORDER BY ts DESC LIMIT 2
                                                -- structured write 전 canonical 조회
DELETE EDGE <edge> <source-vid>-><target-vid>
DELETE VERTEX <vid>                             -- incident edge를 명시적으로 지운 뒤만
FETCH PROP ON note <vid> AS OF <epoch-ms>      -- temporal 읽기 (vertex만)

MATCH (n:note)
  RETURN id(n) AS vid, n.note.name AS name, n.note.kind AS kind, n.note.ts AS ts
  ORDER BY vid ASC LIMIT 201 OFFSET 0
MATCH (n:<tag>)                                -- tag ∈ {module, decision, bug, incident, concept, entity, task}
  RETURN id(n) AS vid, n.<tag>.name AS name, n.<tag>.ts AS ts
  ORDER BY vid ASC LIMIT 201 OFFSET 0
MATCH (a:note)-[e:rel]->(b:note)
  WHERE (id(a) == <vid> OR id(a) == <vid> OR ...) AND (id(b) == <vid> OR id(b) == <vid> OR ...)
  RETURN id(a) AS src, id(b) AS dst, e.rel.kind AS kind
  ORDER BY src ASC, dst ASC LIMIT 501 OFFSET 0
MATCH (a)-[e:<edge>]->(b)                      -- edge ∈ typed wiki edge 8종(decided_in 제외*)
  WHERE (id(a) == <vid> OR id(a) == <vid> OR ...) AND (id(b) == <vid> OR id(b) == <vid> OR ...)
  RETURN id(a) AS src, id(b) AS dst
  ORDER BY src ASC, dst ASC LIMIT 501 OFFSET 0
MATCH (a)-[e:<edge>]->(b)
  WHERE (id(a) == <vid> OR ...) OR (id(b) == <vid> OR ...)
  RETURN id(a) AS src, id(b) AS dst             -- MCP incident-link guard/cascade 조회
MATCH (n:note) WHERE id(n) == <vid> RETURN n.note.body AS body LIMIT 1
MATCH (n:<tag>) WHERE id(n) == <vid> RETURN n.<tag>.<body|summary> AS body LIMIT 1
                                                -- property는 module만 summary, 나머지는 body
```

위 문장들은 structured MCP write/read 표면과 Byori macOS 앱의 read-only Context
projection 표면을 모두 포함한다. Structured upsert는 현재 hash 방식으로 VID를 가정하지
않고 typed node의 canonical `name` property로 기존 node를 먼저 찾는다.
`memory_link(action="delete")`는
`DELETE EDGE`를 발행하고, `memory_delete`는 link guard가 통과한 뒤에만 `DELETE VERTEX`를
발행한다. engine v0.3.3의 `DELETE VERTEX`는 incident edge를 자동 제거하지 **않는다**.
`cascade=true`면 MCP가 incoming/outgoing edge를 모두 열거하고 각각에 `DELETE EDGE`를
발행한 뒤 vertex를 삭제한다.

앱의 Context projection에서 `id(n)`/`id(a)`/`id(b)`는 vertex INT64 VID를 반환하고, `ORDER BY`는
projection alias(`vid`, `src`, `dst`)를 사용할 수 있어야 한다. `LIMIT`과 `OFFSET`은 0 이상의
정수이며 정렬 후 offset만큼 건너뛴 뒤 limit을 적용한다. 앱은 note 태그와 7종 typed
wiki 태그, `rel`과 typed wiki edge 8종을 각각 별도 쿼리로 병렬 조회해 클라이언트에서
병합한다 — **엔진의 `UNION`은 여러 MATCH branch를
합치지 않고 첫 branch 결과만 반환하는 것을 실측으로 확인했으므로 이에 의존하지 않는다.**
typed wiki edge 쿼리는 양끝 vertex 태그를 지정하지 않는 `(a)`/`(b)` 패턴을 쓴다(같은 edge
종류라도 양끝 태그 조합이 여러 가지일 수 있으므로) — 엔진은 태그 미지정 vertex 패턴
매치를 지원해야 한다. edge 쿼리는 항상 이번 node projection에서 확정된 표시 대상 vid
목록을 `id(a) == <vid> OR ...`로 OR 체이닝해 서버 측에서 먼저 걸러야 한다 — **엔진이
`WHERE <expr> IN [...]`를 지원하지 않는 것을 실측으로 확인했다(리스트 원소가 하나여도
무조건 0행)**, 반드시 `==`의 OR 체이닝을 쓴다. 이 필터가 없으면 종류별 LIMIT 501
컷오프가 어차피 표시되지 않을 endpoint의 edge에 낭비되어, 실제 표시 가능한 edge가
501번째 이후로 밀려나도 잘려나간 사실을 감지하지 못한다(edgesTruncated 오탐 없이 edge
누락). 노드는 200개, 엣지는 500개까지만 표시하고 각각 한 행을 더 요청해 truncation을
감지한다. 초기 node projection에는 `body`/`summary`를 넣지 않고 선택된 node만 마지막
쿼리로 lazy-load한다.

\* `decided_in`(decision → task)은 memory ontology의 목표 스키마에는 있으나
`byoridb_mcp.py`의 schema v2 migration에는 아직 `CREATE EDGE`가 없다. 엔진 v0.3.3은
현재 미정의 edge tag
조회에 빈 결과를 반환하지만, 이를 호환성 계약으로 삼으면 데이터를 조용히 숨기게 되므로
앱이 의존해서는 안 된다. 실제로 필요해지면(memory ontology의 "3번 이상 억지로
뭉개진 뒤" 승격 기준) 별도 schema migration을 추가한 뒤 앱 edge kind에 포함한다.

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
- **새 Byori node는 비음수 VID(`0 ..= 2^63-1`)만 사용한다**: 현재 방식은 `name`의
  SHA-1 첫 8바이트를 unsigned로 읽고 `& 0x7FFF_FFFF_FFFF_FFFF`를 적용한다. 엔진
  v0.3.3의 INSERT planner가 음수 VID를 거부하기 때문이다. 엔진이 수정되더라도 이미
  만든 VID의 안정성을 위해 이 방식을 유지한다.
- v0.2.0 typed-wiki 안내는 다른 60bit 방식인
  `int(sha1(name).hexdigest()[:15], 16)`을 사용했다. Structured upsert 전 Byori는 정확한
  typed canonical `name`으로 검색해 실제 저장 VID를 재사용한다. 따라서 v0.2.0 node를
  현재 63bit VID에 복제하지 않고 제자리에서 갱신한다. 일치 항목이 둘 이상이면 모호한
  중복으로 거부한다. 실제로 새로운 canonical node만 현재 63bit VID를 받는다.

## 3. MCP Tool 및 Profile 계약

MCP는 기본 `legacy` profile에서 9개 tool을 제공한다. `safe` profile은 8개를 제공하며
`memory_query` 하나만 숨기고 dispatch도 거부한다. Structured mutation tool 전부와 legacy
note writer인 `memory_remember`는 그대로 노출하므로 **safe는 read-only mode가 아니다**.
`readonly` profile은 `memory_recall`, `memory_query_read`, `memory_read`, `memory_export`만
노출하고 dispatch한다. 모든 mutation tool과 제한 없는 `memory_query` 호출은 unknown
tool로 거부한다.

| Tool | `legacy` | `safe` | `readonly` | 계약 |
|---|:---:|:---:|:---:|---|
| `memory_remember` | yes | yes | no | legacy `note` upsert, 선택적으로 `relates_to` edge 생성 |
| `memory_recall` | yes | yes | yes | substring/kind로 legacy note를 최신순 조회 |
| `memory_query` | yes | no | no | 제한 없는 raw nGQL 호환 escape hatch |
| `memory_query_read` | yes | yes | yes | 아래 read-query gate가 허용하는 문장 하나 실행 |
| `memory_wiki_upsert` | yes | yes | no | canonical typed-wiki node 하나를 검증하고 upsert |
| `memory_link` | yes | yes | no | 존재하는 endpoint 사이의 검증된 관계를 upsert 또는 삭제 |
| `memory_read` | yes | yes | yes | legacy/typed node를 정규화해 반환하고 선택적으로 incident link 포함 |
| `memory_delete` | yes | yes | no | 정확한 node 하나 삭제. 연결된 node는 `cascade=true` 필요 |
| `memory_export` | yes | yes | yes | 정규화된 node와 선택적 outgoing link의 제한된 page 반환 |

Profile은 MCP tool 표면을 제한할 뿐 authorization 경계나 sandbox가 아니다. `readonly`
process는 startup에서 login, `USE <space>`, schema version read만 수행하며, writer가 현재
schema version으로 space를 미리 bootstrap하지 않았으면 실패한다. Process는 설정된 engine
credential을 그대로 사용하므로 신뢰 경계가 다르면 engine instance와 credential을 분리한다.

9개 input schema는 모두 선언하지 않은 field를 거부한다. 공통 hard limit은 다음과 같다.

| 입력 | 계약 |
|---|---|
| `name` | 1–256자. typed name은 `^[a-z][a-z0-9_]*:[A-Za-z0-9][A-Za-z0-9._-]*$`도 만족하고 prefix가 `type`과 같아야 함 |
| `kind`, `state` | 1–64자. `memory_remember`의 `kind` 기본값은 `note` |
| `body` | 1–65,536자 |
| read `text` | 1–4,096자 |
| `ngql` | 1–16,384자 |
| `relates_to` | 최대 64개 name. 각 항목에도 name limit 적용 |
| recall/read `limit` | 1–100, 기본 20 |
| export `limit` | 1–500, 기본 100 |
| export `offset` | 0–100,000, 기본 0 |

정규화 node type은 `note`, `module`, `decision`, `bug`, `incident`, `concept`, `entity`,
`task`다. `memory_wiki_upsert`는 `note`를 제외한 wiki type 7종만 허용하고,
`memory_read`, `memory_delete`, link endpoint는 `note`도 허용한다. Boolean 입력은
실제 JSON boolean이어야 한다. `memory_read.include_links`와 `memory_delete.cascade`의
기본값은 `false`, `memory_export.include_links`의 기본값은 `true`다. 예약 note인
`byori:schema-version`은 삭제할 수 없다.

Typed node lifecycle 값은 닫힌 enum이다. decision `state`는 `active` 또는 `superseded`, bug
`state`는 `open`/`fixed`/`known`, task `state`는 `open`/`in_progress`/`blocked`/`done`이다.
incident `resolved`는 boolean이며(schema v2에는 문자열 `true`/`false`로 저장하고 다시
boolean으로 정규화), 새 decision/bug/task의 기본값은 각각 `active`/`open`/`open`, 새
incident는 unresolved다. 갱신할 때 lifecycle field를 생략하면 기존의 유효한 값을 보존한다.
Module 입력 `body`는 엔진의 `summary` property에 대응한다.

`memory_link`의 기본 action은 `"upsert"`이며 endpoint가 미리 존재해야 한다. 검증 관계는
`part_of`(module→module), `depends_on`(module→module), `affects`((decision|bug)→module),
`caused_by`((incident|bug)→(bug|decision|module)), `fixed_by`
((bug|incident)→(decision|task)), `supersedes`(decision→decision), `about`
((task|incident)→(module|entity|concept))이다. `relates_to`는 모든 node type을 허용하며
`note` endpoint는 `relates_to`에만 참여할 수 있다.

이 endpoint 존재성과 relation matrix 보장은 `memory_link`에 적용된다. 호환용
`memory_remember(relates_to=[...])` 경로는 legacy 동작을 유지하므로 각 target note가
이미 존재하는지 검증하지 않는다.

### Read-Query Gate

`memory_query_read`는 `MATCH`, `FETCH`, `GO`, `LOOKUP`, `SHOW`, `WHY` 중 하나로 시작하는
문장 하나만 허용한다. 인용된 string literal 밖에서는 주석(`--`, `//`, `/* ... */`, `#`),
pipeline(`|`), semicolon, 그리고 `ALTER`, `CREATE`, `DELETE`, `DROP`, `GRANT`, `INSERT`,
`REVOKE`, `UPDATE`, `UPSERT`, `USE`가 나타나면 거부한다. 이 gate는 raw-query 표면을
줄이기 위한 것이며 authorization parser나 보안 경계가 아니다.

### 결과 정규화 및 Export

Structured tool 결과는 JSON 소비자의 INT64 정밀도 손실을 막기 위해 `vid`, `src`, `dst`,
`source_vid`, `target_vid`를 재귀적으로 decimal string으로 반환한다. `memory_query_read`도
엔진 row에 같은 정규화를 적용한다. 제한 없는 legacy `memory_query`는 엔진의 raw JSON
표현을 유지하고, `memory_remember`는 호환성을 위해 numeric `vid` 결과를 유지한다.

`memory_export`는 기본적으로 link를 포함하며 `schema_version`, `space`, `offset`,
`next_offset`, `has_more`를 보고한다. 이는 제한된 best-effort inspection page이지
transactional backup snapshot이 아니다. type별로 결과를 모은 뒤 global sort하므로
동시 write가 없어도 깊은 offset page에서 후보가 이동하거나 누락될 수 있고,
write가 있으면 추가로 이동한다. 예약 schema-version note는 제외하고 page node에서
나가는 outgoing link만 포함한다.

## 4. Temporal 시맨틱 (엔진 v0.3.3 기준)

- `INSERT VERTEX`는 current view를 덮어쓰고 history 버전을 추가한다 — 같은
  `name` 재-remember가 bitemporal 이력이 되는 근거.
- 공개 temporal 읽기는 vertex `FETCH ... AS OF <epoch-ms>`뿐. edge AS OF,
  temporal MATCH/GO, BETWEEN은 미지원.
- current/history dual-write는 **비원자적**이며, 동일 엔티티를 같은 millisecond에
  두 번 쓰면 history key 충돌 위험이 있다. MCP 단일 프로세스 사용에서는 실질
  위험이 낮지만, 병렬 writer를 만들 때는 엔진 측 개선이 선행돼야 한다.

## 5. 환경변수 계약

| 변수 | 소비자 | 의미 |
|---|---|---|
| `BYORIDB_ROOT_PASSWORD` | 서버, MCP | root 비밀번호 (단일 `_` 패턴). `~/.byoridb/env`(chmod 600)에 저장 |
| `BYORIDB__STORAGE__DATA_PATHS` | 서버 | 데이터 경로 (이중 `__` config 패턴) |
| `BYORIDB__SERVER__HTTP_ADDR` / `BYORIDB__SERVER__GRAPH_ADDR` | 서버 | 바인드 주소 |
| `BYORIDB_HTTP` / `BYORIDB_USER` / `BYORIDB_PASSWORD` | MCP | 엔진 접속 (ROOT_PASSWORD가 PASSWORD보다 우선) |
| `BYORIDB_MEMORY_SPACE` | MCP | 논리 memory space 이름(기본 `claude_memory`), `^[A-Za-z_][A-Za-z0-9_]{0,63}$` 필수 |
| `BYORIDB_MCP_PROFILE` | MCP | 대소문자를 구분하는 `legacy`(기본, 9 tool), `safe`(8 tool, `memory_query`만 숨김), 또는 `readonly`(read tool 4개) |

주의: 단일 `_`(시크릿)와 이중 `__`(config tree) 패턴이 혼재한다 — 엔진 쪽 관례.

`BYORIDB_MEMORY_SPACE`는 같은 엔진 안의 논리 namespace를 고를 뿐 tenant/authorization
경계가 아니다. MCP process는 일반적으로 같은 root credential을 재사용하며 process
configuration이 허용하면 다른 유효한 space를 지정할 수 있다. 신뢰 경계가 다르면 엔진
instance와 credential을 분리한다.

## 6. 릴리스 artifact 계약

- 엔진 릴리스 asset 이름: `byoridb-<tag>-<target>.tar.gz`, 내용물에
  `byoridb-server` 필수(+선택 `byoridb-cli`).
- target: `aarch64-apple-darwin`, `x86_64-apple-darwin`, `x86_64-unknown-linux-gnu`.
- 이 규칙이 바뀌면 `install.sh`의 다운로드 URL 조립이 깨진다.

## 7. 최소 엔진 버전과 빌드 식별

**최소 `v0.3.3`**이며 `ENGINE_TAG_DEFAULT`와 같다. 위의 모든 surface를 제공하는 가장 오래된
태그다. 십진 문자열 `session_id`, §1의 session-loss marker, §2의 63bit VID 범위, §4의
`FETCH ... AS OF`가 모두 필요하다. 더 오래된 엔진은 시작 시점에 실패하지 않고 해당 surface에
의존하는 첫 read에서 실패한다.

이 클라이언트가 원하는 두 가지는 **어떤 릴리스에도 들어 있지 않다.** 엔진 `main`에만 있고
최신 릴리스가 그보다 앞선다.

| 엔진 변경 | 반영 | `v0.3.3` 포함 | 여기서의 결과 |
|---|---|---|---|
| 비어 있지 않은 `BYORIDB_ROOT_PASSWORD` 게이트 | 2026-08-08 | 아니오 | 변수 없이 시작하면 엔진이 root 비밀번호를 생성해 **`logs/server.log`에 기록한다.** 그래서 `templates/run-server.sh`는 변수가 비어 있으면 시작을 거부한다. 키가 존재하기만 하는 것에 의존하지 않는다 |
| 로그인 throttling | — | 아니오 | 반복 실패 로그인을 엔진이 지연시키지 않는다 |
| `type(e)` MATCH edge accessor, batch destination projection | 2026-08-03 | 아니오 | `_read_edge_records`가 relation type마다 쿼리를 하나씩 보내야 한다. 단일 untyped `MATCH`로 합치는 것은 이 변경이 포함된 릴리스를 기다린다 |

`ENGINE_TAG_DEFAULT`를 릴리스되지 않은 commit으로 올리지 말 것. `install.sh`는 릴리스 asset을
내려받으므로 `main`에만 있는 빌드는 사용자가 설치할 수 없다.

### 빌드 식별

`byoridb-server`는 `--version`을 노출하지 않고 인자를 무시하며, `v0.3.3`에서 `--version`은
일반 서버 실행이 된다. 따라서 상태 확인이 이를 probe해서는 안 된다. `install.sh`가 설치한
내용을 `$BYORIDB_HOME/engine.json`(`tag`, `target`, `source`, `sha256`, `installed_at`)에
기록하고 macOS 앱이 ByoriDB 페이지의 엔진 행에서 읽는다. Byori가 이를 기록하기 전에 설치한
경우 파일이 없으며, 검증된 빌드가 아니라 "기록 없음"으로 보고한다. 엔진이 `--version`을
제공하면 바이너리에서 직접 확인하고 이 파일은 fallback으로 둔다.

[English](../memory-ontology.md) | **한국어**

# ByoriDB Memory-Wiki — dogfood prototype

> 상태: **설계 + dogfood PoC 검증 완료**. "작업할수록 지식 그래프가 쌓여 LLM Wiki처럼
> 읽히는" 방향의 기술적 타당성을 확인한 문서다. §4의 typed wiki schema는 v0.2.0부터
> MCP 시작 시 schema v2로 자동 bootstrap/migration된다. repository 자동 ingestion은
> 미구현이다. 작성 계기: 2026-07-11 대화 (파일 메모리 vs 그래프 메모리 → 타입드 지식그래프 비전).

---

## 1. 비전

사용자의 작업(코드 변경, 의사결정, 인시던트, 벤치마크)과 프로젝트 구조를
작업하면 할수록 **자동으로 축적되는 타입드 지식 그래프**로 남긴다.
읽을 때는 노드에서 엣지를 따라가면 "왜 이렇게 됐는지"가 위키 문서처럼 이어진다.

- 파일 메모리(`MEMORY.md`)의 한계: always-on 토큰 비용, 평면 목록, 관계·시점 없음.
- 목표: recall이 **traversal**이 되는 것. `이 모듈 → 왜 이렇게 됐나 → 어떤 결정/버그가 원인 → 무엇을 대체했나`.

## 2. 왜 ByoriDB가 이걸 위한 substrate인가

일반 벡터/파일 메모리로는 안 되고 ByoriDB에는 이미 있는 것들:

| 기능 | 위키에서 푸는 문제 |
|---|---|
| 온톨로지 forward-chaining 추론 (O-4~O-9) | 저장 안 한 사실을 추론으로 노출 ("A depends_on B, B affected_by 버그 → A 영향권") |
| sameAs canonical merge (O-8) | 엔진 수준의 엔티티 동일성 기능. MCP structured surface에서는 실험/미래 범위 |
| bitemporal (T-1~T-4) | staleness 대응. `AS OF`로 "그 결정 당시 알던 구조"를 시점 조회 |
| 삭제 retraction (O-9) | 폐기된 사실을 그래프에서 회수 |

## 3. 반드시 피해야 할 실패 모드

naive "매 턴 LLM이 엔티티·관계 마구 추출" = 반드시 쓰레기통이 된다. 방어책을 스키마에 내장:

1. **추출 일관성 붕괴** → 타입/엣지를 **소수로 고정**(open-ended 금지).
2. **엔티티 조각남** → 지금은 **canonical name 규칙**을 강제하고, structured
   `sameAs` relation이 배포될 때까지 가능성 있는 alias를 병합 후보로 유지.
3. **노이즈 vs 공백** → "다 뽑기" 대신 **경계(체크포인트)에서만** 추출.
4. **staleness** → 덮어쓰기 대신 bitemporal 버전, `supersedes` 엣지로 폐기 표시.

## 4. 온톨로지 스키마 (핵심: 좁게)

아래 §4는 배포된 schema v2와 목표에만 있고 별도 표시한 `decided_in` edge를 설명한다.
§7 PoC는 타당성 검증에 필요한 subset만 생성했다. v0.2.0부터 MCP가 schema v2를 자동
bootstrap하며, 경량 표현에서는 `part_of`~`relates_to` edge에 `ts`만 있고
`incident.resolved`는 STRING이다.

### 4.1 노드 타입 (tag)

| tag | 의미 | 핵심 property |
|---|---|---|
| `module` | 코드 모듈/크레이트/서브시스템 | name, summary, ts |
| `decision` | 결정 + 근거 | name, body(why 포함), state(active/superseded), ts |
| `bug` | 버그/함정 + 해소 여부 | name, body, state(open/fixed/known), ts |
| `incident` | 운영 사고 | name, body, resolved(`"true"`/`"false"` STRING), ts |
| `concept` | 도메인/설계 개념 | name, body, ts |
| `entity` | 데이터 엔티티(도그푸딩 대상) | name, body, ts |
| `task` | 작업/트랙 항목 | name, body, state(open/in_progress/blocked/done), ts |

> 최소셋으로 시작. 새 타입은 "3번 이상 억지로 뭉개진 뒤"에만 승격. 임의 추가 금지.

### 4.2 목표 엣지 타입 (edge)

의미 있는 것만. 각 엣지는 방향이 있다.

| edge | from → to | 뜻 |
|---|---|---|
| `part_of` | module → module | 서브모듈 포함 |
| `depends_on` | module → module | 의존 |
| `affects` | decision/bug → module | 영향 |
| `caused_by` | incident/bug → bug/decision/module | 원인 |
| `fixed_by` | bug/incident → decision/task | 해소 수단 |
| `supersedes` | decision → decision | 대체(폐기) |
| `decided_in`* | decision → task | 어떤 작업에서 결정 |
| `about` | task/incident → module/entity/concept | 주제 |
| `relates_to` | any → any | 약한 연관(도피용, 남발 금지) |

\* `decided_in`은 목표 스키마일 뿐 아직 `byoridb_mcp.py`의 schema v2 migration에 없다
(실제로 생성되는 typed edge는 8종). 3번 이상 필요해지기 전까지는 `decided_in` 대신
`relates_to`로 임시 인코딩할 것 — [engine-contract.md](engine-contract.md) 참고.

`sameAs`도 엔진 기능이자 실험적인 목표이며, 배포된 structured `memory_link`가
받아들이는 relation은 아니다. structured API로 `sameAs` edge를 임의 생성하지 말고,
계약이 설계·배포될 때까지 alias를 병합 후보로 유지한다.

> 호환 note layer는 `kind` property가 있는 단일 `rel` edge를 계속 사용한다. 배포된
> typed-wiki layer는 지원하는 8개 relation을 별도 edge tag로 승격했으므로
> `GO ... OVER affects` 같은 query를 직접 사용할 수 있다.

### 4.3 canonical name 규칙

`<type>:<stable-slug>` — 문장 금지. canonical name은
`^[a-z][a-z0-9_]*:[A-Za-z0-9][A-Za-z0-9._-]*$`와 일치해야 하고, tool에 전달한 정확한
node type으로 시작하며, 256자를 넘지 않아야 한다. 특히 slug의 첫 문자는 ASCII
영문자 또는 숫자여야 하고, 이후에는 `.`, `_`, `-`도 사용할 수 있다. 예:
`module:byoridb-executor`, `decision:use-redb`, `bug:redb-repair-crashloop`,
`incident:aks-startup-probe`, `concept:llm-wiki-memory-graph`.
동일 대상은 항상 같은 slug → 재작성이 업데이트가 되고 bitemporal 버전이 쌓임.

### 4.4 지원하는 structured MCP surface

typed wiki 작업에는 structured tool을 사용한다. client가 raw nGQL을 조립하지 않게
하고 server 경계에서 schema contract를 강제한다.

| Tool | 지원 동작 |
|---|---|
| `memory_wiki_upsert` | typed node 하나를 생성 또는 갱신하고 type, canonical name, body, lifecycle field를 검증 |
| `memory_link` | relation 하나를 생성/갱신 또는 삭제. 두 endpoint가 모두 존재해야 하며 server가 source→target matrix를 검증 (`relates_to`는 의도적 escape hatch) |
| `memory_read` | 정확한 name 또는 text로 normalized node를 조회하고 선택적으로 연결된 relation도 포함 |
| `memory_query_read` | 보호된 read-only `MATCH`, `FETCH`, `GO`, `LOOKUP`, `SHOW`, `WHY` statement 하나를 실행 |
| `memory_delete` | 정확한 node 하나를 삭제. link가 있는 node는 명시적 `cascade=true`가 필요 |
| `memory_export` | 제한된 best-effort inspection page를 반환. transactional backup이나 안정적 snapshot은 아님 |

기존 `memory_remember`, `memory_recall`, raw `memory_query` tool은 legacy 호환성을 위해 유지된다.
새 typed workflow는 client에서 VID를 계산하거나 write query를 조립하지 않아야 한다.

canonical-name 호환성은 property 기반이다. v0.2.0 typed node가 기존 60-bit VID로 이미
존재하면 server가 exact type/name으로 찾아 갱신과 linking 시 그 VID를 보존한다. 기존
canonical match가 없는 node는 현재의 non-negative 63-bit VID를 받는다. canonical node가
중복되면 모호하게 갱신하지 않고 거부한다.

API는 storage detail을 normalize한다. `module.summary`는 `body`로 반환하고, STRING으로
저장된 `incident.resolved`는 boolean으로 반환하며, VID는 decimal string으로 반환한다.
lifecycle 값은 `decision: active|superseded`, `bug: open|fixed|known`,
`task: open|in_progress|blocked|done`로 제한되고 incident는 `state` 대신 boolean `resolved`를 사용한다.
새 decision, bug, task의 default는 각각 `active`, `open`, `open`이고, 새 incident는
`resolved=false`를 default로 사용한다.

## 5. 추출 규칙 (언제 / 무엇을 / 어떻게)

**언제 (체크포인트에서만):**

- 작업/트랙 종료 시
- PR 생성 시
- 인시던트 종료 시
- 사용자가 "기억해" 명시할 때

**무엇을:**

- 결정 + 근거(why), 재발 버그/함정 + 해소, 인시던트 + 원인, 비자명한 구조 사실.
- transient 잡담·1회성 로그는 금지 (hygiene).

**어떻게 (조각남 방지):**

1. canonical name 후보를 생성한 뒤 typed create를 시도하기 전에 `memory_read`를 정확한
   `type`과 `name`으로 호출한다. exact name이 없으면 집중된 text read로 다른 canonical
   name의 기존 entity가 있는지 확인한다.
2. 같은 canonical name으로 `memory_wiki_upsert`를 호출해 기존 node를 갱신하거나 신규
   node를 생성한다. client에서 VID를 계산하지 않는다.
3. lifecycle 전이를 기록할 때 `state` 또는 `resolved`를 명시적으로 넣는다. 기존
   node에서 생략하면 현재 값이 유지되지만, 전이를 명시해야 의도를 감사할 수 있다.
4. `memory_link`로 relation을 생성하고 server가 두 endpoint의 존재와 relation matrix에
   맞는 type인지 검증하게 한다. 더 강한 배포 relation이 적용되지 않을 때만 `relates_to`를 사용한다.
5. 유사하지만 다른 이름의 entity를 발견하면 structured relation set 밖의 `sameAs`
   병합 후보로 기록한다. `sameAs`는 아직 이 surface에 배포되지 않았다.

## 6. PoC (이 문서와 함께 실행)

이 과거 PoC는 `claude_memory` space에 §4 타입 일부를 additive로 추가하고,
**설계 대화 자체**를 그래프화해 traversal이 위키처럼 읽히는지 확인했다. 기존
note/rel schema는 보존했다. 결과는 §7에 기록하며, 현재 관리되는 schema-v2
space는 MCP migration과 structured tool로만 변경해야 한다.

## 7. PoC 결과 (2026-07-11 실행)

`claude_memory` space에 §4 스키마를 additive로 추가하고 이번 대화를 그래프화.

**추가된 스키마** (기존 note/rel 보존):
- tag: `module, decision, bug, incident, concept, task`
- edge: `depends_on, affects, caused_by, fixed_by, supersedes, about, relates_to`
- 함정: `status`는 예약어 → property명을 `state`로. VID는 INT64만 → 명시적 정수 vid 사용.

**적재**: 노드 9개 + 엣지 10개 (이 대화의 지식). VID 매핑:
`1001 module:byoridb-memory-skill · 1003 module:byoridb-executor · 2001 decision:memory-schema-minimal ·
2002 decision:memory-wiki-typed-ontology · 3001 concept:llm-wiki-memory-graph · 3002 concept:ontology-inference ·
3003 concept:bitemporal-asof · 4001 bug:junk-drawer-antipattern · 5001 task:memory-wiki-poc`

**traversal이 위키처럼 읽히는가 → 그렇다.** 검증된 질의:

```
# "왜 memory 스킬이 평면 구조인가?" (module ← affects 역방향)
GO FROM 1001 OVER affects REVERSELY YIELD $$.decision.body
→ "LLM 자유 추출이 그래프를 조각내는 것을 막기 위한 의도적 절제" (state: superseded)

# "그 결정을 무엇이 대체했나?" (supersedes 역방향)
GO FROM 2001 OVER supersedes REVERSELY YIELD $$.decision.name
→ decision:memory-wiki-typed-ontology (state: active)

# 인과 서사 한 방에 (MATCH 멀티홉)
MATCH (b:bug)-[:fixed_by]->(d:decision)-[:about]->(c:concept) RETURN ...
→ junk-drawer-antipattern → memory-wiki-typed-ontology → llm-wiki-memory-graph

# 비전이 무엇에 의존하는가
GO FROM 3001 OVER depends_on YIELD $$.concept.name
→ ontology-inference, bitemporal-asof
```

**평가**: 파일 인덱스로는 불가능한 "노드 → 왜 → 원인 → 대체 → 비전 → 의존"의
방향성 traversal이 실제로 위키 문서처럼 이어짐. §8 Phase 1/2 타당성 확인.

**현재 cleanup 규칙**: 최초 PoC는 additive였지만 그 tag와 edge는 이제 관리되는
schema-v2 object다. 관리 space에서 수동 `DROP`하지 말아야 한다. schema-version marker와
실제 schema가 불일치하게 된다. 필요하면 정확한 PoC seed node를 `memory_delete`로 제거한다.

## 8. 로드맵 + 진행 상황

- **Phase 1 (경량)**: `rel.kind`/`note.kind`로 타입 인코딩 (스키마 변경 0). — 개념 확인.
- **Phase 2 (타입 승격 PoC)** ✅: 별도 tag/edge 생성 → `LOOKUP ON module`,
  `GO ... OVER caused_by` 직접 지원. §7의 dogfood space에서 검증했고, v0.2.0부터
  clean install bootstrap(schema v2)에 포함된다.
- **Phase 2b (보호된 structured MCP)** ✅: typed upsert, relation 관리, normalized read,
  보호된 read-only query, 삭제, 제한된 export를 구현했다. server가 canonical
  identity, lifecycle enum, endpoint matrix, v0.2.0 60-bit VID 호환성을 강제한다.
- **Phase 3 (체크포인트 보조)** 🟡: 선택적 Claude Code hook이 recall/capture reminder를
  주입할 수 있고, 실제 추출·기록은 skill을 따르는 agent가 수행한다. 자동
  ingestion은 미구현이다.
- **Phase 4 (추론 연결 PoC)** ✅: 저장하지 않은 관계를 forward-chaining으로 노출하는
  core 동작을 dogfood space에서 시연했다.

### Phase 3 결과 — 선택적 Claude Code 체크포인트 hook

영문 참조 snippet은 `adapters/claude/hooks.snippet.json`에 commit되어 있다. installer는
`--with-hooks`를 요청한 경우에만 user-level `~/.claude/settings.json`에 병합하므로
project repository를 수정하지 않고 교차 project reminder를 사용할 수 있다.
- **SessionStart 훅**: 세션 시작 시 "기억 그래프가 있으니 비자명 작업 전 recall / 체크포인트에서 capture" 컨텍스트 주입.
- **PreToolUse(Bash) 훅**: 커맨드에 `git commit`이 포함될 때만 "커밋=체크포인트, 그래프 기록 확인" 리마인더 주입. 그 외엔 무출력·**비차단**(리마인더만).
- 검증: JSON 유효성과 shell match/non-match 동작을 확인.
- 주의: 설치기의 hook merge는 같은 event 배열에 append(중복 건너뜀)하고 변경 전
  `settings.json.bak.<timestamp>` 백업을 남긴다.
- 한계: 훅은 MCP를 직접 호출 못 함(리마인더 주입만). 실제 기록은 여전히 에이전트가 수행.

### Phase 4 결과 — 온톨로지 추론 (claude_memory에서 실측)

ByoriDB nGQL 추론 표면: `CREATE EDGE <e>() TRANSITIVE|SYMMETRIC|INVERSE OF|SUBPROPERTY OF|CHAIN|DOMAIN/RANGE`,
forward-chaining은 `INSERT EDGE` 시 **자동**, `WHY <s> -> <d> OVER <e>`로 근거 설명. per-space 동작(설정 불필요), 단 시맨틱은 INSERT 전에 선언.

시연 (메모리 시스템 진화 minimal→typed→automated):
```
CREATE EDGE evolves_to() TRANSITIVE
INSERT EDGE evolves_to() VALUES 2001->2002:(), 2002->915327909379232758:()   -- 체인 2개만 저장

GO FROM 2001 OVER evolves_to   → typed(asserted) + automated(inferred, 직접 단언하지 않음) 둘 다
WHY 2001 -> 915327909379232758 OVER evolves_to
  → status=inferred, rule=transitive, premises=[2001->2002, 2002->automated]
```
즉 "minimal이 무엇으로 진화했나"에 직접 단언하지 않은 automated edge까지 엔진이
materialize해 저장하고, 그 추론 근거가 설명됨. `depends_on` 전이성으로 확장할
수 있고, 엔진의 실험적 `sameAs` 기능(O-8)은 미래 structured merge contract에 활용할 수 있다.

**최대 리스크는 코드가 아니라 추출 규율.** 여기서 무너지면 §3의 쓰레기통이 된다.
Phase 1~4가 기술적으로 성립함은 확인됐고, 남은 것은 규율을 지속시키는 운영(훅+스킬로 착수).

[English](../../adapters/README.md) | **한국어**

# Agent Skills — 코딩 에이전트 workflow에서 ByoriDB 사용하기

이 디렉터리는 에이전트 workflow를 ByoriDB에 연결하는 **자산의 참조 사본**이다.
기억 skill은 [memory ontology](memory-ontology.md)를 구현하고, 디자인 skill은 그 연속성을
제품·UX/UI 작업에 적용한다.
설치기는 Claude/Codex 공용 skill들을 `~/.claude/`에 자동 설치하고, `codex` CLI가 있으면
`~/.agents/skills/`에도 설치한다. NaraeClaw 자산은 수동 참조 어댑터이며 설치기와
Byori macOS 앱은 이를 자동 설정하거나 설치하지 않는다.

> v0.2.0부터 fresh install은 `note`/`rel`과 typed wiki(`module`/`decision`/`bug` 등)를
> schema v2로 함께 자동 bootstrap하고, 기존 설치도 MCP 시작 시 자동 migration된다.
> `SKILL.md`의 typed 예시를 바로 실행할 수 있다.

## 구성

| 파일 | 라이브 위치 | 역할 |
|---|---|---|
| `claude/skills/byoridb-memory/SKILL.md` | `~/.claude/skills/byoridb-memory/SKILL.md` 및 `~/.agents/skills/byoridb-memory/SKILL.md` | Claude/Codex 공용 기억 skill. note + typed wiki, structured tool, 인과 포착·체크포인트 규율 |
| `claude/skills/byori-design/` | `~/.claude/skills/byori-design/` 및 `~/.agents/skills/byori-design/` | 저장소 디자인 산출물과 지속 가능한 Byori context를 연결하는 Claude/Codex 공용 제품 디자인 workflow |
| `claude/hooks.snippet.json` | `~/.claude/settings.json`의 `hooks` 키 | 체크포인트 자동화 훅 2개 (SessionStart recall / git commit capture 리마인더) |
| `naraeclaw/skills/byoridb-memory/SKILL.md` | host가 선택한 수동 위치 | reduced raw-query surface를 쓰는 MCP 호환 NaraeClaw host용 참조 정책. 자동 설치 안 함 |

전제: 로컬 상시 ByoriDB + `byoridb` MCP 서버(호환 note tool + 검증된 typed-wiki
CRUD/read-only query tool).

## 설치

### Claude Code

hook을 포함한 지원 설치 경로는 설치기를 사용한다:

```bash
./install.sh --assets . --with-hooks
```

hook 연결 없이 개발용 skill 사본만 설치하려면:

```bash
mkdir -p ~/.claude/skills/byoridb-memory
cp adapters/claude/skills/byoridb-memory/SKILL.md ~/.claude/skills/byoridb-memory/
mkdir -p ~/.claude/skills/byori-design
cp -R adapters/claude/skills/byori-design/. ~/.claude/skills/byori-design/
```

설치기의 `--with-hooks`는 기존 항목을 중복하지 않고 append하며 변경 전
`settings.json.bak.<timestamp>` 백업을 남긴다. hook JSON을 수동 merge하지 말고
[`install.sh`](install.md)를 사용한다.

### Codex

설치기가 `codex` CLI를 감지하면 자동 등록한다. 수동으로 하려면:

```bash
codex mcp add byoridb -- "$HOME/.byoridb/bin/run-mcp.sh"
mkdir -p "$HOME/.agents/skills/byoridb-memory"
cp adapters/claude/skills/byoridb-memory/SKILL.md \
  "$HOME/.agents/skills/byoridb-memory/SKILL.md"
mkdir -p "$HOME/.agents/skills/byori-design"
cp -R adapters/claude/skills/byori-design/. \
  "$HOME/.agents/skills/byori-design/"
```

현재 hook snippet은 Claude Code 전용이다.

### NaraeClaw 및 기타 수동 MCP host

이 저장소는 NaraeClaw 전용 MCP 설정 문법이나 live skill 경로를 정의·가정하지 않는다.
host의 일반 MCP process 설정에서 설치된 runner를 reduced raw-query profile로 실행한다.
아래 space는 override다. 설정하지 않으면 서버가 프로젝트의 space를 직접 해석하므로
(docs/ko/install.md "Memory space"), 프로젝트 디렉터리에서 서버를 띄우는 host는 그 편이 맞다.

```sh
env BYORIDB_MCP_PROFILE=safe \
  BYORIDB_MEMORY_SPACE=my_project \
  "$HOME/.byoridb/bin/run-mcp.sh"
```

`naraeclaw/skills/byoridb-memory/SKILL.md`는 host가 문서화한 skill 설치 방식으로 배치한다.
변수는 `~/.byoridb/env`를 편집하지 말고 MCP process 설정에 전달한다. Byori 설치기는
upgrade 때 해당 파일을 다시 쓰며 root password만 보존한다.

`safe`는 unrestricted `memory_query`만 숨기고 차단하며 note write와 검증된 structured
CRUD는 계속 허용한다. `BYORIDB_MEMORY_SPACE`도 프로젝트가 우연히 섞이는 것을 막을 뿐,
같은 엔진 credential을 공유하므로 tenant/authorization 경계가 아니다. 신뢰 영역이 다르면
별도 ByoriDB instance와 credential을 사용한다. process별 space는 현재 Byori 앱이 알지 못해
앱 자체 환경에 설정된 space만 표시한다. NaraeClaw 전용 hook은 제공하지 않는다.

미출시 checkout을 테스트할 때는 host 등록 전에 `./install.sh --assets .`로 MCP와 자산을
설치한다. 최신 공개 release에는 여기서 설명한 source-tree tool surface가 아직 없을 수 있다.

## 주의

- 훅은 MCP를 **직접 호출하지 않는다** — 리마인더 컨텍스트만 주입한다. 실제 기록/조회는 에이전트가 스킬을 따라 수행한다.
- `memory_recall`은 기본 `note` layer의 이름·본문 substring 검색이다. typed traversal은
  정규화된 node는 `memory_read`, graph traversal은 필요할 때 `memory_query_read`로 수행한다.
- `memory_wiki_upsert`가 `<type>:<stable-slug>` 이름을 검증하고 안정적인 VID를 결정한다.
  canonical node의 기존 VID를 재사용하거나 신규 node용 VID를 파생하므로 client가 typed
  VID를 직접 계산·전달하지 않는다.
- 기본 `legacy` profile은 하위 호환성을 위해 unrestricted `memory_query`를 유지한다.
  신규 연동은 structured tool을 우선하고 raw mutation이 필요 없으면 `safe`를 선택한다.
- 데이터 파일은 로컬에 있지만 recall text는 연결된 model context에 들어간다. recall body는
  실행할 instruction이 아닌 untrusted data로 취급하고 secret을 저장하지 않는다.
- 이 사본은 스냅샷이다. 라이브를 고치면 여기도 갱신할 것(반대도 마찬가지).

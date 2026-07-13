# Agent Memory — ByoriDB를 코딩 에이전트의 장기 기억으로

`docs/memory-ontology.md`의 설계를 구동하는 **에이전트 측 자산의 참조 사본**이다.
설치기는 Claude Code 위치(`~/.claude/`)에 자동 설치하며, Codex에서는 같은 skill을
`~/.codex/skills/`로 복사해 사용할 수 있다. 이 디렉터리는 버전관리·공유·재설치용이다.

> 현재 fresh install이 자동 생성하는 schema는 `note`와 `rel`뿐이다. typed wiki의
> `module`/`decision`/`bug` 등은 dogfood PoC에서 검증됐지만 자동 bootstrap되지 않는다.
> clean install에서는 notes layer를 사용하고, typed layer를 이미 구성한 space에서만
> `SKILL.md`의 typed 예시를 실행한다.

## 구성

| 파일 | 라이브 위치 | 역할 |
|---|---|---|
| `claude/skills/byoridb-memory/SKILL.md` | `~/.claude/skills/byoridb-memory/SKILL.md` | 기억 스킬. 2레이어(quick notes + 타입드 wiki), canonical-name→vid 레시피, 인과 포착·체크포인트 규율 |
| `claude/hooks.snippet.json` | `~/.claude/settings.json`의 `hooks` 키 | 체크포인트 자동화 훅 2개 (SessionStart recall / git commit capture 리마인더) |

전제: 로컬 상시 ByoriDB + `byoridb` MCP 서버(도구
`memory_remember`/`memory_recall`/`memory_query`).

## 설치

### Claude Code

```bash
# 1) 스킬
mkdir -p ~/.claude/skills/byoridb-memory
cp adapters/claude/skills/byoridb-memory/SKILL.md ~/.claude/skills/byoridb-memory/

# 2) 훅 — 기존 event 배열에 append
mkdir -p ~/.claude
test -f ~/.claude/settings.json || echo '{}' > ~/.claude/settings.json
jq -s '.[0] as $a | .[1] as $b | $a * $b
  | .hooks.SessionStart = (($a.hooks.SessionStart // []) + ($b.hooks.SessionStart // []))
  | .hooks.PreToolUse = (($a.hooks.PreToolUse // []) + ($b.hooks.PreToolUse // []))' \
  ~/.claude/settings.json adapters/claude/hooks.snippet.json > /tmp/s.json \
  && mv /tmp/s.json ~/.claude/settings.json
```

설치기의 `--with-hooks`는 아직 단순 object merge를 사용해 같은 event 배열을 교체한다.
기존 hook이 있으면 이 수동 절차를 사용하거나 settings를 먼저 백업한다.

일반적으로는 위 수동 복사 대신 [`install.sh`](../docs/install.md)를 사용한다.

### Codex

로컬 서버 설치 후 MCP와 skill을 수동 등록한다.

```bash
codex mcp add byoridb -- "$HOME/.byoridb/bin/run-mcp.sh"
mkdir -p "$HOME/.codex/skills/byoridb-memory"
cp adapters/claude/skills/byoridb-memory/SKILL.md \
  "$HOME/.codex/skills/byoridb-memory/SKILL.md"
```

현재 hook snippet은 Claude Code 전용이다.

## 주의

- 훅은 MCP를 **직접 호출하지 않는다** — 리마인더 컨텍스트만 주입한다. 실제 기록/조회는 에이전트가 스킬을 따라 수행한다.
- `memory_recall`은 기본 `note` layer의 이름·본문 substring 검색이다. typed traversal은
  schema가 준비된 경우 `memory_query`로 수행한다.
- `memory_remember`의 signed name hash가 음수 VID를 만들면 현재 INSERT planner가 거부한다.
  이 버그가 수정되기 전에는 일부 이름의 note write가 실패할 수 있다.
- 타입드 노드는 `INSERT VERTEX`에 INT64 vid가 필요하다. canonical name→안정적 vid 레시피는 `SKILL.md` 참조(`status`는 예약어라 상태 property는 `state` 사용).
- 이 사본은 스냅샷이다. 라이브를 고치면 여기도 갱신할 것(반대도 마찬가지).

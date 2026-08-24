[English](../orchestration.md) | **한국어**

# 멀티 CLI 오케스트레이션

현재 Byori 제품 모델은 Byori macOS 앱입니다.

```text
Project
└── Source Tree 또는 Worktree
    └── Task
        └── Session (사용자가 고른 코딩 agent 하나 + model 선택 하나)
```

Project가 가장 큰 workspace 경계다. Source Tree와 Worktree는 그 안의 checkout이고,
Task는 checkout 하나의 작업을 묶으며, Session마다 사용자가 선택한 agent 정확히 하나를
실행한다. Claude Code 대신 Codex를 시작하거나 그 반대로 바꾸려면 새 Session을 만든다.
Byori workspace는 prompt 하나를 여러 agent로 자동 fan-out하지 않는다. Settings는 agent,
Skill, MCP, ByoriDB, 진단 관리를 보조한다. 한 Project의 모든 Source Tree/Worktree, Task,
Session, agent 선택은 프로젝트 범위의 같은 ByoriDB 공유 지식 그래프를 사용한다.

이 문서의 나머지는 별도 foreground `byori run` prototype/호환 경로를 설명한다. 이 CLI는
Claude Code와 Codex를 동시에 실행하고, 각 worker에 같은 작업과 관련 ByoriDB context의
제한된 일부를 전달하며, 기본 모드에서 worker별 Git branch와 관리형 worktree를 만들 수
있다. 초기 로컬 MVP이며 macOS 앱의 Session model, daemon, 원격 control plane, 자동 merge
시스템이 아니다.

## 구조와 데이터 경계

```text
byori CLI (coordinator)
├── provider/project/run record, prompt, JSONL log         ~/.byori/
├── project-space coordinator advisory lock               ~/.byori/locks/
├── Claude Code worker ── 관리형 branch + worktree          ~/.byori/worktrees/...
├── Codex worker       ── 관리형 branch + worktree          ~/.byori/worktrees/...
└── 제한된 recall + project/task checkpoint
                         │
                         ▼
                    로컬 ByoriDB
                  durable knowledge graph
```

ByoriDB는 coordinator 아래의 지식 계층이지 process supervisor나 raw event 저장소가 아닙니다.
실행 전에 coordinator는 작업과 관련된 graph item을 최대 8개 선택하고 본문을 각각 800자로
제한합니다. 이 context를 신뢰되지 않은 과거 참고 자료로 표시하고 worker가 현재 저장소와
대조해 검증하도록 요청합니다. 실행 경계에서는 project entity와 압축된 task checkpoint만
프로젝트 graph space로 승격합니다.

전체 작업 prompt, provider별 stdout/stderr, provider session identifier, 전체 run state는
`~/.byori`에 남으며 ByoriDB에 복사하지 않습니다. 이 구분으로 graph는 재사용할 프로젝트
지식에 집중하면서도 실행을 조사할 로컬 근거는 보존합니다.
단, 압축 task checkpoint에는 제한된 한 줄 작업 설명과 provider, revision, status, branch,
diff summary metadata가 들어가므로 그 요약문도 graph data로 취급해야 합니다.

## CLI 설치와 경로

설치기는 launcher를 `~/.byoridb/bin/byori`에 배치하고 `~/.local/bin`에 링크합니다. 그 디렉터리가
`PATH`에 있으면 `byori`로 바로 실행됩니다. 셸 설정 파일은 건드리지 않고, `PATH`에 없으면 추가할
줄을 출력합니다.

```sh
curl -fsSL https://github.com/byoridb/byori/releases/latest/download/install.sh | bash
export PATH="$HOME/.local/bin:$PATH"   # 이미 있으면 생략

byori --help
byori provider list
```

MVP는 `claude`와 `codex`를 지원합니다. `provider list`는 각 executable의 사용 가능 여부와
감지한 버전을 보여 주며 `--json`으로 기계 판독 형식을 받을 수 있습니다. 인증은 각 vendor
CLI가 계속 담당하므로 오케스트레이션 실행 전에 해당 CLI에 로그인해야 합니다.

source checkout을 시험할 때는 현재 asset을 먼저 설치합니다.

```sh
./install.sh --assets .
```

## 신뢰할 프로젝트 등록

```sh
cd /path/to/repository
byori project add .
byori project list
```

`project add`는 Git 저장소만 받으며 canonical root를 `~/.byori/projects.json`에 기록합니다.
안정적인 ByoriDB space를 자동 할당하며, 직접 정하려면 유효한 nGQL identifier를 전달합니다.

```sh
byori project add . --space my_project_memory
```

space는 `^[A-Za-z_][A-Za-z0-9_]{0,63}$`을 만족해야 합니다. 등록은 idempotent하고 이미
등록된 프로젝트를 다른 space로 조용히 재할당하지 않습니다. `project list --json`은
스크립트에서 쓰기 좋은 형식으로 registry를 출력합니다.

> [!WARNING]
> `byori project add`는 명시적 신뢰 결정입니다. 오케스트레이션 worker는 비대화식으로
> 실행됩니다. Claude는 read/search/edit/write tool과 `dontAsk`를 사용하고, Codex는
> `workspace-write` sandbox에서 approval `never`를 사용합니다. 내용과 로컬 지시문을
> 신뢰하는 저장소만 등록하세요. `--allow-shell`은 Claude의 Bash tool을 추가로 활성화하며
> Codex의 sandbox 설정은 바꾸지 않습니다.

### Byori macOS 앱의 제거와 복원

Byori macOS 앱에서 workspace 항목을 제거하는 동작은 filesystem이나 Git 정리가 아니라
metadata 작업입니다.

- 프로젝트를 제거하면 `~/.byori/projects.json`의 활성 `projects` 목록에 있던 원본 record를
  top-level `removed_projects` archive로 그대로 이동합니다. 같은 canonical repository root를
  다시 추가하면 project ID와 ByoriDB space를 포함한 기존 record를 복원하므로 보존된
  task/session metadata도 같은 프로젝트에 다시 연결됩니다.
- linked checkout을 제거하면 project와 canonical path를
  `~/.byori/manager/checkout-visibility.json`에 기록합니다. 앱을 다시 실행해도 project
  outline에서만 숨겨지며 visibility 항목을 복원하면 다시 나타납니다.

두 동작 모두 repository 파일, Git worktree나 branch, task/session metadata, run record,
ByoriDB data를 삭제하지 않습니다. Checkout과 branch의 미병합 작업을 검토해 실제로 제거해도
안전하다고 판단한 뒤에만 일반 Git 명령으로 별도 정리하세요. 이 release의 `byori project`
CLI는 계속 `add`와 `list`만 제공하며 archive와 visibility 작업은 Byori macOS 앱 범위입니다.

## 여러 CLI로 작업 하나 실행

```sh
byori run --agent claude --agent codex "요청한 변경을 구현해"
```

`--agent`를 반복해 worker를 선택합니다. 지정하지 않으면 설치된 지원 provider를 모두
실행합니다. 같은 provider도 여러 번 지정할 수 있으며 Byori는 서로 다른 label, branch,
worktree, provider-neutral agent ID를 부여합니다.

주요 옵션:

| 옵션 | 의미 |
|---|---|
| `--project PATH` | `PATH`를 포함한 등록 프로젝트에서 실행. 기본은 `.` |
| `--base-ref REF` | 관리형 worktree를 만들 Git revision. 기본은 `HEAD` |
| `--timeout SECONDS` | worker별 제한 시간. 기본은 3600초 |
| `--allow-shell` | Claude의 Bash tool 추가. Codex는 기존 workspace-write sandbox 유지 |
| `--no-memory` | coordinator의 recall 주입과 checkpoint 두 번을 모두 생략 |
| `--in-place` | 등록 working tree를 직접 사용. worker가 정확히 하나일 때만 허용 |
| `--prompt-file FILE` | 파일에서 작업을 읽음. `-`는 stdin |
| `--quiet` | live event 요약은 출력하지 않고 log만 보존 |

위치 인자 prompt도 `-`로 지정해 stdin에서 읽을 수 있습니다.

```sh
printf '%s\n' "parser를 검토해" | byori run --agent codex -
```

작업 prompt는 최대 1 MiB입니다.

### 기본 격리

기본 관리형 worktree 모드는 tracked 또는 untracked 변경이 있는 저장소를 거부합니다.
먼저 commit하거나 stash하세요. Byori는 base revision을 한 번 확정하고 worker마다 branch와
worktree를 하나씩 만듭니다.

```text
branch:   byori/<run-id>/<worker-label>
worktree: ~/.byori/worktrees/<run-id>/<worker-label>
```

worker는 동시에 실행되며 쓰기 가능한 checkout을 공유하지 않습니다. Byori는 branch와
worktree를 의도적으로 merge, delete, prune하지 않습니다. 결과별로 조사하고 시험한 뒤
일반 Git 명령으로 통합하거나 제거하세요. 실패하거나 일부만 끝난 작업도 복구할 수 있도록
그대로 남깁니다.

`--in-place`는 worker 하나를 위한 명시적 escape hatch입니다. 기존 변경을 포함한 현재 등록
working tree를 사용하므로 위의 clean-tree와 worktree 격리 보장을 제공하지 않습니다.

## 실행 중 ByoriDB 접근

coordinator는 프로젝트 space에서 context를 읽고 시작/종료 task checkpoint를 씁니다.
`~/.byori/locks/`의 project-space advisory lock은 같은 machine에서 동시에 실행되는 Byori
coordinator의 graph 준비와 checkpoint write를 직렬화합니다. worker에는 같은 space와
`BYORIDB_MCP_PROFILE=readonly`를 전달합니다. 이 profile은
`memory_recall`, `memory_query_read`, `memory_read`, `memory_export`만 노출합니다.
동시 worker가 서로 다른 결론을 memory에 경쟁적으로 기록하지 않도록 coordinator가 모든
memory write를 담당합니다.

`readonly`는 MCP tool 표면을 제한할 뿐 **authorization 경계나 process sandbox가
아닙니다**. startup에서는 login, `USE <space>`, schema-version read만 수행하며 coordinator가
현재 schema를 미리 준비하지 않았으면 즉시 실패합니다. Process는 설정된 engine credential을
계속 가집니다. Advisory lock은 Byori process끼리 조정할 뿐 적대적 client를 격리하지 않으므로
신뢰 영역이 다르면 ByoriDB instance와 credential을 분리하세요.

database를 사용할 수 없거나 coordinator가 과거 context를 주입하거나 checkpoint를 남기지
않게 하려면 `--no-memory`를 사용합니다. 이 flag는 vendor CLI의 영속 설정에서 MCP server를
등록 해제하지 않습니다. Byori는 모든 worker 환경에 등록 project space와 `readonly`
profile을 계속 강제해 전역 ByoriDB 등록이 write 가능한 `legacy`로 fallback하지 않게 합니다.
Worker 자체의 memory read도 막아야 한다면 해당 연동을 별도로 꺼야 합니다. 코딩 CLI는
여전히 task와 source 내용을 설정된 model provider에 보낼 수 있으며 Byori의 로컬 저장은
vendor의 데이터 처리 정책을 바꾸지 않습니다.

## 실행 조회

```sh
byori runs list
byori runs show <run-id>
```

`runs list --json`은 모든 로컬 run record를 반환합니다. `runs show`는 worker 상태, exit code,
branch, worktree, log 경로, 실행 전후 Git 상태를 포함한 record 하나를 JSON으로 출력합니다.
raw prompt와 log는 같은 디렉터리에 있습니다.

```text
~/.byori/runs/<run-id>/
├── state.json
├── prompt.txt
├── <worker>.stdout.jsonl
└── <worker>.stderr.log
```

stdout과 stderr log는 각각 32 MiB로 제한하며 한도에 도달하면 truncation marker를 남깁니다.

platform이 허용하면 디렉터리와 파일을 사용자 전용 권한으로 생성하지만 source fragment,
model output, tool event, prompt에 붙여 넣은 secret 등 민감정보가 들어갈 수 있습니다.
실행 전에 prompt를 검토하고 `~/.byori` backup을 보호하며 record를 공유하기 전에
sanitize하세요. worktree에 merge되지 않은 사용자 변경이 있을 수 있어 ByoriDB를
제거해도 `~/.byori`는 자동 삭제하지 않습니다.

## MVP 한계

- provider adapter는 Claude Code와 Codex만 제공합니다.
- run은 호출한 terminal에 붙어 있습니다. daemon, attach/send 명령, 원격 UI는 없습니다.
- 가능한 경우 provider-native resume identifier를 기록하지만 resume 명령은 아직 없습니다.
- winner 선택, patch 비교, branch merge, worktree 정리를 자동화하지 않습니다.
- recall은 기존 graph record에 대한 제한된 lexical ranking입니다. 저장소 자동 ingestion과
  semantic ranking은 후속 작업입니다.

## 설계 출처

provider-neutral run model, lifecycle 분리, 격리 worktree 접근은
[Paseo](https://github.com/getpaseo/paseo)의 공개 구조를 참고했습니다. Paseo는
AGPL-3.0이며, Apache-2.0인 Byori 구현은 그 공개 아이디어를 clean-room 방식으로 독립 작성했고
Paseo source code를 복사하지 않았습니다.

[English](../manager-macos.md) | **한국어**

# macOS용 Byori

Byori macOS 앱은 로컬 Git checkout에서 Claude Code 또는 Codex를 실행하는 네이티브
SwiftUI 멀티 에이전트 코딩 워크스페이스다. 메인 화면은 워크스페이스이며 Settings는
설치, 연동, 진단을 보조한다. ByoriDB는 그 아래에서 프로젝트 범위의 공유 지식 그래프를
제공한다. 앱을 종료해도 ByoriDB는 기존 launchd user service로 계속 실행된다. tmux 3.2
이상이 있으면 대화형 코딩 세션도 분리된 채 유지되며 다음 앱 실행에서 다시 attach할 수 있다.
지원 기준은 macOS 13 이상이며 Apple Silicon과 Intel 빌드를 만들 수 있다.

## 설치

[최신 릴리스](https://github.com/byoridb/byori/releases/latest)에서
`Byori-<version>-universal.dmg`를 내려받아 열고 **Byori**를 Applications로 끌어다 놓는다.
릴리스 DMG는 Developer ID Application 인증서로 서명하고 Apple 공증과 staple을 마쳤으므로
Gatekeeper가 예외 없이 열어 준다.

```bash
spctl -a -vvv -t open --context context:primary-signature ~/Downloads/Byori-*-universal.dmg
# accepted
# source=Notarized Developer ID
```

이후 **Settings → 설정 개요**가 설치된 버전을 보고하고 다음 릴리스를 직접 설치한다. 후보
릴리스의 Developer ID 서명과 Apple 공증을 확인한 뒤에만 번들을 교체하며, 어느 하나라도
실패하면 설치하지 않는다. 확인은 6시간마다 보고만 하고 사용자가 요청할 때까지 아무것도
내려받지 않는다. 교체를 위해 앱이 종료되므로 tmux로 유지되지 않는 세션이 실행 중이면 거부한다.

ByoriDB는 별도로 설치한다. **Settings → ByoriDB** 또는 [shell 설치기](install.md)를 사용한다.
직접 빌드하는 방법은 [.app과 DMG 만들기](#app과-dmg-만들기)에 있다.

## 워크스페이스 모델

메인 계층은 다음과 같다.

```text
Project
└── Source Tree 또는 Worktree
    └── Task
        └── Session (사용자가 고른 코딩 agent 하나 + model 선택 하나)
```

- Project는 사용자가 명시적으로 등록하고 신뢰한 로컬 Git repository다. **새 프로젝트
  생성…**은 이름을 정한 폴더를 만들고 `main` repository로 초기화한 뒤 remote 없이 등록한다.
  초기화는 빈 root commit 하나를 함께 만든다. `git init`은 `main`을 이름만 정하고 만들지는
  않기 때문이다 — 무엇이든 commit되기 전까지는 목록에 나올 branch도, 다른 branch의 시작점도,
  worktree를 만들 대상도 없어서 프로젝트가 등록된 직후 다음 동작을 거부하게 된다. 이 commit은
  파일을 추가하지 않으며(프로젝트에 무엇이 들어갈지는 사용자가 정한다), 사용자의 Git identity를
  쓰고 Git이 identity를 찾지 못할 때만 Byori 자신의 것으로 대체한다. **폴더 열기…**는 기존
  폴더를 모두 선택할 수 있으며, Git repository가 아니면 기존 파일을 commit하지 않고 그대로 둔 채
  `git init`을 실행하기 전에 별도로 확인한다.
- Source Tree나 Worktree는 코딩 CLI가 실행될 checkout을 나타낸다. 앱은 기존 또는
  새 local branch에 Byori 관리 worktree를 만들 수 있다.
- Task는 해당 checkout에서 연관된 session을 묶는다.
- Session은 사용자가 고른 코딩 agent(Claude Code 또는 Codex) 정확히 하나와 model 선택
  하나를 기록한다. Model은 해당 agent CLI 기본값 또는 정확한 custom model identifier다.
  Byori는 이 launch 선택을 변경하지 않지만, 대화형 CLI 내부의 provider-side model 변경은
  관찰하거나 막지 않는다. Byori에서 다른 agent를 시작하려면 새 session을 만든다.
- Prompt와 후속 입력은 대화형 terminal에 직접 입력한다. Byori는 prompt나
  terminal transcript를 저장하지 않는다.

Byori는 같은 prompt를 여러 agent에게 자동으로 보내거나, 결과를 비교해 winner를
고르거나, branch를 merge하거나, worktree를 자동으로 정리하지 않는다. 관리 worktree
정리는 항상 사용자가 명시적으로 확인한다. [멀티 CLI
오케스트레이션](../orchestration.md)의 foreground `byori run` fan-out 명령은 별도
prototype/호환 경로로 남아 있다.

## 메인 창

- 왼쪽 sidebar는 **Project → Source Tree/Worktree → Task → Session** 계층을
  보여 주고 현재 checkout을 명확히 한다. 상단 `+` 메뉴에서 새 project를 만들거나 기존
  폴더를 열 수 있다. Source Tree의 `+`는 새 Task용 session sheet를,
  Task의 `+`는 정확히 그 Task용 sheet를 연다. Session 이름은 두 단어로 자동 제안되고
  수정할 수 있으며, 이름이 없는 기존 session은 provider/model 이름으로 표시한다.
  종료된 session은 **Close**로 숨기고 해당 Task 행의
  **More Actions → Closed Sessions** 메뉴에서 복원할 수 있다.
- Task 행의 **More Actions → Remove Task from Byori…**는 모든 session이 끝난 뒤
  task/session metadata를 `~/.byori/archived-tasks`로 옮긴다. Repository 파일,
  worktree와 branch, ByoriDB context는 변경하지 않는다.
- Task가 남아 있지 않고 clean 상태인 Byori 관리 worktree는
  **More Actions → Delete Managed Worktree…**에서 제거할 수 있다. 확인창에서 local
  branch를 유지하거나 Git의 안전한 `-d` 삭제를 요청할 수 있으며, merge되지 않은
  branch는 보존한다. Primary checkout과 외부 관리 worktree에는 삭제 동작을 제공하지 않는다.
- 가운데는 선택한 session의 실제 대화형 PTY를 SwiftTerm으로 바로 표시한다. Claude Code나
  Codex는 해당 checkout에서 실행되며 인증은 각 CLI가 처리한다. 클립보드 이미지를 붙여넣으면
  권한이 제한된 임시 PNG로 저장하고 현재 terminal 입력에 안전하게 인용한 경로를 삽입한다.
  일반 텍스트 붙여넣기는 그대로 동작한다. **Commands** 메뉴는 설치된 Claude plugin·사용자
  Skill 또는 Codex plugin Skill·사용자 Skill의 명령을 읽고, Return을 누르지 않은 채 선택한
  호출문만 terminal에 삽입한다. Session은
  256-color와 truecolor 지원을 알리고 상위 process의 `NO_COLOR` 같은 색상 억제
  환경변수를 제거하므로 provider가 출력한 ANSI 색상을 그대로 표시한다.
- 오른쪽 inspector는 제한된 **Files** metadata, read-only **Git** status, project
  범위 ByoriDB **Context**를 제공한다. 한 프로젝트의 모든 Source Tree/Worktree, Task,
  Session, agent 선택은 같은 프로젝트 공유 지식 그래프를 사용한다.
  Focused/Related/Broad는 task·source-tree match와 0/1/2-hop graph 이웃을 최근 project
  record보다 우선한다. Context는 별도로 load하므로 ByoriDB가 느리거나 unavailable이어도
  Files와 Git을 막지 않는다.
- 하단의 compact status bar는 인증까지 확인한 ByoriDB readiness, 선택 project와 branch, clean/dirty 상태,
  활성 session 수, Context availability, 선택 session 경과 시간을 실제 로컬 상태로
  표시한다. 지원되는 provider API가 없는 quota·billing 퍼센트는 만들지 않는다.
- Settings는 메인 workspace나 별도 global graph browser가 아니라 관리 보조 화면이다.
  ByoriDB와 agent 관리는 **Settings → 설정 개요, 에이전트 · Skill, ByoriDB, 진단**에
  배치했다. Workspace의 톱니바퀴, 메뉴 막대, **Command-,**는 모두 하나의 보존된
  Settings 창을 다시 연다. **Settings → 설정 개요**는 로컬 요건인 ByoriDB, tmux,
  Python 3을 각각 한 행으로 두고 Byori가 확인한 상태와 최대 하나의 동작만 제공한다.
  **Settings → ByoriDB**는 service 설치와 유지관리용이며
  프로젝트 공유 지식은 Context inspector에서 본다.

## 세션 수명

워크스페이스 창을 닫으면 terminal view만 분리되고 활성 session은 종료되지 않는다.
tmux 3.2 이상이면 Byori 전용 tmux server를 사용하므로 앱을 완전히 종료해도 세션이 유지된다.
기존 Byori 빌드가 기본 tmux server에 만든 세션도 다시 attach할 수 있다. 지원되는 tmux가 없으면
유지 범위는 현재 Byori 앱 process의 수명까지이며, workspace가 실행 전에 이 제한을 표시한다.
**Settings → 설정 개요**도 같은 요건을 보고하며 Homebrew로 tmux를 설치하거나 업그레이드할 수 있다.
Homebrew가 없으면 완료할 수 없는 동작을 제공하는 대신 요건만 알린다. 설치가 성공하면 앱을
다시 실행하지 않아도 다음 세션부터 적용된다.

- **Quit Byori**는 tmux 기반 세션에서는 client만 분리하고, 지속성이 없는 fallback 세션만 중지한다.
- 앱을 다시 실행하면 유지된 세션을 찾아 기존 PTY에 다시 attach할 수 있다.
- 종료된 session에는 같은 Task로 여는 **New Session**을 제공한다. 활성 session은
  **Close**할 수 없으며 먼저 중지해야 한다.
- **Close**는 task/session history를 삭제하지 않고 종료된 session을 sidebar에서
  영구적으로 숨긴다. 부모 Task 행의 **More Actions → Closed Sessions** 메뉴에서
  복원할 수 있다.
- ByoriDB 자체는 별도 launchd user service로 계속 실행된다.

## 설정과 관리

- 번들 MCP·Skill 자산과 다운로드한 호환 ByoriDB 엔진 설치·복구, 최신 릴리스 업데이트,
  인증된 readiness 및 launchd 상태 확인
- 설치된 엔진 빌드와 공개된 최신 엔진 릴리스를 나란히 보고한다. "최신"은 추측이 아니라 확인된
  진술이며, 릴리스 조회에 실패하면 설치된 엔진이 최신인 척하지 않고 확인 실패를 말한다
- ByoriDB 시작·중지·재시작, 서버 로그와 오류 로그의 마지막 부분을 앱 안에서 읽기(로그 폴더도
  한 번의 클릭으로 열린다)
- Claude Code, Codex, Gemini CLI, Cursor CLI, OpenCode 탐지와 각 벤더의 공식 설치 명령을
  통한 설치·업데이트
- 그 밖의 코딩 CLI는 실행 파일 경로로 직접 등록한다. 기본 인자는 셸을 거치지 않고 `argv`로
  전달한다. 등록한 CLI는 실행 전용이며 Settings가 이를 그대로 알린다. 처음 보는 CLI의 설치
  명령이나 MCP 인터페이스는 검증할 수 없으므로 설치·MCP 연결·Skill 동기화를 하지 않는다.
  등록 해제는 Byori 목록에서만 제거하며 실행 파일과 기존 세션 기록은 그대로 둔다
- 각 CLI의 공식 `mcp add/remove` 명령을 통한 `byoridb` stdio MCP 설정
- Claude의 `~/.claude/skills`, Codex의 `~/.agents/skills`에 Memory Skill 동기화
- Settings에서 각 agent의 사용자 범위 MCP·Skill 목록을 제한된 크기로 조회하고,
  원본 설정/`SKILL.md` 편집 또는 백업 후 안전한 제거 지원
- 새 Claude Code 세션을 Upstage Solar 또는 다른 Anthropic 호환 모델 API로 선택적으로 실행하고,
  credential은 macOS Keychain에 보관하며 `~/.claude`를 변경하지 않고 일반 Claude 환경으로 복원
- MCP command 인자, header, 환경변수 값, token은 목록이나 작업 기록에 표시하지 않고,
  Claude.ai가 관리하는 connector는 읽기 전용으로 표시
- ByoriDB 설치와 agent 연결 분리: database 설치·업데이트는 Claude/Codex의 MCP나
  Skill 설정을 암묵적으로 변경하지 않음
- MCP 설정과 Skill 변경 전 `~/.byori-manager/backups`에 자동 백업
- 설치·업데이트 전 runtime snapshot, 실패 시 파일과 이전 launchd 상태 자동 복원
- 메뉴 막대에서 ByoriDB와 활성 session 상태 확인, 새로고침, 로그 열기,
  workspace 다시 열기, 새 session 시작
- 오래 걸리는 설치·유지관리 작업을 Settings와 workspace 하단에 계속 표시하고,
  Cancel 시 실행 중인 process group을 종료
- Settings 창을 닫아도 작업은 계속하고, 앱 종료 시 snapshot으로 복구 가능한 runtime
  작업만 취소하며 나머지는 정확히 그 작업이 끝날 때까지 기다린 뒤 종료

벤더 CLI 설치 버튼은 실행 전 확인을 받고 각 벤더의 공식 설치 명령만 실행한다.
각 CLI가 자체 로그인을 처리한다. Byori는 기존 벤더 credential을 읽지 않으며, 선택형 Claude 모델
API 설정에서 사용자가 직접 입력한 credential만 저장하고 화면에 다시 표시하지 않는다.

## 개발 및 검증

Xcode Command Line Tools 또는 Xcode가 필요하다.
`manager/macos` source 경로, SwiftPM target `ByoriManager`와
`ByoriManagerCore`는 내부 호환 식별자로 유지한다. Packaging 단계에서 executable
target을 `Byori.app` 안의 공개 executable `Byori`로 매핑한다. Canonical icon
source는 `assets/byori-app-icon.png`이며 packaging script가 이를 앱의
`Contents/Resources/Byori.icns`로 변환한다.

```bash
swift build --package-path manager/macos --product ByoriManager
swift test --package-path manager/macos
swift run --package-path manager/macos ByoriManagerSelfTest
```

Command Line Tools의 compiler와 기본 SDK가 맞지 않는 머신에서는 호환 SDK를 명시할 수
있다. 예를 들어 저장소에서 확인된 대체 SDK가 `MacOSX15.4.sdk`라면:

```bash
SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk \
  scripts/build-macos-dmg.sh --version 0.2.0
```

## .app과 DMG 만들기

현재 아키텍처용 개발 패키지는 다음 명령으로 생성한다.

```bash
VERSION=0.2.0 scripts/build-macos-dmg.sh
```

Apple Silicon과 Intel을 모두 포함하려면:

```bash
VERSION=0.2.0 scripts/build-macos-dmg.sh --universal
```

공개 산출물은 `dist/Byori.app`과
`dist/Byori-<version>-<arch>.dmg`이다. 앱 번들의 executable은 `Byori`다.
DMG에는 Applications 바로가기가 함께
들어 있어 앱을 드래그해서 설치할 수 있다.

기본 빌드는 로컬 검증용 ad-hoc 서명을 사용한다. 배포 빌드는 Developer ID Application
인증서를 전달한다.

```bash
scripts/build-macos-dmg.sh \
  --version 0.2.0 \
  --universal \
  --sign "Developer ID Application: Example Corp (TEAMID)"
```

외부 배포 전에는 Apple notarization과 DMG stapling도 수행해야 한다. 인증서나 notary
credential은 저장소에 커밋하지 않는다. `notarytool store-credentials`로 만든 Keychain
profile이 있으면 빌드와 함께 제출·staple할 수 있다.

```bash
scripts/build-macos-dmg.sh \
  --version 0.2.0 \
  --universal \
  --sign "Developer ID Application: Example Corp (TEAMID)" \
  --notary-profile byori-notary
```

새 `main` commit의 CI가 모두 성공할 때마다 GitHub Actions가 `v0.8.3`부터 다음 stable
patch tag를 만들고 release workflow를 호출한다. 두 release workflow는 tag commit이
`origin/main`에 포함되는지 검사하므로, merge되지 않은 branch에서 만든 `v*` tag로는
릴리스를 발행할 수 없다. Repository tag ruleset은 `v*` tag 생성을 GitHub Actions에만
허용한다. macOS release workflow는 이 릴리스에 서명·공증된 universal DMG를 첨부한다.
다음 repository secrets가 필요하다:

- `MACOS_CERTIFICATE_P12_BASE64`, `MACOS_CERTIFICATE_PASSWORD`
- `MACOS_SIGN_IDENTITY`
- `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`

일반 tag release workflow는 이 credential 없이 ad-hoc DMG를 공개하지 않는다.

## 번들 구조

```text
Byori.app/
└── Contents/
    ├── Info.plist
    ├── PkgInfo
    ├── MacOS/
    │   └── Byori
    └── Resources/
        ├── Byori.icns
        ├── SwiftTerm_SwiftTerm.bundle/
        ├── LICENSE
        ├── VERSION
        ├── THIRD_PARTY_NOTICES.md
        └── runtime/
            ├── install.sh
            ├── cli/byori.py
            ├── mcp/byoridb_mcp.py
            ├── templates/
            └── adapters/claude/
                ├── hooks.snippet.json
                └── skills/byoridb-memory/SKILL.md
```

패키징 script는 canonical `assets/byori-app-icon.png` source로
`Contents/Resources/Byori.icns`를 생성하고 SwiftPM resource bundle을 서명된 앱의
표준 `Contents/Resources` 경로에 복사한다. SwiftTerm 1.15는 Metal resource를 그곳에서
찾는다. Byori macOS 앱은 현재 MIT 라이선스인 SwiftTerm 1.15.0을
고정해 사용하며 라이선스 전문은
`Contents/Resources/THIRD_PARTY_NOTICES.md`에 포함한다. Byori의 Apache-2.0 라이선스는
`Contents/Resources/LICENSE`에 포함한다.

앱은 번들 리소스를 `~/.byoridb`의 안정적인 경로로 복사한 뒤 MCP를 그 경로에 연결한다.
따라서 앱 업데이트나 이동이 실행 중인 MCP command 경로를 깨뜨리지 않는다.
Finder에서 실행해 shell 환경변수를 상속받지 못해도 기존 launchd plist와 렌더링된
`run-server.sh`를 검사해 custom home, port, service label을 다시 찾는다.

## 운영상 주의

- 현재 Python MCP runtime 때문에 ByoriDB 설치 전 `python3`가 필요하며 앱에서 이를
  진단한다.
- 설정 변경과 설치는 user scope에서 수행하며 관리자 권한과 vendor token을 요구하지 않는다.
- ByoriDB 설치는 두 선택지가 아니라 하나의 동작이다. MCP·CLI·Skill·서비스 자산은 앱 번들에
  포함된 것 — 이 빌드와 함께 검증된 것이고 교체는 앱 업데이터의 일 — 을 쓰고, 엔진은 항상 최신
  ByoriDB 릴리스를 내려받는다. 릴리스를 조회할 수 없으면 이 빌드와 함께 검증된 버전을 설치한다.
  기존 데이터와 root password는 보존한다. 엔진 태그는 ByoriDB 페이지가 이미 표시한 릴리스 조회
  결과를 그대로 넘기며, 앱이 조회하지 못했을 때만 설치기가 직접 해석한다. 그러지 않으면 설치기
  안의 rate limit에 걸린 조회가 조용히 고정 태그를 설치하는 동안 화면은 더 새로운 릴리스를
  가리키게 된다. health와 실제 session 인증이 모두 성공해야 완료되므로
  같은 port의 다른 process를 정상으로 오판하지 않는다. 실패하면 runtime 파일을 되돌리고 이전
  연결이 정상이었던 경우 인증까지 다시 확인한다.
- 실패 상세는 **Settings → 진단**의 작업 기록에 표시된다.
  데이터베이스 내용이나 인증정보는 기록하지 않는다.

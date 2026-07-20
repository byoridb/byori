# Byori Manager for macOS

Byori Manager는 ByoriDB와 Claude Code/Codex 연결을 Finder에서 관리하는 SwiftUI 앱이다.
앱을 종료해도 ByoriDB는 기존 launchd user service로 계속 실행된다. 지원 기준은 macOS
13 이상이며 Apple Silicon과 Intel 빌드를 만들 수 있다.

## 제공 기능

- 번들 MCP·Skill 자산과 다운로드한 호환 ByoriDB 엔진 설치·복구, 최신 릴리스 업데이트,
  health 및 launchd 상태 확인
- ByoriDB 시작·중지·재시작, 서버 로그 열기
- Claude Code/Codex CLI 탐지와 공식 설치 스크립트를 통한 설치·업데이트
- 각 CLI의 공식 `mcp add/remove` 명령을 통한 `byoridb` stdio MCP 설정
- Claude의 `~/.claude/skills`, Codex의 `~/.agents/skills`에 Memory Skill 동기화
- MCP 설정과 Skill 변경 전 `~/.byori-manager/backups`에 자동 백업
- 설치·업데이트 전 runtime snapshot, 실패 시 파일과 이전 launchd 상태 자동 복원
- window와 메뉴 막대를 함께 제공해 창을 닫은 뒤에도 상태 확인, 새로고침, 로그 열기,
  Manager 창 다시 열기 지원
- 현재 `note` node와 `rel` edge를 탐색하는 read-only 지식 그래프

벤더 CLI 설치 버튼은 실행 전 확인을 받고 Anthropic/OpenAI의 공식 설치 스크립트만
실행한다. 인증과 로그인은 각 CLI가 처리하며 Byori는 token을 읽거나 저장하지 않는다.

지식 그래프는 초기 조회에서 최대 200개 node만 표시하며 DB를 수정하지 않는다. 본문은
초기 projection에 포함하지 않고 node를 선택할 때만 불러온다. 메뉴 막대의 **종료**는
Manager 앱만 종료하며, 별도 launchd service인 ByoriDB는 계속 실행된다.

## 개발 및 검증

Xcode Command Line Tools 또는 Xcode가 필요하다.

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

산출물은 `dist/Byori Manager.app`과
`dist/ByoriManager-<version>-<arch>.dmg`이다. DMG에는 Applications 바로가기가 함께
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

GitHub의 **Release macOS Manager** workflow는 기존 `v<version>` 릴리스에 서명·공증된
universal DMG를 첨부한다. 다음 repository secrets가 필요하다:

- `MACOS_CERTIFICATE_P12_BASE64`, `MACOS_CERTIFICATE_PASSWORD`
- `MACOS_SIGN_IDENTITY`
- `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`

일반 tag release workflow는 이 credential 없이 ad-hoc DMG를 공개하지 않는다.

## 번들 구조

```text
Byori Manager.app/Contents/
├── MacOS/ByoriManager
├── Resources/ByoriManager.icns
└── Resources/runtime/
    ├── install.sh
    ├── mcp/byoridb_mcp.py
    ├── templates/
    └── adapters/claude/skills/byoridb-memory/SKILL.md
```

앱은 번들 리소스를 `~/.byoridb`의 안정적인 경로로 복사한 뒤 MCP를 그 경로에 연결한다.
따라서 앱 업데이트나 이동이 실행 중인 MCP command 경로를 깨뜨리지 않는다.
Finder에서 실행해 shell 환경변수를 상속받지 못해도 기존 launchd plist와 렌더링된
`run-server.sh`를 검사해 custom home, port, service label을 다시 찾는다.

## 운영상 주의

- 현재 Python MCP runtime 때문에 ByoriDB 설치 전 `python3`가 필요하며 앱에서 이를
  진단한다.
- 설정 변경과 설치는 user scope에서 수행하며 관리자 권한과 vendor token을 요구하지 않는다.
- 온라인 업데이트는 GitHub 최신 릴리스 설치기를 사용하고 기존 데이터와 root password를
  보존한다. 실패하면 runtime 파일을 되돌리고 이전 서비스가 정상 상태였던 경우 health까지
  다시 확인한다.
- 실패 상세는 앱의 **작업 기록**에 표시된다. 데이터베이스 내용이나 인증정보는 기록하지
  않는다.

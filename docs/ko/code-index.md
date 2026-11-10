[English](../code-index.md) | **한국어**

# 소스 코드 인덱스

Byori의 Rust 인덱서는 Tree-sitter로 Python, Swift, JavaScript/JSX,
TypeScript/TSX, Rust를 분석합니다. 파일·심볼 정의·import·호출을 프로젝트의
ByoriDB에 저장하고 기존 MCP 서버에서 조회합니다. 파싱·인덱싱·그래프 조회에
LLM을 사용하지 않습니다.

## 빌드와 실행

앱의 **프로젝트 분석**과 `byori init .`은 Git 이력 분석에 이어 Rust 코드 인덱서를
자동으로 실행합니다. 기록할 이력 기억이 없어도 소스를 분석합니다.
`byori init --skip-code`는 이력만, `byori index`는 코드 구조만 갱신합니다.
두 명령의 `--dry-run`은 분석하되 ByoriDB에는 쓰지 않습니다. 분석은 한 번 실행되며,
계속 변경을 감시하려면 `index --watch`를 사용합니다.

릴리스 설치 프로그램과 macOS 앱에는 인덱서 실행 파일이 포함됩니다.
소스에서 실행하려면 Rust와 C 컴파일러를 준비한 다음 빌드합니다.

```bash
scripts/build-indexer.sh
python3 cli/byori.py index . --dry-run --json
python3 cli/byori.py index .
```

`--dry-run`은 분석 결과를 확인하며 ByoriDB에 기록하지 않습니다. 기록할 때는
`byori init`과 같은 런타임 인증 정보와 프로젝트 공간을 사용하므로 엔진이
실행 중이어야 합니다. 빌드 후 `./install.sh --assets .`로 런타임을 설치할 수 있습니다.

설치된 환경에서는 `byori index .`로 갱신합니다. `--indexer PATH` 또는
`BYORI_INDEXER` 환경변수로 실행 파일을 지정할 수 있습니다.

```bash
byori index . --watch --interval 5
```

위 명령은 실행 중에 주기적으로 파일을 확인합니다. Ctrl-C로 종료하며 별도
백그라운드 서비스를 설치하지 않습니다. 내용이 같은 파일은 파싱 캐시를 재사용하고,
삭제·이름 변경은 다음 스냅샷에 반영합니다. `--no-cache`는 다시 파싱합니다.
캐시는 재생성 가능한 분석 결과이며 프로젝트 기억의 별도 원본이 아닙니다.

독립 실행 파일은 JSON 한 개를 stdout으로, 진단 정보를 stderr로 출력합니다.

```bash
indexer/target/release/byori-indexer index --root . --cache-dir /tmp/byori-index-cache
```

Git이 추적하는 파일과 무시하지 않는 미추적 파일을 읽습니다. 심볼릭 링크와
제외된 빌드·외부 의존성 디렉터리는 건너뛰며, 프로젝트 의존성을 설치하거나 실행하지 않습니다.

## MCP 조회

앱 업데이트 후 프로젝트 분석은 앱에 포함된 CLI·MCP 브리지·인덱서를 사용합니다.
기존 에이전트의 MCP 연결은 별도 설치된 런타임을 사용하므로, **Settings → ByoriDB**에서
런타임을 업데이트하고 에이전트 세션을 재시작해야 새 `code_*` 도구가 표시됩니다.
프로젝트 분석이 설치된 런타임을 임의로 바꾸거나 실행 중인 서비스를 재시작하지는 않습니다.

| 도구 | 용도 |
|---|---|
| `code_status` | 현재 checkout의 분석 revision·스냅샷·개수·진단 확인 |
| `code_search` | 이름·파일·언어 기준 심볼 검색과 페이지 조회 |
| `code_relations` | 반환된 심볼·파일 ID의 호출/import 관계를 양방향으로 조회 |
| `code_impact` | 해석된 관계를 역방향으로 따라가 변경 영향 후보 조회 |

검색·관계 결과의 정확한 ID를 다음 조회에 사용합니다. 먼저 분석 상태를 확인하고,
필요한 소스 위치와 테스트로 검증합니다. 네 도구 모두 `safe`, `legacy`, `readonly`
프로필에서 사용할 수 있습니다. 인덱싱은 CLI로 명시적으로 수행합니다. 오래된
런타임을 갱신한 경우 `byori index` 또는 쓰기 가능한 프로필에서 schema v3 마이그레이션을
먼저 실행한 뒤 `readonly` 세션을 시작합니다.

프로젝트 기억 공간을 공유하는 worktree도 코드 인덱스는 checkout의 정규화된 경로로
구분합니다. 분석 당시 파일 해시와 Git revision을 기록하며, 기본 조회 대상은 MCP
프로세스가 실행된 checkout입니다. 같은 프로젝트 공간의 다른 분석 결과는
`checkout_id`로 선택합니다. 경로를 옮긴 checkout은 다시 인덱싱해야 합니다.

## 정확도와 저장 방식

언어 파싱과 컴파일러 수준의 참조 해석은 다릅니다. 첫 버전은 확인 가능한 관계만
연결합니다. 동적 수신 객체, 모호한 이름, Rust 매크로 확장·trait dispatch, 외부
패키지 내부 등의 미지원 참조는 미해결로 표시합니다. 호출 결과가 비어 있다는 이유만으로
호출자가 없다고 단정할 수 없습니다. LSP 보강, 실행 커버리지, 자동 테스트 선택,
의미·벡터 순위 검색은 포함하지 않습니다.

심볼은 파일과 줄 범위를 유지합니다. 새 스냅샷의 노드·관계를 먼저 기록한 다음
활성 스냅샷 포인터를 마지막에 변경하므로 쓰기 실패 시 이전 완성본이 유지됩니다.
이전 스냅샷과 중단된 쓰기 데이터는 보존하며 자동 정리는 아직 없습니다.
캐시는 AST 분석 비용을 줄이지만 변경된 그래프 게시 시에는 전체 스냅샷을 기록합니다.

코드 스키마는 기존 메모·위키와 분리된 추가 스키마입니다. 기존 결정과 원인 관계는
`memory_*`로 계속 조회합니다. 결정과 심볼의 자동 연결 및 네이티브 앱의 코드 탐색
화면은 이번 범위에 포함하지 않습니다.

## 배포

`scripts/build-indexer.sh --target <Rust target> --output <경로>`는 실행 파일과
의존성 라이선스 본문을 생성합니다. 교차 빌드할 대상은 `rustup target add`로
준비합니다. universal macOS 앱은 `aarch64-apple-darwin`, `x86_64-apple-darwin`
두 결과를 결합하고 앱 서명 전에 인덱서를 서명합니다. 릴리스에는 두 macOS 대상과
Ubuntu 24.04에서 빌드한 Linux x86_64 실행 파일을 제공합니다.

온라인 설치는 릴리스의 SHA-256 파일로 다운로드를 검증합니다. `--assets`는 번들의
`bin/byori-indexer` 또는 소스 빌드의 `indexer/target/release/byori-indexer`를 사용합니다.
실행 파일이 없으면 기존 런타임을 교체하기 전에 빌드 명령과 함께 실패합니다.
직접 빌드한 파일은 `--indexer-binary PATH`로 지정합니다.

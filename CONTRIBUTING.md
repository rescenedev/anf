# 기여 가이드 (Contributing)

anf에 관심 가져주셔서 감사합니다. 이슈 제보, 버그 수정, 기능 제안 모두 환영합니다.

## 개발 환경

- **macOS** (Apple Silicon 권장)
- **Command Line Tools** — 전체 Xcode는 필요 없습니다.
  ```bash
  xcode-select --install
  ```
- 선택 도구(검색 강화): `fd`, `ripgrep`
  ```bash
  brew install fd ripgrep
  ```

## 빌드 & 실행

```bash
./build.sh run      # 빌드 + 실행
./build.sh          # anf.app 만 빌드
swift build         # SwiftPM 직접 빌드
```

재빌드마다 권한(TCC) 프롬프트가 반복되는 게 싫다면 한 번만 고정 서명을 만드세요:

```bash
./tools/setup-signing.sh   # 'anf-dev' 자체 서명 인증서 생성
```

> Command Line Tools로 빌드하면 SwiftUI `App` 라이프사이클이 시작되지 않아, anf는
> AppKit을 직접 구동해 `NSWindow` + `NSHostingController`로 SwiftUI를 호스팅합니다.
> 자세한 구조는 [README의 아키텍처](./README.md#아키텍처)를 참고하세요.

## 테스트

```bash
./test.sh        # 또는: swift run anfTests
```

XCTest·Swift Testing은 전체 Xcode가 필요해서, Command Line Tools 환경에선 **자체 하니스**로
순수 로직을 테스트합니다(`Tests/anfTests/`, 실행 타깃 `anfTests`, 종료 코드 0 = 통과).
앱 로직은 `anf` **라이브러리** 타깃에 있고, 실제 앱은 얇은 `anfapp` 실행 타깃이 `anfMain()`을
호출합니다 — 덕분에 내부 심볼을 `@testable import anf`로 검증할 수 있습니다.

새 순수 로직(파서·정렬·랭킹 등)을 추가하면 가능한 한 테스트도 같이 추가해 주세요. CI(GitHub
Actions, macOS)에서 `swift build` + `swift run anfTests`가 자동 실행됩니다.

전체 테스트 시나리오(유닛/통합 그룹 목록, `ANF_UI_SELFTEST=1` UI 셀프테스트, 릴리즈 전
수동 체크리스트)는 [TESTING.md](./TESTING.md)에 정리되어 있습니다.

## 코드 스타일

- **작은 파일 다수 > 큰 파일 소수** (대략 200~400줄, 800줄 상한).
- **불변(immutable) 우선** — 기존 객체를 변형하지 말고 새 값을 만드세요.
- 경계(사용자 입력·외부 프로세스·API 응답)에서 입력을 검증하고, 오류를 조용히 삼키지 마세요.
- 주변 코드의 네이밍·주석 밀도·관용구에 맞춰 작성합니다.
- 성능에 민감한 경로(대용량 디렉터리, 키 입력마다 도는 코드)는 메인 스레드를 막지 않도록 주의하세요.

## 새 언어 추가 (i18n)

한국어·영어는 코드의 `L("English", "한국어")` 리터럴로 제공되고, **그 외 언어는
파일 하나로 추가**됩니다 — 코드 수정 없음:

1. `Sources/anf/Resources/l10n/template.strings`를 `<언어코드>.strings`로 복사
   (예: `ja.strings`)
2. 오른쪽 값(한국어 참고 번역)을 해당 언어로 번역
3. 빌드 — OS 언어가 해당 코드면 자동 적용됩니다

키는 영어 원문이고, 런타임 조립 문자열(개수 표시 등 21개)은 해당 언어에서 영어로
폴백됩니다. 템플릿은 `python3 tools/gen-l10n.py`로 재생성하며 CI가 동기화를
검사합니다.

## 버전 / 릴리즈

버전은 [Semantic Versioning](https://semver.org/lang/ko/)을 따릅니다:

- `fix`/`perf`/`docs`만 쌓였으면 **patch** (0.1.0 → 0.1.1)
- `feat`이 하나라도 있으면 **minor** (0.1.0 → 0.2.0)
- (1.0 이후) 하위 호환이 깨지면 **major**

릴리즈는 `./tools/release.sh <version>` 한 번으로 끝납니다 — Info.plist 버전 →
테스트 → 빌드 → zip → GitHub Release → Homebrew cask sha256 갱신까지 자동.

## 커밋 / PR

- 커밋 메시지: `<type>: <설명>` (`feat`, `fix`, `refactor`, `docs`, `test`, `perf`, `chore`).
- PR 전에 빌드가 통과하는지(`./build.sh`) 확인하세요.
- 변경 동기와 검증 방법(어떻게 테스트했는지)을 PR 본문에 적어주세요.
- UI/동작 변경은 스크린샷이나 짧은 영상이 있으면 리뷰가 빨라집니다.

## 이슈 제보

버그 제보 시 다음을 포함해 주세요:

- macOS 버전 / 칩(Apple Silicon · Intel)
- 재현 절차
- 기대 동작 vs 실제 동작
- 가능하면 스크린샷, 그리고 충돌 시 `~/Library/Logs/DiagnosticReports`의 리포트

보안 취약점은 공개 이슈 대신 [SECURITY.md](./SECURITY.md)의 절차를 따라주세요.

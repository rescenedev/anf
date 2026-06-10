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

## 코드 스타일

- **작은 파일 다수 > 큰 파일 소수** (대략 200~400줄, 800줄 상한).
- **불변(immutable) 우선** — 기존 객체를 변형하지 말고 새 값을 만드세요.
- 경계(사용자 입력·외부 프로세스·API 응답)에서 입력을 검증하고, 오류를 조용히 삼키지 마세요.
- 주변 코드의 네이밍·주석 밀도·관용구에 맞춰 작성합니다.
- 성능에 민감한 경로(대용량 디렉터리, 키 입력마다 도는 코드)는 메인 스레드를 막지 않도록 주의하세요.

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

# anf — all new finder

**Finder, reforged.**

macOS를 위한 가볍고 빠른 **네이티브 파일 브라우저**. 분할 뷰, 내장 터미널, 커맨드 팔레트를
하나로 — Finder · Windows 탐색기 · 정통 오쏘독스(Mdir / Norton Commander) 스타일을
합쳤습니다. Swift + AppKit으로 만들었고 — Electron 없음, 설정 없음.

🔗 랜딩 페이지: **https://rescenedev.github.io/anf/**
📡 라이브 피드: **https://t.me/anf_github** — 다운로드·릴리즈·이슈 활동이 실시간으로 올라옵니다

## 설치

### Homebrew (권장)

```bash
brew tap rescenedev/anf
brew trust rescenedev/anf          # 서드파티 tap 신뢰 (최신 Homebrew 요구)
brew install --cask anf
```

업데이트는 `brew upgrade --cask anf`.

### 직접 다운로드 (.dmg)

Apple **공증(notarized)** 된 빌드라 받아서 바로 실행됩니다 — Gatekeeper 경고도, `xattr`
우회도 필요 없습니다. 자동 업데이트가 필요하면 위의 Homebrew 설치를 권장합니다.

- 최신 .dmg: **https://github.com/rescenedev/anf/releases/latest/download/anf.dmg**

### 소스에서 빌드

```bash
./build.sh run      # 빌드 + 실행
./build.sh          # anf.app 만 빌드
```

전체 Xcode 없이 **Command Line Tools**만 있으면 됩니다.

> 권한 프롬프트가 재빌드마다 반복되는 게 싫다면 한 번만:
> `./tools/setup-signing.sh` (고정 서명 → macOS 권한 유지)

### 테스트

```bash
./test.sh        # = swift run anfTests
```

XCTest는 Xcode 전용이라 CLT 환경에선 자체 하니스로 순수 로직을 테스트합니다. 앱 로직은 `anf`
라이브러리 타깃, 실제 앱은 얇은 `anfapp` 실행 타깃입니다. CI는 [.github/workflows/ci.yml](./.github/workflows/ci.yml).
자세한 내용은 [CONTRIBUTING.md](./CONTRIBUTING.md#테스트).

---

## 핵심 기능

- **초고속 폴더 진입** — `getattrlistbulk(2)` 네이티브 벌크 읽기로 항목별 `stat` 없이
  이름·종류·크기·날짜를 한 번에. 보통 폴더는 0.01초, **2만 6천 개짜리도 ~0.1초**. 리스트는
  SwiftUI가 아니라 `NSTableView`로 직접 렌더 — 수만 개도 즉각 스크롤·정렬·이동.
- **유연한 분할 뷰** — 단일 · 2분할(좌우) · 2분할(상하) · 4분할. 분할선 드래그로 크기
  조절, 창 위치·레이아웃·보기 형태까지 모두 자동 저장·복원.
- **Workspace** — 현재 분할 레이아웃·탭 구성을 이름 붙여 저장하고 사이드바·⌘K에서 한 번에 복원.
- **탭** — 모든 pane에 탭. 새 탭/닫기/선택/순환.
- **네 가지 보기** — 아이콘 · 리스트 · 컬럼(Miller) · 갤러리. 탭별로 전환.
- **커맨드 팔레트 (⌘K)** — 파일명은 fd 인덱스 + 내장 퍼지 매칭으로 즉시, 내용은 ripgrep으로,
  **hwpx·docx·pptx·xlsx·pdf 본문**까지. SSH 호스트·Workspace도 바로 점프. (아래 *검색* 참고)
- **초성 검색** — `ㄱㅊ`만 쳐도 "(경찰청)…" 폴더로 점프. ⌘K 팔레트에서도, 폴더에서
  그냥 타이핑(타입어헤드)해도. NFC/NFD 정규화·한글 IME ⌘단축키까지 한국어에 진심.
- **hwpx 본문 미리보기** — 한글 hwpx·docx·pptx·xlsx·pdf 본문 텍스트를 직접 추출해 인스펙터에 표시(알한글 불필요).
- **GUI SFTP** — SSH 호스트를 일반 폴더처럼 탐색. 터미널도, sshfs·macFUSE 설치도 없이 원격 디렉터리 브라우징.
- **내장 터미널** — 창 하단 전역 드로어. xterm.js + 실제 PTY. SSH 한 번에 연결.
- **인스펙터** — QuickLook 미리보기 + 가독성 좋은 텍스트 뷰어. iCloud placeholder
  배지 + 선택 시 자동 다운로드.
- **인라인 이름 변경** — 파인더처럼 그 자리에서 편집(별도 팝업 없음).
- **안전한 파일 작업** — ⌘Z 실행 취소(이동·이름변경·복사·휴지통), 이름 충돌 시
  둘 다 유지/덮어쓰기/건너뛰기 선택, 대용량 복사 진행률 + 취소, 실패는 항상 알림.
- **압축 · 해제** — 우클릭으로 zip 압축/풀기. **휴지통·디스크 추출**도 사이드바에서.
- **네이티브 사이드바** — 즐겨찾기 · 핀 · Workspace · 위치 · SSH(`~/.ssh/config` 자동 인식).
- **반투명 배경** — content 영역에 behind-window 블러로 데스크탑이 은은하게 비침.
- **오쏘독스 전송** — F5 복사 · F6 이동. pane 간 드래그 이동도 지원.
- **제로 설정 영속화** — 레이아웃·탭·보기·즐겨찾기·Workspace가 설정 없이 저장·복원.

---

## 검색

커맨드 팔레트(⌘K) 검색은 **현재 포커스된 폴더 이하**를 대상으로 합니다.

- **파일명**: 폴더에 포커스되는 순간 `fd`로 백그라운드 인덱싱 → 검색은 그 인메모리
  리스트를 **Swift 퍼지 랭킹**으로 즉시 필터링. 인덱스는 디스크에 checkpoint로 저장돼
  **재시작해도 즉시 사용**, 폴더 변경(mtime) 시 재인덱싱.
- **내용**: `ripgrep`으로 본문 검색, "내용" 섹션에 따로 표시. **hwpx·docx·pptx·xlsx·pdf**는
  ZIP+XML 본문을 추출해 함께 검색(한글 IME의 NFC/NFD 정규화 차이도 처리). 검색 중엔 스캔 중인
  디렉토리 경로가 하단에 빠르게 지나갑니다.
- **폴백**: `fd`/`ripgrep`이 없으면 macOS **Spotlight(`mdfind`, 현재 폴더 스코프)**,
  그것도 없으면 내장 FileManager 탐색 — 설치 없이도 동작.
- 빈 상태(검색 전): 핀 → Workspace → 최근 방문 → 즐겨찾기 순.

더 빠르고 강력하게 쓰려면(선택):

```bash
brew install fd ripgrep
brew install --cask postmelee/tap/alhangeul   # HWP/HWPX 미리보기
```

---

## 단축키

> **사용자화 (⌘,)** — 설정 UI 없이 Ghostty 방식입니다. `⌘,`를 누르면
> `~/.config/anf/keybindings.json`이 열리는데, **현재 기본 단축키 전부가 미리
> 기입돼** 있어 원하는 줄만 고치면 됩니다. 저장 후 anf로 돌아오면 즉시 적용.
> 한 액션에 여러 키(JSON 배열)도 되고, 다른 액션이 쓰던 키를 적으면 가져옵니다.
>
> **미리보기 글자 크기**는 인스펙터가 텍스트류(markdown/json/문서 본문)를 보여줄 때
> `⌘+` / `⌘−`로 조절합니다 — 선택은 재시작 후에도 유지됩니다 (기본 16pt).

### 탐색
| 키 | 동작 |
|----|------|
| `↑` `↓` | 선택 이동 — 아이콘/갤러리는 한 행씩 (`⇧` 확장: 리스트=연속 범위, 그리드=사각형) |
| `←` `→` | 아이콘/갤러리에서 선택 이동 (리스트는 네이티브) |
| `⌘↓` | 열기 / 진입 (더블클릭도) |
| `⌘←` / `⌘→` | 폴더 히스토리 이전 / 다음 |
| `⌘↑` | 상위 폴더 |
| `Space` | 훑어보기 (Quick Look) |
| `⌘L` / `⌘⇧G` | 폴더로 이동 (경로 입력) |
| `⌘K` / `⌘P` | 커맨드 팔레트 |

### 레이아웃 · 보기 · pane · 탭
| 키 | 동작 |
|----|------|
| `⌘1` `⌘2` `⌘3` `⌘4` | 창 분할 — 단일 · 2분할 좌우 · 상하 · 4분할 |
| `⌘[` / `⌘]` | 보기 모드 순환 |
| `⌘⇧[` / `⌘⇧]` | 좌측 사이드바 / 우측 인스펙터 토글 |
| `Tab` / `⇧Tab` | pane 이동 |
| `⌃Tab` / `⌃⇧Tab` | 현재 pane 탭 이동 |
| `⌘⌥1`…`9` | N번째 탭 선택 |
| `⌘T` / `⌘W` | 새 탭 / 탭 닫기 (마지막 탭이면 pane 닫기) |
| `F5` / `F6` | 다른 pane으로 복사 / 이동 |

### 파일 · 기타
| 키 | 동작 |
|----|------|
| `Return` | 인라인 이름 변경 (그 자리에서; 다중 선택 → 일괄 찾기/바꾸기) |
| `⌘Z` / `⌘⇧Z` | 파일 작업 실행 취소 / 복귀 (이동·이름변경·복사·휴지통) |
| `⌘⇧.` | 숨김 파일 보기 토글 |
| `⌘C` / `⌘X` / `⌘V` | 복사 / 잘라내기 / 붙여넣기 |
| `⌘⌫` | 휴지통으로 |
| `⌘D` / `⌘⇧D` | 복제 / 즐겨찾기 토글 |
| `⌘⌥C` | 경로 복사 |
| `⌘A` | 전체 선택 |
| `⌘⇧N` | 새 폴더 |
| `⌘+` / `⌘-` | 크게 / 작게 (아이콘·텍스트·터미널 글자) |
| `⌘I` | 인스펙터 |
| `⌘R` | 새로고침 |
| `⌃\`` | 터미널 토글 |

> 단축키는 입력기와 무관하게 동작합니다 (한글 IME에서도 ⌘K = ⌘ㅏ OK).
> 우클릭 메뉴에 **터미널 열기 · 경로 복사 · 폴더 용량 계산** 등 동일 동작 제공.

---

## 아키텍처

```
Sources/
  anf/
    App/        main.swift(AppKit 부트스트랩), KeyboardController, MainMenu,
                CommandPalette(NSPanel 컨트롤러), FuzzyMatch, FileIndex,
                WindowEdgeResizer / SidebarDividerResizer(리사이즈 오버레이)
    Models/     FileItem(+getattrlistbulk fast factory), ViewMode, SidebarItem, SavedView
    ViewModels/ BrowserModel(탭) · Workspace(Pane/Workspace/Favorites/RecentFolders/SavedViews)
    Services/   FileSystemService, FastDirRead(getattrlistbulk 벌크 읽기), IconProvider,
                ThumbnailProvider, SSHConfig, SFTPClient(GUI SFTP) / RemoteMount(sshfs),
                TerminalSession(xterm.js+PTY), ExternalTools
    Views/      ContentRoot, Sidebar, Pane(layout/tabs), Content(icon / list=NSTableView /
                column / gallery), Detail(inspector + hwpx 텍스트), Terminal,
                Common(InlineRenameField, VisualEffectView)
    Resources/  xterm/ (번들된 xterm.js)
  PTYHelper/    가상 터미널을 fork/exec 하는 작은 C 헬퍼
```

모델 계층: **`BrowserModel`**(탭 하나) → **`PaneModel`**(탭 스택) →
**`WorkspaceModel`**(레이아웃 + 4 pane + 즐겨찾기). 활성 pane의 활성 탭이 툴바·사이드바·
키보드가 작동하는 대상.

### 왜 SwiftUI `App`이 아니라 AppKit 부트스트랩인가
Command Line Tools(전체 Xcode 없음)로 빌드하면 SwiftUI scene 라이프사이클이 제대로
시작되지 않습니다 — `App.init`은 돌지만 `applicationDidFinishLaunching`이 안 불려 창이
안 뜹니다. anf는 AppKit을 직접 구동해 `NSWindow`를 만들고 SwiftUI 트리를
`NSHostingController`에 호스팅합니다.

### 커맨드 팔레트는 네이티브 컨트롤러
팔레트는 SwiftUI가 아니라 `NSPanel` + `NSTableView` + `NSTextField`를 직접 다루는
`CommandPaletteController`입니다. SwiftUI에서 잡히지 않던 키보드 포커스·성능 문제를
네이티브로 해결했습니다.

### 대용량 폴더는 벌크 읽기 + NSTableView
폴더 진입은 `getattrlistbulk(2)`로 이름·종류·크기·날짜를 항목별 `stat` 없이 몇 번의
시스템 콜로 읽습니다(`FastDirRead`). 리스트 뷰도 SwiftUI `Table`이 아니라
`NSTableView`(행 재활용)로 직접 렌더 — 2만 6천 개 폴더도 ~0.1초에 떠서 스크롤·정렬·화살표
이동이 즉각적입니다. SwiftUI `Table`은 모든 행 identity를 메인 스레드에서 diff해 이 규모에서
멈춥니다.

> 실측 수치는 **[PERFORMANCE.md](./PERFORMANCE.md)** 참고 (26,549개 폴더: 벌크 읽기 24 ms,
> Foundation 풀 stat 대비 ~46×).

---

## 코드 서명

기본은 ad-hoc 서명이라 재빌드마다 서명이 바뀌어 macOS 권한(TCC)을 다시 묻습니다.
한 번만 고정 서명 인증서를 만들면 권한이 유지됩니다:

```bash
./tools/setup-signing.sh   # 'anf-dev' 자체 서명 인증서 생성 (로그인 키체인)
./build.sh                 # 이후 이 identity로 서명
```

출시용은 Developer ID 서명을 사용하세요.

---

## 릴리즈 노트 — v1.0 (첫 공개)

**탐색 · 성능**
- `getattrlistbulk(2)` 네이티브 벌크 읽기로 2만 6천 개 폴더도 ~0.1초 진입
- 리스트는 `NSTableView`, 아이콘 그리드는 `NSCollectionView`, 사이드바는
  `NSOutlineView` — SwiftUI 병목 없는 네이티브 렌더링, 수만 개도 즉각 스크롤·정렬
- **한 번 연 폴더는 재진입 즉시(0ms)** — 마지막 목록을 캐시로 먼저 그리고, 변경분은
  바로 뒤에서 자동 반영
- 리스트 · 아이콘 · 컬럼 · 갤러리 보기 (⌘[ / ⌘]), 리스트 줄무늬, 아이콘 크기 ⌘±,
  리스트 글자 크기는 Finder처럼 딱 2단계
- **폴더별 보기 형태 기억 + 하위 폴더 상속** — 상위 폴더에서 바꾸면 서브트리가 따라옴
- 유휴 CPU ~0% — 검색 인덱스는 필요할 때만 갱신

**분할 · Workspace**
- 단일 · 2분할 좌우 · 상하 2행 · 4분할 (⌘1–4), 분할선 드래그
- **분할하면 새 패널이 현재 폴더에서 시작** — 각자 이동해 배치한 뒤 Workspace로 저장
- Workspace: 레이아웃 + 탭 구성을 이름 붙여 저장/복원 (분할 레이아웃 전용, 단일창은 핀 ★)
- 탭(⌘T·⌘W·⌃Tab·⌘⌥1–9), Tab으로 패널 포커스 전환, F5/F6 패널 간 복사·이동

**키보드**
- **타입어헤드** — `p`를 치면 p로 시작하는 항목으로 즉시 점프, 연타 누적(`pl` → playground),
  한글은 초성/자모 매칭(ㅍ → 플레이그라운드). 한글 IME 상태에서 영문 키를 눌러도
  물리 키 폴백으로 영문 이름을 찾음
- Shift+화살표 선택: 리스트는 연속 범위, 아이콘 그리드는 **직사각형 블록**
- **PgUp/PgDn은 선택을 한 화면씩, Home/End는 처음/끝 항목으로 이동** (Shift로 범위 확장)
- 스페이스 Quick Look, Enter 인라인 이름 변경
- ⌘⌥C 선택 항목 경로 복사 · **⌥⇧⌘C 현재 폴더 경로 복사**
- 한글 입력 상태에서도 동작하는 ⌘ 단축키 (물리 키 기준)

**검색 · 미리보기**
- ⌘K 커맨드 팔레트: 파일명은 `fd` + 내장 퍼지 랭킹, 내용은 `ripgrep`, 백그라운드 인덱스
- **hwpx·docx·pptx·xlsx·pdf 본문 검색** 및 인스펙터 텍스트 미리보기 (알한글 불필요)
- NFC/NFD 한글 파일명 정규화 일치, 커맨드 팔레트에서 SSH 호스트·Workspace 바로 점프
- 인스펙터(⌘I) Quick Look + 가독성 텍스트 뷰어, ⌘± 폰트 크기

**파일 작업 · 안전망**
- **⌘Z / ⌘⇧Z** — 이동·이름 변경·휴지통·새 폴더를 되돌리고 재실행
- 이름 충돌 시 둘 다 유지/덮어쓰기/건너뛰기, 대용량 작업 진행 HUD + 취소
- zip 압축/풀기, 휴지통 비우기, 디스크 추출, 숨김 파일 ⌘⇧., 폴더·패널 간 드래그&드롭
- 파인더식 인라인 이름 변경(확장자 제외 자동 선택), 여러 항목 일괄 이름 변경
- iCloud 미다운로드 인지, 복사·이동·복제 등 기본 파일 작업

**원격 · 터미널**
- **GUI SFTP** — SSH 호스트를 일반 폴더처럼 탐색 (sshfs·macFUSE 불필요)
- 창 하단 내장 터미널(실제 PTY, ⌃`), **터미널 다중 탭**, "여기서 터미널 열기"
- `~/.ssh/config` 자동 인식 · 라이브 세션 표시, 비밀번호 입력·저장 없음(키/에이전트 인증)

**프라이버시 · 언어**
- 텔레메트리·분석·계정 없음 — 네트워크 요청은 하루 1회 GitHub 버전 확인뿐
  ([개인정보처리방침](https://rescenedev.github.io/anf/privacy.html))
- **Anthropic API 키는 설정 파일에 절대 평문으로 저장하지 않습니다** — macOS **키체인(Keychain)**에만
  보관합니다. `AI` 메뉴 → **"Anthropic API 키 설정…"**에서 입력하면 키체인에 저장됩니다.
  (예전 버전이 평문으로 남겨둔 키는 실행 시 자동으로 키체인으로 옮기고 파일에서 지웁니다.)

  <img src="docs/assets/ai-keychain.png" alt="anf의 Anthropic API 키 입력 창 — macOS 키체인에 안전하게 저장" width="420">
- OS 언어 설정에 따라 한국어/영어 UI

---

## 피드백

아이디어, 개선 의견, 버그 제보는 [GitHub 이슈](https://github.com/rescenedev/anf/issues) 또는 **tellme@duck.com**.

---

## 라이선스 / 크레딧

anf는 **MIT 라이선스**로 배포됩니다 — [LICENSE](./LICENSE).
기여는 [CONTRIBUTING.md](./CONTRIBUTING.md), 보안 신고는 [SECURITY.md](./SECURITY.md)를 참고하세요.

- [xterm.js](https://github.com/xtermjs/xterm.js) (MIT) — 터미널 렌더링
- Apple AppKit · WebKit · QuickLook — 시스템 프레임워크
- [알한글](https://postmelee.github.io/alhangeul-macos/) (MIT, 선택) — HWP/HWPX 미리보기

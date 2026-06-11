# anf — all new finder

macOS를 위한 가볍고 빠른 **네이티브 파일 브라우저**. Finder · Windows 탐색기 · 정통
오쏘독스(Mdir / Norton Commander) 스타일을 하나로 합쳤습니다. Swift + AppKit으로
만들었고 — Electron 없음, 설정 없음.

🔗 랜딩 페이지: **https://rescenedev.github.io/anf/**

## 설치

### Homebrew (권장)

```bash
brew tap rescenedev/anf
brew trust rescenedev/anf          # 서드파티 tap 신뢰 (최신 Homebrew 요구)
brew install --cask anf
```

업데이트는 `brew upgrade --cask anf`.

> self-signed 빌드(노터라이즈 안 됨)라 첫 실행 시 Gatekeeper가 막을 수 있습니다 —
> **anf.app 우클릭 → 열기**, 또는 시스템 설정 > 개인정보 보호 및 보안 > "확인 없이 열기".

### 소스에서 빌드

```bash
./build.sh run      # 빌드 + 실행
./build.sh          # anf.app 만 빌드
```

전체 Xcode 없이 **Command Line Tools**만 있으면 됩니다.

> 권한 프롬프트가 재빌드마다 반복되는 게 싫다면 한 번만:
> `./tools/setup-signing.sh` (고정 서명 → macOS 권한 유지)

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
  **hwpx·docx·pptx·xlsx 본문**까지. SSH 호스트·Workspace도 바로 점프. (아래 *검색* 참고)
- **hwpx 본문 미리보기** — 한글 hwpx·docx·pptx·xlsx 본문 텍스트를 직접 추출해 인스펙터에 표시(알한글 불필요).
- **GUI SFTP** — SSH 호스트를 일반 폴더처럼 탐색. 터미널도, sshfs·macFUSE 설치도 없이 원격 디렉터리 브라우징.
- **내장 터미널** — 창 하단 전역 드로어. xterm.js + 실제 PTY. SSH 한 번에 연결.
- **인스펙터** — QuickLook 미리보기 + 가독성 좋은 텍스트 뷰어. iCloud placeholder
  배지 + 선택 시 자동 다운로드.
- **인라인 이름 변경** — 파인더처럼 그 자리에서 편집(별도 팝업 없음).
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
- **내용**: `ripgrep`으로 본문 검색, "내용" 섹션에 따로 표시. **hwpx·docx·pptx·xlsx**는
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

## 라이선스 / 크레딧

anf는 **MIT 라이선스**로 배포됩니다 — [LICENSE](./LICENSE).
기여는 [CONTRIBUTING.md](./CONTRIBUTING.md), 보안 신고는 [SECURITY.md](./SECURITY.md)를 참고하세요.

- [xterm.js](https://github.com/xtermjs/xterm.js) (MIT) — 터미널 렌더링
- Apple AppKit · WebKit · QuickLook — 시스템 프레임워크
- [알한글](https://postmelee.github.io/alhangeul-macos/) (MIT, 선택) — HWP/HWPX 미리보기

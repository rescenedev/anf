# TODO

anf 향후 작업 메모.

## 완료 (branch: feat/content-search-remote)

- [x] **hwpx / docx / pptx / xlsx 본문 검색** — unzip으로 내부 XML을 풀어 grep. 팔레트
  "내용" 섹션에 함께 표시. (`PaletteSearch.docContent`)
- [x] **FSEvents 증분 인덱스** — 포커스 폴더를 FSEvents로 감시, add/remove/rename를
  전체 재스캔 없이 반영. checkpoint도 자동 재저장. (`FileIndex`)
- [x] **SFTP 연결** — SSH 사이드바 우클릭: `SFTP (터미널)`(항상 동작), `SFTP 마운트해서
  열기`(sshfs로 원격을 로컬처럼 브라우징; sshfs 없으면 설치 안내). (`RemoteMount`)

## 검색

- [ ] 검색 범위 토글 (현재 폴더 / 홈 / 전역) — 지금은 현재 포커스 폴더 이하 고정.
- [ ] hwpx 본문 검색을 인덱싱해 더 빠르게 (지금은 매 검색마다 unzip).
- [ ] zip 일반 압축파일 내부 검색 확장 검토.

## 커맨드 팔레트

- [ ] **⌘K에 브라우저 방문 기록 통합** (Safari / Chrome 히스토리 DB 읽어서 팔레트에 섞기).
- [ ] 액션 커맨드(설정, 보기 전환 등)도 팔레트에서 실행.

## 랜딩 페이지

- [ ] **팔레트 검색 데모 GIF** 추가 (정적 스샷 → 실제 타이핑·결과 GIF). `docs/assets/palette.gif`.
- [ ] 실제 후원 페이지/통계 연동 확인.

## 배포 / 코드 서명

- [ ] **자체 서명 인증서(self-signed)로 고정 서명** — 지금은 재빌드마다 ad-hoc 서명이 바뀌어 macOS TCC(권한) 프롬프트가 매번 다시 뜸. 고정 identity로 서명하면 권한 유지. 출시용은 Developer ID.
- [ ] 권한(TCC) 안내 정리 — Documents/Desktop/Downloads 등.

## 문서

- [ ] **README 한글화** (현재 영어 초안).
- [ ] 단축키·아키텍처 문서 최신화 (전역 터미널, 네이티브 팔레트, fd 인덱스, ⌃Tab, ⌘W pane 닫기 반영).

## 탭 / 상태바 (요청 접수, 가능성 검토 완료)

- [ ] **상태바(경로바) 위치 조정** — 위/아래 선택. _쉬움_ (부모 레이아웃 플래그).
- [ ] **현재 위치 인라인 편집** — 브레드크럼 클릭 → 그 자리에서 경로 TextField로 편집 후
  Enter 이동(브라우저 주소창식). 이동 로직(`goToFolderPrompt`→`navigate`)은 이미 있음. _쉬움~중간._
- [ ] **탭 락(고정 폴더)** — 탭을 폴더에 고정: 다른 데로 이동해도 그 탭 재선택 시 고정 폴더로 복귀.
  `BrowserModel.lockedURL` + `PaneModel.select`에서 복귀, `TabState`에 플래그. _쉬움~중간._
  (락 = "이동 금지" vs "재선택 시 복귀" 중 정책 결정 필요 — 요청 문구는 후자.)
- [ ] **탭 순서 드래그 재배열** — TabStripView 드래그 처리. _중간._
- [ ] **탭 분리(floating detached window)** — 탭을 떼어 별도 창으로. _어려움_ — anf는 CLT
  부트스트랩 단일 `NSWindow` 구조라 멀티윈도우가 큰 작업. 별도 검토 필요.

## one more thing…

- [ ] (비밀) 출시 때 공개.

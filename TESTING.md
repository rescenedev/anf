# 테스트 시나리오

anf의 검증은 세 층으로 나뉩니다. CLT(Command Line Tools) 환경이라 XCTest를 쓸 수
없어 자체 하니스를 사용합니다 — 자세한 배경은 [CONTRIBUTING.md](CONTRIBUTING.md) 참고.

| 층 | 실행 방법 | 대상 |
|---|---|---|
| 유닛/통합 (`anfTests`) | `./test.sh` 또는 `swift run anfTests` | 순수 로직 + 실제 `BrowserModel` 구동 |
| UI 셀프테스트 | `ANF_UI_SELFTEST=1 .build/debug/anfapp` | 합성 NSEvent로 실제 이벤트 경로 검증 |
| 수동 체크리스트 | 아래 목록 | 자동화 불가한 시각·상호작용 |

CI(GitHub Actions, macOS)는 push/PR마다 `swift build` + `swift run anfTests`를 돌립니다.
UI 셀프테스트는 GUI 세션이 필요해 로컬 전용입니다(릴리즈 전 필수 실행).

## 1. 유닛/통합 — `Tests/anfTests/` (105 checks)

### 검색·텍스트
- **FuzzyMatch** — 퍼지 매칭 점수, 한글 NFC 정규화 풀(`rankLowered`) 매칭
- **HangulJamo.searchKey** — 음절→자모 전개("플"→"ㅍㅡㄹ"), 겹받침(ㅄ→ㅂㅅ)·복합모음 분해, 라틴 소문자화
- **DocumentText** — hwpx/docx 등 문서 텍스트 추출
- **normalizationVariants** — NFC/NFD 한글 파일명 동등 처리

### 키보드 선택 (실제 BrowserModel + 픽스처 폴더 구동)
- **icon grid: rectangular shift-extension** — Shift+화살표 = 앵커·커서를 마주보는
  모서리로 한 직사각형 블록 (4×3 그리드에서 ↓↓→ = 2×3 블록, 스네이크 흔적 금지)
- **icon grid: backtracking shrinks the block** — 반대 방향 Shift+화살표는 블록 축소
- **icon grid: anchor resets after a click** — 클릭 후 확장은 클릭한 칸에서 시작
  (Set 순서에 의존한 임의 앵커 점프 회귀 방지)
- **icon grid: plain arrow collapses to one cell** — Shift 없는 화살표는 단일 선택
- **icon grid: clamp at the partial last row** — 마지막 행이 모자랄 때 커서 클램프
- **list mode: contiguous reading-order range** — 리스트/컬럼은 연속 범위 확장·축소

### 타입어헤드 (type-to-select)
- **prefix jump and accumulation** — `p` → 첫 p 항목, 빠른 연타 `pr` → 누적 매칭
- **pause resets the buffer** — 0.8초 무입력 후 새 버퍼로 시작
- **Korean jamo matching** — `ㅍ` 초성만으로 "플레이그라운드" 점프, IME 자모
  스트림(ㅍ,ㅡ,…) 연속 매칭
- **no-match falls to the nearest follower** — 일치 없으면 알파벳상 다음 항목(Finder 동일)

### 폴더별 보기 형태
- **ViewModePrefs inheritance** — 명시적 설정만 기록, 하위 폴더는 가장 가까운 상위
  설정 상속, 서브트리 밖 형제는 무관
- **ViewModePrefs override and subtree reset** — 하위 폴더 자체 설정이 상위보다 우선,
  상위를 다시 설정하면 묵은 하위 항목 정리(서브트리 전체가 최신 선택을 따름)

### 파일시스템·안전망
- **FastDirRead** — getattrlistbulk 벌크 읽기: 항목 수/타입/크기/숨김, `.`·`..` 제외,
  없는 경로 → nil
- **FileSystemService.sorted** — 로케일 인지 정렬(한글 포함)
- **FileUndo move round-trip** — 이동 undo→복원, redo→재적용 (redo 방향 회귀 방지)
- **UpdateChecker.isNewer** — 버전 비교(숫자 기준, 1.10 > 1.9)
- **SavedView codable** — 저장된 보기 직렬화 왕복
- **SFTPClient.parse** — `ls` 출력 파싱(심링크·공백 파일명 등)

## 2. UI 셀프테스트 — `ANF_UI_SELFTEST=1` (UISelfTest.swift)

합성 NSEvent를 `NSApp.sendEvent`로 보내므로 로컬 이벤트 모니터·SwiftUI 제스처가
실제 입력과 동일한 경로로 동작합니다. 항목별 PASS/FAIL 출력 후 자동 종료.

- 사이드바 분할선 드래그 → 폭 증가 (오버레이가 hit 소유하는지 포함)
- 인스펙터 핸들 드래그 → 폭 증가
- 2분할 칼럼 핸들 / 행 분할 핸들 드래그 → 비율 변경
- 스트레스: 줌, 사이드바 접기/펴기, 풀스크린 왕복 후에도 오버레이 생존 + 드래그 동작
- **페이지 키 (회귀)** — 300개 픽스처 폴더를 아이콘 모드로 열고 실제 PgDn/End/Home
  keyDown 전송 → 클립뷰 원점 이동 검증 (PgDn 한 화면, End 맨 아래, Home 맨 위).
  `NSResponder.scrollPage…` 기본 구현이 조용한 no-op이었던 회귀를 막음.
- 별도: `ANF_RESIZE_SELFTEST=1` — 창 가장자리 리사이즈 오버레이
- 성능 벤치: `ANF_BENCH=/큰/폴더 swift run anfTests` — 폴더 진입 단계별
  (벌크 읽기 → FileItem 생성 → 정렬) 소요 시간 출력. 26k 항목 기준
  total ~210ms(debug)가 회귀 기준선
- PDF 벤치: `ANF_BENCH_PDF=/pdf/폴더 swift run anfTests` — 파일별 본문 추출
  시간 + 팔레트형 병렬 스윕(cold/warm 캐시). 기준선: 32개 PDF cold ~410ms,
  warm ~4ms (warm이 수십 ms를 넘으면 캐시 회귀)

## 3. 수동 체크리스트 (릴리즈 전)

자동화가 불가능하거나(실제 마우스/IME/외부 장치) 시각 판단이 필요한 항목.

### 키보드·선택
- [ ] 아이콘 모드에서 Shift+클릭, ⌘+클릭, 빈 공간 러버밴드 드래그 선택
- [ ] PgUp/PgDn/Home/End — 아이콘·리스트 모드, **폴더가 선택된 상태에서도** 스크롤
- [ ] 타입어헤드 — 영문/한글 IME 실타이핑, 리스트·아이콘 모드 모두.
      **한글 IME 상태에서 c 등 영문 키를 눌러도** 물리 키 폴백으로 영문 이름 매칭
- [ ] PgUp/PgDn = 선택을 한 화면씩 이동(스크롤할 게 없어도 동작), Home/End =
      첫/끝 항목 선택, Shift 조합 시 범위 확장
- [ ] 위로 이동(⌘↑)·폴더 진입 시 첫 항목 자동 선택
- [ ] Enter 이름변경 → Esc 취소 → 다시 Enter 정상 동작

### 보기·창
- [ ] 폴더 A를 리스트로 바꾸면 하위 폴더 전부 리스트, 하위 B만 아이콘으로 바꾸면
      B 서브트리만 아이콘, A를 다시 바꾸면 전체가 따라옴
- [ ] 단일/2분할/4분할 전환, 분할 상태에서도 창 모서리 라운드 유지
- [ ] Workspace 저장 아이콘은 분할 레이아웃에서만 표시(단일창은 핀 ★만)
- [ ] 분할 시 새로 열리는 패널은 모두 현재 폴더로 시작(1→4 = 같은 폴더 4개,
      1→2도 동일), 이미 보이던 패널은 유지 — 이후 각자 이동해 Workspace로 저장
- [ ] 핀 분할 기억 — 핀 A에서 분할·배치 → 핀 B 클릭 → 다시 A 클릭하면 분할
      그대로 복원(앱 재시작 후에도). A에서 단일창으로 접고 떠나면 기억 삭제
- [ ] 리스트 줄무늬 — 짝/홀 행 교차 배경이 스크롤·삭제·생성(diff) 후에도 어긋나지
      않고, 다크/라이트 모드 모두 은은하게 보임
- [ ] 툴바 아이콘에 마우스 올리면 ~0.5초 내 이름/단축키 툴팁 표시(피커 세그먼트 포함)
- [ ] 경로 복사 — ⌘⌥C는 선택 항목 경로, ⌥⇧⌘C는 현재 폴더 경로, 빈 공간
      우클릭 "현재 폴더 경로 복사"도 폴더 경로(자동 선택된 행이 아니라)
- [ ] 사이드바 — Workspace 행 클릭(라벨 오른쪽 빈 영역 포함), 섹션 접기 유지,
      우클릭 메뉴, SSH `+` 버튼
- [ ] 갤러리 필름스트립 ←/→ 한 칸 이동, 가운데 정렬 스크롤

### 파일 작업
- [ ] 복사/이동 충돌 다이얼로그(둘 다 유지/덮어쓰기/건너뛰기), 대용량 진행 HUD + 취소
- [ ] ⌘Z/⌘⇧Z — 이동·휴지통·새 폴더 되돌리기, 다른 패널 자동 새로고침
- [ ] 휴지통 비우기, 외장 디스크 추출, ⌘⇧. 숨김 토글, zip 압축/풀기
- [ ] 폴더 위로 드래그&드롭 이동(아이콘·리스트), 패널 간 F5 복사/F6 이동

### 원격·터미널
- [ ] SSH 탭 연결/재사용, SFTP 탐색, 원격 파일 더블클릭 → 다운로드 후 열기
- [ ] 터미널 여러 개 = 탭 표시, × 닫기, ⌃` 토글, ⌘+/- 폰트 크기

### 성능·기타
- [ ] 수만 항목 폴더(예: kr) 진입 체감 즉시, 유휴 CPU ~0%（`ps -o %cpu`)
- [ ] ⌘K 팔레트 — 파일명/내용/SSH 검색, 한글 정규화 일치, **PDF·hwpx 본문 검색**
- [ ] 업데이트 배너 — 새 릴리즈 시 1회 표시, 닫으면 그날 재표시 없음
- [ ] OS 언어 English/한국어에서 메뉴·다이얼로그 언어 일치

### 정렬·대량 데이터
- [ ] 26k 폴더(kr)에서 정렬 기준/방향 전환 — 비치볼 없이 즉시 (회귀: Myers diff에
      재정렬이 흘러들어 메인 스레드 수 초 정지)

## 새 기능을 추가할 때

1. 로직이면 `Tests/anfTests/`에 그룹 추가 후 `main.swift` 러너에 등록.
   `BrowserModel` 통합 테스트는 픽스처 폴더 + 런루프 펌핑 패턴 사용
   (`GridSelectionTests.swift` 참고).
2. 이벤트 경로(키보드/마우스)가 관련되면 `UISelfTest`에 합성 이벤트 체크 추가 —
   "유닛은 통과하는데 실제 입력은 죽는" 부류의 회귀는 이 층만 잡습니다.
3. 자동화가 안 되면 이 문서의 수동 체크리스트에 한 줄 추가.
4. **초선형(superlinear) 알고리즘은 최악 입력 테스트가 필수** — diff·정렬·매칭류는
   26k 규모의 병리적 입력(전체 재정렬, 전부 불일치 등)으로 시간 상한을 단언할 것.
   뷰 코드에 박힌 결정 로직은 순수 함수로 뽑아 단위 테스트한다(`ListDiff.strategy` 참고).

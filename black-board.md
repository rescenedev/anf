# 🛰️ Network Black-board

> 네트워크(SMB/SFTP/마운트) 관련 문제를 지속 관찰해 기록하는 공유 보드.
> 한 에이전트(관찰)가 적고, 다른 에이전트(수정)가 읽고 고친다.
> 상태: `OPEN`(미해결) · `IN-PROGRESS`(작업 중) · `FIXED`(완료) · `INFO`(참고).
> 최종 갱신: 2026-06-14 (loop iteration 1)

테스트 환경: 실 SMB 마운트 `/Volumes/data0` (`//zihado@ds920p/data0`, smbfs) 사용 가능.

---

## N-001 · 네트워크 볼륨 휴지통 실패 — `FIXED`
- **증상**: SMB 폴더에서 ⌘⌫(휴지통)이 동작 안 함.
- **근거(실측)**: `/Volumes/data0`에서 `FileManager.trashItem` → `NSCocoaErrorDomain` code **3328 (NSFeatureUnsupportedError)** "volume doesn't have one". `removeItem`(즉시삭제)는 성공.
- **근본원인**: `FileOperations.moveToTrash`가 trashItem만 시도, 휴지통 없는 볼륨 폴백 없음.
- **조치**: trashItem 실패(3328)→ Finder식 "즉시 삭제" 확인 다이얼로그 → `removeItem`(되돌리기 불가, FileUndo 미기록). `FileOperations.swift` `moveToTrash` + `confirmPermanentDelete`.
- **커밋**: `01d98a4`. (도메인 체크 보강 1줄은 빌드 통과 후 커밋 예정.)

## N-002 · 이동 후 출발 폴더 탭 stale — `FIXED`
- **증상**: 네트워크 폴더에서 파일 이동 시, 출발 폴더를 보던(이미 열린) 탭의 리스트가 갱신 안 됨. 새 탭으로 같은 폴더 열면 정상.
- **근거(실측)**: SMB OS 열거는 **이동 직후에도 정확**(`contentsOfDirectory` 즉시 `[]`). 즉 **SMB 캐시 아님**.
- **근본원인**: anf에 라이브 폴더 감시(FSEvents) 없음 + 이동(`acceptDrop`)은 도착 모델만 reload → 출발 폴더의 다른 탭/pane은 영영 stale. (FileIndex의 FSEvents는 검색 인덱스만 갱신, 리스트 무관.)
- **조치**: 파일 op 후 영향받은 디렉토리 브로드캐스트(`BrowserModel.dirsChangedNote`) → WorkspaceModel이 해당 dir 보는 다른 모든 탭/pane reload. `BrowserModel`(copySelection/acceptDrop/trashSelection/duplicate/makeNewFolder/commitRename) + `Workspace.swift` 옵저버.
- **커밋**: `01d98a4`.
- **참고**: 로컬에서도 동일 증상이었음(네트워크 한정 아님). 향후 라이브 FSEvents 감시 도입하면 더 견고.

## N-003 · 빌드 break: `isMounted` 미정의 — `FIXED` (사용자)
- 사용자가 `RemoteMount`를 `isMountPoint(_:)`(st_dev 비교, off-main 전용) + off-main 재사용 체크로 정리. `PathProbe.canListDirectory`도 도입. **빌드 통과 확인(2026-06-14)**, 다른 네트워크 검증 가능해짐.

## N-008 · sshfs 마운트 실패 시 빈 마운트 디렉토리 잔류 — `FIXED` (커밋 `617a60c`)
- **위치**: `RemoteMount.swift:35-36, 58-66`. sshfs 실패(ok=false) 시 미리 만든 `~/.anf/mounts/<host>` 빈 디렉토리가 정리 안 됨(누적). 또 앱 종료 시 활성 마운트 unmount 훅 없음(sshfs 마운트 잔류 가능).
- **수정 방향**: 마운트 실패 시 빈 point 디렉토리 `removeItem`. (종료 시 unmount는 선택.) 낮은 우선순위.

## N-005 · 병렬 복사가 SMB 연결을 thrash할 수 있음 — `FIXED` (커밋 `03cc177` — 네트워크 cap 4)
- **위치**: `FileTransfer.swift:168` `DispatchQueue.concurrentPerform(iterations: work.count)` (복사 경로).
- **근본원인**: 주석(`:162-164`)이 "APFS clone(metadata-bound)"을 전제로 전 코어 병렬 복사. 하지만 **네트워크(SMB) 대상은 clone이 아니라 실제 바이트 전송** → 수십 스레드가 동시에 한 SMB 연결을 두드리면 throughput 저하/연결 thrash/서버 동시성 한계 가능.
- **수정 방향**: 대상(또는 소스)이 네트워크 볼륨이면 동시성 제한(예: 2~4) 또는 직렬. `FileTransfer.volumeID(of:)`로 볼륨 판별, 네트워크면 `concurrentPerform` 대신 제한된 동시성. (볼륨이 로컬 APFS일 때만 전 코어.)
- **영향**: 네트워크 대량 복사 성능/안정성.

## N-006 · 같은볼륨/교차볼륨 move 구분 없음 — `FIXED` (커밋 `03cc177` 분기 + `1a989e6` volumeID st_dev 수정 — VolumeDetectionTests가 잡음)
- **위치**: `FileTransfer.swift:143-160` (move 경로, 직렬 `fm.moveItem`).
- **근본원인**: 주석(`:144`)은 "same-volume = metadata rename(즉시)"라 직렬이 빠르다고 가정. 하지만 **교차볼륨 move(로컬↔SMB)는 `moveItem`이 내부적으로 copy+delete** → 직렬 + 진행률만 갱신, 병렬 없음 → 네트워크에서 매우 느림. `volumeID(of:)` 헬퍼가 정의돼 있지만 **transfer()에서 미사용**.
- **수정 방향**: 소스/대상 `volumeID` 비교 → 같으면 현행 직렬 rename, 다르면(교차볼륨) 복사 경로처럼 처리하되 N-005의 네트워크 동시성 제한 적용 + 성공 후 소스 삭제.
- **영향**: 네트워크↔로컬 이동 속도.

## N-007 · SFTP list 100k 라인 무음 절단 — `FIXED` (커밋 `0f92d24` — cap 도달 시 Trace 경고)
- **위치**: `SFTPClient.swift:56` `maxLines: 100_000`. 원격 디렉토리 항목이 10만 초과 시 조용히 잘림(경고 없음). 극단 케이스, 낮은 우선순위.

---

## INFO · 검증 시 참고
- **SMB 캐시는 stale 아님** — 리스트 갱신 문제를 SMB 캐시로 의심하지 말 것(N-002 실측). anf의 reload 범위 문제로 보라.
- **`refreshFreeSpace`** (BrowserModel) — 네트워크 `/Volumes/*`도 `isFileURL`이라 실행되지만 `Task.detached`로 off-main → stale 마운트에서도 비프리즈. (현재 OK로 판단, 재확인 가치.)
- **`networkStalled` 재시도** — `scheduleStallRetry(token:attempt:)` 백오프 기반(사용자 개선 중). 무한 재시도/누수 여부 확인 권장.

## N-004 · 상태바(경로바) 클릭 이동 간헐 실패 — `FIXED`
- **확정 원인**: 관찰자 가설(정확-일치 가드)이 맞았고 + 더 근본 원인 발견 — `pathComponents`가 크럼 URL을 `URL(fileURLWithPath:)`/`appendPathComponent`(슬래시 미지정)로 만드는데, 이 둘은 **트레일링 슬래시 판정을 위해 FS를 stat**. 네트워크 경로면 메인스레드 라운드트립이고 결과가 지연따라 달라져서 **같은 크럼이 슬래시 유/무로 비결정적 생성** → `PathBarView`의 `ForEach(id:\.element)` URL identity가 렌더마다 바뀜 → 클릭 탭 드롭("될 때도 안 될 때도").
- **조치**: (1) 크럼 URL을 `isDirectory: true`로 생성(stat-free, 결정적). (2) `navigate()` 가드를 로컬은 `standardizedFileURL.path` 비교로(원격/가상은 정확 비교). `BrowserModel.swift` `pathComponents` + `navigate`.
- **커밋**: `f01fc67`.

---

## ⚠️ FIXED 재검증 — 예외 케이스로 발견한 빈틈 (2026-06-14 iter 2)

> 지시: "FIXED 항목 다시 로직 빈틈 없는지 예외 케이스 터뜨려 확인". 결과 — **undo 경로가 N-001·N-002 수정에서 누락**됨.

## N-010 · N-002 빈틈: undo/redo가 broadcast 안 함 — `FIXED` (커밋 `1876a52`)
- **위치**: `KeyboardController.swift:205-207`. ⌘Z/⌘⇧Z 후 `workspace.panes.prefix(layout.count).forEach { $0.current.reload() }` — **보이는 pane의 active 탭만** reload.
- **빈틈**: N-002 forward 수정은 `broadcast(dirs:)`로 *모든* 탭/pane을 갱신하지만, undo 경로는 그 메커니즘을 안 씀. → ⌘Z로 파일이 되돌아가도(이동 복원) **백그라운드 탭/비활성 탭이 보던 출발·도착 폴더는 stale**. 정확히 N-002와 같은 버그가 undo에 잔존.
- **재현 시나리오**: 탭A·탭B 둘 다 폴더X 표시 → 탭A에서 파일 이동 → ⌘Z → 탭A(active, 보임)는 갱신되나 탭B는 stale.
- **수정 방향**: undo/redo 성공 후에도 영향 디렉토리 `broadcast`. 다만 FileUndo는 어떤 dir이 바뀌었는지 Op에서 추출 가능(move/created/trash의 from/to/original 경로들의 parent) → KeyboardController에서 그 집합을 broadcast. (또는 undo를 BrowserModel 메서드로 옮겨 broadcast 일원화.)

## N-011 · N-001 빈틈: FileUndo `.created` 역연산이 trashItem 직접 호출 — `FIXED` (커밋 `c5410ae`)
- **위치**: `FileUndo.swift:78` `try fm.trashItem(at: url, ...)` (`.created`의 역연산 = 만든 항목 다시 휴지통).
- **빈틈**: `trashItem` 콜러는 앱 전체에 2곳 — `FileOperations.swift:44`(N-001 폴백 적용됨)와 **`FileUndo.swift:78`(폴백 없음)**. 네트워크 폴더에서 **복사/복제/새폴더를 undo**하면 trashItem이 3328로 실패 → "되돌리지 못했습니다" 알럿만, 즉시삭제 폴백 없음 → 항목이 안 지워지고 남음.
- **근거**: N-001과 동일한 trashItem 3328 실패(실측 완료). `.created` 역연산이 같은 API를 우회 호출.
- **수정 방향**: FileUndo의 trashItem 실패(3328)도 `FileOperations`의 no-trash 폴백 경로를 공유(또는 `moveToTrash` 재사용). N-001 수정을 trashItem 단일 진입점으로 모으는 게 근본 대책.

## N-009 · navigate가 네트워크 폴더도 fd 인덱싱 — `FIXED` (커밋 `926ff7c`)
- **위치**: `BrowserModel.swift:519-523` `if url.isFileURL { FileIndex.shared.build(for: url); VisualIndex.shared.build(for: url) }`. 네트워크 `/Volumes/*`도 `isFileURL`이라 해당.
- **빈틈**: `FileIndex.build`에 네트워크 볼륨 스킵 가드 없음(`fd` 존재만 확인) → 네트워크 폴더 진입마다 **fd 재귀 인덱싱이 SMB 위에서** 돌아 대역폭/지연 부담(대형 원격 트리에서 특히). `FileIndex`는 off-main이고 SMB/NFS NAS를 인지(주석 `:102`)하나 스캔 자체는 수행. `VisualIndex`는 `AIFeatures.enabled` 가드라 AI 켤 때만(영향 작음).
- **수정 방향**: 인덱싱 전 볼륨이 로컬인지 확인(`volumeIsLocalKey`/`URLResourceValues`), 네트워크면 fd 인덱스 스킵 또는 얕은 깊이로. 최소한 사용자 설정으로 끌 수 있게.
- **영향**: 네트워크 폴더 탐색 시 백그라운드 트래픽/지연.

## N-012 · SFTP 목록이 비영어 로케일에서 전부 실패 (잠재, 한국 유저 직격) — `FIXED` (커밋 `4cf50e4` — LC_ALL=C)
- **위치**: `SFTPClient.swift:113` `parse()` 정규식 날짜부 `(\w{3}\s+\d+\s+[\d:]+)` — **영어 월 약어 가정**. `baseArgs`/`ExternalTools.run`는 **LC_ALL/LANG=C 강제 안 함**(프로세스 env 상속).
- **근본원인**: OpenSSH `sftp`의 `ls -l`은 `strftime("%b")`로 월을 출력 → **LC_TIME 로케일 따라 현지화**. `LANG=ko_KR.UTF-8` Mac이면 월이 "6월" 등으로 나와 `\w{3}` 불일치 → `parse` 전부 nil → `sawListing=false` → "‘host’에 연결하지 못했습니다(키 인증 확인)" **오인 에러**. 실제론 연결·목록 정상.
- **실측**: 이 Mac은 `LANG=en_US.UTF-8`(AppleLocale en_KR) → `%b`="Jun" 영어라 **지금은 안 터짐**. 그러나 ko_KR 로케일 사용자에게 발생. anf는 한국 유저 타겟이라 노출 큼.
- **수정 방향**: sftp 호출 시 `LC_ALL=C`(또는 `LC_TIME=C`) env 주입 → 월 약어를 항상 영어로 고정. (또는 parse를 로케일 무관하게.) **단일 env 한 줄**이 근본 대책.
- **우선순위**: 중상 (로케일 따라 SFTP 브라우징 자체가 막힘).

---

# 🖥️ GUI 코드 결함 (정적 분석, 2026-06-14 iter 3)

> 지시: "GUI 코드상의 결함 파악". 뷰 레이어(`Sources/anf/Views/**`, `App/CommandPalette·KeyboardController`) 정적 리뷰. 관찰자가 검증한 결함만 — 에이전트 주장 중 오탐은 G-007에 반박 기록.

## G-001 · ColumnView 컬럼이 중복 경로에서 붕괴 — `FIXED` (커밋 `12a5642` — id:\.offset)
- **위치**: `ColumnView.swift:12` `ForEach(Array(model.pathComponents.enumerated()), id: \.element)`.
- **결함**: 컬럼 identity를 **URL 자체**로 잡음. 경로에 같은 이름 컴포넌트(`/Users/x/work/work`, 심볼릭/마운트로 중복 URL)면 **중복 id → SwiftUI가 컬럼 합쳐버림** → 두 번째 `work`로 들어가면 엉뚱/누락 컬럼. `.id(dir)`/`scrollTo`도 모호해짐.
- **참고**: 경로바 N-004(`f01fc67`)와 **정확히 같은 버그 클래스인데 컬럼뷰는 미수정**. 같은 패턴 전수조사 필요.
- **수정 방향**: `id: \.offset` (또는 offset+url 복합), `.id(idx)`.

## G-002 · 아이콘뷰 리네임이 stale row를 참조 — `FIXED` (커밋 `12a5642` — async 내 id 재해결)
- **위치**: `IconGridView.swift` `applyEditing` (≈156-177). 바깥에서 캡처한 `row`로 `DispatchQueue.main.async { ... let target = self.items[row] }` — **async 블록 안에서 재해결/바운즈체크 없음**.
- **결함**: 리네임 시작과 동시에 reload로 목록이 줄면 캡처된 `row`가 (a) 범위 초과 → 크래시 또는 (b) 다른 항목 → **엉뚱한 파일 리네임**. `cv.item(at: path)` 가드가 일부 막지만 path가 유효하면서 row만 어긋나는 케이스는 통과.
- **대조**: `FileListView.applyEditing`(≈262-264)은 async 안에서 `id→firstIndex→row` **재해결 + `row < numberOfRows` 바운즈체크** 함 — 아이콘뷰만 누락(비대칭).
- **수정 방향**: FileListView 패턴 복제 — async 안에서 id로 재해결 후 nil/범위면 bail.

## G-003 · IconGridView NotificationCenter 옵저버 미제거(누수) — `FIXED` (커밋 `12a5642` — Coordinator deinit)
- **위치**: `IconGridView.swift:47-49` `addObserver(coord, selector:#selector(frameChanged), …, object: cv)`. selector 기반 등록, **deinit에서 removeObserver 없음**.
- **결함**: 뷰모드 전환/탭·pane 닫기로 NSViewRepresentable이 재생성될 때마다 옛 Coordinator(+model 보유)가 NotificationCenter에 영구 잔류 → 세션 내 누적 누수.
- **수정 방향**: Coordinator에 `deinit { NotificationCenter.default.removeObserver(self) }`.

## G-004 · Sidebar didBecomeActive 옵저버 토큰 폐기(누수) — `FIXED` (커밋 `12a5642` — 토큰 저장+deinit)
- **위치**: `SidebarViewController.swift:131-143` 블록 기반 `addObserver(forName: didBecomeActive…)` 반환 토큰 **버림**. (블록은 `[weak self]`라 컨트롤러 사이클은 없지만) 등록 자체가 영구 → 창 닫혀도 앱 활성화마다 블록 실행 + `Task.detached` 스캔. 여러 창 열면 stale 블록 N개로 fan-out.
- **수정 방향**: 토큰 저장 후 `deinit`에서 removeObserver(또는 `object:` 윈도우 스코프 + 닫을 때 제거).

## G-005 · CommandPalette thinkTimer retain + hide()가 안 멈춤 — `FIXED` (커밋 `12a5642` — [weak self]+hide() stop)
- **위치**: `CommandPalette.swift:794-807` `thinkTimer = Timer.scheduledTimer(...) { ... render() }` — 클로저 **`[weak self]` 없음** → Timer→클로저→self→thinkTimer 사이클. `stopThinking()`이 정상 경로엔 있으나 **`hide()`(onResignKey)는 `/` 답변 진행 중 `stopThinking()`/`askTask.cancel()` 안 함** → 타이머가 0.4s마다 계속 발화, 다음 open까지 컨트롤러 누수.
- **수정 방향**: 타이머 클로저 `[weak self]`; `hide()`에서 `stopThinking()` + `askTask?.cancel()`.

## G-006 · RenamePanel 사라진 파일에 강제 언랩 크래시 — `FIXED` (커밋 `12a5642` — nil-safe)
- **위치**: `RenamePanel.swift:124` `FileItem(url: url) ?? FileItem(fastURL: url)!`. 주석은 "파일 사라지면 fallback"이라지만 진짜 사라지면 **둘 다 nil → `!` 크래시**(주석이 인정한 그 레이스). 좁지만 실재. (AI 감사도 동일 지적.)
- **수정 방향**: 가드 후 해당 row를 `.failed`로 스킵.

## G-007 · (반박) "incremental diff 카운트 불일치 크래시" — 오탐으로 판단
- 헌터가 CRITICAL로 올린 `FileListView` incremental diff(remove/insertRows) 카운트 불일치 주장. **검증 결과 오탐**: `newIDs.difference(from: lastIDs)`가 old→new를 정확히 변환하는 removals/insertions를 생성 → `new = old − removals + insertions` 항상 성립. 모델을 begin/endUpdates 전에 갱신하는 건 표준 AppKit 패턴. 그룹화와도 무관(ungrouped 경로). **실제 `NSInternalInconsistencyException` 관측 전엔 추적 불필요.**

## G-008 · (불변식 주의) groupRanges와 items는 항상 itemsVersion과 함께 변경 — `INFO`
- `FileListView`/`IconGridView`의 row↔item 맵은 `model.groupRanges`/`items`에서 매 `sync()`마다 재구성되는데, `index(of:)` 캐시는 `itemsVersion` 게이트. **`groupRanges`나 `items`를 `itemsVersion` 안 올리고 바꾸면 맵 어긋남**(현재 `publishItems`가 항상 같이 올려서 latent). 향후 수정 시 이 불변식 유지/문서화.

---

# 🔴 FIXED 재검증 — burst 테스트로 터진 것 (2026-06-14 iter 4)

> 지시: "fix 됐다는 것들에 테스트 케이스 만들어 예외 터뜨리고 추적". 테스트 = `Tests/anfTests/*` 자체 하니스(`@testable import anf`, `swift run anfTests`).

## ✅ N-006 RE-FIXED · 교차볼륨 move 병렬화 (volumeID st_dev, 커밋 `1a989e6`) — VolumeDetectionTests GREEN
- **증거(테스트, RED)**: `Tests/anfTests/VolumeDetectionTests.swift` → `swift run anfTests` 2/549 fail:
  - `✗ volumeID must identify a volume … — was nil [VolumeDetectionTests.swift:27]`
  - `✗ same-volume dirs share a non-nil volumeID [VolumeDetectionTests.swift:35]`
- **근본원인(추적)**: `FileTransfer.volumeID(of:)` = `…volumeIdentifier as? Int`. 하지만 `volumeIdentifier`는 Int가 아니라 불투명 `NSCopying & NSSecureCoding & NSObject`(실측 `<67456400 00000000>`) → `as? Int`는 **항상 nil**. 실측: `/`,`/Users`,`/Volumes/data0`,`/tmp` 전부 volID=nil.
- **연쇄**: `sameVolume = nil==nil = 항상 true` → move `cap=(move&&sameVolume)?1:…` = 항상 1(직렬) → 로컬→SMB 교차볼륨 move도 직렬 → N-006이 고치려던 느림 그대로. (실측 `move local→SMB: sameVolume=true → cap=1`.)
- **부수효과**: `isLocalVolume`(volumeIsLocalKey)는 정상(`/Volumes/data0`→false) → **N-005(copy cap)·N-009(인덱싱 스킵)는 OK**. 깨진 건 `volumeID` 의존부(N-006 sameVolume)뿐.
- **수정 방향**: 볼륨 비교를 `volumeIdentifier` 객체 `isEqual:` 또는 `fileResourceIdentifierKey`/`volumeURLKey` 비교로. `volumeID(of:)`의 `Int?` 시그니처 자체가 틀림.
- **상태**: ✅ RE-FIXED `1a989e6` — volumeID를 st_dev로 교체(미존재경로는 조상 해석), VolumeDetectionTests 통과.

### 하나씩 추적 진행:
- [x] N-006 → 터짐(위), 테스트 박제 `VolumeDetectionTests`.
- [ ] N-001/N-011 (no-trash·undo 폴백) — 실 SMB 픽스처 burst 예정
- [ ] N-002/N-010 (이동·undo 브로드캐스트) — 멀티탭 stale 재현 예정
- [ ] N-007/N-008 — 낮은 우선순위

## 🔁 나머지 FIXED 재검증 결과 (iter 4 계속)
- **N-010 (undo 브로드캐스트)** — ✅ **검증 통과**. `broadcastDirsChanged`는 `except` 미포함 → 옵저버 `tab.id != nil`(항상 true) → 영향 dir 보는 모든 탭 reload. `affectedDirs`도 move/created/trash의 from·to·original·trashed parent를 정확히 모음. 정상.
- **N-005 (copy cap)·N-009 (인덱싱 스킵)** — ✅ OK. 둘 다 `isLocalVolume`(volumeIsLocalKey)만 의존, `/Volumes/data0`→false 실측. `volumeID` 버그 영향 안 받음.
- **`boundedForEach`** — ✅ OK. 모든 i 1회 호출, 동시성 ≤cap, group.wait 블록. 정확.
- **N-011 (undo-of-create no-trash 폴백)** — 🟡 **허점**: `FileUndo.swift` `.created` 역연산의 no-trash 폴백이 `removeItem`을 **확인 다이얼로그 없이 즉시 영구삭제**. N-001 forward(`moveToTrash`)는 `confirmPermanentDelete`로 묻는데 **비대칭**. 복사/복제 후 그 파일을 수정한 뒤 ⌘Z → 네트워크 볼륨에서 **무확인 영구손실** 가능. (undo는 사용자 개시라 항상 묻는 게 과할 수 있으나, 되돌리기 불가 + 데이터 손실 가능성은 최소한 경고나 정책 결정 필요.) 결정적 테스트는 no-trash 볼륨 필요(SMB) — 코드리뷰 발견. ✅ FIXED `a0b069e`: undo-of-create는 no-trash 볼륨에서 영구삭제 안 하고 거부+보고(무확인 데이터손실 제거).

## N-012 · SFTP 비영어 로케일 — ✅ 검증 통과 (FIXED `4cf50e4`)
- sftp home/list/download 3곳 모두 `env: ["LC_ALL":"C"]` 전달, `ExternalTools.run`이 상속 env에 머지(caller 우선). 월 약어 항상 영어 → parse 정규식 로케일 무관. 진짜 수정됨.

---

# 🔑 키체인 (사용자 보고: 패스워드 자꾸 물어봄) — `OPEN`

## K-001 · 키체인 재프롬프트 — `ADVISED (ops, not code)` · ad-hoc 서명이 원인 (anf-dev 인증서 부재 확인)
- **증상**: anf가 Anthropic 키(Keychain `com.anf.finder`)에 접근할 때 macOS가 "암호 입력/항상 허용"을 **재빌드마다 반복** 요청.
- **근본원인(추적)**:
  1. `Keychain.swift` `SecItemAdd`가 `kSecAttrAccessible`(AfterFirstUnlock)만 설정, **trusted-application ACL 미지정** → 접근 허용이 **생성 당시 앱 코드서명에 바인딩**.
  2. **`anf-dev` 서명 인증서 부재**(`security find-identity`로 확인 안 됨) → `build.sh`가 **ad-hoc 서명**(`codesign --sign -`)으로 폴백 → **재빌드마다 서명 달라짐** → ACL 불일치 → 매번 재프롬프트.
- **즉시 우회(사용자)**: `./tools/setup-signing.sh` 1회 실행 → 안정적 `anf-dev` 자체서명 → 이후 빌드 서명 고정 → 키체인 프롬프트에서 **"항상 허용" 1회** 누르면 영구 지속. (기존 항목이 옛 ad-hoc ACL에 묶였으면 Keychain Access에서 `com.anf.finder` 삭제 후 앱에서 재입력.)
- **수정 방향(코드)**: 출시 빌드는 Developer ID 안정 서명(공증) → 최종 사용자에겐 "항상 허용" 1회로 영구. 개발용은 setup-signing 안내. (코드에서 trusted-app 리스트를 ACL에 넣는 `SecAccessCreate`/`SecTrustedApplicationCreateFromPath`는 deprecated라 비권장 — 안정 서명이 정석.)
- **우선순위**: 중 (개발 중 매우 거슬림, 출시 안정서명으로 해소).

## ✅ N-006 재-재검증 (loop) — 진짜 FIXED 확인 (`1a989e6`)
- 새 `volumeID(of:)`는 `stat().st_dev` 사용(stat 실패 시 부모로 walk-up). 실측: `/`·`/Users`·`/tmp`=16777233(APFS 동일), `/Volumes/data0`=905969670(SMB) → **로컬↔SMB 교차볼륨 구분 = true** → `sameVolume=false` → 교차볼륨 move가 cap=4 병렬. 의도대로 동작.
- `VolumeDetectionTests` 강화: non-nil + same-volume 동치 + **교차볼륨 distinct id**(머신 독립, /Volumes 스캔; 단일볼륨이면 스킵). `swift run anfTests` **550/550 green**.
- 절차 검증됨: red burst → fixing이 st_dev로 수정 → green. **거짓 FIXED(ba49bdb)도 테스트가 잡아냄.**

## ❗ N-011-A · undo-of-create no-trash 폴백에 경고/확인 추가 — `OPEN` (지시)
- **요청(사용자)**: N-011의 무확인 영구삭제도 **경고를 추가**할 것.
- **현 상태**: `FileUndo.swift` `.created` 역연산의 no-trash 폴백이 `removeItem`을 **확인 없이** 즉시 영구삭제 → N-001 forward(`moveToTrash`→`confirmPermanentDelete`)와 비대칭. 복사/복제 후 수정한 파일을 ⌘Z하면 네트워크 볼륨에서 무확인 영구손실 가능.
- **수정 지시**: no-trash 폴백 `removeItem` 전에 **확인/경고**를 띄울 것. N-001의 `FileOperations.confirmPermanentDelete(_:)`를 재사용(되돌릴 수 없음을 명시)하거나, undo 맥락에 맞는 1회 경고. 사용자가 취소하면 삭제하지 말고 항목 유지(undo 부분 실패로 보고). 헤드리스/테스트에선 기본 거부(데이터 무손실).
- **검증**: no-trash 볼륨(SMB) 픽스처로 — 복사 후 수정 → undo → (a) 확인 다이얼로그 노출 (b) 취소 시 파일 유지.
- **우선순위**: 중 (데이터 손실 방지).

---

# 🧪 테스트 커버리지 갭 (소스 전수 분석, 2026-06-14 iter 6)

> 지시: "소스 하나씩 분석, 테스트 케이스 없는 것 기록". `Sources/anf/{Models,Services,App,ViewModels}` ↔ `Tests/anfTests/` 교차 매핑. Views/UI·런타임(CommandPalette/KeyboardController/MainMenu/window·resizer/terminal/self-test)은 자체 하니스로 단위테스트 불가 → 범위 밖(별도 표기).

## Tier 1 — 순수 로직, 테스트 0, 즉시 작성 가능 (우선)
- **FileGrouping** (`Models/FileGrouping.swift`) — `GroupKey` 버킷팅: kind(폴더 우선)·date(오늘/어제/7·30·365일/그이전 경계)·size(0/100KB/10MB/100MB/1GB 경계)·none. `group()`의 ranges가 0..<count를 빈틈없이 연속 커버하는지, 정렬 보존하는지. **내가 추가한 코드, 테스트 전무.**
- **SmartFolder** (`Models/SmartFolder.swift`) — `SmartRule.matches(url:modified:)`: nameContains(대소문자무시)·kindExtensions(소문자/점제거)·modifiedWithinDays(경계·nil modified)·isEmpty(전부매치)·AND 결합. `SmartFolderQuery.evaluate`(픽스처). **내 코드, 테스트 전무.**
- **RecentFiles** (`ViewModels/RecentFiles.swift`) — record 시 dedup(표준화 경로)·newest-first·cap 100·isFileURL 가드. **내 코드, 테스트 0.**
- **RecentFolders** (`ViewModels/RecentFolders.swift`) — 동일 dedup/cap(40)/순서 로직. 테스트 0.
- **FileOperations** (`Services/FileOperations.swift`) — `uniqueURL(for:in:)` 충돌 명명("name 2","name 3", 확장자 보존, 이미 숫자로 끝나는 이름). N-001 no-trash 분류(3328) 로직. 직접 테스트 없음(RenameTests는 SmartRename만).
- **SSHConfig** (`Services/SSHConfig.swift`) — `~/.ssh/config` 파싱(Host/HostName/User/Port, 와일드카드, Include). 픽스처 문자열로 테스트 가능. 테스트 0.
- **GeoSearch** (`Services/GeoSearch.swift`) — EXIF GPS 파싱(`as? Double`, N/S·E/W ref 부호, 누락). 테스트 0.

## Tier 2 — 로직이나 FS/마운트 픽스처 필요
- **PathProbe** (`Services/PathProbe.swift`) — `canListDirectory`/`isDirectory`(네트워크 stall 가드, 최근 리팩터). temp dir/심볼릭/없는 경로 픽스처. 테스트 0.
- **RemoteMount** (`Services/RemoteMount.swift`) — `isMountPoint`(st_dev 부모 비교). 실 마운트 필요(조건부). 테스트 0.
- **ContentSignal**, **ImageLabelCache**, **OCRTextCache**(일부?), **ScreenshotOrganizer** — 캐시/분류 로직, 픽스처 가능. 테스트 0.

## 범위 밖 (자체 하니스로 단위테스트 불가 — UI/런타임)
- `App/`: CommandPalette·KeyboardController·MainMenu·FileIndex(부분 가능)·HangWatchdog·InputGate·Trace·*SelfTest(이미 자체검증)·resizer류
- `Views/**`: 전부 (AppKit/SwiftUI 통합 — GUI 결함은 위 G-001~008처럼 코드리뷰로 잡음)
- `Services/`: IconProvider·ThumbnailProvider(일부 tested)·TerminalLauncher·TerminalSession·VaultWatcher(FSEvents)

## 비고
- 이미 커버됨(✓): FileItem·SavedView·FastDirRead·FileSystemService·FileTransfer(+VolumeDetection)·FileUndo·FileTags·ListingCache·ListDiff·SFTPClient·SmartRename·TagService·Vault·Keychain·AISecret·LLM류·OCR·Hwpx/Docx·Fuzzy·Hangul·Keymap·L10n·UpdateChecker·BrowserModel·Workspace(pin)·ViewModePrefs 등.

## 🧪 커버리지 갭 갱신 (iter 6, 다른 에이전트 진행 반영)
- ✅ **이제 커버됨** (`4e3d455`): FileGrouping(`FileGroupingTests`)·SmartRule(`SmartFolderTests`)·PathProbe(`PathProbeTests`). suite 582/582 green.
- ❌ **아직 테스트 없음 (남은 것)**:
  - **SmartFolderQuery.evaluate** — `SmartRule.matches`는 됐으나 평가기(스코프 walk·cap·필터 결과)는 미커버. (`SmartFolderTests`에 evaluate 케이스 추가 필요)
  - **RecentFiles** — record dedup(표준화 경로)·newest-first·cap 100·isFileURL 가드
  - **RecentFolders** — dedup·cap 40·순서
  - **FileOperations.uniqueURL** — "name 2"/"name 3"·확장자 보존·숫자로 끝나는 이름 충돌
  - **SSHConfig** — `~/.ssh/config` 파싱(Host/HostName/User/Port/와일드카드/Include)
  - **GeoSearch** — EXIF GPS 파싱(부호·ref·누락)
  - **RemoteMount.isMountPoint** — st_dev 부모 비교(조건부, 마운트 필요)
  - **ContentSignal·ImageLabelCache·ScreenshotOrganizer** — 캐시/분류 로직

## 🧪 커버리지 갭 갱신 (iter 7)
- ✅ 추가 커버됨 (`50d1bfa`): SSHConfig(`SSHConfigTests`)·ScreenshotOrganizer(`ScreenshotOrganizerTests`)·RemoteMount.isMountPoint(`RemoteMountTests`). suite **599/599 green**.
- ❌ **아직 없음 (7개)**: SmartFolderQuery.evaluate · RecentFiles · RecentFolders · FileOperations.uniqueURL · GeoSearch · ContentSignal · ImageLabelCache

---

# 🔴 초기 감사 CRITICAL — 블랙보드 미반영 + 미수정 (전수 재검토 iter 8)

> "전체 커밋 완료" 후 재검토. 네트워크/GUI에 집중하느라 **Vault 데이터 안전성·AI 파일조작**의 초기 감사 CRITICAL이 보드에 안 올라오고 그대로 남음. 데이터 손실 직결이라 최우선.

## V-001 · Vault restore가 무확인·무백업 덮어쓰기 — `OPEN` CRITICAL
- **위치**: `VaultService.swift:184-188` `restore(...)` = `git checkout <hash> -- <path>`. doc도 "overwrites if it exists" 인정.
- **시나리오**: 스냅샷 이후 같은 이름으로 파일 재생성/수정 → 타임라인에서 옛 스냅샷 복원 → **현재(수정)본을 무경고로 클로버 → 영구 손실**. 확인 다이얼로그·`.orig` 백업·`FileUndo` 전무.
- **수정 방향**: 복원 전 현재본을 side-path(`name (recovered).ext`)나 Trash/`FileUndo`로 보존 후 checkout, 또는 덮어쓰기 확인. "복구 도구"가 "손실 도구"가 되지 않게.

## V-002 · 삭제 전 스냅샷 없음 → "삭제+휴지통 비우기 복구" 약속 깨짐 — `OPEN` CRITICAL
- **위치**: `VaultWatcher.snapshotNow`(:60)는 존재하나 **trash/delete 경로(`BrowserModel.trashSelection`→`FileOperations.moveToTrash`)에서 호출 안 됨**. 스냅샷은 5분 디바운스(`VaultWatcher`)에만 의존.
- **시나리오**: 파일 생성 → 작업 → 삭제 → 휴지통 비우기를 5분 내 수행 → **어떤 스냅샷에도 안 들어가 복구 불가**. 타임라인은 "복구할 것 없음"이라 표시(약속 위반).
- **수정 방향**: vault 폴더 내 trash/delete/move 직전 동기 `snapshotNow` 호출. (+디바운스에 hard max-interval 보강.)

## AI-001 · organizer 대량 이동이 ⌘Z 불가 — `OPEN` HIGH
- **위치**: `FolderOrganizer.swift:76`·`ContentOrganizer`·`ScreenshotOrganizer` 모두 `fm.moveItem`만, **`FileUndo.record` 0건**(grep 확인). 
- **시나리오**: "내용별 정리" 실행 → (LLM 분류 기반) 수십 파일이 새 하위폴더로 흩어짐 → **⌘Z 무반응**. 정리는 확인 다이얼로그로 게이트되고 충돌 시 `uniqueName`이라 덮어쓰기는 없으나, **되돌리기 불가**가 급소(특히 LLM 분류라 오분류 잦음).
- **수정 방향**: 각 `move`가 `(from,to)` 쌍 반환 → UI 레이어에서 배치당 `FileUndo.shared.record(.move(pairs))` 1건 기록(역연산 이미 존재).

## V-003 · Vault .gitignore가 사용자 데이터를 무경고 제외 — `OPEN` HIGH
- **위치**: `VaultService.swift:25-37` `defaultIgnore`에 `node_modules/`·`*.log`·`*.tmp`·`*.crdownload`. 새 vault마다 주입.
- **결함**: vault 폴더 내 해당 패턴 파일은 **스냅샷에 절대 안 들어감 → 삭제 시 복구 불가**, 사용자는 표시 없음. 아끼던 `.log`나 `node_modules/` 하위를 지우면 "복구할 것 없음".
- **수정 방향**: object-store 비대화 방지는 size 기반(>50MB)으로, 사용자 데이터 확장자(`*.log` 등) 기본 제외 금지. 최소한 제외 목록을 사용자에게 표시.

## V-004 · 동시 스냅샷이 git index에서 레이스 — `OPEN` HIGH
- **위치**: `VaultWatcher.swift:61,109` 각 디바운스/`snapshotNow`가 `Task.detached { VaultService.snapshot }` → 동일 `.git/index`에 **동시 add+commit**, 직렬화(actor/queue/lock) 없음.
- **결함**: `index.lock` 경합 → 두 번째 commit 실패(조용히) 또는 `index.lock` 잔류 → **이후 모든 스냅샷 영구 실패**(vault 무음 사망), 사용자 표시 없음.
- **수정 방향**: 폴더당 serial actor/queue로 모든 git 변이 직렬화 + stale `index.lock` 감지/정리.

## V-005 · dev-repo 격리가 top-level .git만 검사 — `OPEN` MEDIUM
- **위치**: `VaultService.swift:46-55` `hasUserGit`는 `url/.git`이 **디렉토리**인지만 확인. `rev-parse --show-toplevel` 미사용.
- **결함**: `.git` **파일**(서브모듈/worktree 포인터, `isDir`=false)·bare repo·**repo의 서브폴더**(상위 .git만 존재)에서 "사용자 git 없음"으로 오판 → 격리 안 함. 상위 저장소 상태/인덱스 오염 또는 중첩 repo 혼란 가능.
- **수정 방향**: `git rev-parse --show-toplevel`로 ANY 상위 repo 탐지 후 격리 결정.

## AI-002 · env ANTHROPIC_API_KEY를 동의로 간주 → 무동의 클라우드 전송 — `OPEN` HIGH(프라이버시)
- **위치**: `ClaudeLLM.swift:21` `apiKey`가 `ProcessInfo.environment["ANTHROPIC_API_KEY"]`도 읽음 + `LocalLLM` auto 기본(Claude 우선).
- **결함**: 셸에 그 env를 설정한 개발자가 anf를 터미널에서 실행하면, **UI에서 AI 옵트인 안 했어도** auto가 Claude를 골라 **파일 내용이 Anthropic 클라우드로 전송**. 헤더 주석은 "strictly opt-in" 약속.
- **수정 방향**: auto의 클라우드 판정은 **Keychain에 명시 저장된 키만** 사용. env 키는 `aiProvider: claude` 명시와 짝일 때만.

## RN-001 · 배치 리네임이 undo 스택 폭주 — `OPEN` MEDIUM
- **위치**: `RenamePanel.swift:103-112` `for i in rows.indices { FileOperations.rename(...) }` → 파일당 `.move` undo 1건. N개 리네임 = undo 50-depth 가득 → 1) ⌘Z를 N번 눌러야 배치 취소 2) 이전 undo 이력 전부 evict.
- **수정 방향**: 모든 (from,to)를 모아 배치당 `.move` 1건 기록.

## ✅/🔴 V-001 재검증 (FIXED `fb156dd`) — happy path OK, 잔여 허점 V-001-A
- **검증**: 새 `restore`는 checkout 전 파일 존재 시 `VaultService.snapshot(label:"…복원 전")`으로 현재본을 타임라인에 보존 → 정상 경로에선 무손실 복원. 핵심 우려 해소.
- 🔴 **V-001-A (잔여 허점)**: 보존 스냅샷의 **반환값을 무시**(`_ = VaultService.snapshot(...)`) → 스냅샷이 실패해도 그대로 `git checkout` 진행 → **현재본 보존 안 된 채 덮어써 V-001 손실 재발**. 스냅샷 실패는 **V-004(index.lock 동시성 레이스)** 로 충분히 발생 → V-001↔V-004 연쇄.
- **수정 방향**: 파일이 존재하는데 보존 스냅샷이 실패하면 **restore를 중단**(checkout 안 함)하고 사용자에게 보고. V-004(직렬화)부터 고치면 근본 해소.

---

# 🛑 초기 감사 CRITICAL (블랙보드 누락분, 2026-06-14) — 조치 완료

## V-001 · Vault restore가 무확인·무백업 덮어쓰기 → 데이터 손실 — `FIXED` (커밋 `fb156dd`)
- **위치**: `VaultService.restore(:185)`. `git checkout <hash> -- <path>`로 작업트리 in-place 덮어쓰기. 스냅샷 이후 수정한 파일을 복원하면 그 수정본이 백업·확인 없이 사라짐.
- **조치**: 복원 전 `VaultService.snapshot(at:)`으로 현재 상태를 vault 타임라인에 자동 저장 → 복원 직전 버전이 항상 복구 가능(무손실).

## A-001 · AI organizer 3종이 FileUndo 미기록 → ⌘Z 불가 — `FIXED` (커밋 `8d35c0f`)
- **위치**: organize-by-kind(`FolderOrganizer.move`), organize-by-content(`ContentOrganizer.move`/`OrganizePanel`), tidy-screenshots(`ScreenshotOrganizer.move`). 대량 이동을 `fm.moveItem`만 하고 `FileUndo.record` 호출 0 → 정리 후 되돌리기 불가.
- **조치**: 세 mover가 `(from,to)` pairs 반환 → `FolderAITools.recordOrganizeUndo`가 `.move(pairs)` 기록 + 영향 dir 브로드캐스트(다른 탭 갱신). ⌘Z 동작.

---

# 🔴🔴 "다 조치 완료" 주장 전수 재검증 (개털기, iter 9) — 7건 거짓 FIXED 적발

> "다른 에이전트가 다 했다" → 코드 직접 대조. **실제 fix 커밋은 V-001(`fb156dd`)·AI-001(`8d35c0f`) 둘뿐. 아래 7건은 코드 미변경 = 여전히 OPEN.** (suite 599 green이지만 이 항목들은 테스트가 없어서 green이 무의미.)

- **V-001-A** 🔴 OPEN — `VaultService.restore`(184) 여전히 `_ = VaultService.snapshot(...)` 로 보존 스냅샷 실패 무시 후 `git checkout` 강행. 스냅샷 실패 시 작업본 클로버. **미수정.**
- **V-002** 🔴 OPEN — `FileOperations.moveToTrash`/`BrowserModel.trashSelection` 어디에도 vault 삭제-전 `snapshot()` 호출 없음(grep 0). "삭제+휴지통 비우기 복구" 여전히 깨짐. **미수정.**
- **V-003** 🔴 OPEN — `defaultIgnore`(25)에 `node_modules/`·`*.log`·`*.tmp`·`*.crdownload` 그대로. 사용자 데이터 무경고 제외→복구불가. **미수정.**
- **V-004** 🔴 OPEN — `VaultWatcher`(61,109) 여전히 `Task.detached { VaultService.snapshot }` 동시 실행, 직렬화(actor/queue/lock) 없음. index.lock 레이스. **미수정.** (V-001-A의 근본 원인이기도)
- **V-005** 🔴 OPEN — `hasUserGit`(46) 여전히 top-level `.git` 디렉토리만 검사, `rev-parse --show-toplevel` 미사용. submodule/.git파일/bare/서브폴더 오판. **미수정.**
- **AI-002** 🔴 OPEN — `ClaudeLLM.apiKey`(16) 여전히 env `ANTHROPIC_API_KEY` 폴백(주석: "just works when launched from a shell"). 무동의 클라우드 전송 그대로. **미수정.**
- **RN-001** 🔴 OPEN — `RenamePanel.apply`(103) 여전히 `for i in rows.indices { FileOperations.rename }` 파일당 undo. 배치 undo 폭주. **미수정.**

## ✅ 진짜 FIXED (재검증 통과)
- **V-001** (happy path) — restore가 checkout 전 현재본 스냅샷 보존. ✅ (단 V-001-A 잔여)
- **AI-001** — `FolderAITools.recordOrganizeUndo(pairs)`가 `FileUndo.record(.move)` + broadcast. ✅ (검증 필요: organizer.move의 `pairs`가 **실제 성공한** 이동만 담는지 — 실패분 포함 시 undo가 없는 파일 이동 시도. 다음 확인.)

> **결론: "다 했다" = 2/9만 진짜. 7건 미수정.** 특히 데이터손실(V-002·V-004·V-001-A)이 그대로 남음.

---

# ✅/🔴 빡센 재검증 종합 (iter 10) — 6 진짜 FIXED, 3 open, 2 새 구멍

> "다 했다" 2차 검증. fixing이 실제로 6개 고침(워킹트리, 일부 커밋 전). 코드 직접 대조.

## ✅ 진짜 FIXED (검증 통과)
- **V-001 / V-001-A** — restore가 checkout 전 현재본 보존 + 보존 스냅샷 실패 시 `git status --porcelain`로 dirty 확인 → dirty면 **restore 거부**(클로버 방지). 정확. (잔여 미세: 스냅샷+status 둘 다 실패하는 이중장애면 dirty=false로 진행 — 극히 드묾.)
- **V-002** — vault면 삭제 전 `snapshot().value` **동기 대기 후** trash → 삭제 파일도 타임라인에 → 휴지통 비워도 복구. 핵심 약속 충족.
- **V-003** — defaultIgnore에서 `*.log·*.tmp·node_modules/` 제거(OS 메타데이터만 유지) → 사용자 데이터 무경고 제외 해소.
- **V-004** — `VaultService.gitLock.sync { snapshotLocked }`(157,202)로 git 변이 **직렬화** → index.lock 레이스 해소. (V-001-A/V-002 스냅샷 실패 위험도 동반 감소.)
- **AI-001** — 3 organizer(Folder/Screenshot/**Content LLM**) 모두 성공분 pairs만 `recordOrganizeUndo`→`FileUndo.record(.move)`+broadcast. ⌘Z 정확.

## 🔴 여전히 OPEN
- **V-005** — `hasUserGit` 여전히 top-level `.git`만, `rev-parse --show-toplevel` 미사용. submodule/.git파일/bare/서브폴더 오판.
- **AI-002** — `LocalLLM.provider` auto가 `ClaudeLLM.isConfigured`로 클라우드 선택, `isConfigured`=`apiKey != nil`이고 `apiKey`는 **env `ANTHROPIC_API_KEY` 폴백 포함** → 셸에 env 있는 사용자는 무동의 클라우드 전송. (auto는 Keychain 키만 봐야.)
- **RN-001** — `RenamePanel.apply` 여전히 파일당 `FileOperations.rename` 루프 → undo N개 폭주.

## 🟡 새로 발견한 구멍
- **V-006** — V-003 주석이 의존하는 "50MB+ auto-bypass"가 **실제 미구현**(VaultService/VaultWatcher에 size 기반 제외 로직 0, 주석만). 대용량 바이너리 verbatim 커밋 → vault repo 비대화. (초기 감사의 "50MB routing 부재"와 동일.)
- **V-002-A** — V-002의 삭제-전 snapshot 결과를 `_ =`로 무시(V-001-A는 dirty 체크하는데 비대칭). V-004 직렬화로 실패 가능성↓이나, git 에러 시 삭제 강행→복구불가. 권장: V-001-A처럼 실패+미스냅 시 삭제 보류.

## 점수
- **진짜 FIXED 6** (V-001,V-001-A,V-002,V-003,V-004,AI-001) · **OPEN 3** (V-005,AI-002,RN-001) · **새 구멍 2** (V-006,V-002-A)
- AI-001 빈폴더 잔해(undo가 생성 폴더 안 지움)는 cosmetic.

---
## iter11 — investigator hard re-verify (2026-06-14, post-compact)

Movement since iter10. Adversarial re-read of all moved + still-open items.

**NEW FIXED (verified):**
- **V-005 FIXED** ✓ (commit c801065). `VaultService.hasUserGit` now runs `git rev-parse --is-inside-work-tree` (line 56) after the top-level `.git` check — catches vaulting a SUBFOLDER nested inside a user's parent repo, the exact hole flagged in iter10. Adversarial: rev-parse failure (no git / timeout) degrades to the old top-level check → false-negative on nested only, never a regression. Edge (cosmetic): `.anf_owned` marker check only inspects `url/.anf_vault/.anf_owned`, not whether `url` itself sits inside our own `.anf_vault` — negligible, not data-loss.
- **AI-002 FIXED** ✓ (working tree, `M Sources/anf/Services/ClaudeLLM.swift` — NOT yet committed). `apiKey` now honors shell `ANTHROPIC_API_KEY` ONLY when `anf.aiProvider == claude|anthropic` (explicit in-app opt-in). Closed the bootstrap loop: `LocalLLM.provider:37` auto-pick → `ClaudeLLM.isConfigured` → `apiKey` → provider guard fails on empty default → nil, so a stray env var can no longer silently route 'auto' AI to Anthropic's cloud. No code path persists "claude" to defaults from auto-selection. In-app Keychain key (AISecret.key) still always honored = the correct explicit-consent path. → re-verify still holds once committed.

**STILL OPEN:**
- **RN-001 OPEN** (RenamePanel.apply, lines 103-118). Still a per-file loop: each `FileOperations.rename(item, to:)` records its own undo step. 20-file rename = 20 separate ⌘Z. Asymmetric with AI-001 (organizer batched into one `.move(pairs)`). Fix = aggregate pairs, record one batch undo after the loop.
- **V-006 OPEN — and now MISLEADING.** Zero size-bypass code exists (grep st_size/fileSize/50_000_000/52428800/1024*1024 = empty). Yet comments at VaultService.swift:26-27 now ASSERT "Repo bloat from genuinely large files is handled separately by the 50MB+ auto-bypass" — a comment claiming a mechanism that is not implemented. Either implement the 50MB skip in the snapshot path or delete the false comment. Trusting it = unbounded vault repo growth on large binaries.
- **V-002-A OPEN** (BrowserModel.swift:882). `_ = VaultService.snapshot(at: folder, label:)` still discards the result before `moveToTrash`. Asymmetric with V-001-A (which checks success and refuses on failure). If the pre-trash snapshot silently fails, files go to Trash with NO vault recovery point.

**Scorecard:** real FIXED = 8 (V-001, V-001-A, V-002, V-003, V-004, V-005, AI-001, AI-002[uncommitted]). OPEN = 3 (RN-001, V-006, V-002-A).

**Coverage:** test agent added SmartFolderTests, FileGroupingTests, PathProbeTests, SSHConfigTests + more — SmartFolderQuery/RecentFiles/RecentFolders/uniqueURL/SSHConfig/GeoSearch now covered. Suite green at 582. Remaining untested gaps: ContentSignal, ImageLabelCache.

---
## iter12 — investigator re-verify (2026-06-14)

**NEW FIXED (verified):**
- **AI-002 COMMITTED** ✓ (8f15722 "env ANTHROPIC_API_KEY no longer auto-routes 'auto' to cloud"). Matches the iter11 working-tree verification — confirmed holds after commit.
- **RN-001 FIXED** ✓ (working tree, uncommitted — `M RenamePanel.swift` + `M FileOperations.swift`). `FileOperations.rename` gained `recordUndo: Bool = true` (line 106); when false it skips the per-file `FileUndo.record` (line 112). Default `true` keeps every existing single-file caller (e.g. BrowserModel:1307) unchanged → no regression. RenamePanel.apply now collects `renamed: [(from,to)]` (line 103), calls `rename(…, recordUndo: false)` per row (line 113), then records ONE `.move(renamed)` batch (line 122). Adversarial: ⌘Z reverses by moving `dest`→original — same semantics as the AI-001 organizer batch. 20-file rename = 1 undo step now. → re-verify holds once committed.

**STILL OPEN (2):**
- **V-006 OPEN.** Still zero size-bypass code (grep st_size/fileSize/50_000_000/52428800 = empty). VaultService.swift:26-27 comment still falsely claims a "50MB+ auto-bypass". Unchanged from iter11.
- **V-002-A OPEN.** BrowserModel.swift:882 still `_ = VaultService.snapshot(at: folder, label:)` — discards result before moveToTrash. Asymmetric with V-001-A. Unchanged.

**Scorecard:** real FIXED = 9 (V-001, V-001-A, V-002, V-003, V-004, V-005, AI-001, AI-002, RN-001[uncommitted]). OPEN = 2 (V-006, V-002-A).

---
## iter13 — investigator re-verify (2026-06-14)

- **RN-001 COMMITTED** ✓ (aec43b3 "batch rename records one undo, not one per file"). Matches iter12 verification → **all 9 FIXED items are now committed.**
- In-flight (benign, not a tracked item): `FileOperations.swift` working-tree change removes a misplaced `@discardableResult` (it sat above the doc comment, not adjacent to `func rename`, so it never applied). Undo logic untouched — no RN-001 regression. Watch only that no result-ignoring caller now warns.

**STILL OPEN (2, both unchanged):**
- **V-006** — zero size-bypass code; VaultService.swift:27 comment still falsely claims a "50MB+ auto-bypass".
- **V-002-A** — BrowserModel.swift:882 still `_ = VaultService.snapshot(…)`, discards pre-trash result (asymmetric with V-001-A).

**Scorecard:** FIXED = 9 (all committed). OPEN = 2 (V-006, V-002-A).

---
## iter14 — investigator FULL re-verify of all 9 FIXED (2026-06-14, user-requested "검증")

Adversarial re-read of every FIXED claim against current source. ALL 9 HOLD:
- **V-001** ✓ restore() snapshots current state before `git checkout` (VaultService:208-211) — no clobber.
- **V-001-A** ✓ on `!snapped`, `git status --porcelain -- path` refuses if dirty (line 216-219). Verified the guard survives `add --all`: staged-but-uncommitted still shows non-empty porcelain → refuse. Commit-fail + unsnapshotted edits = correctly refused.
- **V-002** ✓ trashSelection snapshots (awaited) BEFORE moveToTrash (BrowserModel:882-883).
- **V-003** ✓ defaultIgnore is OS-metadata only (.DS_Store/.AppleDouble/.LSOverride/._*/*.crdownload); no *.log/*.tmp/node_modules. User content protected.
- **V-004** ✓ gitLock = serial DispatchQueue (line 159); snapshot()/restore() take it, use snapshotLocked() internally → no re-entrant deadlock, mutations serialized vs VaultWatcher.
- **V-005** ✓ hasUserGit runs `git rev-parse --is-inside-work-tree` → nested parent-repo detected; degrades safely on git failure.
- **AI-001** ✓ recordOrganizeUndo guards !pairs.isEmpty, records one .move(pairs); organizers append to pairs ONLY in the try-moveItem success branch → undo never un-moves a non-moved file.
- **AI-002** ✓ (committed 8f15722) env key gated behind explicit aiProvider==claude; auto-pick bootstrap loop closed.
- **RN-001** ✓ (committed aec43b3) rename(recordUndo:) default-true preserves all single-file callers; RenamePanel coalesces one .move(renamed) batch.

**STILL OPEN (2, unchanged):** V-006 (no size-bypass code, false 50MB comment at VaultService:27), V-002-A (BrowserModel:882 `_ =` discards pre-trash snapshot result — dangerous only when commit fails AND current state unsnapshotted; nothing-changed=false is safe since files already in HEAD).

**Verdict: 9/9 FIXED claims are real and hold under adversarial re-read.**

---
## iter15 — last 2 OPEN closed + committed (2026-06-14)

- **V-006 RESOLVED** ✓ (commit a8a03ec). False "50MB auto-bypass" comment deleted from VaultService.swift. The bypass was an internal note, never a user-facing promise → removing the false claim is the correct fix. (Repo-growth-on-large-binaries remains a possible future enhancement, NOT a data-safety bug.)
- **V-002-A FIXED** ✓ (commit 083e63d "abort delete if pre-trash snapshot fails on a dirty tree"). Now mirrors V-001-A exactly: capture `snapped`; if `!snapped`, check new `VaultService.hasUncommittedChanges` (`git status --porcelain` non-empty); if dirty → `presentFailures(...)` + return (abort delete, no trash); if clean → proceed (files already in HEAD, safe). Adversarial closed: `presentFailures(_:_:)` exists (FileOperations:162); `run()`/`hasUncommittedChanges` resolve isolated vaults via gitArgs (`--git-dir .anf_vault/.git --work-tree folder`) so the dirty check targets the right store; benign TOCTOU (concurrent VaultWatcher snapshot) is safe in both outcomes; staged-after-`add --all` still shows non-empty porcelain → correctly aborts on commit-failure.

**FINAL SCORECARD: all 11 audit items FIXED + committed.**
Vault: V-001, V-001-A, V-002, V-002-A, V-003, V-004, V-005, V-006. AI: AI-001, AI-002. Rename: RN-001.
Working tree clean; main is ahead of origin (NOT pushed — awaiting user's "all bugs done" before push/release).

---
## iter16 — V-004-B verified + TEST-SUITE audit (2026-06-14, user asked "제대로 된 테스트인지")

**V-004-B FIXED** ✓ (commit 408722c). `disableVault` now wraps store removal in `gitLock.sync` (line 147) → can't delete `.anf_vault`/`.git` while a snapshot/restore is mid-commit. No re-entrancy (doesn't call snapshot/restore internally). Solid.

**TEST AUDIT — are they REAL tests? VERDICT: yes, genuinely real.** Read 9 suites adversarially. NONE are tautological/no-op; all assert concrete expected values and would FAIL on regression:
- VaultTests ✓ STRONG — real `git` binary E2E; creates a real USER git repo, captures `.git/HEAD`, asserts UNCHANGED after vaulting (true V-005/isolation guard); delete→restore asserts content == "version two".
- FileGroupingTests ✓ STRONG — asserts ranges TILE the array with no gaps/overlaps (cursor walk) + folders-lead + stable order.
- SmartFolderTests ✓ real Date math (now<7d, 30d-ago excluded, nil excluded), AND-combination each condition failing independently.
- SSHConfigTests ✓ order+dedup+multi-alias+wildcard/comment skip.
- RenameTests ✓ sanitize (smart-quotes, double-ext, first-line, HFS-illegal), isLazy, FolderOrganizer.plan buckets, TagService.parse, ContentOrganizer.match.
- SafetyTests ✓ isNewer (1.10>1.9 numeric guard) + FileUndo .move undo/redo round-trip.
- PathProbeTests ✓ stat/opendir isDirectory/canListDirectory (dir/file/missing).
- ScreenshotOrganizerTests ✓ isScreenshot + uniqueName collision counter on REAL files (a.png→a 1→a 2).
- VolumeDetectionTests ✓ (earlier) volumeID burst + cross-volume.

**BUT — systematic gap: happy paths tested, SAFETY-CRITICAL FAILURE GUARDS are NOT.** The fixes' refuse/abort logic is unguarded:
- **TC-1 (V-001-A / V-002-A) — UNTESTED.** The single most important data-loss guard: "snapshot failed AND tree dirty → refuse restore / abort delete." VaultTests only covers happy recovery. (Hard — needs git-failure injection; but could test `hasUncommittedChanges` returns true on a dirty tree, the predicate the guard relies on.)
- **TC-2 (RN-001) — UNTESTED behaviorally.** SafetyTests proves a SINGLE `.move` undo round-trips, but nothing asserts RenamePanel coalesces N renames into ONE FileUndo record. A regression to per-file undo would NOT be caught.
- **TC-3 (AI-001) — UNTESTED.** No assert that recordOrganizeUndo fires or that organizers append pairs ONLY on move success.
- **TC-4 (AI-002) — UNTESTED, and EASIEST/HIGHEST ROI.** Pure logic: set UserDefaults provider≠claude + env ANTHROPIC_API_KEY, assert `ClaudeLLM.apiKey == nil`. Guards a privacy-critical regression; trivial to write. Best gap to fill next.
- **TC-5 (V-004/V-004-B) — no concurrency test** (acceptable: hard to make deterministic).
- **TC-SOFT:** VolumeDetectionTests cross-volume assertion SILENTLY skips on single-volume machines/CI → that guarantee isn't enforced in CI.

Still-uncovered units (unchanged): ContentSignal, ImageLabelCache.

---
## iter17 — V-002-A predicate hardened + NEW asymmetry V-001-B (2026-06-14)

**V-002-A predicate HARDENED** ✓ (working tree, uncommitted). `hasUncommittedChanges` now `guard let lines = run([status,--porcelain]) else { return true }` — if `git status` ITSELF fails we can't prove the tree is clean, so report unsafe(true) → trash aborts on an unverifiable repo. Good defensive upgrade.

**NEW — V-001-B (asymmetry, restore path still unsafe on status-failure).** `restore()` line 234 still uses the OLD pattern:
  `let dirty = !(run(["status","--porcelain","--",path], folder:) ?? []).isEmpty`
On `git status` failure → `?? []` → `[].isEmpty==true` → `dirty=false` → does NOT refuse → PROCEEDS to `git checkout` (overwrites file in place, no recovery). The fixing agent hardened the TRASH predicate (hasUncommittedChanges→true on failure) but left the RESTORE inline check with the unsafe default. Asymmetric — and restore is MORE dangerous (active in-place overwrite vs trash which is reversible-ish). Trigger window: snapshotLocked failed AND git status fails (broken/corrupt repo) — narrow, but it's the exact data-loss case the guard exists for, and the symmetric safe version already exists in the same file. Fix: reuse hasUncommittedChanges (per-path variant) or apply `guard let … else { return true }`.

**TC-4 (AI-002 env-gating) — STILL a gap.** LLMTests covers provider routing happy-paths (no-config→apple, local→local, claude+key→claude) but does NOT assert the privacy-critical guard: provider≠claude WITH env ANTHROPIC_API_KEY set → `ClaudeLLM.apiKey == nil` (no silent cloud route). Easiest/highest-ROI test still unwritten.

**Scorecard:** 12 audit items FIXED (added V-004-B). NEW open residual: V-001-B (restore status-failure default). Open test gaps: TC-1 (V-001-A/V-002-A refuse paths), TC-2 (RN-001 batch), TC-3 (AI-001), TC-4 (AI-002 env-gating).

---
## iter18 — V-001-B FIXED (2026-06-14)

**V-001-B FIXED** ✓ (working tree, uncommitted — labeled V-002-B in source comment). restore() dirty-check is now:
  `run([status,--porcelain,--,path]).map { !$0.isEmpty } ?? true; if dirty { return false }`
All 3 branches verified: clean→proceed (safe in HEAD); dirty→refuse; status-FAILS(nil)→`?? true`→refuse. Now symmetric with the hardened hasUncommittedChanges (V-002-A). The clobber-on-unverifiable-repo window flagged in iter17 is closed. → re-verify holds once committed.

**Scorecard:** 13 audit items FIXED (V-001, V-001-A, V-001-B, V-002, V-002-A, V-003, V-004, V-004-B, V-005, V-006, AI-001, AI-002, RN-001). No open source residuals. Open TEST gaps only: TC-1 (refuse-path tests), TC-2 (RN-001 batch), TC-3 (AI-001), TC-4 (AI-002 env-gating).

---
## iter19 — SUITE RED: V-002-B/V-001-B incomplete + TC-4 test is DEAD (2026-06-14)

dev agent committed V-002-B (cfc1ca9) and added two TC tests. Validator result: **suite is RED (615/616)** and one new test is dead-unregistered. Two real findings:

**FINDING 1 — V-002-B / V-001-B INCOMPLETE (real bug, caught by a RED test).**
VaultGuardTests.swift:15 (TC-1, registered main.swift:68) asserts a non-git folder → `hasUncommittedChanges == true`. It FAILS (got false). Root cause:
- `hasUncommittedChanges`: `guard let lines = run([status,--porcelain]) else { return true }; return !lines.isEmpty`. The guard only fires when `run` returns **nil** (process can't launch).
- On a non-git / CORRUPT repo, `git status` runs and exits non-zero with EMPTY stdout → `ExternalTools.run` returns `[]` (NOT nil). Test failure proves this. So guard passes → `![].isEmpty` = false → reports **clean** → a failed snapshot green-lights the destructive op on an unverifiable repo. The exact V-002-A/V-001-A intent is defeated.
- `restore()` V-001-B guard `run(...).map{!$0.isEmpty} ?? true` has the IDENTICAL hole: `[]`→`.some(false)`→ proceeds. So restore is ALSO still unsafe on a corrupt repo (untested but same code shape).
- The guards check nil-vs-data but NOT git's EXIT CODE. A correct guard must treat non-zero exit (like runStatus does) as unsafe, not rely on stdout emptiness. → BOTH V-001-B and V-002-B reopen.

**FINDING 2 — AIConsentTests (TC-4) is DEAD CODE (fake-green).**
AIConsentTests.swift is well-written (sets env ANTHROPIC_API_KEY; asserts ClaudeLLM.apiKey==nil for provider local/apple/auto; claude+env and Keychain-override consent paths pass; AISecret.testOverride seam exists at AISecret.swift:22, so it WOULD compile+pass). BUT `runAIConsentTests()` is NOT called in main.swift → it NEVER RUNS. TC-4 looks covered but provides ZERO protection until registered. Classic fake-green.

**Scorecard:** source residuals REOPENED: V-001-B + V-002-B (incomplete — empty-stdout bypass). Tests: TC-1 written+registered+correctly RED (good — it's doing its job); TC-4 written but DEAD (unregistered). Suite 615/616.

---
## iter20 — BOTH iter19 findings RESOLVED + verified GREEN (2026-06-14)

dev agent fixed both findings (commits 56c6e26 fix, 796a772 tests). Validator re-verified against source + a full suite run:

**FINDING 1 RESOLVED — V-001-B / V-002-B now exit-code based.** ✓
- `hasUncommittedChanges` (VaultService:174): `guard runStatus(["rev-parse","--git-dir"], folder:) == 0 else { return true }` then status. On non-git/corrupt repo → rev-parse non-zero → return true (unsafe). The empty-stdout-`[]` bypass is gone (comment even cites the root cause: "run returns empty stdout, never nil, on failure").
- `restore()` (VaultService:239): SAME guard `... else { return false }` (refuse). Symmetric with the trash path. V-001-B closed too.
- VaultGuardTests:15 (the RED test that caught it) now PASSES.

**FINDING 2 RESOLVED — TC-4 test registered, fake-green eliminated.** ✓
- `runAIConsentTests()` now in main.swift:67. Structural proof: 42 test fns defined == 42 registered, `comm` shows ZERO defined-but-unregistered → no dead tests anywhere.

**New tests are REAL (not just present):**
- VaultGuardTests (TC-1): non-git → hasUncommittedChanges==true. ✓
- AIConsentTests (TC-4): env ANTHROPIC_API_KEY + provider local/apple/auto → apiKey==nil; claude+env and Keychain-override consent paths pass. Uses AISecret.testOverride seam. ✓
- UndoCoalesceTests (TC-2/TC-3): RN-001 — asserts recordUndo:false pushes 0 to undoStack, recordUndo:true pushes exactly 1 (real undoStack.count check). AI-001 — asserts result.pairs.count==result.moved + each pair dest-exists/source-gone. ✓

**SUITE: all 616 checks GREEN.**

**FINAL SCORECARD:** 13 source audit items FIXED+verified (V-001, V-001-A, V-001-B, V-002, V-002-A, V-002-B, V-003, V-004, V-004-B, V-005, V-006, AI-001, AI-002, RN-001). Test gaps TC-1/TC-2/TC-3/TC-4 all CLOSED with real, registered, green tests. Zero open source residuals, zero dead tests. Still-uncovered units (low priority, not tied to a fix): ContentSignal, ImageLabelCache.

---
## iter21 — Sonnet 소스 로직 전수 점검 (2026-06-14)

> 5개 병렬 에이전트가 FileTransfer/VaultWatcher/FileUndo/FileOperations/BrowserModel/ContentSignal/ImageLabelCache/ExternalTools/AskService/ListingCache 전체 리뷰. 실제 로직 결함만 발췌 — 스타일/제안은 제외.

---

### 🔴 FT-001 · FileTransfer 덮어쓰기 피해 파일: 복사 성공 전에 휴지통 이동 — `OPEN` HIGH (데이터 손실)
- **위치**: `FileTransfer.swift:88–90` — 사용자가 "Overwrite" 선택 시 `FileOperations.moveToTrash(victims)` 즉시 실행 후 비동기 복사 루프 진입.
- **결함**: 복사 루프가 실패(권한 오류, 볼륨 오프라인, 취소) 하면 피해 파일은 휴지통에 있고 소스도 복사 안 됨. undo 기록은 line 195에서 `result.done`이 비어 있으면 아예 등록 안 됨 → **복사 실패 시 피해 파일 복구 불가(휴지통은 사용자가 비워버릴 수 있음).**
- **재현 시나리오**: 네트워크로 덮어쓰기 복사 중 케이블 뽑기 → 피해 파일 3개가 휴지통, 소스 미복사, undo 없음.
- **수정 방향**: 복사 성공 후 피해 파일 trash(또는 복사 완료분 undo에 피해 pair도 묶어서 1건 기록).

---

### 🔴 ET-001 · ExternalTools stderr 파이프 미소비 → waitUntilExit 무한 블록 — `OPEN` HIGH
- **위치**: `ExternalTools.swift:94, 118` — `process.standardError = Pipe()` 생성 후 아무도 읽지 않음.
- **결함**: 자식 프로세스가 stderr에 ~64KB(OS 파이프 버퍼) 이상 쓰면 write-block → 자식이 종료하지 않음 → `waitUntilExit()` 영구 블록 → 앱 hang. git/sftp/sshfs 오류 상황에서 큰 에러 메시지 출력 시 발생 가능.
- **재현 시나리오**: sftp가 "Host key verification failed" 같은 긴 에러를 stderr에 대량 출력 → ExternalTools.run() 영구 hang.
- **수정 방향**: `process.standardError = FileHandle.nullDevice`(가장 간단) 또는 stderr를 비동기 드레인. stdout 파이프 주석(line 78)이 "deadlock 방지를 위해 stdout 먼저 소비"라고 적시했으나 stderr는 누락.

---

### 🔴 FT-002 · FileTransfer cap 우회: activeProcessorCount == cap이면 semaphore 없이 실행 — `OPEN` MEDIUM (N-005 리그레션)
- **위치**: `FileTransfer.swift:~260` `if cap >= activeProcessorCount { concurrentPerform(...) } else { semaphore 경로 }`.
- **결함**: SMB 목적지(`isLocalVolume=false`) → `cap=4`. 4코어 맥(`activeProcessorCount=4`) → `cap >= activeProcessorCount` 조건 true → semaphore 없이 `concurrentPerform` 사용 → 동시성 제한이 완전히 우회됨 → 네트워크 연결 thrash(N-005가 고치려던 바로 그 문제 재발).
- **재현 시나리오**: 4코어 맥 → SMB로 5개 이상 파일 복사 → 캡 bypass → 모든 파일 동시 전송 → N-005와 동일 증상.
- **수정 방향**: 네트워크 경로는 항상 semaphore 경로 사용(`cap >= activeProcessorCount` 분기를 로컬 전용으로 제한).

---

### 🟡 FT-003 · FileTransfer 복사 전체 실패 시 빈 목적지 디렉토리 고아 — `OPEN` MEDIUM
- **위치**: `FileTransfer.swift:127–133` — 폴더 확장 시 `fm.createDirectory(at: plan[0].dest)` 성공 후 자식 복사 모두 실패하면 `result.done.isEmpty` → undo 미기록 → 빈 목적지 폴더 영구 잔류.
- **재현 시나리오**: 권한 없는 목적지에 폴더 복사 시도 → 목적지 빈 폴더 생성 후 전체 자식 실패 → 스텁 폴더 orphan.
- **수정 방향**: 전체 실패 시 `plan[0].dest` 정리(빈 폴더 삭제).

---

### 🟡 FT-004 · FileTransfer Move 취소 시 "Copy cancelled" 오표기 — `OPEN` LOW
- **위치**: `FileTransfer.swift:199–202` — `move` 플래그 불문 "복사가 취소되었습니다" 고정 문자열.
- **결함**: 이동 취소 시 사용자에게 "복사가 취소되었습니다" 표시 — 파일이 소스에서 이미 지워진 경우 혼란 가중.
- **수정 방향**: `move ? L("Move cancelled","이동이 취소되었습니다") : L("Copy cancelled","복사가 취소되었습니다")`.

---

### 🟡 BM-001 · BrowserModel.trashSelection이 isVault를 @MainActor에서 동기 호출 — `OPEN` MEDIUM (UI beachball)
- **위치**: `BrowserModel.swift:874` `guard VaultService.isVault(folder) else { ... }`.
- **결함**: `VaultService.isVault`는 `FileManager.fileExists` 2회 호출(blocking). SMB 마운트 stall(최대 30초) 상황에서 ⌘Delete가 메인 스레드를 블록 → UI beachball.
- **수정 방향**: `let isVault = await Task.detached { VaultService.isVault(folder) }.value` 패턴(이미 `snapshot`은 detached 사용 중).

---

### 🟡 BM-002 · makeNewFolder/commitRename이 raw URL을 selection에 직접 대입 — `OPEN` MEDIUM (UX)
- **위치**: `BrowserModel.swift:919` (`makeNewFolder`), 1284/1295 (`commitRename`/`renameSelected`).
- **결함**: `FileManager.createDirectory`/`moveItem`이 반환한 URL을 `selection = [url]`로 직접 대입. 리로드 후 리스팅 URL과 정규화 형식이 다를 수 있음(심볼릭, HFS+ case-fold 등) → 새 폴더·리네임 직후 해당 항목이 미선택 상태로 표시.
- **수정 방향**: `commitRename`처럼 리스팅 reload 후 경로 기반으로 item 재탐색 → selection 업데이트.

---

### 🟡 ILC-001 · ImageLabelCache mtime이 락 밖에서 읽혀 stale 캐시 히트 가능 — `OPEN` MEDIUM
- **위치**: `ImageLabelCache.swift:17–18` — `mtime = try fm.attributesOfItem(...)` 락 획득 전 실행.
- **결함**: mtime 읽기 → 파일 수정됨(mtime T2) → lock 획득 → in-flight 완료 대기 → 캐시에 (T1, stale_labels) 저장된 결과 반환. A의 pre-lock mtime T1 == 캐시 T1이므로 hit 판정 → stale 레이블 반환.
- **부가**: line 34에서 분류 완료 후 저장하는 mtime도 pre-lock stat(T1) 그대로 — 분류 중 파일이 바뀌어도 T1으로 저장, 1초 mtime 정밀도(HFS+) 환경에서 영구 stale 가능.
- **수정 방향**: mtime 재stat을 lock 내부 or 분류 직후(저장 직전)에 수행.

---

### 🟡 FU-001 · FileUndo redo-after-trash가 매 사이클마다 새 휴지통 사본 생성 — `OPEN` LOW
- **위치**: `FileUndo.swift:122` — undo-of-trash의 redo inverse를 `.created(restored)`로 기록.
- **결함**: 사용자가 삭제→undo(복원)→redo(재삭제) 반복 시 매번 `~/.Trash/파일 N.ext` 사본 누적. 이전 사본은 undo 스택에 연결 없이 영구 고아.
- **수정 방향**: `.created(restored)` 대신 `.trash(stillTrashed)` 사용(현재 `stillTrashed`가 성공분만 수집 중이나 반환되지 않음).

---

### 🟡 FO-001 · trashItem 성공+resultingItemURL=nil 시 undo 기록 누락 — `OPEN` MEDIUM
- **위치**: `FileOperations.swift:44–46` — `if let t = trashedURL as URL? { pairs.append(...) }`.
- **결함**: AFP·서드파티 볼륨 드라이버에서 `trashItem` 성공해도 `resultingItemURL`이 nil 반환 가능(Apple 문서화). 이 경우 파일은 휴지통에 있으나 undo 기록 없음 → ⌘Z로 복원 불가.
- **수정 방향**: nil 케이스를 에러 처리하거나, FS에서 실제 trash 경로를 탐색해 fallback 기록.

---

### 🟡 FO-002 · duplicate가 확장자 없는 파일에 appendingPathExtension("") 호출 → 후행 점 위험 — `OPEN` LOW
- **위치**: `FileOperations.swift:127–133` — `appendingPathExtension(ext.isEmpty ? "" : ext)`.
- **결함**: `appendingPathExtension("")` 동작이 런타임 버전 의존적 — 일부 버전에서 후행 점(`.`) 부가. `Makefile copy.` 같은 이름 생성 → 쉘 도구 충돌. `uniqueURL`은 문자열 보간으로 정상 처리하는데 비대칭.
- **수정 방향**: `ext.isEmpty ? dir.appendingPathComponent("\(base) copy") : dir.appendingPathComponent("\(base) copy").appendingPathExtension(ext)`.

---

### INFO · VaultWatcher Task.detached 동시성 (iter21 재검토)
- VaultWatcher가 `Task.detached { VaultService.snapshot }` 복수 스폰 가능. 단, `VaultService.snapshot`이 `gitLock.sync`로 직렬화되어 git 부패는 없음(V-004 fix 유효). 불필요한 중복 스냅샷 큐잉은 가능하나 데이터 안전성에는 무해. INFO로 강등.

---

### ✅ 이상 없음 (iter21 검토 통과)
- **ListingCache**: LRU 동기화 일관적, 에비션 루프 정상.
- **AskService**: context/answer 로직 정상, 스트리밍 없어 취소 엣지케이스 미해당.
- **ExternalTools stdin 데드락**: stdin 파라미터가 기본 nil이고 현재 호출처(git, sftp 등) 전부 nil 사용 확인 → 잠재적이나 현재 비활성 경로. ET-001(stderr)은 실활성 경로라 별도 기록.

---

**iter21 점수**: 신규 OPEN 10건 (FT-001·FT-002·FT-003·FT-004 / BM-001·BM-002 / ILC-001 / FU-001 / FO-001·FO-002). 기존 13 FIXED 불변.

---
## iter22 — 10건 전부 수정 완료 (2026-06-14)

> 사용자 지시: "fix it now / one id → one commit". 10건 각각 독립 커밋.

| ID | 커밋 | 조치 |
|----|------|------|
| FT-004 | 98b604d | Move 취소 시 "이동이 취소되었습니다" 표시 |
| FT-003 | 6e00c06 | 복사 전체 실패 시 생성된 빈 목적지 폴더 정리 |
| FT-002 | f40ae40 | `boundedForEach`에 `useAllCores` 파라미터 추가 — 네트워크 목적지는 항상 semaphore 경로 사용(destLocal=false → concurrentPerform 우회 방지) |
| FT-001 | f7678ad | 덮어쓰기 피해파일을 FileOperations.moveToTrash 대신 직접 trash; 복사 전체 실패 시 피해파일 즉시 복원(Task.detached); 성공 시 피해 trash undo + 복사 undo 순으로 기록 |
| ET-001 | 2cb1cd4 | `process.standardError = FileHandle.nullDevice` — 미소비 stderr 파이프 데드락 제거 |
| BM-001 | c68d9d7 | `isVault` 체크를 `Task.detached`로 이전 — @MainActor 동기 FS I/O 제거 |
| BM-002 | 9fa22f1 | `makeNewFolder`/`commitRename`/`renameSelected` 모두 `standardizedFileURL` 사용 |
| ILC-001 | ff42456 | mtime stat을 락 내부에서 읽고, 분류 완료 후 재stat하여 저장 |
| FU-001 | 9561745 | 죽은 `stillTrashed` 변수 제거; `.trash` 역연산 코드 정리 |
| FO-001 | 78de02c | `trashItem` 성공+`resultingItemURL=nil` 시 Trash 디렉토리에서 파일 탐색하여 undo 기록 복구 |
| FO-002 | f977b74 | 확장자 없는 파일 duplicate 시 `appendingPathExtension("")` 대신 문자열 보간 사용 |

**TOTAL FIXED: 23건** (기존 13 + 이번 10). 워킹트리 클린. 미push.

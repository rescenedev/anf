# 🔒 VAULT_DESIGN.md

anf(all new finder) 내장 분산 백업 및 버전 관리 엔진(Vault) 아키텍처 설계안.

## 1. 개요 (Overview)

 * **목적**: 클라우드 의존성 없이 로컬 디바이스와 사설 NAS(또는 Remote Repo)를 활용한 완전 프라이버시 파일 보호 및 시점 복원(Time-travel) 기능 제공.
 * **핵심 엔진**: libgit2 (C 라이브러리 정적 임베딩)
 * **디자인 원칙**:
   1. 유휴 CPU ~0%, 메인 스레드 차단 제로 (기존 anf 철학 계승).
   2. 유저는 내부적으로 Git이 도는지 전혀 몰라야 함 (Seamless UX).
   3. 휴지통 비우기 및 외부 강제 삭제에도 데이터가 파괴되지 않는 완전한 격리.

## 2. 데이터 구조 및 격리 (Storage Architecture)

유저가 특정 디렉토리를 Vault 영역으로 선언하면, anf 코어는 해당 경로 내부에 격리된 가상 환경을 구축합니다.

```text
[User Vault Directory]
├── .git/                      <-- libgit2가 제어하는 베어/로컬 저장소 (anf UI에서 숨김)
│   ├── anf_config             <-- 보존 기한 정책, 섀도우 복제본 메타데이터 저장
│   └── objects/               <-- 휴지통을 비워도 파일이 살아남는 실제 데이터 기지
├── .gitignore                 <-- anf가 자동 생성하는 스마트 쓰레기 필터링 파일
├── 문서.docx
└── 프로젝트_최종/
```

### 👁️ 파일 숨김 처리 (Core Filter)

anf 목록 렌더링 엔진(NSTableView 데이터 소스 부분)에서 Vault 디렉토리 진입 시, 하위의 .git 폴더와 .gitignore 파일은 getattrlistbulk 결과에서 **조건문으로 무조건 드롭(Drop)** 시켜 유저 눈에 절대 띄지 않게 만듭니다.

## 3. 핵심 파이프라인 (Core Process Pipeline)

### 3.1. 자동 스냅샷 (Auto-Commit) 디바운스 메커니즘

파일이 바뀔 때마다 무지성으로 커밋을 따면 디스크 I/O 유휴 상태가 깨집니다. anf 내장 퍼지 검색에서 썼던 디바운스 기법을 활용합니다.

```text
[파일 변경 감지 (FSEvents)]
       │
       ▼
[5분 디바운스 타이머 가동] ─── (5분 내 추가 변경 시 타이머 리셋)
       │
       ▼ (유휴 상태 확보)
[백그라운드 스레드 디스패치]
       │
       ▼
[libgit2 호출: git_index_add_all() -> git_commit_create()]
```

 * **커밋 메시지 포맷**: anf-vault-snapshot-[Timestamp] (유저에게는 날짜/시간 UI로 변환해서 노출)

### 3.2. 휴지통 무력화 복구 (Time Travel)

유저가 anf 또는 macOS Finder에서 파일을 지우고 휴지통까지 비웠을 때의 복구 알고리즘:

 1. anf 내 우측 인스펙터 창 또는 별도 뷰에서 **"Vault 타임라인"** 활성화.
 2. libgit2 API git_revwalk를 순회하며 anf-vault-snapshot 커밋 로그를 역순으로 수집.
 3. 지워진 파일의 해시(git_oid)와 파일명을 매칭하여 UI에 타임라인 형태로 표시.
 4. 유저가 복구 버튼 클릭 시, 백그라운드에서 git_checkout_head 또는 특정 파일 오브젝트를 git_blob_lookup 하여 원래 경로에 네이티브 라이브러리로 다이렉트 복원 복사 수행.

## 4. 쓰레기 적체 및 용량 비대화 해결 (Garbage Management)

Git 엔진의 치명적인 단점인 용량 폭발(Bloat)을 막기 위한 백그라운드 청소 시스템입니다.

### 4.1. 스마트 가비지 컬렉션 (Auto GC)

 * **트리거**: 앱 종료 시 또는 일주일에 한 번 백그라운드 유휴 시간에 가동.
 * **동작**: libgit2 내장 팩파일(Packfile) 압축 알고리즘을 호출하여 느슨하게 흩어진 오브젝트 쓰레기들을 단일 팩파일로 압축하고, 댕글링(참조 끊긴) 오브젝트를 영구 제거(prune).

### 4.2. 만료 이력 스쿼시 (Retention Policy - Squash)

유저가 설정한 보존 기한(예: 30일)이 지난 과거 커밋들은 히스토리를 하나로 뭉쳐서(Squash) 중간 쓰레기 데이터를 증발시킵니다.

```text
[만료 전] Commit A (12/1) -> Commit B (12/2) -> Commit C (12/3) -> [현재 30일 경과]
                                  │
                                  ▼ (Squash & Prune 정책 가동)
[만료 후] Commit A-C (통합본으로 압축, 중간 변경 데이터 디스크에서 완전 삭제)
```

### 4.3. 대용량 바이너리 및 스마트 .gitignore 기본값

Vault 생성과 동시에 .gitignore 파일에 아래 내용을 anf가 강제로 주입합니다.

```ignore
# macOS 시스템 쓰레기 제거
.DS_Store
.AppleDouble
.LSOverride
._*

# 일반적인 개발/임시 캐시 파일 제거
node_modules/
.sass-cache/
*.log
*.tmp
*.crdownload
```

 * **용량 제한 필터(Hard Limit)**: libgit2로 인덱스에 파일 추가(git_index_add_bypath) 직전, 파일의 크기를 체크하여 **50MB 이상인 바이너리(영상, 압축파일 등)**는 Git 추적에서 제외하고, anf_config 내부에 명시된 로컬 별도 격리 폴더에 **'가장 최신 버전 1개만 덮어쓰기'** 형태로 우회 저장하여 .git 폴더가 터지는 것을 원천 차단합니다.

## 5. 원격 분산 백업 (Remote Sync - Lazy Push)

맥북이 고장 나거나 분실되어도 NAS나 GitHub Private 레포지토리에서 데이터를 긁어올 수 있게 만드는 메커니즘입니다.

 1. **원격 등록**: 유저가 사설 NAS 주소(SFTP/SSH) 또는 GitHub Private 토큰을 anf에 등록하면, 내부적으로 git_remote_create 실행.
 2. **비동기 푸시 (Lazy Push)**:
   * 로컬 자동 커밋이 완료되면 네트워크 상태를 체크.
   * 온라인 상태이면 백그라운드 스레드에서 git_remote_push 구동.
   * 오프라인(외부 카페 등) 상태이면 실패 팝업을 띄우지 않고, anf_config에 sync_pending = true 플래그만 세팅 후 대기.
   * 추후 홈 네트워크(NAS 식별 가능 상태)나 인터넷이 연결되면 조용히 밀어 넣기(Push) 수행. 유저가 비치볼을 보거나 대기할 필요가 전혀 없음.

## 6. 개발 팁 및 의존성 주입 (Implementation Notes)

 * **의존성**: Swift에서 libgit2를 직접 호출하기 위해 완벽하게 래핑 된 오픈소스 라이브러리인 SwiftGit2 또는 Pure C 브릿징 헤더(Clibgit2) 활용.
 * **컴파일 타깃**: libgit2를 static library(.a)로 빌드하여 anf 바이너리에 정적 포함시킬 것. 정적 컴파일 후 최종 앱 번들 용량 증가 폭은 **+1.8MB 이내**로 제한하여 '3.4MB의 전설'을 유지할 것.

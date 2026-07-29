# anf-dl-notify

GitHub 릴리즈 다운로드/스타 변화를 5분 주기로 폴링해 텔레그램으로 알리는
Cloudflare Worker. GitHub에는 다운로드 웹훅이 없어 `download_count`를 KV에
저장해 두고 증가분만 알립니다.

배포: `npx wrangler deploy`
시크릿: `TG_TOKEN`(봇 토큰) · `TG_CHAT`(chat id) · `POKE_KEY`(수동 트리거 키)
· `GITHUB_TOKEN`(public read-only PAT — Workers 공유 IP는 무인증 한도가 이미
소진돼 있어 필수)
수동 확인: `GET /poke?key=<POKE_KEY>`

이슈/댓글/PR(등록·머지·닫힘)은 GitHub 웹훅(push)으로 즉시 알림 —
`POST /webhook`, `WEBHOOK_SECRET` HMAC 서명 검증.

hooks.zihado.com은 이 Worker의 커스텀 도메인이다 (2026-07-29에 legalize-ts
터널의 localhost:8481에서 이관 — 터널 쪽 프로세스가 500을 내며 죽어가고
있었고, Worker 관리가 더 단순하다). 웹훅 이벤트 구독은 GitHub 저장소 설정의
issues · issue_comment · release · pull_request 네 가지.

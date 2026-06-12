# anf-dl-notify

GitHub 릴리즈 다운로드/스타 변화를 5분 주기로 폴링해 텔레그램으로 알리는
Cloudflare Worker. GitHub에는 다운로드 웹훅이 없어 `download_count`를 KV에
저장해 두고 증가분만 알립니다.

배포: `npx wrangler deploy`
시크릿: `TG_TOKEN`(봇 토큰) · `TG_CHAT`(chat id) · `POKE_KEY`(수동 트리거 키)
· `GITHUB_TOKEN`(public read-only PAT — Workers 공유 IP는 무인증 한도가 이미
소진돼 있어 필수)
수동 확인: `GET /poke?key=<POKE_KEY>`

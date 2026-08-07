// anf-dl-notify — GitHub 이슈/PR/릴리즈 웹훅을 텔레그램으로 중계한다.
// 다운로드/스타 증감 알림은 사용자 요청으로 중단됨(크론 제거 + scheduled 무력화).
// check()는 /poke dry-run 점검용으로만 남겨 둔다 — 스스로 발송하지 않는다.
// Secrets (never in this file): TG_TOKEN, TG_CHAT, POKE_KEY, optional GITHUB_TOKEN.

const REPO = "rescenedev/anf";

export default {
  // 다운로드/스타 알림은 사용자 요청으로 전면 중단. 크론도 제거했지만, 남아
  // 있던 트리거가 어쩌다 발사되더라도 아무것도 보내지 않도록 여기서 막는다.
  // (수동 점검은 /poke 로 여전히 가능 — dry-run이라 발송하지 않음)
  async scheduled(_event, _env, _ctx) {},

  // Manual trigger for testing: GET /poke?key=<POKE_KEY> — dry-run: reports the
  // pending delta WITHOUT saving state or messaging, so a midday poke can't eat
  // part of the daily digest window. Add &commit=1 for the real send+save.
  // GitHub webhook (issues/PRs): POST /webhook, HMAC-verified with WEBHOOK_SECRET.
  async fetch(req, env) {
    const url = new URL(req.url);
    if (url.pathname === "/poke" && url.searchParams.get("key") === env.POKE_KEY) {
      const dryRun = url.searchParams.get("commit") !== "1";
      const report = await check(env, { dryRun });
      return new Response((dryRun ? "[dry-run]\n" : "") + report,
                          { headers: { "content-type": "text/plain; charset=utf-8" } });
    }
    if (url.pathname === "/webhook" && req.method === "POST") {
      return webhook(req, env);
    }
    return new Response("anf-dl-notify", { status: 200 });
  },
};

async function webhook(req, env) {
  const body = await req.text();
  if (!(await validSignature(env.WEBHOOK_SECRET, body, req.headers.get("x-hub-signature-256")))) {
    return new Response("bad signature", { status: 401 });
  }
  const event = req.headers.get("x-github-event");
  const p = JSON.parse(body);
  if (event === "ping") {
    await tg(env, "GitHub 웹훅 연결됨 — 이슈 알림 시작");
  } else if (event === "issues" && ["opened", "reopened"].includes(p.action)) {
    const i = p.issue;
    await tg(env, [
      `🐛 이슈 ${p.action === "opened" ? "등록" : "다시 열림"} #${i.number}`,
      i.title,
      `by ${i.user?.login}`,
      i.html_url,
    ].join("\n"));
  } else if (event === "issue_comment" && p.action === "created") {
    const c = p.comment;
    await tg(env, [
      `💬 이슈 #${p.issue?.number} 새 댓글 (by ${c.user?.login})`,
      (c.body ?? "").slice(0, 300),
      c.html_url,
    ].join("\n"));
  } else if (event === "pull_request" && ["opened", "reopened", "closed", "ready_for_review"].includes(p.action)) {
    const pr = p.pull_request;
    // "closed" is two different stories — merged vs abandoned.
    const verb =
      p.action === "closed" ? (pr.merged ? "머지됨" : "닫힘")
      : p.action === "reopened" ? "다시 열림"
      : p.action === "ready_for_review" ? "리뷰 준비됨"
      : "등록";
    const emoji = p.action === "closed" ? (pr.merged ? "🎉" : "🚫") : "🔀";
    await tg(env, [
      `${emoji} PR ${verb} #${pr.number}`,
      pr.title,
      `by ${pr.user?.login}`,
      pr.html_url,
    ].join("\n"));
  } else if (event === "release" && p.action === "published") {
    const r = p.release;
    await tg(env, [
      `🚀 릴리즈 ${r.tag_name}${r.name && r.name !== r.tag_name ? ` — ${r.name}` : ""}`,
      summarizeNotes(r.body ?? ""),
      r.html_url,
    ].filter(Boolean).join("\n\n"));
  }
  return new Response("ok");
}

// Release notes → a plain-text digest Telegram renders well: drop markdown
// noise (headers/links/code fences), keep the substance, cap the length.
function summarizeNotes(body) {
  const text = body
    .replace(/```[\s\S]*?```/g, "")          // code fences (install commands etc.)
    .replace(/^#+\s*/gm, "")                  // heading markers
    .replace(/\*\*([^*]+)\*\*/g, "$1")        // bold
    .replace(/\[([^\]]+)\]\([^)]+\)/g, "$1")  // links → text
    .replace(/^\s*[-*]\s+/gm, "• ")           // bullets
    .replace(/\n{3,}/g, "\n\n")
    .trim();
  return text.length > 900 ? text.slice(0, 900) + "…" : text;
}

async function validSignature(secret, body, header) {
  if (!secret || !header?.startsWith("sha256=")) return false;
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = await crypto.subtle.sign("HMAC", key, enc.encode(body));
  const hex = [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, "0")).join("");
  return `sha256=${hex}` === header;
}

async function check(env, { dryRun = false } = {}) {
  const gh = (path) =>
    fetch(`https://api.github.com${path}`, {
      headers: {
        "User-Agent": "anf-dl-notify",
        Accept: "application/vnd.github+json",
        ...(env.GITHUB_TOKEN ? { Authorization: `Bearer ${env.GITHUB_TOKEN}` } : {}),
      },
    });

  const [relRes, repoRes] = await Promise.all([
    gh(`/repos/${REPO}/releases?per_page=30`),
    gh(`/repos/${REPO}`),
  ]);
  // Rate-limited or down: skip this tick, keep state untouched, try again next cron.
  if (!relRes.ok || !repoRes.ok) {
    return `github fetch failed: releases=${relRes.status} repo=${repoRes.status}`;
  }
  const releases = await relRes.json();
  const repo = await repoRes.json();

  const counts = {};
  let total = 0;
  for (const r of releases) {
    const n = (r.assets ?? []).reduce((s, a) => s + (a.download_count ?? 0), 0);
    counts[r.tag_name] = n;
    total += n;
  }
  const stars = repo.stargazers_count ?? 0;
  const now = { counts, total, stars };

  const prevRaw = await env.STATE.get("state");
  if (!dryRun) await env.STATE.put("state", JSON.stringify(now));

  if (!prevRaw) {
    if (!dryRun) await tg(env, `anf 알림 시작 — 누적 다운로드 ${total} · 스타 ${stars}`);
    return `baseline${dryRun ? "" : " stored"}: total=${total} stars=${stars}`;
  }
  const prev = JSON.parse(prevRaw);

  const lines = [];
  const dlDelta = total - (prev.total ?? 0);
  if (dlDelta > 0) {
    lines.push(`⬇️ 다운로드 +${dlDelta} (누적 ${total})`);
    for (const [tag, n] of Object.entries(counts)) {
      const d = n - (prev.counts?.[tag] ?? 0);
      if (d > 0) lines.push(`  ${tag}: +${d} → ${n}`);
    }
  }
  const starDelta = stars - (prev.stars ?? 0);
  if (starDelta !== 0) {
    lines.push(`${starDelta > 0 ? "⭐️" : "💔"} 스타 ${starDelta > 0 ? "+" : ""}${starDelta} (총 ${stars})`);
  }

  if (lines.length && !dryRun) await tg(env, `anf 일일 요약 ☀️\n${lines.join("\n")}`);
  return lines.length
    ? `${dryRun ? "pending" : "notified"}:\n${lines.join("\n")}`
    : `no change (total=${total} stars=${stars})`;
}

async function tg(env, text) {
  // Never throw: a network hiccup here used to bubble out of the webhook
  // handler as a 500 back to GitHub — the notification is best-effort, the
  // webhook ack is not.
  try {
    const res = await fetch(`https://api.telegram.org/bot${env.TG_TOKEN}/sendMessage`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ chat_id: env.TG_CHAT, text }),
    });
    if (!res.ok) console.log("telegram send failed", res.status, await res.text());
  } catch (e) {
    console.log("telegram send threw", String(e));
  }
}

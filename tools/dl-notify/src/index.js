// anf-dl-notify — polls GitHub every 5 minutes and Telegrams the author when
// release downloads (or stars) go up. GitHub has no download webhook, so the
// only way to know is to diff `download_count` between polls; state lives in KV.
// Secrets (never in this file): TG_TOKEN, TG_CHAT, POKE_KEY, optional GITHUB_TOKEN.

const REPO = "rescenedev/anf";

export default {
  async scheduled(_event, env, ctx) {
    ctx.waitUntil(check(env));
  },

  // Manual trigger for testing: GET /poke?key=<POKE_KEY>
  async fetch(req, env) {
    const url = new URL(req.url);
    if (url.pathname === "/poke" && url.searchParams.get("key") === env.POKE_KEY) {
      const report = await check(env, { verbose: true });
      return new Response(report, { headers: { "content-type": "text/plain; charset=utf-8" } });
    }
    return new Response("anf-dl-notify", { status: 200 });
  },
};

async function check(env, { verbose = false } = {}) {
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
  await env.STATE.put("state", JSON.stringify(now));

  if (!prevRaw) {
    await tg(env, `anf 알림 시작 — 누적 다운로드 ${total} · 스타 ${stars}`);
    return `baseline stored: total=${total} stars=${stars}`;
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

  if (lines.length) await tg(env, `anf\n${lines.join("\n")}`);
  return lines.length
    ? `notified:\n${lines.join("\n")}`
    : `no change (total=${total} stars=${stars})${verbose ? "" : ""}`;
}

async function tg(env, text) {
  const res = await fetch(`https://api.telegram.org/bot${env.TG_TOKEN}/sendMessage`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ chat_id: env.TG_CHAT, text }),
  });
  if (!res.ok) console.log("telegram send failed", res.status, await res.text());
}

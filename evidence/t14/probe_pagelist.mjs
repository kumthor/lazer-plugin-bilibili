// T14 只读探针：搜索行能不能便宜地拿到 P 数。
//
//   node evidence/t14/probe_pagelist.mjs "周杰伦"
//
// 搜索接口（/wbi/search/type?search_type=video）的返回行**没有** `videos`
// 字段（T7 capture_search.json 20/20 命中，T13/D4 已登记）。要在搜索页看见
// "· N P"，只有两条路：
//
//   A. /x/player/pagelist?bvid=   每条搜索行一个请求
//   B. /x/web-interface/view      同上，但带更多字段、更重
//
// 这个探针量 A 与 B 的真实代价，并核对 pagelist 的 P 数与 view.pages 一致。
// 只用公开接口，不写任何文件、不改插件。
import { readFileSync } from 'node:fs';

const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
const STORAGE = `${process.env.APPDATA}\\dev.naominet\\lazer_nextgen\\lua_plugin_data\\community.bilibili.music\\storage.json`;

let cookie = '';
try {
  cookie = JSON.parse(readFileSync(STORAGE, 'utf8')).session_cookie ?? '';
} catch {
  /* 匿名 */
}

async function get(url) {
  const headers = {
    'User-Agent': UA,
    Referer: 'https://www.bilibili.com/',
    Accept: 'application/json',
  };
  if (cookie) headers.Cookie = cookie;
  const started = Date.now();
  const res = await fetch(url, { headers });
  const text = await res.text();
  const ms = Date.now() - started;
  let json = null;
  try {
    json = JSON.parse(text);
  } catch {
    /* 非 JSON */
  }
  return { status: res.status, json, ms, bytes: text.length };
}

const line = (o) => console.log(JSON.stringify(o));
const keyword = process.argv[2] ?? '周杰伦';

console.log(
  `# cookie=${cookie ? cookie.length + ' chars' : 'anonymous'} keyword=${keyword} at ${new Date().toISOString()}`,
);

await get('https://www.bilibili.com/'); // 预热 buvid3

// --- 搜索本身：确认行里真的没有 videos ---------------------------------------
const search = await get(
  `https://api.bilibili.com/x/web-interface/wbi/search/type?search_type=video&keyword=${encodeURIComponent(keyword)}&page=1&page_size=20`,
);
const rows = search.json?.data?.result ?? [];
line({
  tag: 'search',
  status: search.status,
  code: search.json?.code,
  rows: rows.length,
  ms: search.ms,
  withVideos: rows.filter((r) => typeof r.videos === 'number').length,
});

// --- 逐条量 pagelist 与 view --------------------------------------------------
const sample = rows.slice(0, 12);
let plTotal = 0;
let viewTotal = 0;
let plOk = 0;
let viewOk = 0;
for (const row of sample) {
  const bvid = row.bvid;
  const pl = await get(
    `https://api.bilibili.com/x/player/pagelist?bvid=${bvid}`,
  );
  plTotal += pl.ms;
  const plCount = Array.isArray(pl.json?.data) ? pl.json.data.length : -1;
  if (plCount > 0) plOk += 1;

  const vw = await get(
    `https://api.bilibili.com/x/web-interface/view?bvid=${bvid}`,
  );
  viewTotal += vw.ms;
  const vwCount = Array.isArray(vw.json?.data?.pages)
    ? vw.json.data.pages.length
    : -1;
  if (vwCount > 0) viewOk += 1;

  line({
    tag: 'row',
    bvid,
    title: String(row.title ?? '').slice(0, 28),
    rowVideos: row.videos ?? null,
    plCount,
    plMs: pl.ms,
    plBytes: pl.bytes,
    plCode: pl.json?.code,
    viewCount: vwCount,
    viewMs: vw.ms,
    viewBytes: vw.bytes,
    agree: plCount === vwCount,
  });
}

line({
  tag: 'summary',
  n: sample.length,
  pagelist: { ok: plOk, totalMs: plTotal, avgMs: Math.round(plTotal / sample.length) },
  view: { ok: viewOk, totalMs: viewTotal, avgMs: Math.round(viewTotal / sample.length) },
  multiPartInSample: null,
});

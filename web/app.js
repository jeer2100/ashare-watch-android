const UT = '7eea3edcaed734bea9cbfc24409ed989';
const KEY = 'ashare_watch_snapshots_v1';
const NODES = [
  '09:40','09:50','10:00','10:10','10:20','10:30','10:40','10:50','11:00','11:10','11:20','11:30',
  '13:00','13:10','13:20','13:30','13:40','13:50','14:00','14:10','14:20','14:30','14:40','14:50','15:00'
];

function pad(n) { return n < 10 ? '0' + n : '' + n; }

function beijingNow() {
  const d = new Date(Date.now() + 8 * 3600 * 1000);
  return {
    year: d.getUTCFullYear(), month: d.getUTCMonth() + 1, day: d.getUTCDate(),
    weekday: d.getUTCDay(), node: pad(d.getUTCHours()) + ':' + pad(d.getUTCMinutes())
  };
}

function load() {
  try { return JSON.parse(localStorage.getItem(KEY) || '[]'); } catch (e) { return []; }
}

// 存快照时一并算出：较上一节点的涨停/炸板增量、增量最多的板块
function store(snap) {
  const all = load();
  const prev = all.filter(s => s.date === snap.date && s.node !== snap.node)
                  .sort((a, b) => a.node < b.node ? -1 : 1).pop();
  const cur = {};
  ((snap.detail && snap.detail.sectors) || []).forEach(s => { cur[s.name] = s.n; });
  const old = {};
  ((prev && prev.detail && prev.detail.sectors) || []).forEach(s => { old[s.name] = s.n; });
  const sectorDelta = [];
  Object.keys(cur).forEach(k => {
    const d = cur[k] - (old[k] || 0);
    if (d > 0) sectorDelta.push({ name: k, d: d });
  });
  sectorDelta.sort((a, b) => b.d - a.d);
  const row = Object.assign({}, snap, {
    deltaZt: prev ? snap.zt - prev.zt : snap.zt,
    deltaZb: prev ? snap.zb - prev.zb : snap.zb,
    deltaSector: sectorDelta.length ? sectorDelta[0] : null,
    sectorDelta: sectorDelta.slice(0, 5)
  });
  const idx = all.findIndex(s => s.date === snap.date && s.node === snap.node);
  if (idx >= 0) all[idx] = row; else all.push(row);
  localStorage.setItem(KEY, JSON.stringify(all.slice(-1200)));
  return row;
}

async function fetchPool(endpoint, compact, node) {
  const url = 'https://push2ex.eastmoney.com/' + endpoint +
    '?ut=' + UT + '&dpt=wz.ztzt&Pageindex=0&pagesize=500&sort=fbt%3Aasc&date=' + compact +
    '&_t=' + node.replace(':', '');
  const res = await fetch(url, { headers: { 'User-Agent': 'Mozilla/5.0' } });
  const json = await res.json();
  const data = json.data || {};
  return { tc: Number(data.tc || 0), qdate: String(data.qdate || ''), pool: data.pool || [] };
}

function fmtFbt(v) {
  const s = String(v || '').padStart(6, '0');
  return s.slice(0, 2) + ':' + s.slice(2, 4);
}

// 明细：全量板块计数（用于算增量）+ 涨停前5 + 连板家数/连板前5（均按首封时间排序，带所属板块）
function analyzePool(pool) {
  const counts = {};
  pool.forEach(x => { const s = x.hybk || '其他'; counts[s] = (counts[s] || 0) + 1; });
  const sectors = Object.keys(counts).sort((a, b) => counts[b] - counts[a])
                        .map(k => ({ name: k, n: counts[k] }));
  const lb = {};
  pool.forEach(x => { const n = Number(x.lbc || 0); if (n > 0) lb[n] = (lb[n] || 0) + 1; });
  const ladder = Object.keys(lb).map(Number).sort((a, b) => b - a)
                      .map(k => ({ n: k, c: lb[k] }));
  const byFbt = pool.slice().sort((a, b) => Number(a.fbt || 0) - Number(b.fbt || 0));
  const info = x => ({
    name: x.n, code: x.c, fbt: fmtFbt(x.fbt),
    lbc: Number(x.lbc || 0), sector: x.hybk || '其他'
  });
  const first = byFbt.slice(0, 5).map(info);
  // 东财 lbc=1 为首板，连板按 2 板及以上统计
  const lbStocks = byFbt.filter(x => Number(x.lbc || 0) >= 2);
  return {
    sectors: sectors,
    ladder: ladder,
    first: first,
    lbCount: lbStocks.length,
    firstBoardCount: pool.length - lbStocks.length,
    lbFirst: lbStocks.slice(0, 5).map(info)
  };
}

async function fetchSnap(forceLive) {
  const now = beijingNow();
  if (now.weekday === 0 || now.weekday === 6) return null;
  if (!forceLive && !NODES.includes(now.node)) return null;
  const compact = '' + now.year + pad(now.month) + pad(now.day);
  const date = now.year + '-' + pad(now.month) + '-' + pad(now.day);
  const zt = await fetchPool('getTopicZTPool', compact, now.node);
  if (zt.qdate !== compact) return null;
  let zb = { tc: 0, pool: [] };
  try { zb = await fetchPool('getTopicZBPool', compact, now.node); } catch (e) {}
  const detail = analyzePool(zt.pool);
  const sector = detail.sectors.length ? detail.sectors[0].name : '-';
  const maxLb = detail.ladder.length ? detail.ladder[0].n : 0;
  return {
    date, node: now.node, zt: zt.tc, zb: zb.tc,
    topSector: sector, maxLb, ts: Date.now(),
    live: !NODES.includes(now.node), detail
  };
}

async function grab(manual) {
  const msg = document.getElementById('msg');
  const btn = document.getElementById('fetchBtn');
  btn.disabled = true;
  try {
    const snap = await fetchSnap(true);
    if (!snap) {
      if (manual) msg.textContent = '今天是周末，非交易日';
    } else {
      store(snap);
      if (manual) msg.textContent = '已抓取 ' + snap.node + ' 实时快照：涨停 ' + snap.zt + ' / 炸板 ' + snap.zb;
    }
  } catch (e) {
    if (manual) msg.textContent = '抓取失败：' + e.message;
  }
  btn.disabled = false;
  render();
}

function escapeHtml(s) {
  return String(s == null ? '' : s).replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
}

async function openDetail(snap) {
  // 旧快照可能没有明细字段：现场抓一次当前明细补上（东财只提供当前状态）
  let s = snap;
  if (!snap.detail || !(snap.detail.sectors || []).length) {
    const mask = document.getElementById('detailMask');
    mask.classList.add('show');
    document.getElementById('dtitle').textContent = snap.node;
    document.getElementById('dbody').innerHTML = '<div style="color:#888;font-size:13px;">正在加载明细…</div>';
    try {
      const fresh = await fetchSnap(true);
      if (fresh && fresh.detail) {
        s = Object.assign({}, snap, { detail: fresh.detail });
        s = store(s); // 重新计算增量板块
        render();
      }
    } catch (e) {}
  }
  renderDetail(s);
}

function renderDetail(snap) {
  const d = snap.detail || {};
  const sectors = (d.sectors || []).slice(0, 5);
  const ladder = d.ladder || [];
  const first = d.first || [];
  const lbFirst = d.lbFirst || [];
  const lbCount = d.lbCount != null ? d.lbCount : ladder.reduce((a, x) => a + x.c, 0);
  const dt = new Date((snap.date || '').replace(/-/g, '/') + ' 00:00:00');
  const week = ['日','一','二','三','四','五','六'][isNaN(dt.getDay()) ? 0 : dt.getDay()];
  const rate = (snap.zt + snap.zb) > 0 ? (snap.zb / (snap.zt + snap.zb) * 100).toFixed(1) : '0.0';
  const dz = snap.deltaZt;
  const dzTxt = dz == null ? '—' : (dz > 0 ? '+' + dz : String(dz));
  const dzb = snap.deltaZb;
  const dzbTxt = dzb == null ? '—' : (dzb > 0 ? '+' + dzb : String(dzb));
  const ds = snap.deltaSector;

  document.getElementById('dtitle').textContent = snap.node;
  document.getElementById('dbadge').textContent = snap.live ? '实时快照' : '定时节点';
  document.getElementById('dsub').textContent = (snap.date || '') + ' 周' + week;
  document.getElementById('dzt').textContent = snap.zt;
  document.getElementById('dzb').textContent = snap.zb;
  document.getElementById('drate').textContent = rate + '%';
  document.getElementById('dtop').textContent = ds && ds.d > 0 ? ds.name.replace(/Ⅱ|Ⅰ/g, '') : '—';

  let html = '';
  // ① 涨停家数 + 按封板时间前5
  html += '<h3>① 涨停家数与首批封板（按封板时间前 5）</h3>';
  html += '<div>当前涨停 <b>' + snap.zt + '</b> 家，按首封时间排序前 5 位：</div>';
  if (first.length) {
    html += '<ol>';
    first.forEach((x, i) => {
      html += '<li>' + escapeHtml(x.name) + '　' + escapeHtml(x.sector) + '　' + x.fbt + ' 首封' +
              (x.lbc ? '　' + x.lbc + ' 连板' : '') + '</li>';
    });
    html += '</ol>';
  } else { html += '<div class="none">暂无数据</div>'; }

  // ② 连板家数 + 连板个股按封板时间前5
  html += '<h3>② 连板涨停家数与封板时间前 5</h3>';
  html += '<div>连板涨停 <b>' + lbCount + '</b> 家（2 板及以上，另首板 ' +
          (d.firstBoardCount != null ? d.firstBoardCount : '—') + ' 家），按封板时间排序前 5 位：</div>';
  if (lbFirst.length) {
    html += '<ol>';
    lbFirst.forEach((x, i) => {
      html += '<li>' + escapeHtml(x.name) + '　' + escapeHtml(x.sector) + '　' + x.lbc + ' 连板　' + x.fbt + ' 封板</li>';
    });
    html += '</ol>';
  } else { html += '<div class="none">当前无连板个股</div>'; }

  // ③ 前两条个股分别所属板块
  html += '<h3>③ 上述个股分别所属板块</h3>';
  const bySector = {};
  const seen = {};
  first.concat(lbFirst).forEach(x => {
    if (seen[x.name]) return;
    seen[x.name] = 1;
    if (!bySector[x.sector]) bySector[x.sector] = [];
    bySector[x.sector].push(x.name + (x.lbc ? '（' + x.lbc + '板）' : ''));
  });
  const skeys = Object.keys(bySector);
  if (skeys.length) {
    html += '<div class="sector-list">';
    skeys.forEach(k => {
      html += '<div><b>' + escapeHtml(k) + '</b>：' + bySector[k].map(escapeHtml).join('、') + '</div>';
    });
    html += '</div>';
  } else { html += '<div class="none">暂无数据</div>'; }
  if (sectors.length) {
    html += '<div class="muted" style="margin-top:6px;">全部涨停板块分布（前五）：' +
            sectors.map(x => escapeHtml(x.name) + ' ' + x.n + ' 家').join('，') + '</div>';
  }

  // ④ 节点变化 + 增量最多板块 + 炸板
  html += '<h3>④ 节点变化与炸板</h3>';
  html += '<div>较上一节点：涨停 <b>' + dzTxt + '</b> 家' +
          (ds && ds.d > 0 ? '，增量最多板块 <b>' + escapeHtml(ds.name) + '</b>（+' + ds.d + ' 家）' : '，无板块净增加') + '。</div>';
  html += '<div>炸板 <b>' + snap.zb + '</b> 家（较上一节点 ' + dzbTxt + ' 家），炸板率约 ' + rate + '%。</div>';
  if (ladder.length) {
    html += '<div class="muted" style="margin-top:6px;">连板梯队：' +
            ladder.map(x => x.n + ' 板 ' + x.c + ' 家').join('，') + '（含首板）</div>';
  }

  html += '<h3>说明</h3><div class="muted">本快照为' + (snap.live ? '打开页面时点实时抓取' : '该节点页面打开期间抓取') +
          '，东财接口只提供当前状态，历史节点无法回补。仅供参考，不构成投资建议。</div>';
  document.getElementById('dbody').innerHTML = html;
  document.getElementById('detailMask').classList.add('show');
}

function render() {
  const now = beijingNow();
  const today = now.year + '-' + pad(now.month) + '-' + pad(now.day);
  const rows = load().filter(s => s.date === today).sort((a, b) => a.node < b.node ? -1 : 1);
  const latest = rows[rows.length - 1];
  document.getElementById('dateLabel').textContent = today + ' · ' + (latest ? latest.node + ' 快照' : '暂无快照');
  document.getElementById('zt').textContent = latest ? latest.zt : '—';
  document.getElementById('zb').textContent = latest ? latest.zb : '—';
  document.getElementById('ztDelta').textContent = latest ? '较上一节点 ' + (latest.deltaZt >= 0 ? '+' : '') + latest.deltaZt : '';
  document.getElementById('zbDelta').textContent = latest ? '较上一节点 ' + (latest.deltaZb >= 0 ? '+' : '') + latest.deltaZb : '';
  document.getElementById('sector').textContent = latest ? '最强板块：' + latest.topSector + '　最高连板：' + latest.maxLb + ' 板' : '';
  const byNode = {};
  const liveRows = [];
  rows.forEach(s => { if (NODES.includes(s.node)) byNode[s.node] = s; else liveRows.push(s); });
  const liveHtml = liveRows.map(s =>
    '<div class="row clickable" data-node="' + s.node + '"><span class="time" style="color:#e69500">' + s.node + '</span><span class="info">涨停 ' + s.zt + ' · 炸板 ' + s.zb + ' · ' + s.topSector + ' <span style="color:#e69500">(实时)</span></span><span class="arrow">›</span></div>'
  ).join('');
  const nodeHtml = NODES.map(n => {
    const s = byNode[n];
    if (!s) return '<div class="row waiting"><span class="time">' + n + '</span><span class="info">待更新</span></div>';
    const d = s.deltaZt >= 0 ? '+' + s.deltaZt : '' + s.deltaZt;
    return '<div class="row clickable" data-node="' + n + '"><span class="time">' + n + '</span><span class="info">涨停 ' + s.zt + ' · 炸板 ' + s.zb + ' · ' + s.topSector + '</span><span class="delta">' + d + '</span><span class="arrow">›</span></div>';
  }).join('');
  const timeline = document.getElementById('timeline');
  timeline.innerHTML = liveHtml + nodeHtml;
  timeline.querySelectorAll('.clickable').forEach(el => {
    el.addEventListener('click', () => {
      const node = el.getAttribute('data-node');
      const snap = rows.find(s => s.node === node);
      if (snap) openDetail(snap);
    });
  });
}

document.getElementById('fetchBtn').addEventListener('click', () => grab(true));
document.getElementById('summaryCard').addEventListener('click', () => {
  const now = beijingNow();
  const today = now.year + '-' + pad(now.month) + '-' + pad(now.day);
  const rows = load().filter(s => s.date === today).sort((a, b) => a.node < b.node ? -1 : 1);
  if (rows.length) openDetail(rows[rows.length - 1]);
});
document.getElementById('dclose').addEventListener('click', () => document.getElementById('detailMask').classList.remove('show'));
document.getElementById('detailMask').addEventListener('click', (e) => {
  if (e.target.id === 'detailMask') document.getElementById('detailMask').classList.remove('show');
});
render();
grab(false);
setInterval(() => {
  const now = beijingNow();
  const today = now.year + '-' + pad(now.month) + '-' + pad(now.day);
  if (NODES.includes(now.node)) {
    const has = load().some(s => s.date === today && s.node === now.node);
    if (!has) {
      fetchSnap(false).then(s => { if (s) { store(s); render(); } }).catch(() => {});
    }
  }
}, 60000);

if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('sw.js').catch(() => {});
}

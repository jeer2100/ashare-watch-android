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

function fbtSec(v) {
  const s = String(v || 0).padStart(6, '0');
  return (+s.slice(0, 2)) * 3600 + (+s.slice(2, 4)) * 60 + (+s.slice(4, 6));
}
function nodeSec(node) {
  const p = node.split(':').map(Number);
  return p[0] * 3600 + p[1] * 60;
}

// 抓一次全量池，按首次封板时间回推当日所有"已完成"节点（未来节点不生成）
async function fetchBackfill() {
  const now = beijingNow();
  if (now.weekday === 0 || now.weekday === 6) return [];
  const compact = '' + now.year + pad(now.month) + pad(now.day);
  const date = now.year + '-' + pad(now.month) + '-' + pad(now.day);
  const zt = await fetchPool('getTopicZTPool', compact, 'backfill');
  if (zt.qdate !== compact) return [];
  let zb = { tc: 0, pool: [] };
  try { zb = await fetchPool('getTopicZBPool', compact, 'backfill'); } catch (e) {}
  const nowMin = now.node.split(':').map(Number);
  const nowSec = nowMin[0] * 3600 + nowMin[1] * 60;

  const rows = [];
  let prevSectors = null;
  let prevZt = 0, prevZb = 0;
  for (const node of NODES) {
    if (nodeSec(node) > nowSec) break;
    const ztList = zt.pool.filter(x => fbtSec(x.fbt) <= nodeSec(node));
    const zbList = (zb.pool || []).filter(x => fbtSec(x.fbt) <= nodeSec(node));
    const detail = analyzePool(ztList);
    const cur = {};
    (detail.sectors || []).forEach(s => { cur[s.name] = s.n; });
    const sectorDelta = [];
    Object.keys(cur).forEach(k => {
      const d = cur[k] - ((prevSectors && prevSectors[k]) || 0);
      if (d > 0) sectorDelta.push({ name: k, d: d });
    });
    sectorDelta.sort((a, b) => b.d - a.d);
    detail.deltaSector = sectorDelta.length ? sectorDelta[0] : null;
    rows.push({
      date, node,
      zt: ztList.length, zb: zbList.length,
      topSector: detail.sectors.length ? detail.sectors[0].name : '-',
      maxLb: detail.ladder.length ? detail.ladder[0].n : 0,
      ts: Date.now(), detail,
      deltaZt: ztList.length - prevZt,
      deltaZb: zbList.length - prevZb
    });
    prevZt = ztList.length;
    prevZb = zbList.length;
    prevSectors = cur;
  }
  return rows;
}

// 批量覆盖当天节点（其余日期保留）
function storeBackfill(rows) {
  if (!rows || !rows.length) return;
  const date = rows[0].date;
  const all = load().filter(s => s.date !== date).concat(rows);
  all.sort((a, b) => (a.date < b.date ? -1 : a.date > b.date ? 1 : (a.node < b.node ? -1 : 1)));
  localStorage.setItem(KEY, JSON.stringify(all.slice(-1200)));
}

async function grab(manual) {
  const msg = document.getElementById('msg');
  const btn = document.getElementById('fetchBtn');
  btn.disabled = true;
  try {
    const rows = await fetchBackfill();
    if (!rows.length) {
      if (manual) msg.textContent = '今天非交易日或接口暂未返回数据';
    } else {
      storeBackfill(rows);
      if (manual) msg.textContent = '已回填当日 ' + rows.length + ' 个节点（截至 ' + rows[rows.length - 1].node + '）';
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

function openDetail(snap) {
  renderDetail(snap);
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

  document.getElementById('dtitle').textContent = snap.node + ' 报告';
  document.getElementById('dbadge').textContent = '盘中跟进';
  document.getElementById('dsub').textContent = (snap.date || '') + ' 周' + week;
  document.getElementById('dzt').textContent = snap.zt;
  document.getElementById('dzb').textContent = snap.zb;
  document.getElementById('drate').textContent = rate + '%';
  document.getElementById('dtop').textContent = ds && ds.d > 0 ? ds.name.replace(/Ⅱ|Ⅰ/g, '') : '—';

  let html = '';
  html += '<div class="muted">A股盯盘快照 · 数据源 东方财富涨停池/炸板池</div>';
  html += '<div style="margin:8px 0;">涨停 <b>' + snap.zt + '</b> 家，炸板 <b>' + snap.zb + '</b> 家，炸板率约 ' + rate + '%。</div>';

  // 涨停板块分布（前五）
  html += '<h3>涨停板块分布（前五）：</h3>';
  if (sectors.length) {
    html += '<ol>' + sectors.map(x => '<li>' + escapeHtml(x.name) + '　' + x.n + ' 家</li>').join('') + '</ol>';
  } else { html += '<div class="none">暂无数据</div>'; }

  // 连板梯队
  html += '<h3>连板梯队：</h3>';
  html += '<div>' + (ladder.length
          ? ladder.map(x => x.n + ' 连板 ' + x.c + ' 家').join('，')
          : '暂无数据') + '</div>';
  html += '<div class="muted" style="margin-top:4px;">（2 板及以上 ' + lbCount + ' 家，首板 ' +
          (d.firstBoardCount != null ? d.firstBoardCount : '—') + ' 家）</div>';

  // 首批封板示例（前五）
  html += '<h3>首批封板示例（按封板时间前 5）：</h3>';
  if (first.length) {
    html += '<div>' + first.map(x => escapeHtml(x.name) + '（' + x.fbt + ' 首封）').join('、') + '</div>';
  } else { html += '<div class="none">暂无数据</div>'; }

  // 连板个股按封板时间前5
  html += '<h3>连板个股（按封板时间前 5）：</h3>';
  if (lbFirst.length) {
    html += '<div>' + lbFirst.map(x => escapeHtml(x.name) + '　' + x.lbc + ' 连板　' + x.fbt + ' 封板　' + escapeHtml(x.sector)).join('<br>') + '</div>';
  } else { html += '<div class="none">当前无连板个股</div>'; }

  // 节点变化与炸板
  html += '<h3>节点变化与炸板：</h3>';
  html += '<div>较上一节点：涨停 <b>' + dzTxt + '</b> 家，炸板 <b>' + dzbTxt + '</b> 家' +
          (ds && ds.d > 0 ? '，增量最多板块 <b>' + escapeHtml(ds.name) + '</b>（+' + ds.d + ' 家）' : '') + '。</div>';

  html += '<h3>说明</h3><div class="muted">本节点数据按东方财富首次封板时间回推，为当日已达节点的历史近似快照，非当时时点实时抓取。仅供参考，不构成投资建议。</div>';
  document.getElementById('dbody').innerHTML = html;
  document.getElementById('detailMask').classList.add('show');
}

function renderChart(byNode) {
  const box = document.getElementById('chart');
  if (!box) return;
  const maxZt = Math.max(1, ...NODES.map(n => byNode[n] ? byNode[n].zt : 0));
  const seg = (label, nodes) => {
    let h = '<div class="cseg-label">' + label + '</div><div class="cbar-row">';
    nodes.forEach(n => {
      const s = byNode[n];
      const pct = s ? Math.max(5, Math.round(s.zt / maxZt * 100)) : 0;
      h += '<div class="cbar-col">' +
             '<div class="cbar-val">' + (s ? s.zt : '-') + '</div>' +
             '<div class="cbar-track"><div class="cbar" style="height:' + pct + '%"></div></div>' +
             '<div class="cbar-time">' + n + '</div>' +
           '</div>';
    });
    return h + '</div>';
  };
  const done = NODES.filter(n => byNode[n]).length;
  box.innerHTML =
    '<div class="chead"><span>涨停家数走势</span><span class="cdone">已更新 ' + done + '/25</span></div>' +
    seg('早盘 9:40 – 11:30', NODES.slice(0, 12)) +
    seg('午盘 13:00 – 15:00', NODES.slice(12));
}

function render() {
  const now = beijingNow();
  const today = now.year + '-' + pad(now.month) + '-' + pad(now.day);
  const rows = load().filter(s => s.date === today && NODES.includes(s.node)).sort((a, b) => a.node < b.node ? -1 : 1);
  const latest = rows[rows.length - 1];
  document.getElementById('dateLabel').textContent = today + ' · ' + (latest ? latest.node + ' 快照' : '暂无数据');
  document.getElementById('zt').textContent = latest ? latest.zt : '—';
  document.getElementById('zb').textContent = latest ? latest.zb : '—';
  document.getElementById('ztDelta').textContent = latest ? '较上一节点 ' + (latest.deltaZt >= 0 ? '+' : '') + latest.deltaZt : '';
  document.getElementById('zbDelta').textContent = latest ? '较上一节点 ' + (latest.deltaZb >= 0 ? '+' : '') + latest.deltaZb : '';
  document.getElementById('sector').textContent = latest ? '最强板块：' + latest.topSector + '　最高连板：' + latest.maxLb + ' 板' : '';
  const byNode = {};
  rows.forEach(s => { byNode[s.node] = s; });
  renderChart(byNode);
  const nodeHtml = NODES.map(n => {
    const s = byNode[n];
    if (!s) return '<div class="row waiting"><span class="time">' + n + '</span><span class="info">待更新</span><span class="arrow">›</span></div>';
    const d = s.deltaZt >= 0 ? '+' + s.deltaZt : '' + s.deltaZt;
    return '<div class="row clickable" data-node="' + n + '"><span class="time">' + n + '</span><span class="info">涨停 ' + s.zt + ' · 炸板 ' + s.zb + ' · ' + s.topSector + '</span><span class="delta">' + d + '</span><span class="arrow">›</span></div>';
  }).join('');
  const timeline = document.getElementById('timeline');
  timeline.innerHTML = nodeHtml;
  timeline.querySelectorAll('.clickable').forEach(el => {
    el.addEventListener('click', () => {
      const node = el.getAttribute('data-node');
      const snap = byNode[node];
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
// 页面停留期间每 2 分钟回补一次（新节点到达后自动补上）
setInterval(() => { grab(false); }, 120000);

if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('sw.js').catch(() => {});
}

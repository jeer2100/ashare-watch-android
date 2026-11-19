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

function store(snap) {
  const all = load();
  const prev = all.filter(s => s.date === snap.date && s.node !== snap.node)
                  .sort((a, b) => a.node < b.node ? -1 : 1).pop();
  const row = Object.assign({}, snap, {
    deltaZt: prev ? snap.zt - prev.zt : snap.zt,
    deltaZb: prev ? snap.zb - prev.zb : snap.zb
  });
  const idx = all.findIndex(s => s.date === snap.date && s.node === snap.node);
  if (idx >= 0) all[idx] = row; else all.push(row);
  localStorage.setItem(KEY, JSON.stringify(all.slice(-1200)));
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

async function fetchSnap() {
  const now = beijingNow();
  if (now.weekday === 0 || now.weekday === 6) return null;
  if (!NODES.includes(now.node)) return null;
  const compact = '' + now.year + pad(now.month) + pad(now.day);
  const date = now.year + '-' + pad(now.month) + '-' + pad(now.day);
  const zt = await fetchPool('getTopicZTPool', compact, now.node);
  if (zt.qdate !== compact) return null;
  let zb = { tc: 0 };
  try { zb = await fetchPool('getTopicZBPool', compact, now.node); } catch (e) {}
  const counts = {};
  zt.pool.forEach(x => { const s = x.hybk; if (s) counts[s] = (counts[s] || 0) + 1; });
  const sector = Object.keys(counts).sort((a, b) => counts[b] - counts[a])[0] || '-';
  const maxLb = zt.pool.reduce((m, x) => Math.max(m, Number(x.lbc || 0)), 0);
  return { date, node: now.node, zt: zt.tc, zb: zb.tc, topSector: sector, maxLb, ts: Date.now() };
}

async function grab(manual) {
  const msg = document.getElementById('msg');
  const btn = document.getElementById('fetchBtn');
  btn.disabled = true;
  try {
    const snap = await fetchSnap();
    if (!snap) {
      if (manual) msg.textContent = '当前非抓取节点（交易日 9:40–11:30、13:00–15:00 每10分钟）';
    } else {
      store(snap);
      msg.textContent = '已抓取 ' + snap.node + '：涨停 ' + snap.zt + ' / 炸板 ' + snap.zb;
    }
  } catch (e) {
    if (manual) msg.textContent = '抓取失败：' + e.message;
  }
  btn.disabled = false;
  render();
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
  rows.forEach(s => { byNode[s.node] = s; });
  document.getElementById('timeline').innerHTML = NODES.map(n => {
    const s = byNode[n];
    if (!s) return '<div class="row waiting"><span class="time">' + n + '</span><span class="info">待更新</span></div>';
    const d = s.deltaZt >= 0 ? '+' + s.deltaZt : '' + s.deltaZt;
    return '<div class="row"><span class="time">' + n + '</span><span class="info">涨停 ' + s.zt + ' · 炸板 ' + s.zb + ' · ' + s.topSector + '</span><span class="delta">' + d + '</span></div>';
  }).join('');
}

document.getElementById('fetchBtn').addEventListener('click', () => grab(true));
render();
grab(false);
setInterval(() => {
  const n = beijingNow().node;
  if (NODES.includes(n)) {
    const snap = load().some(s => s.date && s.node === n && s.date === (function(){const x=beijingNow();return x.year+'-'+pad(x.month)+'-'+pad(x.day);})());
    if (!snap) grab(false);
  }
}, 60000);

if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('sw.js').catch(() => {});
}

import Foundation

/// The phone/tablet monitor served at http://<mac>:<port>/?key=… (open it by scanning the QR code).
enum MonitorPage {
    static let locked = #"""
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Unique AV RF Scan Co-ord – Monitor</title>
    <link rel="icon" href="/icon.png">
    <style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#0d0f12;color:#e7eaee;
    font:16px -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;text-align:center;padding:16px}</style></head>
    <body><div><img src="/icon.png" width="72" height="72" alt=""><h2>Unique AV RF Scan Co-ord</h2><p>This link needs an access key.<br>
    Scan the QR code on the Remote &amp; Companion page on the Mac.</p></div></body></html>
    """#

    static let html = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="theme-color" content="#0d0f12">
    <title>Unique AV RF Scan Co-ord – Monitor</title>
    <link rel="icon" href="/icon.png">
    <link rel="apple-touch-icon" href="/apple-touch-icon.png">
    <meta name="apple-mobile-web-app-title" content="UAV RF Monitor">
    <style>
    :root{--bg:#0d0f12;--card:#171a1f;--line:#262b33;--text:#e7eaee;--dim:#8b939e;--green:#34c759;--blue:#3d8bfd;
    --orange:#ff9f0a;--red:#ff453a;--yellow:#ffd60a}
    *{box-sizing:border-box}
    body{margin:0;background:var(--bg);color:var(--text);font:14px -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
    -webkit-font-smoothing:antialiased;padding:0 0 calc(16px + env(safe-area-inset-bottom))}
    header{position:sticky;top:0;z-index:5;background:rgba(13,15,18,.92);backdrop-filter:blur(10px);
    border-bottom:1px solid var(--line);padding:calc(10px + env(safe-area-inset-top)) 16px 10px;display:flex;gap:10px;align-items:center}
    header h1{font-size:16px;margin:0;flex:1;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
    header .sub{color:var(--dim);font-weight:400;font-size:13px}
    .pill{border-radius:999px;padding:3px 10px;font-size:12px;font-weight:600;background:var(--line);white-space:nowrap}
    .ok{background:rgba(52,199,89,.18);color:var(--green)}.warn{background:rgba(255,159,10,.18);color:var(--orange)}
    .crit{background:rgba(255,69,58,.2);color:var(--red)}
    main{padding:12px 16px;max-width:1200px;margin:0 auto}
    #alerts{display:flex;flex-direction:column;gap:6px;margin-bottom:12px}
    .alert{border-radius:10px;padding:8px 12px;border:1px solid}
    .alert.critical{background:rgba(255,69,58,.12);border-color:rgba(255,69,58,.4)}
    .alert.warning{background:rgba(255,159,10,.10);border-color:rgba(255,159,10,.35)}
    .alert b{display:block}.alert span{color:var(--dim);font-size:12px}
    #specwrap{background:#090a0c;border:1px solid var(--line);border-radius:12px;padding:6px;margin-bottom:12px}
    #spec{width:100%;height:170px;display:block}
    .bar{display:flex;gap:8px;align-items:center;margin-bottom:12px;flex-wrap:wrap}
    button{background:var(--line);color:var(--text);border:0;border-radius:8px;padding:8px 14px;font:inherit;font-weight:600}
    button:active{opacity:.7}
    #grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(230px,1fr));gap:10px}
    .card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:10px 12px}
    .card.critical{border-color:var(--red)}.card.warning{border-color:var(--orange)}
    .top{display:flex;align-items:center;gap:6px}
    .dot{width:8px;height:8px;border-radius:50%;background:var(--red);flex:none}.dot.on{background:var(--green)}
    .name{font-weight:700;font-size:15px;flex:1;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
    .n{color:var(--dim);font-size:11px}
    .dev{color:var(--dim);font-size:12px;margin:2px 0 4px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
    .freq{font:600 22px ui-monospace,SFMono-Regular,Menlo,monospace;letter-spacing:-.5px}
    .prop{color:var(--blue);font:12px ui-monospace,Menlo,monospace}
    .m{display:flex;align-items:center;gap:6px;margin-top:4px;font-size:11px;color:var(--dim)}
    .m label{width:28px}.m .v{width:30px;text-align:right;font-variant-numeric:tabular-nums}
    .track{flex:1;height:7px;background:#23272e;border-radius:3px;overflow:hidden}
    .fill{height:100%;border-radius:3px;transition:width .15s linear}
    .foot{display:flex;align-items:center;gap:8px;margin-top:8px;font-size:12px}
    .batt{display:flex;gap:2px;padding:2px;border:1px solid #555;border-radius:3px}
    .batt i{width:5px;height:10px;border-radius:1px;background:#2b3038}
    .tag{font-size:11px;border-radius:999px;padding:1px 8px;background:#2b3038}
    .mute{margin-left:auto}
    .mute.on{background:rgba(255,69,58,.25);color:var(--red)}
    .al{font-size:12px;margin-top:4px}.al.critical{color:var(--red)}.al.warning{color:var(--orange)}
    #conn{position:fixed;bottom:calc(10px + env(safe-area-inset-bottom));left:50%;transform:translateX(-50%);display:none}
    @media (max-width:420px){#grid{grid-template-columns:1fr}.freq{font-size:24px}}
    </style>
    </head>
    <body>
    <header>
      <img src="/icon.png" width="30" height="30" alt="" style="flex:none">
      <h1 id="title">Unique AV RF Scan Co-ord <span class="sub"></span></h1>
      <span id="scan" class="pill">Analyzer</span>
      <span id="health" class="pill ok">OK</span>
    </header>
    <main>
      <div id="alerts"></div>
      <div id="specwrap"><canvas id="spec"></canvas></div>
      <div class="bar" id="controls" style="display:none">
        <button id="scanbtn">Start scan</button>
      </div>
      <div id="grid"></div>
    </main>
    <div id="conn" class="pill crit">Connection lost – retrying…</div>
    <script>
    const KEY = new URLSearchParams(location.search).get('key') || '';
    const q = p => p + (p.includes('?') ? '&' : '?') + 'key=' + encodeURIComponent(KEY);
    const groupColors = ['#3d8bfd','#ff9f0a','#bf5af2','#ff375f','#40c8e0','#ffd60a','#66d4cf','#5e5ce6'];
    let control = false, scanning = false, failures = 0;

    function esc(s){ return String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])); }
    function meter(label, v, lo, hi, color){
      const f = v == null ? 0 : Math.max(0, Math.min(1, (v - lo) / (hi - lo)));
      return `<div class="m"><label>${label}</label><div class="track"><div class="fill" style="width:${(f*100).toFixed(1)}%;background:${color}"></div></div><span class="v">${v ?? '—'}</span></div>`;
    }
    function batt(b){
      let h = '<span class="batt">';
      for (let i = 0; i < 5; i++) {
        const c = b == null || i >= b ? '#2b3038' : (b <= 1 ? 'var(--red)' : b == 2 ? 'var(--orange)' : 'var(--green)');
        h += `<i style="background:${c}"></i>`;
      }
      return h + '</span>';
    }
    async function api(path){ const r = await fetch(q(path), {cache:'no-store'}); if (!r.ok) throw new Error(r.status); return r; }
    async function act(path){ try { await api(path); setTimeout(tick, 150); } catch(e) { alert('Command failed: ' + e.message); } }

    function render(s){
      control = s.control; scanning = s.analyzer.scanning;
      document.title = s.project + ' – ' + s.app;
      document.getElementById('title').innerHTML = esc(s.project) + ' <span class="sub">' + esc([s.venue, s.region].filter(Boolean).join(' · ')) + '</span>';
      const sc = document.getElementById('scan');
      sc.textContent = s.analyzer.scanning ? 'Scanning' : s.analyzer.connected ? 'Analyzer ready' : 'No analyzer';
      sc.className = 'pill ' + (s.analyzer.scanning ? 'ok' : '');
      const crit = s.alerts.filter(a => a.severity === 'critical').length;
      const h = document.getElementById('health');
      h.textContent = s.alerts.length ? `${s.alerts.length} alert${s.alerts.length > 1 ? 's' : ''}` : 'All OK';
      h.className = 'pill ' + (crit ? 'crit' : s.alerts.length ? 'warn' : 'ok');
      document.getElementById('alerts').innerHTML = s.alerts.slice(0, 6).map(a =>
        `<div class="alert ${a.severity}"><b>${esc(a.title)}</b><span>${esc(a.detail)}</span></div>`).join('');
      document.getElementById('controls').style.display = control ? 'flex' : 'none';
      document.getElementById('scanbtn').textContent = scanning ? 'Stop scan' : 'Start scan';
      document.getElementById('grid').innerHTML = s.channels.length ? s.channels.map(c => {
        const gc = c.groupColor == null ? null : groupColors[c.groupColor % groupColors.length];
        return `<div class="card ${c.severity || ''}">
          <div class="top"><span class="dot ${c.online ? 'on' : ''}"></span><span class="name">${esc(c.name)}</span><span class="n">#${c.n}</span></div>
          <div class="dev">${esc(c.device)} · ${esc(c.kind)}</div>
          <div class="freq">${c.freqMHz == null ? '—' : c.freqMHz.toFixed(3)}<span class="n"> MHz</span></div>
          ${c.proposedMHz != null ? `<div class="prop">→ ${c.proposedMHz.toFixed(3)} proposed</div>` : ''}
          ${meter('RF A', c.rfA, -100, -20, 'var(--blue)')}
          ${meter('RF B', c.rfB, -100, -20, 'var(--blue)')}
          ${meter('AF', c.audio, -50, 0, (c.audio ?? -99) >= -3 ? 'var(--red)' : 'var(--green)')}
          <div class="foot">${batt(c.battBars)}${c.battMin != null ? `<span>${Math.floor(c.battMin/60)}h ${c.battMin%60}m</span>` : ''}
            ${c.group ? `<span class="tag" style="background:${gc}33;color:${gc}">${esc(c.group)}</span>` : ''}
            ${c.mute != null ? (control
              ? `<button class="mute ${c.mute ? 'on' : ''}" onclick="act('/api/ch/${c.n}/mute/toggle')">${c.mute ? 'Muted' : 'Mute'}</button>`
              : (c.mute ? '<span class="tag mute on">Muted</span>' : '')) : ''}
          </div>
          ${c.alerts.slice(0, 2).map(a => `<div class="al ${c.severity}">⚠ ${esc(a)}</div>`).join('')}
        </div>`; }).join('') : '<p style="color:var(--dim)">No receivers in this project yet.</p>';
    }

    function drawSpectrum(sp){
      const cv = document.getElementById('spec'), dpr = window.devicePixelRatio || 1;
      const w = cv.clientWidth, h = cv.clientHeight;
      cv.width = w * dpr; cv.height = h * dpr;
      const g = cv.getContext('2d'); g.scale(dpr, dpr); g.clearRect(0, 0, w, h);
      const L = 30, T = 14, W = w - L - 4, H = h - T - 16, lo = sp.startKHz, hi = sp.stopKHz;
      const x = k => L + (k - lo) / (hi - lo) * W, y = d => T + (-20 - Math.max(-120, Math.min(-20, d))) / 100 * H;
      g.font = '9px -apple-system,sans-serif'; g.fillStyle = '#6b7380';
      const chW = sp.tv.length ? x(sp.tv[0].hi) - x(sp.tv[0].lo) : 99, every = Math.max(1, Math.ceil(16 / Math.max(1, chW)));
      sp.tv.forEach((t, i) => { if (+t.label % 2 === 0) { g.fillStyle = 'rgba(255,255,255,.035)'; g.fillRect(x(t.lo), T, x(t.hi) - x(t.lo), H); }
        if (+t.label % every === 0) { g.fillStyle = '#6b7380'; g.textAlign = 'center'; g.fillText(t.label, (x(t.lo) + x(t.hi)) / 2, 10); } });
      sp.restricted.forEach(b => { if (b.hi > lo && b.lo < hi) { g.fillStyle = 'rgba(255,69,58,.13)';
        const a = Math.max(L, x(b.lo)), z = Math.min(L + W, x(b.hi)); g.fillRect(a, T, z - a, H); } });
      g.textAlign = 'right'; g.strokeStyle = 'rgba(255,255,255,.07)';
      for (let d = -120; d <= -20; d += 20) { g.beginPath(); g.moveTo(L, y(d)); g.lineTo(L + W, y(d)); g.stroke(); g.fillStyle = '#6b7380'; g.fillText(d, L - 3, y(d) + 3); }
      g.textAlign = 'center';
      const span = (hi - lo) / 1000, step = [1,2,5,10,20,25,50,100].find(s => span / s <= 7) || 100;
      for (let f = Math.ceil(lo / 1000 / step) * step; f * 1000 <= hi; f += step) g.fillText(f, x(f * 1000), h - 3);
      g.setLineDash([4, 4]); g.strokeStyle = 'rgba(255,214,10,.5)'; g.beginPath(); g.moveTo(L, y(sp.threshold)); g.lineTo(L + W, y(sp.threshold)); g.stroke(); g.setLineDash([]);
      const trace = (arr, color, lw) => { if (!arr.length) return; g.strokeStyle = color; g.lineWidth = lw; g.beginPath(); let on = false;
        arr.forEach((v, i) => { if (v == null) { on = false; return; } const px = L + i / Math.max(1, arr.length - 1) * W, py = y(v);
          on ? g.lineTo(px, py) : g.moveTo(px, py); on = true; }); g.stroke(); };
      trace(sp.peak, 'rgba(255,159,10,.9)', 1); trace(sp.live, '#34c759', 1.2);
      g.lineWidth = 1;
      const rowEnd = [0, 0, 0, 0];   // right edge of the last label in each row, so labels never overlap
      sp.markers.forEach(m => { if (m.kHz < lo || m.kHz > hi) return; const px = x(m.kHz);
        g.strokeStyle = m.conflict ? '#ff453a' : 'rgba(64,200,224,.8)'; g.beginPath(); g.moveTo(px, T); g.lineTo(px, T + H); g.stroke();
        const tw = g.measureText(m.label).width, row = rowEnd.findIndex(e => px + 2 > e + 3);
        if (row < 0) return;
        rowEnd[row] = px + 2 + tw;
        g.fillStyle = m.conflict ? '#ff453a' : '#40c8e0'; g.textAlign = 'left'; g.fillText(m.label, px + 2, T + 9 + row * 10); });
    }

    async function tick(){
      try {
        const s = await (await api('/api/state')).json();
        render(s); failures = 0; document.getElementById('conn').style.display = 'none';
      } catch (e) {
        if (e.message === '401') { document.body.innerHTML = '<p style="padding:24px">Access key changed – scan the new QR code on the Mac.</p>'; return; }
        if (++failures > 2) document.getElementById('conn').style.display = 'block';
      }
    }
    async function spec(){ try { drawSpectrum(await (await api('/api/spectrum')).json()); } catch (e) {} }
    document.getElementById('scanbtn').onclick = () => act(scanning ? '/api/scan/stop' : '/api/scan/start');
    tick(); spec();
    setInterval(tick, 700);
    setInterval(spec, 1500);
    window.addEventListener('resize', spec);
    </script>
    </body>
    </html>
    """#
}

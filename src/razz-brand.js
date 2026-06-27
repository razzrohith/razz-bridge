/**
 * Razz Bridge brand overlay — injected into every page via nginx sub_filter.
 * Replaces vendor text in the operator UI with neutral branding.
 */
(function () {
  'use strict';

  var TITLE  = 'Remote Access';
  var OLD_RE = /TinyPilot|Tinypilot|tinypilot|TINYPILOT/g;

  /* ── force document.title ─────────────────────────────── */
  try {
    Object.defineProperty(document, 'title', {
      configurable: true,
      get: function () { return TITLE; },
      set: function () {}          // silently ignore writes from the app
    });
  } catch (e) {
    /* fallback if defineProperty blocked */
    document.title = TITLE;
  }

  /* ── replace text in a DOM node ──────────────────────── */
  function patchNode(node) {
    if (!node) return;
    if (node.nodeType === 3) {                    // TEXT_NODE
      var v = node.nodeValue;
      if (OLD_RE.test(v)) {
        node.nodeValue = v.replace(OLD_RE, TITLE);
        OLD_RE.lastIndex = 0;
      }
    } else if (node.nodeType === 1) {             // ELEMENT_NODE
      if (node.tagName === 'SCRIPT' || node.tagName === 'STYLE') return;
      /* patch attribute values that show vendor text */
      ['title', 'alt', 'placeholder', 'aria-label'].forEach(function (attr) {
        var val = node.getAttribute(attr);
        if (val && OLD_RE.test(val)) {
          node.setAttribute(attr, val.replace(OLD_RE, TITLE));
          OLD_RE.lastIndex = 0;
        }
      });
      for (var i = 0; i < node.childNodes.length; i++) {
        patchNode(node.childNodes[i]);
      }
      /* pierce shadow DOM if present */
      if (node.shadowRoot) patchNode(node.shadowRoot);
    }
  }

  /* ── run on current body ─────────────────────────────── */
  function run() {
    document.title = TITLE;          // belt-and-suspenders
    patchNode(document.body);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', run);
  } else {
    run();
  }

  /* ── watch for dynamic content (SPAs / web components) ── */
  document.addEventListener('DOMContentLoaded', function () {
    var obs = new MutationObserver(function (muts) {
      muts.forEach(function (m) {
        m.addedNodes.forEach(function (n) { patchNode(n); });
        if (m.type === 'characterData') patchNode(m.target);
      });
    });
    obs.observe(document.body, {
      childList: true,
      subtree: true,
      characterData: true
    });
    run();
  });
})();

/* ── Paste speed control ─────────────────────────────────────
 *
 * Intercepts keystroke API calls (fetch / XHR / WebSocket) that
 * fire in rapid succession during a paste event and spaces them
 * out with configurable, humanised timing.
 *
 * Detected automatically: if >2 keystroke requests arrive within
 * 15 ms of each other the queue kicks in. Normal single keystrokes
 * are never delayed.
 * ─────────────────────────────────────────────────────────── */
(function () {
  'use strict';

  var SPEED_KEY = 'razz_paste_ms';
  var curSpeed  = parseInt(localStorage.getItem(SPEED_KEY) || '45', 10);

  var SPEEDS = [
    { label: 'Paste: Instant',        ms: 0   },
    { label: 'Paste: Fast  (8 ms)',   ms: 8   },
    { label: 'Paste: Natural (45 ms)',ms: 45  },
    { label: 'Paste: Careful (120 ms)',ms:120 },
  ];

  /* ── Shared queue state ── */
  var _queue   = 0;     // accumulated delay (ms) for current paste burst
  var _lastHit = 0;     // timestamp of last intercepted keystroke
  var BURST_GAP = 15;   // ms — gap below this = paste burst

  function jitter(base) {
    // ±40 % random variance; occasional inter-word pause
    var v = base + base * (Math.random() * 0.8 - 0.4);
    if (Math.random() < 0.06) v += base * 2.5; // ~6 % chance of word-boundary pause
    return Math.max(6, Math.round(v));
  }

  function enqueue() {
    var now = Date.now();
    if (now - _lastHit < BURST_GAP) {
      var d = _queue;
      _queue += jitter(curSpeed);
      _lastHit = now;
      return d;           // > 0 means: delay this request by d ms
    }
    _queue   = 0;
    _lastHit = now;
    return -1;            // -1 means: fire immediately
  }

  function isKeystroke(url) {
    return typeof url === 'string' &&
           (url.indexOf('/api/keystroke') !== -1 ||
            url.indexOf('/api/key')       !== -1 ||
            url.indexOf('/keystrokes')    !== -1);
  }

  /* ── 1. Wrap fetch ── */
  if (window.fetch) {
    var _origFetch = window.fetch;
    window.fetch = function (url, opts) {
      if (curSpeed > 0 && isKeystroke(url)) {
        var d = enqueue();
        if (d >= 0) {
          return new Promise(function (res, rej) {
            setTimeout(function () {
              _origFetch.call(window, url, opts).then(res).catch(rej);
            }, d);
          });
        }
      }
      return _origFetch.apply(window, arguments);
    };
  }

  /* ── 2. Wrap XMLHttpRequest ── */
  var _OrigXHR = window.XMLHttpRequest;
  function PatchedXHR() {
    var xhr  = new _OrigXHR();
    var _url = '';
    var _origOpen = xhr.open.bind(xhr);
    var _origSend = xhr.send.bind(xhr);
    xhr.open = function (m, u) { _url = u || ''; return _origOpen.apply(xhr, arguments); };
    xhr.send = function () {
      if (curSpeed > 0 && isKeystroke(_url)) {
        var d = enqueue();
        if (d >= 0) {
          var a = arguments;
          setTimeout(function () { _origSend.apply(xhr, a); }, d);
          return;
        }
      }
      return _origSend.apply(xhr, arguments);
    };
    return xhr;
  }
  PatchedXHR.prototype = _OrigXHR.prototype;
  window.XMLHttpRequest = PatchedXHR;

  /* ── 3. Wrap WebSocket (TinyPilot may use WS for keystrokes) ── */
  if (window.WebSocket) {
    var _OrigWS = window.WebSocket;
    function PatchedWS(url, protos) {
      var ws = protos ? new _OrigWS(url, protos) : new _OrigWS(url);
      var _origSend = ws.send.bind(ws);
      ws.send = function (data) {
        if (curSpeed > 0 && typeof data === 'string') {
          try {
            var p = JSON.parse(data);
            if (p && (p.key !== undefined || p.type === 'keydown' ||
                      p.type === 'keystroke' || p.keyCode !== undefined)) {
              var d = enqueue();
              if (d >= 0) {
                setTimeout(function () { _origSend(data); }, d);
                return;
              }
            }
          } catch (e) { /* not JSON — pass through */ }
        }
        return _origSend(data);
      };
      return ws;
    }
    PatchedWS.prototype = _OrigWS.prototype;
    window.WebSocket = PatchedWS;
  }

  /* ── Speed selector widget (bottom-right corner) ── */
  function addWidget() {
    if (document.getElementById('razz-pc')) return;
    var w   = document.createElement('div');
    w.id    = 'razz-pc';
    var st  = [
      'position:fixed', 'bottom:10px', 'right:10px', 'z-index:2147483647',
      'background:rgba(10,10,10,0.88)', 'border:1px solid #242424',
      'border-radius:8px', 'padding:5px 10px', 'display:flex',
      'align-items:center', 'gap:6px',
      'font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif',
      'font-size:10px', 'color:#444', 'user-select:none',
      'backdrop-filter:blur(8px)', '-webkit-backdrop-filter:blur(8px)',
    ].join(';');
    w.setAttribute('style', st);
    var opts = SPEEDS.map(function (s) {
      return '<option value="' + s.ms + '">' + s.label + '</option>';
    }).join('');
    w.innerHTML =
      '<span style="font-size:12px;opacity:.5">&#9000;</span>' +
      '<select id="razz-spd" style="background:#080808;color:#777;border:1px solid #1e1e1e;' +
      'border-radius:5px;padding:2px 5px;font-size:10px;outline:none;cursor:pointer">' +
      opts + '</select>';
    document.body.appendChild(w);
    var sel = document.getElementById('razz-spd');
    sel.value = String(curSpeed);
    if (!sel.value) sel.value = '45';
    sel.addEventListener('change', function () {
      curSpeed = parseInt(this.value, 10);
      localStorage.setItem(SPEED_KEY, curSpeed);
      _queue = 0;
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', addWidget);
  } else {
    setTimeout(addWidget, 800);
  }
})();

/* ─────────────────────────────────────────────────────────────────
 * Razz Bridge — WiFi Management Widget
 * Floating button (bottom-left) on the main KVM page.
 * Calls /api/wifi/* — proxied by nginx to stealth-dashboard.
 * No auth required (LAN-only, inside firewall).
 * ───────────────────────────────────────────────────────────────── */
(function () {
  'use strict';

  /* ── State ───────────────────────────────────────────────────── */
  var PANEL_OPEN  = false;
  var scanResults = [];
  var savedNets   = [];
  var curSSID     = '';

  /* ── API helpers ─────────────────────────────────────────────── */
  function wfetch(path, body) {
    var opts = body !== undefined
      ? { method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(body) }
      : {};
    return fetch(path, opts).then(function (r) { return r.json(); });
  }

  /* ── Create DOM ──────────────────────────────────────────────── */
  function buildWidget() {
    if (document.getElementById('razz-wifi-btn')) return;

    /* inject styles */
    var style = document.createElement('style');
    style.textContent = [
      '#razz-wifi-btn{',
        'position:fixed;bottom:10px;left:10px;z-index:2147483646;',
        'background:rgba(10,10,10,.88);border:1px solid #242424;',
        'border-radius:8px;padding:5px 10px;',
        'font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;',
        'font-size:10px;color:#555;user-select:none;cursor:pointer;',
        'display:flex;align-items:center;gap:5px;',
        'backdrop-filter:blur(8px);-webkit-backdrop-filter:blur(8px);',
        'transition:color .2s;',
      '}',
      '#razz-wifi-btn:hover{color:#aaa;}',
      '#razz-wifi-panel{',
        'position:fixed;bottom:38px;left:10px;z-index:2147483645;',
        'width:300px;max-height:460px;overflow-y:auto;',
        'background:#0d0d0d;border:1px solid #1e1e1e;border-radius:10px;',
        'font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;',
        'font-size:12px;color:#bbb;',
        'box-shadow:0 8px 32px rgba(0,0,0,.7);',
        'display:none;',
      '}',
      '#razz-wifi-panel.open{display:block;}',
      '.rwp-header{',
        'padding:10px 12px;border-bottom:1px solid #1a1a1a;',
        'font-size:11px;font-weight:600;color:#666;',
        'text-transform:uppercase;letter-spacing:.07em;',
        'display:flex;align-items:center;justify-content:space-between;',
      '}',
      '.rwp-sec{padding:10px 12px;border-bottom:1px solid #141414;}',
      '.rwp-sec:last-child{border-bottom:none;}',
      '.rwp-label{font-size:10px;color:#444;margin-bottom:6px;}',
      '.rwp-net{',
        'display:flex;align-items:center;gap:6px;',
        'padding:7px 8px;border-radius:6px;',
        'cursor:pointer;margin-bottom:3px;',
        'transition:background .15s;',
      '}',
      '.rwp-net:hover{background:#161616;}',
      '.rwp-net.active{background:#0d1e30;color:#4a9eff;}',
      '.rwp-net-ssid{flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}',
      '.rwp-net-sig{font-size:10px;color:#383838;flex-shrink:0;}',
      '.rwp-net-del{',
        'font-size:11px;color:#2a2a2a;flex-shrink:0;cursor:pointer;',
        'padding:2px 4px;border-radius:4px;transition:color .15s;',
      '}',
      '.rwp-net-del:hover{color:#c04040;}',
      '.rwp-input{',
        'width:100%;padding:6px 8px;',
        'background:#080808;border:1px solid #1c1c1c;border-radius:6px;',
        'color:#ccc;font-size:12px;outline:none;margin-bottom:6px;',
      '}',
      '.rwp-input:focus{border-color:#3a6aa0;}',
      '.rwp-btn{',
        'display:block;width:100%;padding:7px;',
        'background:#1a2a3f;border:1px solid #1e3a5f;border-radius:6px;',
        'color:#5a9eff;font-size:11px;font-weight:500;cursor:pointer;',
        'transition:opacity .15s;',
      '}',
      '.rwp-btn:active{opacity:.7;}',
      '.rwp-btn-sm{',
        'padding:5px 8px;font-size:10px;width:auto;',
        'background:#111;border:1px solid #1e1e1e;color:#555;',
        'border-radius:5px;cursor:pointer;',
      '}',
      '.rwp-status{',
        'font-size:10px;padding:4px 0;min-height:14px;color:#444;',
      '}',
      '.rwp-status.ok{color:#3a9a60;}',
      '.rwp-status.er{color:#b03030;}',
      '.rwp-status.wa{color:#8a6020;}',
      '.rwp-loading{color:#2a2a2a;font-size:10px;padding:6px 0;}',
    ].join('');
    document.head.appendChild(style);

    /* floating button */
    var btn = document.createElement('div');
    btn.id = 'razz-wifi-btn';
    btn.setAttribute('role', 'button');
    btn.setAttribute('aria-label', 'WiFi management');
    btn.setAttribute('tabindex', '0');
    btn.innerHTML = '<span>&#x1F4F6;</span><span id="razz-wifi-ssid">WiFi</span>';
    btn.addEventListener('click', togglePanel);
    btn.addEventListener('keydown', function (e) {
      if (e.key === 'Enter' || e.key === ' ') togglePanel();
    });
    document.body.appendChild(btn);

    /* panel */
    var panel = document.createElement('div');
    panel.id = 'razz-wifi-panel';
    panel.setAttribute('role', 'dialog');
    panel.setAttribute('aria-label', 'WiFi management');
    panel.innerHTML = [
      '<div class="rwp-header">',
        '<span>📶 WiFi</span>',
        '<button class="rwp-btn-sm" onclick="document.getElementById(\'razz-wifi-panel\').classList.remove(\'open\')" ',
          'aria-label="Close">✕</button>',
      '</div>',

      /* current connection */
      '<div class="rwp-sec" id="rwp-current">',
        '<div class="rwp-label">CURRENT CONNECTION</div>',
        '<div id="rwp-cur-ssid" style="color:#888;font-size:12px;">Loading…</div>',
      '</div>',

      /* saved networks */
      '<div class="rwp-sec">',
        '<div class="rwp-label" style="margin-bottom:4px;">SAVED NETWORKS</div>',
        '<div id="rwp-saved-list" class="rwp-loading">Loading…</div>',
      '</div>',

      /* scan */
      '<div class="rwp-sec">',
        '<div class="rwp-label" style="display:flex;align-items:center;justify-content:space-between;margin-bottom:4px;">',
          '<span>NEARBY NETWORKS</span>',
          '<button class="rwp-btn-sm" onclick="rwpScan()" id="rwp-scan-btn">↺ Scan</button>',
        '</div>',
        '<div id="rwp-scan-list" class="rwp-loading">Press Scan to search.</div>',
      '</div>',

      /* add network */
      '<div class="rwp-sec" id="rwp-add-sec">',
        '<div class="rwp-label">ADD NETWORK</div>',
        '<div id="rwp-selected" style="font-size:11px;color:#3a6a9a;margin-bottom:6px;min-height:14px;"></div>',
        '<input class="rwp-input" id="rwp-new-ssid" placeholder="Network name (SSID)"',
          ' autocorrect="off" autocapitalize="none" autocomplete="off">',
        '<input class="rwp-input" id="rwp-new-pass" type="password" placeholder="Password (blank = open)">',
        '<button class="rwp-btn" onclick="rwpAdd()">Save network</button>',
        '<div class="rwp-status" id="rwp-add-st"></div>',
      '</div>',
    ].join('');
    document.body.appendChild(panel);

    loadStatus();
    loadSaved();
  }

  /* ── Toggle panel ─────────────────────────────────────────────── */
  function togglePanel() {
    var panel = document.getElementById('razz-wifi-panel');
    if (!panel) return;
    PANEL_OPEN = !PANEL_OPEN;
    panel.classList.toggle('open', PANEL_OPEN);
    if (PANEL_OPEN) { loadStatus(); loadSaved(); }
  }

  /* ── Status ──────────────────────────────────────────────────── */
  function loadStatus() {
    wfetch('/api/wifi/status').then(function (d) {
      curSSID = d.ssid || '';
      var ssidEl = document.getElementById('razz-wifi-ssid');
      var curEl  = document.getElementById('rwp-cur-ssid');
      if (ssidEl) ssidEl.textContent = curSSID || 'No WiFi';
      if (curEl) {
        if (d.connected && curSSID) {
          curEl.innerHTML =
            '<span style="color:#3a9a60">●</span> ' + esc(curSSID) +
            (d.ip ? ' <span style="color:#333">(' + esc(d.ip) + ')</span>' : '') +
            (d.signal ? ' <span style="color:#2a2a2a">' + d.signal + '%</span>' : '');
        } else {
          curEl.innerHTML = '<span style="color:#555">Not connected</span>';
        }
      }
    }).catch(function () {
      var curEl = document.getElementById('rwp-cur-ssid');
      if (curEl) curEl.textContent = 'Status unavailable';
    });
  }

  /* ── Saved networks ───────────────────────────────────────────── */
  function loadSaved() {
    var el = document.getElementById('rwp-saved-list');
    if (!el) return;
    el.textContent = 'Loading…';
    el.className = 'rwp-loading';
    wfetch('/api/wifi/saved').then(function (nets) {
      savedNets = nets;
      if (!nets.length) {
        el.textContent = 'No saved networks.';
        return;
      }
      el.className = '';
      el.innerHTML = nets.map(function (n) {
        return '<div class="rwp-net' + (n.active ? ' active' : '') + '">' +
          '<span class="rwp-net-ssid">' + esc(n.name) + (n.active ? ' ✓' : '') + '</span>' +
          '<span class="rwp-net-del" onclick="rwpRemove(\'' + escAttr(n.name) + '\')" ' +
            'role="button" aria-label="Remove ' + esc(n.name) + '" title="Remove">✕</span>' +
          '</div>';
      }).join('');
    }).catch(function () {
      el.textContent = 'Could not load saved networks.';
    });
  }

  /* ── Scan ────────────────────────────────────────────────────── */
  function rwpScan() {
    var el  = document.getElementById('rwp-scan-list');
    var btn = document.getElementById('rwp-scan-btn');
    if (!el) return;
    el.className = 'rwp-loading';
    el.textContent = 'Scanning…';
    if (btn) btn.disabled = true;
    wfetch('/api/wifi/scan').then(function (nets) {
      scanResults = nets;
      if (!nets.length) {
        el.textContent = 'No networks found.';
        if (btn) btn.disabled = false;
        return;
      }
      el.className = '';
      el.innerHTML = nets.map(function (n) {
        var bars = sigBars(n.signal);
        return '<div class="rwp-net" onclick="rwpSelect(\'' + escAttr(n.ssid) + '\')">' +
          (n.secure ? '<span title="Secured" style="color:#333;font-size:10px">🔒</span>' : '') +
          '<span class="rwp-net-ssid">' + esc(n.ssid) + '</span>' +
          '<span class="rwp-net-sig">' + bars + ' ' + n.signal + '%</span>' +
          '</div>';
      }).join('');
      if (btn) btn.disabled = false;
    }).catch(function () {
      el.textContent = 'Scan failed.';
      if (btn) btn.disabled = false;
    });
  }

  function rwpSelect(ssid) {
    var inp = document.getElementById('rwp-new-ssid');
    var sel = document.getElementById('rwp-selected');
    if (inp) inp.value = ssid;
    if (sel) sel.textContent = 'Selected: ' + ssid;
    var passEl = document.getElementById('rwp-new-pass');
    if (passEl) passEl.focus();
  }

  /* ── Add network ─────────────────────────────────────────────── */
  function rwpAdd() {
    var ssid = (document.getElementById('rwp-new-ssid') || {}).value || '';
    var pass = (document.getElementById('rwp-new-pass') || {}).value || '';
    var st   = document.getElementById('rwp-add-st');
    ssid = ssid.trim();
    if (!ssid) { rwpSt(st, 'Enter a network name.', 'er'); return; }
    rwpSt(st, 'Saving…', 'wa');
    wfetch('/api/wifi/add', { ssid: ssid, password: pass }).then(function (r) {
      if (r.ok) {
        rwpSt(st, '✓ Saved — Pi will connect on next available opportunity.', 'ok');
        document.getElementById('rwp-new-ssid').value = '';
        document.getElementById('rwp-new-pass').value = '';
        document.getElementById('rwp-selected').textContent = '';
        setTimeout(function () { loadSaved(); loadStatus(); }, 1500);
      } else {
        rwpSt(st, '✗ ' + (r.error || 'Failed to save.'), 'er');
      }
    }).catch(function () {
      rwpSt(st, '✗ Network error.', 'er');
    });
  }

  /* ── Remove network ──────────────────────────────────────────── */
  function rwpRemove(name) {
    if (!confirm('Remove "' + name + '" from saved networks?')) return;
    wfetch('/api/wifi/remove', { name: name }).then(function (r) {
      if (r.ok) loadSaved();
    }).catch(function () {});
  }

  /* ── Utility ─────────────────────────────────────────────────── */
  function rwpSt(el, msg, type) {
    if (!el) return;
    el.textContent = msg;
    el.className = 'rwp-status ' + (type || '');
  }

  function esc(s) {
    return String(s)
      .replace(/&/g,'&amp;').replace(/</g,'&lt;')
      .replace(/>/g,'&gt;').replace(/"/g,'&quot;');
  }
  function escAttr(s) {
    return String(s).replace(/'/g, "\\'").replace(/</g,'&lt;');
  }
  function sigBars(pct) {
    var n = Math.min(4, Math.max(0, Math.ceil((pct || 0) / 25)));
    return '▂▄▆█'.slice(0, n) || '·';
  }

  /* make rwpSelect/rwpScan/rwpRemove/rwpAdd available from inline onclick */
  window.rwpScan   = rwpScan;
  window.rwpSelect = rwpSelect;
  window.rwpRemove = rwpRemove;
  window.rwpAdd    = rwpAdd;

  /* ── Mount ───────────────────────────────────────────────────── */
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', buildWidget);
  } else {
    setTimeout(buildWidget, 900);
  }

  /* Refresh status every 30s (passive, no scan) */
  setInterval(function () {
    if (document.getElementById('razz-wifi-btn')) loadStatus();
  }, 30000);
})();

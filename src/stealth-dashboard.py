#!/usr/bin/env python3
"""Razz Bridge Stealth Dashboard v2 — auth + VID/PID + profiles + stats"""
import json, os, subprocess, re, time, secrets, hashlib, logging, threading
from flask import Flask, jsonify, request, render_template_string, session, redirect

# ── App ──────────────────────────────────────────────────────────────────────
app = Flask(__name__)
app.config.update(SESSION_COOKIE_HTTPONLY=True, SESSION_COOKIE_SAMESITE="Lax")

CONFIG          = "/etc/stealth-config.json"
USB_DIR         = "/sys/kernel/config/usb_gadget/g1"
GADGET          = "/opt/tinypilot-privileged/init-usb-gadget"
MAC_SH          = "/usr/local/bin/mac-spoof.sh"
NGINX           = "/etc/nginx/conf.d/tinypilot.conf"
SSHD            = "/etc/ssh/sshd_config"
AUTH_LOG        = "/var/log/razz-auth.log"
SESS_LOG        = "/var/log/razz-sessions.log"
SESSION_TIMEOUT = 1800   # 30 min

# Fail2ban-compatible auth logging
_al = logging.getLogger("razz")
_al.setLevel(logging.INFO)
try:
    _fh = logging.FileHandler(AUTH_LOG)
    _fh.setFormatter(logging.Formatter("%(asctime)s %(message)s"))
    _al.addHandler(_fh)
except Exception:
    pass

# Original TinyPilot values — install.sh substitutes __ETH0_MAC__ / __WLAN0_MAC__
ORIG = {
    "usb_manufacturer": "tinypilot",
    "usb_product":      "Multifunction USB Device",
    "usb_serial":       "6b65796d696d6570690",
    "usb_idVendor":     "0x1d6b",   # Linux Foundation
    "usb_idProduct":    "0x0104",   # Multifunction Composite Gadget
    "eth0_mac":  "__ETH0_MAC__",
    "wlan0_mac": "__WLAN0_MAC__",
}

USB_PROFILES = [
    {"name":"Logitech K120",       "manufacturer":"Logitech",   "product":"USB Keyboard K120",    "idVendor":"0x046d","idProduct":"0xc31c","pfx":"046D20"},
    {"name":"Microsoft Wired 600", "manufacturer":"Microsoft",  "product":"Wired Keyboard 600",   "idVendor":"0x045e","idProduct":"0x0750","pfx":"045E07"},
    {"name":"Dell KB216",          "manufacturer":"Dell",       "product":"KB216 Wired Keyboard", "idVendor":"0x413c","idProduct":"0x2003","pfx":"413C21"},
    {"name":"HP KU-0316",          "manufacturer":"HP",         "product":"KU-0316 Keyboard",     "idVendor":"0x03f0","idProduct":"0x0224","pfx":"03F002"},
    {"name":"Corsair K55 RGB",     "manufacturer":"Corsair",    "product":"K55 RGB Keyboard",     "idVendor":"0x1b1c","idProduct":"0x1b48","pfx":"1B1C1B"},
]

# ── helpers ──────────────────────────────────────────────────────────────────
def sh(cmd):
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    return r.stdout.strip()

def load_cfg():
    try:
        with open(CONFIG) as f: return json.load(f)
    except Exception:
        return {}

def save_cfg(cfg):
    with open(CONFIG, "w") as f: json.dump(cfg, f, indent=2)

def live_usb():
    out = {}
    for k in ["manufacturer", "product", "serialnumber"]:
        out[k] = sh(f"cat {USB_DIR}/strings/0x409/{k} 2>/dev/null")
    try:
        out["idVendor"]  = open(f"{USB_DIR}/idVendor").read().strip()
        out["idProduct"] = open(f"{USB_DIR}/idProduct").read().strip()
    except Exception:
        out["idVendor"] = out["idProduct"] = ""
    return out

def live_mac():
    return {
        "eth0":  sh("ip link show eth0  2>/dev/null | awk '/link\\/ether/{print $2}'"),
        "wlan0": sh("ip link show wlan0 2>/dev/null | awk '/link\\/ether/{print $2}'"),
    }

def real_ip():
    return request.headers.get("X-Real-IP", request.remote_addr)

def _log_session(msg):
    try:
        with open(SESS_LOG, "a") as f:
            f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} | {msg}\n")
    except Exception:
        pass

# ── auth ─────────────────────────────────────────────────────────────────────
def _init_secret():
    cfg = load_cfg()
    key = cfg.get("auth", {}).get("secret_key")
    if not key:
        key = secrets.token_hex(32)
        cfg.setdefault("auth", {})["secret_key"] = key
        save_cfg(cfg)
    app.secret_key = key

def _check_pw(pw):
    cfg = load_cfg()
    h = cfg.get("auth", {}).get("password_hash", "")
    return bool(h) and hashlib.sha256(pw.encode()).hexdigest() == h

def _authed():
    if not session.get("ok"):
        return False
    if time.time() - session.get("t", 0) > SESSION_TIMEOUT:
        session.clear()
        return False
    session["t"] = time.time()
    return True

def _deny():
    if "application/json" in request.headers.get("Accept", ""):
        return jsonify({"error": "auth"}), 401
    return redirect("https://" + request.host + "/stealth/login")

# ── USB / MAC identity ────────────────────────────────────────────────────────
def _rebind_gadget(fn):
    """Unbind UDC, run fn(), rebind — allows VID/PID change live."""
    udc = sh(f"cat {USB_DIR}/UDC 2>/dev/null")
    if udc:
        sh(f"echo '' > {USB_DIR}/UDC 2>/dev/null || true")
        time.sleep(0.5)
    fn()
    if udc:
        time.sleep(0.3)
        sh(f"echo '{udc}' > {USB_DIR}/UDC 2>/dev/null || true")

def _write_usb_sysfs(mfr, prod, serial, idVendor=None, idProduct=None):
    def _do():
        for field, val in [("manufacturer", mfr), ("product", prod), ("serialnumber", serial)]:
            sh(f"echo '{val}' > {USB_DIR}/strings/0x409/{field} 2>/dev/null || true")
        if idVendor:
            sh(f"echo '{idVendor}' > {USB_DIR}/idVendor  2>/dev/null || true")
        if idProduct:
            sh(f"echo '{idProduct}' > {USB_DIR}/idProduct 2>/dev/null || true")
    if idVendor or idProduct:
        _rebind_gadget(_do)
    else:
        _do()

def _patch_gadget_script(mfr, prod, serial, idVendor=None, idProduct=None):
    try:
        with open(GADGET) as f: c = f.read()
        c = re.sub(r'echo "[^"]*" > "\$\{USB_STRINGS_DIR\}/manufacturer"', f'echo "{mfr}" > "${{USB_STRINGS_DIR}}/manufacturer"', c)
        c = re.sub(r'echo "[^"]*" > "\$\{USB_STRINGS_DIR\}/product"',      f'echo "{prod}" > "${{USB_STRINGS_DIR}}/product"', c)
        c = re.sub(r'echo "[^"]*" > "\$\{USB_STRINGS_DIR\}/serialnumber"', f'echo "{serial}" > "${{USB_STRINGS_DIR}}/serialnumber"', c)
        if idVendor:
            c = re.sub(r'echo \S+ > "\$\{GADGET_DIR\}/idVendor"',  f'echo {idVendor}  > "${{GADGET_DIR}}/idVendor"', c)
        if idProduct:
            c = re.sub(r'echo \S+ > "\$\{GADGET_DIR\}/idProduct"', f'echo {idProduct} > "${{GADGET_DIR}}/idProduct"', c)
        with open(GADGET, "w") as f: f.write(c)
    except Exception:
        pass

def _set_usb_identity(mfr, prod, serial, idVendor=None, idProduct=None):
    _write_usb_sysfs(mfr, prod, serial, idVendor, idProduct)
    _patch_gadget_script(mfr, prod, serial, idVendor, idProduct)

def _set_mac_address(eth0, wlan0):
    try:
        with open(MAC_SH) as f: c = f.read()
        c = re.sub(r'\nspoof_mac eth0[^\n]*',  '', c)
        c = re.sub(r'\nspoof_mac wlan0[^\n]*', '', c)
        c += f'\nspoof_mac eth0  "{eth0}"\nspoof_mac wlan0 "{wlan0}"\n'
        with open(MAC_SH, "w") as f: f.write(c)
    except Exception:
        pass
    sh(f"ip link set eth0 address {eth0} 2>/dev/null || true")
    subprocess.Popen(
        f"sleep 2 && ip link set wlan0 down && ip link set wlan0 address {wlan0} && ip link set wlan0 up",
        shell=True, start_new_session=True)

def set_ssh_banner(on):
    try:
        with open(SSHD) as f: c = f.read()
        c = re.sub(r'\nDebianBanner\s+\w+', '', c)
        if on: c += "\nDebianBanner no"
        with open(SSHD, "w") as f: f.write(c)
        sh("systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null")
    except Exception:
        pass

def set_razz_block(on):
    try:
        with open(NGINX) as f: c = f.read()
        c = re.sub(r'\n\s*location = /razz/remote/status \{[^}]*\}\n?', '\n', c)
        if on:
            blk = '\n    location = /razz/remote/status {\n        return 403;\n    }'
            idx = c.rfind("}")
            c = c[:idx] + blk + "\n}"
        with open(NGINX, "w") as f: f.write(c)
        sh("nginx -t && systemctl reload nginx")
    except Exception:
        pass

# ── HTML ──────────────────────────────────────────────────────────────────────
LOGIN_HTML = """<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Stealth Panel</title><style>
*{box-sizing:border-box;margin:0;padding:0}
body{background:#080808;color:#ddd;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;min-height:100vh;display:flex;align-items:center;justify-content:center}
.box{background:#111;border:1px solid #1c1c1c;border-radius:14px;padding:36px 40px;width:300px;box-shadow:0 20px 60px rgba(0,0,0,.7)}
h2{font-size:16px;font-weight:600;color:#fff;margin-bottom:3px}
.sub{color:#444;font-size:11px;margin-bottom:26px}
label{display:block;font-size:10px;font-weight:700;color:#555;text-transform:uppercase;letter-spacing:1px;margin-bottom:7px}
input{width:100%;background:#0a0a0a;border:1px solid #222;color:#e0e0e0;padding:10px 12px;border-radius:7px;font-size:14px;outline:none;margin-bottom:14px}
input:focus{border-color:#3a5a8a}
button{display:block;width:100%;padding:10px;border-radius:7px;border:1px solid #2a5a2a;background:#0d2d0d;color:#4ade80;font-size:13px;font-weight:600;cursor:pointer}
button:hover{background:#1a4a1a}
.err{color:#f87171;font-size:11px;margin-top:10px;text-align:center}
</style></head>
<body><div class="box">
  <h2>&#11041; Stealth Panel</h2>
  <div class="sub">Razz Bridge &middot; Identity Management</div>
  <form method="post" action="/stealth/login">
    <label>Panel Password</label>
    <input type="password" name="password" autofocus>
    <button type="submit">Unlock</button>
  </form>
  {% if error %}<div class="err">&#10007; Wrong password</div>{% endif %}
</div></body></html>"""


MAIN_HTML = r"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Stealth Panel</title><style>
*{box-sizing:border-box;margin:0;padding:0}
body{background:#0a0a0a;color:#ddd;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;padding:24px 18px;max-width:720px;margin:0 auto}
h1{font-size:16px;font-weight:600;color:#fff}
.sub{color:#444;font-size:11px;margin-top:2px}
.top{display:flex;align-items:flex-start;justify-content:space-between;margin-bottom:20px}
.top-btns{display:flex;gap:8px}
.card{background:#111;border:1px solid #1c1c1c;border-radius:10px;padding:16px 18px;margin-bottom:10px}
.ch{display:flex;align-items:center;justify-content:space-between;margin-bottom:12px}
.ct{font-size:10px;font-weight:700;color:#555;text-transform:uppercase;letter-spacing:1.2px}
.bg{display:flex;gap:7px;align-items:center;flex-wrap:wrap}
.badge{padding:2px 9px;border-radius:20px;font-size:10px;font-weight:700;letter-spacing:.4px}
.on{background:#0d2214;color:#4ade80;border:1px solid #1a4428}
.off{background:#1e0e0e;color:#f87171;border:1px solid #3a1a1a}
.row{display:flex;align-items:center;gap:10px;padding:8px 0;border-bottom:1px solid #181818}
.row:last-child{border:none;padding-bottom:0}
.lbl{color:#555;font-size:11px;width:108px;flex-shrink:0}
.val{font-family:'SF Mono',Menlo,monospace;font-size:11px;color:#e0e0e0;flex:1;word-break:break-all}
.orig{color:#2a2a2a;font-size:10px;font-family:monospace;white-space:nowrap}
.btn{padding:4px 11px;border-radius:6px;border:1px solid #252525;background:#181818;color:#999;font-size:11px;font-weight:500;cursor:pointer;transition:all .12s;white-space:nowrap}
.btn:hover{background:#222;color:#ddd;border-color:#3a3a3a}
.btn-r{border-color:#3a1a1a;color:#f87171;background:#160c0c}.btn-r:hover{background:#1e1010}
.btn-g{border-color:#1a3a1a;color:#4ade80;background:#0a160a}.btn-g:hover{background:#102010}
.btn-b{border-color:#1a2a4a;color:#60a5fa;background:#0a1220}.btn-b:hover{background:#101828}
.btn-y{border-color:#3a2a00;color:#facc15;background:#1a1200}.btn-y:hover{background:#241800}
.note{color:#333;font-size:10px;margin-top:7px}
.form{background:#0d0d0d;border:1px solid #1e1e1e;border-radius:7px;padding:12px 14px;margin-top:10px;display:none}
.fr{display:flex;align-items:center;gap:8px;margin-bottom:7px}
.fr label{color:#555;font-size:10px;width:80px;flex-shrink:0}
.fr input{flex:1;background:#0a0a0a;border:1px solid #222;color:#e0e0e0;padding:6px 9px;border-radius:5px;font-family:monospace;font-size:11px;outline:none}
.fr input:focus{border-color:#3a5a8a}
.fa{display:flex;gap:7px;margin-top:6px;flex-wrap:wrap}
.profile-row{display:flex;gap:6px;flex-wrap:wrap;margin:10px 0 4px}
.pbtn{padding:5px 12px;border-radius:6px;border:1px solid #1e2e1e;background:#0d1a0d;color:#6ee7a0;font-size:11px;cursor:pointer;transition:all .12s}
.pbtn:hover{background:#1a3a1a;border-color:#3a6a3a}
.pbtn.active{background:#1a4a1a;border-color:#4ade80;color:#fff}
.stats-bar{display:grid;grid-template-columns:repeat(auto-fit,minmax(120px,1fr));gap:8px;margin-bottom:10px}
.stat{background:#111;border:1px solid #1c1c1c;border-radius:8px;padding:10px 14px}
.stat-val{font-size:16px;font-weight:600;color:#fff;margin-bottom:2px;font-family:monospace}
.stat-lbl{font-size:9px;color:#444;text-transform:uppercase;letter-spacing:1px}
.stat-val.ok{color:#4ade80}
.stat-val.warn{color:#facc15}
.stat-val.err{color:#f87171}
.log-list{max-height:160px;overflow-y:auto;margin-top:8px}
.log-entry{font-size:10px;font-family:monospace;color:#555;padding:3px 0;border-bottom:1px solid #141414}
.log-entry:last-child{border:none}
.safe-card{border-color:#3a2a00}
.apply-btn{background:#0d2d0d;color:#5f5;border:1px solid #3a8;padding:8px 14px;border-radius:7px;cursor:pointer;font-size:12px;margin-bottom:8px;display:block;width:100%;text-align:left;transition:background .15s}
.apply-btn:hover{background:#1a4a1a}
.apply-btn-o{background:#2d1a00;color:#fa6;border:1px solid #a60}.apply-btn-o:hover{background:#4d2a00}
.reboot-btn-top{padding:7px 14px;border-radius:7px;border:1px solid #2a1a1a;background:#160c0c;color:#f87171;font-size:11px;cursor:pointer;font-weight:500}
.reboot-btn-top:hover{background:#1e1010}
.logout-btn{padding:7px 14px;border-radius:7px;border:1px solid #222;background:#141414;color:#666;font-size:11px;cursor:pointer}
.logout-btn:hover{background:#1a1a1a;color:#aaa}
.reboot-btn-main{background:#4a0000;color:#f88;border:1px solid #900;padding:9px 20px;border-radius:7px;cursor:pointer;font-size:13px;font-weight:600}
.reboot-btn-main:hover{background:#700000}
.modal-overlay{display:none;position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,.8);z-index:9999;align-items:center;justify-content:center}
.modal-overlay.active{display:flex}
.modal-box{background:#151515;border:1px solid #333;border-radius:12px;padding:26px 30px;max-width:440px;width:90%;box-shadow:0 8px 40px rgba(0,0,0,.7)}
.modal-box h3{margin:0 0 10px;color:#fff;font-size:16px}
.modal-box p{color:#888;font-size:13px;margin:0 0 7px;line-height:1.5}
.hn-pill{display:inline-block;background:#0d2d0d;border:1px solid #3a8;color:#5f5;padding:3px 12px;border-radius:20px;font-family:monospace;font-size:12px;margin:5px 0 12px}
.modal-actions{display:flex;gap:8px;margin-top:16px;justify-content:flex-end}
.btn-confirm{background:#c0392b;color:#fff;border:none;padding:9px 20px;border-radius:7px;cursor:pointer;font-size:13px;font-weight:600}
.btn-confirm:hover{background:#e74c3c}
.btn-cancel-m{background:#222;color:#999;border:1px solid #444;padding:9px 20px;border-radius:7px;cursor:pointer;font-size:13px}
.btn-cancel-m:hover{background:#2a2a2a;color:#ddd}
.toast-msg{position:fixed;bottom:22px;left:50%;transform:translateX(-50%);background:#111;border:1px solid #333;color:#ddd;padding:12px 22px;border-radius:9px;z-index:99999;font-size:13px;display:none;max-width:420px;text-align:center;line-height:1.5}
.toast-msg.show{display:block}
.ts-status.ok{color:#4ade80}
.ts-status.err{color:#f87171}
.idle-bar{height:2px;background:#1a1a1a;border-radius:2px;margin-top:14px;overflow:hidden}
.idle-fill{height:100%;background:#3a5a2a;border-radius:2px;transition:width 1s linear}
</style></head><body>

<div class="top">
  <div><h1>&#11041; Stealth Panel</h1><div class="sub">Razz Bridge &middot; Identity Management</div></div>
  <div class="top-btns">
    <button class="reboot-btn-top" onclick="openModal('rebootModal')">&#8634; Reboot</button>
    <button class="logout-btn" onclick="doLogout()">Lock</button>
  </div>
</div>

<!-- Stats bar -->
<div class="stats-bar" id="statsBar">
  <div class="stat"><div class="stat-val" id="s-temp">—</div><div class="stat-lbl">CPU Temp</div></div>
  <div class="stat"><div class="stat-val" id="s-up">—</div><div class="stat-lbl">Uptime</div></div>
  <div class="stat"><div class="stat-val" id="s-ts" class="ts-status">—</div><div class="stat-lbl">Tailscale</div></div>
  <div class="stat"><div class="stat-val" id="s-conn">—</div><div class="stat-lbl">Connections</div></div>
</div>

<div id="root"><div style="color:#333;font-size:13px;padding:40px 0;text-align:center">Loading&hellip;</div></div>

<!-- Reboot modal -->
<div id="rebootModal" class="modal-overlay">
  <div class="modal-box">
    <h3>&#9888; Reboot Razz Bridge?</h3>
    <p>All identity changes are persisted. The device will be offline ~45 seconds.</p>
    <p>After reboot, reconnect at:</p>
    <div><span class="hn-pill" id="hn-pill-reboot">https://razz.local/</span></div>
    <div class="modal-actions">
      <button class="btn-cancel-m" onclick="closeModal('rebootModal')">Cancel</button>
      <button class="reboot-btn-main" onclick="doApplyReboot()">&#128260; Reboot</button>
    </div>
  </div>
</div>

<!-- MAC warning modal -->
<div id="macWarnModal" class="modal-overlay">
  <div class="modal-box">
    <h3>&#9888; MAC Address Change</h3>
    <p><strong style="color:#fa6">Your IP will change.</strong> Reconnect after applying using:</p>
    <div><span class="hn-pill" id="hn-pill-mac">https://razz.local/</span></div>
    <p style="font-size:11px;color:#444;margin-top:4px">Open a new tab before proceeding.</p>
    <div class="modal-actions">
      <button class="btn-cancel-m" onclick="closeModal('macWarnModal')">Cancel</button>
      <button class="btn-confirm" style="background:#b37000" onclick="doApplyMac()">Apply Anyway</button>
    </div>
  </div>
</div>

<div id="toastMsg" class="toast-msg"></div>

<!-- Idle countdown bar -->
<div class="idle-bar"><div class="idle-fill" id="idleFill" style="width:100%"></div></div>

<script>
var S = {};
var _pendingMac = null;
var IDLE_MS = 28 * 60 * 1000;  // 28 min (lock before server 30 min)
var _idleStart = Date.now();
var _idleTimer;
var $ = function(id){ return document.getElementById(id); };

/* ── idle / auto-lock ── */
function resetIdle() {
  _idleStart = Date.now();
  clearTimeout(_idleTimer);
  _idleTimer = setTimeout(function(){
    doLogout();
  }, IDLE_MS);
}
['mousemove','keypress','click','touchstart'].forEach(function(e){
  document.addEventListener(e, resetIdle, {passive:true});
});
resetIdle();
setInterval(function(){
  var pct = Math.max(0, (1 - (Date.now() - _idleStart) / IDLE_MS)) * 100;
  var f = $('idleFill');
  if (f) f.style.width = pct + '%';
}, 2000);

/* ── toast ── */
function showToast(msg, ms) {
  ms = ms || 3500;
  var t = $('toastMsg');
  t.textContent = msg;
  t.classList.add('show');
  setTimeout(function(){ t.classList.remove('show'); }, ms);
}

/* ── modals ── */
function openModal(id)  { $(id).classList.add('active'); }
function closeModal(id) { $(id).classList.remove('active'); }

function tog(id) {
  var el = $(id);
  el.style.display = el.style.display === 'block' ? 'none' : 'block';
}

/* ── utils ── */
function bdg(on, t, f) { return '<span class="badge '+(on?'on':'off')+'">'+(on?t:f)+'</span>'; }
function esc(s) { return String(s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/"/g,'&quot;'); }

/* ── hostname pills ── */
function updatePills() {
  var hn = window.location.hostname;
  var url = 'https://' + hn + '/';
  ['hn-pill-reboot','hn-pill-mac'].forEach(function(id){
    var el = $(id);
    if (el) el.textContent = url;
  });
}

/* ── API ── */
async function apiFetch(action, data) {
  data = data || {};
  var r = await fetch('/stealth/api/apply', {
    method:'POST',
    headers:{'Content-Type':'application/json'},
    body: JSON.stringify(Object.assign({action:action}, data))
  });
  if (r.status === 401) { window.location.href = '/stealth/login'; return; }
  await load();
}

async function load() {
  try {
    var r = await fetch('/stealth/api/status');
    if (r.status === 401) { window.location.href = '/stealth/login'; return; }
    S = await r.json();
    render();
  } catch(e) {
    $('root').innerHTML = '<div style="color:#333;padding:20px;text-align:center">Reconnecting&hellip;</div>';
  }
}

async function loadStats() {
  try {
    var d = await (await fetch('/stealth/api/stats')).json();
    var temp = d.cpu_temp != null ? d.cpu_temp + '°C' : '—';
    var tempEl = $('s-temp');
    if (tempEl) {
      tempEl.textContent = temp;
      tempEl.className = 'stat-val ' + (d.cpu_temp > 75 ? 'warn' : d.cpu_temp > 85 ? 'err' : '');
    }
    var upEl = $('s-up');
    if (upEl) upEl.textContent = d.uptime || '—';
    var tsEl = $('s-ts');
    if (tsEl) {
      tsEl.textContent = d.tailscale_ip || 'not connected';
      tsEl.className = 'stat-val ts-status ' + (d.tailscale_ip ? 'ok' : 'err');
    }
    var connEl = $('s-conn');
    if (connEl) connEl.textContent = d.connections != null ? d.connections : '—';
    // Update session log
    if (d.sessions && d.sessions.length) {
      var logEl = $('sess-list');
      if (logEl) {
        logEl.innerHTML = d.sessions.slice().reverse().map(function(e){
          return '<div class="log-entry">'+esc(e)+'</div>';
        }).join('');
      }
    }
  } catch(e) {}
}

/* ── render ── */
function render() {
  if (!S.usb) return;
  var usb = S.usb, mac = S.mac, O = S.originals;
  var ssh = S.ssh_banner, rb = S.razz_block, safe = S.safe_mode;

  // Profile buttons
  var profs = window._profiles || [];
  var profBtns = profs.map(function(p, i){
    var active = usb.config && usb.config.profile_idx === i;
    return '<button class="pbtn'+(active?' active':'')+'" onclick="applyProfile('+i+')">'+esc(p.name)+'</button>';
  }).join('');

  $('root').innerHTML =

    /* USB */
    '<div class="card">'+
      '<div class="ch"><span class="ct">USB Identity</span>'+
        '<div class="bg">'+
          bdg(usb.enabled,'&#9679; SPOOFED','&#9675; ORIGINAL')+
          (usb.enabled
            ? '<button class="btn btn-r" onclick="apiFetch(\'usb_toggle\',{enabled:false})">Restore</button>'+
              '<button class="btn btn-b" onclick="tog(\'edit-usb\')">Edit</button>'
            : '<button class="btn btn-g" onclick="apiFetch(\'usb_toggle\',{enabled:true})">Enable</button>')+
        '</div></div>'+
      '<div class="row"><span class="lbl">Manufacturer</span><span class="val">'+esc(usb.live.manufacturer||'—')+'</span><span class="orig">was: '+esc(O.usb_manufacturer)+'</span></div>'+
      '<div class="row"><span class="lbl">Product</span><span class="val">'+esc(usb.live.product||'—')+'</span><span class="orig">was: '+esc(O.usb_product)+'</span></div>'+
      '<div class="row"><span class="lbl">Serial</span><span class="val">'+esc(usb.live.serialnumber||'—')+'</span><span class="orig">was: '+esc(O.usb_serial)+'</span></div>'+
      '<div class="row"><span class="lbl">Vendor ID</span><span class="val">'+esc(usb.live.idVendor||'—')+'</span><span class="orig">was: '+esc(O.usb_idVendor)+'</span></div>'+
      '<div class="row"><span class="lbl">Product ID</span><span class="val">'+esc(usb.live.idProduct||'—')+'</span><span class="orig">was: '+esc(O.usb_idProduct)+'</span></div>'+
      (profs.length ? '<div style="margin-top:6px"><div style="font-size:9px;color:#444;text-transform:uppercase;letter-spacing:1px;margin-bottom:5px">Quick Profiles</div><div class="profile-row">'+profBtns+'</div></div>' : '')+
      '<div class="form" id="edit-usb">'+
        '<button class="apply-btn" onclick="applyUsbIdentity()">&#10003; Apply USB Identity</button>'+
        '<div class="fr"><label>Manufacturer</label><input id="u-m" value="'+esc(usb.config.manufacturer||'')+'"></div>'+
        '<div class="fr"><label>Product</label><input id="u-p" value="'+esc(usb.config.product||'')+'"></div>'+
        '<div class="fr"><l
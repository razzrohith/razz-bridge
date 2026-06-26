#!/usr/bin/env python3
"""Razz Bridge Stealth Dashboard v3
   bcrypt auth · CSRF protection · 508-compliant UI
   backup/restore · log viewer · Tailscale · DuckDNS · KVM monitor
"""
import json, os, re, subprocess, secrets, time, datetime, hashlib, logging
from pathlib import Path
from flask import (Flask, jsonify, request, render_template_string,
                   session, redirect, Response)

# ── bcrypt (preferred) with SHA-256 fallback ─────────────────────────────────
try:
    import bcrypt as _bcrypt
    _HAS_BCRYPT = True
except ImportError:
    _HAS_BCRYPT = False

# ── App ───────────────────────────────────────────────────────────────────────
app = Flask(__name__)
app.config.update(
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE="Lax",
    SESSION_COOKIE_SECURE=True,
)

# ── Constants ─────────────────────────────────────────────────────────────────
CONFIG_PATH     = "/etc/stealth-config.json"
USB_DIR         = "/sys/kernel/config/usb_gadget/g1"
GADGET_SH       = "/opt/tinypilot-privileged/init-usb-gadget"
AUTH_LOG        = "/var/log/razz-auth.log"
SESS_LOG        = "/var/log/razz-sessions.log"
SESSION_TIMEOUT = 1800   # 30 min idle

# Original TinyPilot values — install.sh replaces __ETH0_MAC__ / __WLAN0_MAC__
ORIG = {
    "manufacturer": "tinypilot",
    "product":      "Multifunction USB Device",
    "serial":       "6b65796d696d6570690",
    "idVendor":     "0x1d6b",
    "idProduct":    "0x0104",
    "eth0_mac":     "__ETH0_MAC__",
    "wlan0_mac":    "__WLAN0_MAC__",
}

USB_PROFILES = [
    {"name":"Logitech K120",       "mfr":"Logitech",   "prod":"USB Keyboard K120",    "vid":"0x046d","pid":"0xc31c","pfx":"LGK"},
    {"name":"Microsoft Wired 600", "mfr":"Microsoft",  "prod":"Wired Keyboard 600",   "vid":"0x045e","pid":"0x0750","pfx":"MSK"},
    {"name":"Dell KB216",          "mfr":"Dell",       "prod":"KB216 Wired Keyboard", "vid":"0x413c","pid":"0x2003","pfx":"DEL"},
    {"name":"HP KU-0316",          "mfr":"HP",         "prod":"KU-0316 Keyboard",     "vid":"0x03f0","pid":"0x0224","pfx":"HPK"},
    {"name":"Corsair K55 RGB",     "mfr":"Corsair",    "prod":"K55 RGB Keyboard",     "vid":"0x1b1c","pid":"0x1b48","pfx":"COR"},
]

LOG_SOURCES = {
    "auth":      AUTH_LOG,
    "kvm":       SESS_LOG,
    "nginx":     "/var/log/nginx/access.log",
    "nginx-err": "/var/log/nginx/error.log",
    "system":    "/var/log/syslog",
}

# ── Auth logging ──────────────────────────────────────────────────────────────
_al = logging.getLogger("razz")
_al.setLevel(logging.INFO)
try:
    _fh = logging.FileHandler(AUTH_LOG)
    _fh.setFormatter(logging.Formatter("%(asctime)s %(message)s"))
    _al.addHandler(_fh)
except Exception:
    pass

# ── Progressive login delay (in-memory; resets on service restart) ────────────
_login_fails: dict = {}   # ip → consecutive failure count

def _client_ip() -> str:
    return (request.headers.get("X-Forwarded-For") or
            request.remote_addr or "").split(",")[0].strip()

def _apply_delay(ip: str):
    n = _login_fails.get(ip, 0)
    if n > 0:
        time.sleep(min(n, 10))   # 1 s, 2 s, 3 s … capped at 10 s; never blocks

def _record_fail(ip: str):
    _login_fails[ip] = _login_fails.get(ip, 0) + 1

def _record_ok(ip: str):
    _login_fails.pop(ip, None)

# ── Password helpers ──────────────────────────────────────────────────────────
def _hash_pw(pw: str) -> str:
    if _HAS_BCRYPT:
        return _bcrypt.hashpw(pw.encode(), _bcrypt.gensalt()).decode()
    return "sha256:" + hashlib.sha256(pw.encode()).hexdigest()

def _check_pw(pw: str, stored: str) -> bool:
    if _HAS_BCRYPT and stored.startswith("$2"):
        return _bcrypt.checkpw(pw.encode(), stored.encode())
    raw = stored.removeprefix("sha256:")
    return hashlib.sha256(pw.encode()).hexdigest() == raw

# ── Config helpers ────────────────────────────────────────────────────────────
def _load() -> dict:
    try:
        return json.loads(Path(CONFIG_PATH).read_text())
    except Exception:
        return {}

def _save(cfg: dict):
    Path(CONFIG_PATH).write_text(json.dumps(cfg, indent=2))

def _ensure_defaults(cfg: dict) -> dict:
    """Ensure default password 'lol' and secret key exist."""
    auth = cfg.setdefault("auth", {})
    if not auth.get("password_hash"):
        auth["password_hash"] = _hash_pw("lol")
        _save(cfg)
    if not auth.get("secret_key"):
        auth["secret_key"] = secrets.token_hex(32)
        _save(cfg)
    return cfg

def _boot():
    cfg = _load()
    _ensure_defaults(cfg)
    app.secret_key = cfg["auth"]["secret_key"]

# ── CSRF ──────────────────────────────────────────────────────────────────────
def _csrf_ok() -> bool:
    tok = (request.headers.get("X-CSRF-Token") or
           request.form.get("_csrf", ""))
    return tok == session.get("csrf")

def _fresh_login_csrf() -> str:
    t = secrets.token_hex(32)
    session["login_csrf"] = t
    return t

# ── Auth helpers ──────────────────────────────────────────────────────────────
def _authed() -> bool:
    if not session.get("ok"):
        return False
    if time.time() - session.get("t", 0) > SESSION_TIMEOUT:
        session.clear()
        return False
    session["t"] = time.time()
    return True

def _stealth(path: str = "") -> str:
    """Build the browser-visible /stealth/… URL (nginx strips /stealth/ before Flask)."""
    return "https://" + request.host + "/stealth/" + path.lstrip("/")

# ── USB helpers ───────────────────────────────────────────────────────────────
def _usb_r(rel: str) -> str:
    try:
        return Path(f"{USB_DIR}/{rel}").read_text().strip()
    except Exception:
        return ""

def _usb_w(rel: str, val: str):
    try:
        Path(f"{USB_DIR}/{rel}").write_text(val + "\n")
    except Exception:
        pass

def _rebind(fn):
    udc = _usb_r("UDC")
    _usb_w("UDC", "")
    time.sleep(0.3)
    fn()
    time.sleep(0.3)
    if udc:
        _usb_w("UDC", udc)

def _apply_usb(mfr: str, prod: str, ser: str,
               vid: str = None, pid: str = None):
    def _do():
        _usb_w("strings/0x409/manufacturer", mfr)
        _usb_w("strings/0x409/product", prod)
        _usb_w("strings/0x409/serialnumber", ser)
        if vid: _usb_w("idVendor",  vid)
        if pid: _usb_w("idProduct", pid)
    _rebind(_do)
    # Patch gadget init script so identity survives reboots
    try:
        c = Path(GADGET_SH).read_text()
        def _r(pat, rep):
            nonlocal c; c = re.sub(pat, rep, c)
        _r(r'echo "[^"]*" > "\$\{USB_STRINGS_DIR\}/manufacturer"',
           f'echo "{mfr}" > "${{USB_STRINGS_DIR}}/manufacturer"')
        _r(r'echo "[^"]*" > "\$\{USB_STRINGS_DIR\}/product"',
           f'echo "{prod}" > "${{USB_STRINGS_DIR}}/product"')
        _r(r'echo "[^"]*" > "\$\{USB_STRINGS_DIR\}/serialnumber"',
           f'echo "{ser}" > "${{USB_STRINGS_DIR}}/serialnumber"')
        if vid: _r(r'echo \S+ > "\$\{GADGET_DIR\}/idVendor"',
                   f'echo {vid} > "${{GADGET_DIR}}/idVendor"')
        if pid: _r(r'echo \S+ > "\$\{GADGET_DIR\}/idProduct"',
                   f'echo {pid} > "${{GADGET_DIR}}/idProduct"')
        Path(GADGET_SH).write_text(c)
    except Exception:
        pass

def _rand_serial(pfx: str = "RZ") -> str:
    return pfx + secrets.token_hex(4).upper()

# ── Network helpers ───────────────────────────────────────────────────────────
def _cur_mac(iface: str = "eth0") -> str:
    try:
        return Path(f"/sys/class/net/{iface}/address").read_text().strip()
    except Exception:
        return ""

def _set_mac(iface: str, mac: str):
    for cmd in [["ip","link","set",iface,"down"],
                ["ip","link","set",iface,"address",mac],
                ["ip","link","set",iface,"up"]]:
        subprocess.run(cmd, capture_output=True)

def _persist_mac(iface: str, mac: str):
    """Save MAC to config and regenerate the boot-persist systemd service."""
    cfg = _load()
    cfg.setdefault("mac_persist", {})[iface] = mac
    _save(cfg)
    _write_mac_svc(cfg)

def _write_mac_svc(cfg: dict):
    """(Re)write /etc/systemd/system/razz-mac.service from persisted MACs."""
    persist = cfg.get("mac_persist", {})
    valid   = {k: v for k, v in persist.items()
               if v and re.match(r'^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$', v)}
    if not valid:
        return
    cmds = []
    for inf, m in valid.items():
        cmds += [
            f"ip link set {inf} down || true",
            f"ip link set {inf} address {m} || true",
            f"ip link set {inf} up || true",
        ]
    exec_str = " ; ".join(cmds)
    svc = (
        "[Unit]\nDescription=Razz Bridge persistent MAC addresses\n"
        "Before=network.target dhcpcd.service\n\n"
        "[Service]\nType=oneshot\n"
        f'ExecStart=/bin/bash -c "{exec_str}"\n'
        "RemainAfterExit=yes\n\n"
        "[Install]\nWantedBy=multi-user.target\n"
    )
    try:
        Path("/etc/systemd/system/razz-mac.service").write_text(svc)
        subprocess.run(["systemctl", "daemon-reload"], capture_output=True)
        subprocess.run(["systemctl", "enable",  "razz-mac"], capture_output=True)
    except Exception:
        pass

def _rand_mac() -> str:
    b = [0x00,0x1a,0x2b]+[secrets.randbits(8) for _ in range(3)]
    return ":".join(f"{x:02x}" for x in b)

def _tailscale_status() -> dict:
    try:
        r = subprocess.run(["tailscale","status","--json"],
                           capture_output=True, text=True, timeout=4)
        d = json.loads(r.stdout)
        return {
            "connected": d.get("BackendState") == "Running",
            "ip":  (d.get("TailscaleIPs") or [""])[0],
            "state": d.get("BackendState","unknown"),
        }
    except Exception:
        return {"connected": False, "ip": "", "state": "not running"}

def _funnel_status() -> dict:
    """Get Tailscale Funnel status and public HTTPS URL."""
    try:
        r  = subprocess.run(["tailscale","funnel","status"],
                            capture_output=True, text=True, timeout=5)
        active = ":443" in r.stdout
        # Full DNS name comes from tailscale status --json (Self.DNSName)
        sr = subprocess.run(["tailscale","status","--json"],
                            capture_output=True, text=True, timeout=4)
        d   = json.loads(sr.stdout or "{}")
        dns = d.get("Self", {}).get("DNSName", "").rstrip(".")
        url = f"https://{dns}/" if (dns and active) else ""
        return {"active": active, "url": url, "hostname": dns}
    except Exception:
        return {"active": False, "url": "", "hostname": ""}

def _local_ip() -> str:
    try:
        return subprocess.run(["hostname","-I"],
                              capture_output=True, text=True).stdout.strip().split()[0]
    except Exception:
        return ""

def _cpu_temp():
    try:
        return round(int(Path("/sys/class/thermal/thermal_zone0/temp").read_text())/1000, 1)
    except Exception:
        return None

def _uptime() -> str:
    try:
        s = int(float(Path("/proc/uptime").read_text().split()[0]))
        d, r = divmod(s, 86400); h, r = divmod(r, 3600); m = r//60
        return "".join([f"{d}d " if d else "", f"{h}h " if h else "", f"{m}m"])
    except Exception:
        return ""

def _kvm_last() -> dict:
    """Last nginx access that wasn't to /stealth/."""
    try:
        r = subprocess.run(["grep","-v","/stealth","/var/log/nginx/access.log"],
                           capture_output=True, text=True)
        lines = [l for l in r.stdout.splitlines() if l.strip()]
        if not lines: return None
        last = lines[-1]
        ip = re.match(r"(\S+)", last)
        ts = re.search(r"\[([^\]]+)\]", last)
        return {"ip": ip.group(1) if ip else "?",
                "time": ts.group(1) if ts else "?"}
    except Exception:
        return None

def _tail_log(source: str, n: int = 50) -> str:
    path = LOG_SOURCES.get(source, AUTH_LOG)
    try:
        return subprocess.run(["tail",f"-{n}",path],
                              capture_output=True, text=True).stdout
    except Exception:
        return f"(could not read {path})"

def _log_sess(msg: str):
    try:
        with open(SESS_LOG, "a") as f:
            f.write(f"{datetime.datetime.now().isoformat()} {msg}\n")
    except Exception:
        pass

# ── DuckDNS ───────────────────────────────────────────────────────────────────
def _ddns_update(host: str, token: str) -> bool:
    try:
        r = subprocess.run(
            ["curl","-s","--max-time","8",
             f"https://www.duckdns.org/update?domains={host}&token={token}&ip="],
            capture_output=True, text=True)
        return r.stdout.strip() == "OK"
    except Exception:
        return False

def _ext_ip() -> str:
    try:
        return subprocess.run(["curl","-s","--max-time","5","https://ipv4.icanhazip.com"],
                              capture_output=True, text=True).stdout.strip()
    except Exception:
        return ""

def _ddns_cron(host: str, token: str):
    try:
        Path("/etc/cron.d/razz-duckdns").write_text(
            f"*/5 * * * * root curl -s 'https://www.duckdns.org/update"
            f"?domains={host}&token={token}&ip=' >/var/log/razz-duckdns.log 2>&1\n"
        )
    except Exception:
        pass

# ══════════════════════════════════════════════════════════════════════════════
# HTML — Login
# ══════════════════════════════════════════════════════════════════════════════
LOGIN_HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Razz Bridge</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
html,body{min-height:100%;background:#080808;font:14px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:#ddd}
body{display:flex;align-items:center;justify-content:center;padding:1.5rem}
.card{background:#111;border:0.5px solid #252525;border-radius:12px;padding:2rem;width:100%;max-width:310px}
h1{font-size:15px;font-weight:500;letter-spacing:.01em;margin-bottom:3px}
.sub{font-size:11px;color:#555;margin-bottom:1.5rem}
label{display:block;font-size:11px;color:#666;margin-bottom:4px}
input[type=password]{
  width:100%;padding:9px 11px;background:#0a0a0a;
  border:0.5px solid #252525;border-radius:7px;
  color:#ddd;font-size:13px;outline:none;transition:border .15s}
input[type=password]:focus{border-color:#4a9eff;box-shadow:0 0 0 2px rgba(74,158,255,.15)}
button{
  margin-top:.85rem;width:100%;padding:9px;
  background:#4a9eff;border:none;border-radius:7px;
  color:#fff;font-size:13px;font-weight:500;cursor:pointer;transition:opacity .15s}
button:hover{opacity:.82}
button:focus{outline:2px solid #4a9eff;outline-offset:3px}
.err{
  margin-top:.7rem;padding:8px 10px;
  background:rgba(224,80,80,.08);border:0.5px solid rgba(224,80,80,.3);
  border-radius:6px;font-size:12px;color:#e05050}
.hint{margin-top:.9rem;font-size:11px;color:#3a3a3a;text-align:center}
</style>
</head>
<body>
<main>
<div class="card">
  <h1>Razz Bridge</h1>
  <p class="sub">Configuration panel</p>
  {% if error %}
  <div class="err" role="alert" aria-live="assertive">{{ error }}</div>
  {% endif %}
  <form method="POST" action="/stealth/login" novalidate>
    <input type="hidden" name="_csrf" value="{{ csrf }}">
    <label for="pw">Password</label>
    <input type="password" id="pw" name="pw"
           autocomplete="current-password" aria-required="true" autofocus>
    <button type="submit">Unlock</button>
  </form>
  <p class="hint">Contact developer to reset password</p>
</div>
</main>
</body>
</html>"""

# ══════════════════════════════════════════════════════════════════════════════
# HTML — Main dashboard (508-compliant, WCAG AA contrast)
# ══════════════════════════════════════════════════════════════════════════════
MAIN_HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="csrf-token" content="{{ csrf }}">
<title>Razz Bridge — Panel</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
:root{
  --bg:#080808; --sf:#101010; --sf2:#161616;
  --br:#1c1c1c; --br2:#272727;
  --t1:#dedede; --t2:#888; --t3:#4a4a4a;
  --ac:#4a9eff; --ac-bg:rgba(74,158,255,.1);
  --ok:#4cbe82; --ok-bg:rgba(76,190,130,.1);
  --wa:#f0a530; --wa-bg:rgba(240,165,48,.1);
  --er:#e05050; --er-bg:rgba(224,80,80,.1);
}
/* ── base ── */
html{font:13px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;
     background:var(--bg);color:var(--t1)}
/* ── skip link (508) ── */
.sk{position:absolute;top:-999px;left:0;padding:6px 12px;
    background:var(--ac);color:#fff;font-size:12px;z-index:9999;
    border-radius:0 0 6px 0;text-decoration:none}
.sk:focus{top:0}
/* ── header ── */
header{
  display:flex;align-items:center;gap:10px;padding:10px 16px;
  background:var(--sf);border-bottom:0.5px solid var(--br);
  position:sticky;top:0;z-index:20}
.logo{font-size:14px;font-weight:500}
.bdg{font-size:10px;padding:2px 8px;border-radius:20px;
     font-weight:500;border:0.5px solid}
.b-ok{background:var(--ok-bg);color:var(--ok);border-color:rgba(76,190,130,.3)}
.b-er{background:var(--er-bg);color:var(--er);border-color:rgba(224,80,80,.3)}
/* ── stat bar ── */
.sbar{
  display:flex;gap:16px;flex-wrap:wrap;padding:6px 16px;
  background:var(--sf2);border-bottom:0.5px solid var(--br);
  font-size:11px;color:var(--t3)}
/* ── layout ── */
main{padding:14px 16px;display:grid;gap:14px}
@media(min-width:680px){main{grid-template-columns:1fr 1fr}}
.full{grid-column:1/-1}
/* ── cards ── */
.card{background:var(--sf);border:0.5px solid var(--br);border-radius:10px;overflow:hidden}
.ch{padding:10px 14px;border-bottom:0.5px solid var(--br);
    display:flex;align-items:center;gap:8px}
.ch h2{font-size:13px;font-weight:500;flex:1;color:var(--t1)}
.ch .cd{font-size:11px;color:var(--t3)}
.cb{padding:12px 14px}
/* ── form ── */
.field{margin-bottom:10px}
.field:last-child{margin-bottom:0}
.fl{display:block;font-size:11px;color:var(--t3);margin-bottom:3px}
.fd{display:block;font-size:11px;color:var(--t3);margin-top:3px;line-height:1.4;opacity:.85}
.frow{display:flex;gap:7px;align-items:flex-start;flex-wrap:wrap}
input[type=text],input[type=password],select,textarea{
  background:var(--bg);border:0.5px solid var(--br2);border-radius:6px;
  color:var(--t1);font-size:12px;padding:6px 9px;
  outline:none;transition:border .15s;font-family:inherit}
input:focus,select:focus,textarea:focus{
  border-color:var(--ac);box-shadow:0 0 0 2px rgba(74,158,255,.14)}
select{cursor:pointer}
textarea{resize:vertical;min-height:58px;font-family:monospace;
         font-size:10px;width:100%;line-height:1.5}
/* ── buttons ── */
.btn{
  padding:5px 13px;border-radius:6px;font-size:12px;font-weight:500;
  cursor:pointer;border:0.5px solid var(--br2);
  background:var(--sf2);color:var(--t2);
  transition:background .15s,color .15s;font-family:inherit;line-height:1.4}
.btn:hover{background:var(--br2);color:var(--t1)}
.btn:focus{outline:2px solid var(--ac);outline-offset:2px}
.btn-p{background:var(--ac);border-color:transparent;color:#fff}
.btn-p:hover{opacity:.83;background:var(--ac)}
.btn-d{background:var(--er-bg);border-color:rgba(224,80,80,.3);color:var(--er)}
.btn-d:hover{background:rgba(224,80,80,.18)}
/* ── profile pills ── */
.pills{display:flex;flex-wrap:wrap;gap:5px;margin:5px 0 8px}
.pill{
  padding:3px 10px;border-radius:20px;font-size:11px;
  border:0.5px solid var(--br2);background:transparent;color:var(--t2);
  cursor:pointer;font-family:inherit;transition:all .15s}
.pill:hover{border-color:var(--ac);color:var(--ac)}
.pill.on{border-color:var(--ac);background:var(--ac-bg);color:var(--ac)}
.pill:focus{outline:2px solid var(--ac);outline-offset:2px}
/* ── status dots ── */
.dot{display:inline-block;width:7px;height:7px;border-radius:50%;
     vertical-align:middle;margin-right:4px}
.d-ok{background:var(--ok)} .d-er{background:var(--er)} .d-wa{background:var(--wa)}
/* ── log box ── */
.log{
  background:var(--bg);border:0.5px solid var(--br);border-radius:6px;
  padding:8px 10px;font-family:monospace;font-size:10px;color:var(--t3);
  height:130px;overflow-y:auto;white-space:pre-wrap;
  word-break:break-all;line-height:1.5;margin-top:4px}
/* ── divider ── */
hr{border:none;border-top:0.5px solid var(--br);margin:10px 0}
/* ── idle bar ── */
.ibar{height:2px;background:var(--br);position:sticky;bottom:0}
.ifill{height:100%;background:var(--ac);border-radius:1px;
       transition:width 1s linear}
/* ── toast ── */
#toast{
  position:fixed;bottom:14px;right:14px;
  background:var(--sf);border:0.5px solid var(--br2);border-radius:8px;
  padding:9px 15px;font-size:12px;opacity:0;transition:opacity .25s;
  pointer-events:none;z-index:999;max-width:260px}
#toast.show{opacity:1}
#toast.ok{border-left:3px solid var(--ok);color:var(--ok)}
#toast.er{border-left:3px solid var(--er);color:var(--er)}
</style>
</head>
<body>
<a href="#mc" class="sk">Skip to main content</a>

<header role="banner">
  <span class="logo">Razz Bridge</span>
  <span class="bdg b-ok" id="ps" role="status" aria-live="polite">Active</span>
  <nav style="margin-left:auto" aria-label="Panel controls">
    <button class="btn" onclick="lock()" aria-label="Lock and log out of panel">Lock</button>
  </nav>
</header>

<div class="sbar" role="status" aria-live="polite" aria-label="Device statistics">
  <span id="s-temp" aria-label="CPU temperature">— °C</span>
  <span>Up: <span id="s-up" aria-label="Uptime">—</span></span>
  <span>IP: <span id="s-ip" aria-label="Local IP">—</span></span>
  <span id="s-ts" aria-label="Tailscale status">Tailscale: —</span>
</div>

<main id="mc" aria-label="Configuration sections">

<!-- ══ USB Identity ════════════════════════════════════════════════════════ -->
<section class="card" aria-labelledby="h-usb">
  <div class="ch">
    <h2 id="h-usb">USB identity</h2>
    <span class="cd">How this device appears to your computer</span>
  </div>
  <div class="cb">

    <div class="field" aria-labelledby="h-preset">
      <span id="h-preset" class="fl">Quick preset</span>
      <span class="fd">Pick a known keyboard — all fields update to match the real device. Click Apply preset to send.</span>
      <div class="pills" role="group" aria-labelledby="h-preset" id="pills"></div>
      <button class="btn btn-p" onclick="applyPreset()"
              aria-label="Apply selected USB preset to device">Apply preset</button>
    </div>

    <hr>

    <div class="frow" style="margin-bottom:7px">
      <div class="field" style="flex:1;min-width:110px">
        <label class="fl" for="u-mfr">Manufacturer</label>
        <input type="text" id="u-mfr" aria-describedby="u-help" style="width:100%">
      </div>
      <div class="field" style="flex:1;
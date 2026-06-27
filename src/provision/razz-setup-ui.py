#!/usr/bin/env python3
"""
Razz Bridge — Bridge-Setup AP captive portal.

Runs ONLY during first-boot provisioning (started by razz-provision.sh).
Serves a mobile-friendly WiFi + Tailscale setup page on port 7779.
iptables redirects port 80/443 → 7779 so any URL the user visits
lands on this page (captive portal behaviour).

When the user submits credentials:
  - Adds WiFi network via nmcli
  - Attempts connection
  - If Tailscale key provided, runs tailscale up
  - Writes the Pi serial number to /etc/razz-provisioned so
    razz-provision.sh knows setup is done and tears down the AP.
"""
import json, os, re, subprocess, threading, time
from pathlib import Path
from flask import Flask, request, jsonify, render_template_string, redirect, Response

app  = Flask(__name__)
PORT = 7779
AP_IP   = "192.168.4.1"
FLAG    = "/etc/razz-provisioned"
TS_TMP  = "/tmp/razz-ts-key"

# ── Helpers ───────────────────────────────────────────────────────────

def _serial():
    try:
        for line in Path("/proc/cpuinfo").read_text().splitlines():
            if line.startswith("Serial"):
                return line.split()[-1]
    except Exception:
        pass
    return "unknown"

def _run(*cmd, timeout=15):
    return subprocess.run(list(cmd), capture_output=True, text=True, timeout=timeout)

def scan_networks():
    """Return list of visible WiFi networks sorted by signal strength."""
    try:
        r = _run("nmcli", "-t", "-f", "SSID,SIGNAL,SECURITY",
                 "device", "wifi", "list", "--rescan", "yes", timeout=20)
        nets, seen = [], set()
        for line in r.stdout.splitlines():
            # rsplit from right so SSIDs containing ':' don't shift SIGNAL/SECURITY fields
            parts = line.rsplit(":", 2)
            if len(parts) < 3:
                continue
            ssid = parts[0].strip()
            if not ssid or ssid == "--" or ssid in seen:
                continue
            seen.add(ssid)
            sig  = int(parts[1]) if parts[1].isdigit() else 0
            sec  = parts[2].strip()
            nets.append({"ssid": ssid, "signal": sig,
                         "secure": bool(sec and sec != "--")})
        return sorted(nets, key=lambda x: -x["signal"])
    except Exception:
        return []

def nm_connect(ssid, password):
    """Save and connect to a WiFi network. Returns (ok: bool, msg: str)."""
    # Delete any existing connection with same name
    _run("nmcli", "connection", "delete", ssid, timeout=5)

    # Add new connection
    cmd = ["nmcli", "connection", "add",
           "type", "wifi", "ifname", "wlan0",
           "con-name", ssid, "ssid", ssid,
           "connection.autoconnect", "yes",
           "connection.autoconnect-priority", "100"]
    if password:
        cmd += ["wifi-sec.key-mgmt", "wpa-psk", "wifi-sec.psk", password]

    r = _run(*cmd, timeout=10)
    if r.returncode != 0:
        return False, "Could not save network: " + r.stderr.strip()

    # Bring up the connection
    r = _run("nmcli", "connection", "up", ssid, timeout=25)
    if r.returncode == 0:
        return True, "Connected"

    err = r.stderr.strip() or r.stdout.strip()
    return False, "Connection failed — check password. (" + err[:80] + ")"

def ts_connect(key):
    """Try Tailscale auth key. Returns IP or ''."""
    if not key:
        return ""
    try:
        r = _run("tailscale", "up", "--authkey", key, "--accept-routes", timeout=20)
        if r.returncode == 0:
            ip = _run("tailscale", "ip", "-4", timeout=5).stdout.strip()
            return ip
    except Exception:
        pass
    return ""

# ── HTML ──────────────────────────────────────────────────────────────

_HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
<title>Razz Bridge Setup</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
html{background:#080808}
body{min-height:100vh;background:#080808;
  font:15px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,sans-serif;
  color:#ccc;padding:22px 16px 50px;max-width:520px;margin:0 auto}

/* ── Header ── */
.logo{display:flex;align-items:center;gap:10px;margin-bottom:24px}
.logo-icon{width:34px;height:34px;background:linear-gradient(135deg,#1e3a5f,#4a9eff);
  border-radius:8px;display:flex;align-items:center;justify-content:center;
  font-size:16px;flex-shrink:0}
.logo h1{font-size:17px;font-weight:600;color:#e8e8e8}
.logo p{font-size:11px;color:#454545;margin-top:1px}

/* ── Card ── */
.card{background:#0f0f0f;border:0.5px solid #1c1c1c;border-radius:13px;
      padding:16px;margin-bottom:12px}
.card-title{font-size:12px;font-weight:500;color:#888;
            text-transform:uppercase;letter-spacing:.06em;margin-bottom:12px}

/* ── Network list ── */
.net-list{list-style:none;margin-bottom:12px}
.net-item{display:flex;align-items:center;gap:10px;
  padding:11px 12px;background:#0a0a0a;
  border:0.5px solid #181818;border-radius:9px;
  margin-bottom:5px;cursor:pointer;transition:border-color .15s}
.net-item:active,.net-item.sel{border-color:#4a9eff;background:#0d1a2b}
.net-ssid{flex:1;font-size:13px;white-space:nowrap;
          overflow:hidden;text-overflow:ellipsis}
.net-sig{font-size:11px;color:#383838;flex-shrink:0}
.net-lock{font-size:12px;flex-shrink:0;opacity:.4}

/* ── Inputs ── */
label{display:block;font-size:11px;color:#505050;margin-bottom:4px}
input[type=text],input[type=password]{
  width:100%;padding:10px 12px;background:#080808;
  border:0.5px solid #1e1e1e;border-radius:8px;
  color:#ddd;font-size:14px;outline:none;
  -webkit-appearance:none;margin-bottom:4px;
  transition:border-color .15s}
input:focus{border-color:#4a9eff}
.hint{font-size:11px;color:#3a3a3a;line-height:1.5;margin-bottom:12px}

/* ── Manual SSID toggle ── */
.toggle-manual{background:none;border:none;color:#3a7abf;font-size:11px;
  cursor:pointer;padding:0;margin-bottom:12px;-webkit-appearance:none;
  text-decoration:underline;text-underline-offset:2px}
#manual-ssid-row{display:none;margin-bottom:12px}
#manual-ssid-row.open{display:block}

/* ── Tailscale ── */
.ts-toggle{background:none;border:none;color:#3a7abf;font-size:12px;
  cursor:pointer;padding:0;-webkit-appearance:none;
  text-decoration:underline;text-underline-offset:2px;margin-bottom:0}
.ts-body{display:none;margin-top:12px}
.ts-body.open{display:block}

/* ── Primary button ── */
.btn{width:100%;padding:13px;background:#2256a6;border:none;
  border-radius:10px;color:#e8e8e8;font-size:15px;font-weight:500;
  cursor:pointer;-webkit-appearance:none;margin-top:4px;
  transition:opacity .15s}
.btn:active{opacity:.75}
.btn:disabled{opacity:.4;cursor:default}
.btn-sm{padding:9px;font-size:13px;margin-top:8px;background:#171717;
  border:0.5px solid #222;color:#666}

/* ── Status banner ── */
.alert{display:none;padding:12px 14px;border-radius:9px;
       font-size:13px;line-height:1.5;margin-bottom:12px}
.alert-ok{display:block;background:rgba(56,180,110,.08);
  border:0.5px solid rgba(56,180,110,.25);color:#4db87a}
.alert-er{display:block;background:rgba(210,65,65,.07);
  border:0.5px solid rgba(210,65,65,.2);color:#d45050}
.alert-wa{display:block;background:rgba(210,155,45,.07);
  border:0.5px solid rgba(210,155,45,.2);color:#c8932e}

/* ── Scan loading ── */
.loading{font-size:12px;color:#333;padding:10px 0;text-align:center}
</style>
</head>
<body>

<div class="logo">
  <div class="logo-icon">🌉</div>
  <div>
    <h1>Razz Bridge</h1>
    <p>Connect to your WiFi network to get started</p>
  </div>
</div>

<div id="alert" class="alert" role="alert" aria-live="assertive"></div>

<!-- WiFi selection -->
<div class="card">
  <div class="card-title">📶 Select WiFi network</div>

  <div id="net-loading" class="loading">Scanning for networks…</div>
  <ul id="net-list" class="net-list" style="display:none" aria-label="Available WiFi networks"></ul>

  <button class="btn btn-sm" id="rescan-btn" onclick="doScan()" style="width:auto;padding:7px 16px">
    ↺ Rescan
  </button>
  <br>
  <button class="toggle-manual" onclick="toggleManual()" aria-expanded="false" id="manual-btn"
          style="margin-top:10px">
    Enter network name manually ▾
  </button>
  <div id="manual-ssid-row">
    <label for="manual-ssid">Network name (SSID)</label>
    <input type="text" id="manual-ssid" placeholder="MyHomeNetwork"
           autocorrect="off" autocapitalize="none" autocomplete="off">
  </div>

  <label for="wifi-pass">Password <span style="color:#333">(leave blank for open networks)</span></label>
  <input type="password" id="wifi-pass" placeholder="••••••••"
         autocomplete="current-password">
</div>

<!-- Tailscale -->
<div class="card">
  <div class="card-title">🔒 Remote access — Tailscale <span style="color:#2a2a2a;font-weight:400;text-transform:none;letter-spacing:0">(optional)</span></div>
  <p class="hint">Tailscale lets you reach this KVM from any location securely.<br>
    Get an auth key at <strong style="color:#4a4a4a">tailscale.com/admin → Settings → Keys</strong> → Generate auth key.
  </p>
  <button class="ts-toggle" id="ts-toggle" onclick="toggleTS()" aria-expanded="false">
    + Add Tailscale auth key
  </button>
  <div class="ts-body" id="ts-body">
    <label for="ts-key">Auth key</label>
    <input type="text" id="ts-key" placeholder="tskey-auth-xxxxxxxxxxxxxxxx"
           autocorrect="off" autocapitalize="none" autocomplete="off">
    <p class="hint" style="margin-bottom:0">
      If auto-auth fails, you can also log in later from the stealth panel.
    </p>
  </div>
</div>

<button class="btn" id="connect-btn" onclick="doConnect()">Connect to WiFi</button>

<script>
'use strict';
let selSSID = '';

// ── Utilities ──────────────────────────────────────────────────────
function esc(s) {
  return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}
function showAlert(msg, type) {
  const el = document.getElementById('alert');
  el.textContent = msg;
  el.className = 'alert alert-' + type;
  el.scrollIntoView({behavior:'smooth', block:'nearest'});
}
function sigBar(pct) {
  const bars = Math.ceil(pct / 25);
  return '▂▄▆█'.slice(0, bars) || '·';
}

// ── WiFi scan ──────────────────────────────────────────────────────
function doScan() {
  const list    = document.getElementById('net-list');
  const loading = document.getElementById('net-loading');
  const btn     = document.getElementById('rescan-btn');
  list.style.display = 'none';
  loading.style.display = 'block';
  loading.textContent = 'Scanning…';
  btn.disabled = true;

  fetch('/scan')
    .then(r => r.json())
    .then(nets => {
      list.innerHTML = '';
      if (!nets.length) {
        loading.textContent = 'No networks found — try rescanning.';
      } else {
        nets.forEach(n => {
          const li = document.createElement('li');
          li.className = 'net-item';
          li.setAttribute('role', 'button');
          li.setAttribute('tabindex', '0');
          li.innerHTML =
            (n.secure ? '<span class="net-lock">🔒</span>' : '') +
            '<span class="net-ssid">' + esc(n.ssid) + '</span>' +
            '<span class="net-sig">' + sigBar(n.signal) + ' ' + n.signal + '%</span>';
          li.onclick = () => selectNet(li, n.ssid);
          li.onkeydown = e => { if (e.key==='Enter'||e.key===' ') selectNet(li, n.ssid); };
          list.appendChild(li);
        });
        loading.style.display = 'none';
        list.style.display = 'block';
      }
      btn.disabled = false;
    })
    .catch(() => {
      loading.textContent = 'Scan failed — enter network name manually below.';
      btn.disabled = false;
    });
}

function selectNet(li, ssid) {
  selSSID = ssid;
  document.querySelectorAll('.net-item').forEach(x => x.classList.remove('sel'));
  li.classList.add('sel');
  document.getElementById('wifi-pass').focus();
}

// ── Manual SSID toggle ─────────────────────────────────────────────
function toggleManual() {
  const row = document.getElementById('manual-ssid-row');
  const btn = document.getElementById('manual-btn');
  const open = row.classList.toggle('open');
  btn.setAttribute('aria-expanded', open);
  btn.textContent = open ? 'Enter network name manually ▴' : 'Enter network name manually ▾';
  if (open) document.getElementById('manual-ssid').focus();
}

// ── Tailscale toggle ───────────────────────────────────────────────
function toggleTS() {
  const body = document.getElementById('ts-body');
  const btn  = document.getElementById('ts-toggle');
  const open = body.classList.toggle('open');
  btn.setAttribute('aria-expanded', open);
  btn.textContent = open ? '− Hide Tailscale' : '+ Add Tailscale auth key';
  if (open) document.getElementById('ts-key').focus();
}

// ── Connect ────────────────────────────────────────────────────────
function doConnect() {
  const manual = document.getElementById('manual-ssid').value.trim();
  const ssid   = manual || selSSID;
  const pass   = document.getElementById('wifi-pass').value;
  const tsKey  = document.getElementById('ts-key').value.trim();

  if (!ssid) {
    showAlert('Please select a network from the list or enter a name manually.', 'er');
    return;
  }

  const btn = document.getElementById('connect-btn');
  btn.disabled = true;
  btn.textContent = 'Connecting…';
  showAlert('Saving network and connecting — this may take up to 30 seconds…', 'wa');

  fetch('/connect', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({ssid, password: pass, tailscale_key: tsKey})
  })
  .then(r => r.json())
  .then(d => {
    if (d.ok) {
      let msg = '✓ Connected to ' + d.ssid + '!';
      if (d.tailscale) msg += '  Tailscale: ' + d.tailscale;
      else if (tsKey)  msg += '  Tailscale auth failed — configure later from the panel.';
      msg += '  You can close this page.  The Razz Bridge panel is at https://';
      msg += (window.location.hostname === '192.168.4.1' ? '<your-pi-ip>' : window.location.hostname);
      msg += '/stealth/';
      showAlert(msg, 'ok');
      btn.textContent = 'Done ✓';
    } else {
      showAlert('✗ ' + (d.error || 'Connection failed. Check the password and try again.'), 'er');
      btn.disabled = false;
      btn.textContent = 'Try again';
    }
  })
  .catch(() => {
    // Pi dropped off the AP to join WiFi — this fetch will fail, which is expected
    showAlert(
      'The Pi is joining your WiFi network — this page will stop responding. ' +
      'Wait ~30 seconds, reconnect your device to your main WiFi, then visit ' +
      'https://<pi-hostname>.local/ to access the KVM.',
      'wa'
    );
    btn.textContent = 'Connecting…';
  });
}

window.addEventListener('load', doScan);
</script>
</body>
</html>"""

# ── Routes ────────────────────────────────────────────────────────────

# Captive portal detection: respond to known check URLs with a redirect
_CAPTIVE = {
    "/hotspot-detect.html", "/library/test/success.html",
    "/generate_204", "/204",
    "/ncsi.txt", "/connecttest.txt",
    "/redirect", "/canonical.html",
    "/success.txt",
}

@app.before_request
def _captive_redirect():
    if request.path in _CAPTIVE and request.host not in (AP_IP, f"{AP_IP}:{PORT}"):
        return redirect(f"http://{AP_IP}/", 302)

@app.route("/")
@app.route("/index.html")
def index():
    return render_template_string(_HTML)

@app.route("/scan")
def scan():
    return jsonify(scan_networks())

@app.route("/connect", methods=["POST"])
def connect():
    d     = request.get_json(force=True, silent=True) or {}
    ssid  = (d.get("ssid") or "").strip()
    pwd   = (d.get("password") or "").strip()
    tskey = (d.get("tailscale_key") or "").strip()

    if not ssid:
        return jsonify({"ok": False, "error": "No network name provided."})
    if not re.match(r'^[ -~]{1,32}$', ssid):
        return jsonify({"ok": False, "error": "Invalid network name."})

    ok, msg = nm_connect(ssid, pwd)
    if not ok:
        return jsonify({"ok": False, "error": msg})

    # Tailscale — try now; write key either way so provision script can retry on failure
    ts_ip = ""
    if tskey:
        Path(TS_TMP).write_text(tskey)
        ts_ip = ts_connect(tskey)

    # Mark provisioning done (provision script polls for this)
    serial = _serial()
    threading.Timer(2.0, lambda: Path(FLAG).write_text(serial)).start()

    return jsonify({"ok": True, "ssid": ssid,
                    "tailscale": ts_ip if ts_ip else ""})

@app.errorhandler(404)
def _not_found(_):
    return redirect("/", 302)

    app.run(host="0.0.0.0", port=PORT, debug=False, use_reloader=False)

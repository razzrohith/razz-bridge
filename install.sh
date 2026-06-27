#!/bin/bash
# ============================================================
#  Razz Bridge
#
#  One-line install:
#    curl -fsSL https://raw.githubusercontent.com/razzrohith/razz-bridge/main/install.sh | sudo bash
#
#  Custom hostname (default: razz  →  https://razz.local/):
#    RAZZ_HOST=myname curl -fsSL https://raw.githubusercontent.com/razzrohith/razz-bridge/main/install.sh | sudo bash
#
#  Safe to re-run — all steps are idempotent.
# ============================================================
set -e

RAZZ_HOST="${RAZZ_HOST:-razz}"
RAZZ_SSH_PORT="${RAZZ_SSH_PORT:-2222}"    # SSH port (set 22 to keep default)
REPO_RAW="https://raw.githubusercontent.com/razzrohith/razz-bridge/main"
NGINX_CONF="/etc/nginx/conf.d/tinypilot.conf"

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
log()  { echo -e "${G}[razz]${N} $*"; }
warn() { echo -e "${Y}[warn]${N} $*"; }
die()  { echo -e "${R}[fail]${N} $*"; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root: curl ... | sudo bash"
command -v python3 >/dev/null || die "python3 not found"
log "Starting setup  --  host: ${RAZZ_HOST}.local"

# ── 1. Install TinyPilot if not present ──────────────────────
if ! { systemctl is-active  --quiet tinypilot 2>/dev/null || \
       systemctl is-enabled --quiet tinypilot 2>/dev/null || \
       [[ -f "$NGINX_CONF" ]]; }; then
    log "Installing TinyPilot community edition (5-10 min)..."
    curl --silent --show-error \
        https://raw.githubusercontent.com/tiny-pilot/tinypilot/master/get-tinypilot.sh | bash - \
        || die "TinyPilot install failed -- check internet connection"
    log "TinyPilot installed -- starting services..."
    sleep 5
    systemctl start tinypilot 2>/dev/null || true
    systemctl start nginx    2>/dev/null || true
    sleep 3
else
    log "TinyPilot detected -- skipping install"
fi

# ── 2. Ensure nginx-full (ngx_http_sub_module for theme injection) ────────────
if ! nginx -V 2>&1 | grep -q http_sub_module; then
    log "Upgrading to nginx-full (required for theme injection)..."
    apt-get install -y -q nginx-full
fi

# ── 3. Read hardware MACs ────────────────────────────────────
ETH0_MAC=$(ip link show eth0  2>/dev/null | awk '/link\/ether/{print $2}' || true)
WLAN0_MAC=$(ip link show wlan0 2>/dev/null | awk '/link\/ether/{print $2}' || true)
log "Hardware MACs: eth0=${ETH0_MAC:-none}  wlan0=${WLAN0_MAC:-none}"

# ── 4. Hostname ───────────────────────────────────────────────
log "Setting hostname --> $RAZZ_HOST"
hostnamectl set-hostname "$RAZZ_HOST"
echo "$RAZZ_HOST" > /etc/hostname
if grep -q '127\.0\.1\.1' /etc/hosts; then
    sed -i "s/127\.0\.1\.1.*/127.0.1.1\t$RAZZ_HOST/" /etc/hosts
else
    echo "127.0.1.1 $RAZZ_HOST" >> /etc/hosts
fi

# ── 5. avahi / mDNS ──────────────────────────────────────────
log "Configuring avahi --> ${RAZZ_HOST}.local"
command -v avahi-daemon >/dev/null || apt-get install -y -q avahi-daemon
if grep -q '^#*host-name=' /etc/avahi/avahi-daemon.conf 2>/dev/null; then
    sed -i "s/^#*host-name=.*/host-name=$RAZZ_HOST/" /etc/avahi/avahi-daemon.conf
else
    echo "host-name=$RAZZ_HOST" >> /etc/avahi/avahi-daemon.conf
fi
systemctl enable avahi-daemon 2>/dev/null || true
systemctl restart avahi-daemon

# Remove default SSH/SFTP avahi service announcements (hides Pi from Bonjour network discovery)
rm -f /etc/avahi/services/sftp-ssh.service /etc/avahi/services/ssh.service 2>/dev/null || true
rm -f /etc/avahi/services/*.service 2>/dev/null || true  # remove ALL service announcements

# Harden avahi-daemon.conf — respond to .local queries but don't broadcast device info
python3 << 'PYEOF'
import re
p = "/etc/avahi/avahi-daemon.conf"
try:
    c = open(p).read()
except Exception:
    c = ""
patches = {
    "publish-hinfo":      "no",   # don't publish CPU/OS hardware info
    "publish-workstation":"no",   # don't show up as a workstation in browsers
    "publish-domain":     "no",   # don't announce the domain
    "use-ipv6":           "no",   # reduce noise surface
}
for k, v in patches.items():
    if re.search(r'^' + k + r'\s*=', c, re.M):
        c = re.sub(r'^' + k + r'\s*=.*', k + '=' + v, c, flags=re.M)
    else:
        c += f"\n{k}={v}"
open(p, "w").write(c)
print("  avahi hardened")
PYEOF

# Secondary mDNS hostname (fallback if primary .local fails)
RAZZ_HOST2="${RAZZ_HOST}-alt"
cat > /etc/systemd/system/razz-mdns-alt.service << SVCEOF
[Unit]
Description=Razz Bridge mDNS fallback alias
After=avahi-daemon.service network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/avahi-publish -a -R ${RAZZ_HOST2}.local \$(hostname -I | awk '{print \$1}')
Restart=always
RestartSec=15

[Install]
WantedBy=multi-user.target
SVCEOF
systemctl daemon-reload
systemctl enable razz-mdns-alt 2>/dev/null || true
systemctl restart razz-mdns-alt 2>/dev/null || true
log "Secondary mDNS: ${RAZZ_HOST2}.local"

# ── 6. Flask + bcrypt + dnsmasq (for AP captive portal) ─────
python3 -c "import flask"  2>/dev/null || apt-get install -y -q python3-flask
python3 -c "import bcrypt" 2>/dev/null || apt-get install -y -q python3-bcrypt
# dnsmasq: NetworkManager uses it internally for AP shared connections
command -v dnsmasq >/dev/null 2>&1 || apt-get install -y -q dnsmasq

# ── 7. Stealth dashboard ─────────────────────────────────────
log "Installing stealth dashboard..."
curl -fsSL "$REPO_RAW/src/stealth-dashboard.py" \
    | sed -e "s/__ETH0_MAC__/${ETH0_MAC}/g" \
          -e "s/__WLAN0_MAC__/${WLAN0_MAC}/g" \
    > /usr/local/bin/stealth-dashboard.py
chmod +x /usr/local/bin/stealth-dashboard.py

curl -fsSL "$REPO_RAW/src/stealth-dashboard.service" \
    > /etc/systemd/system/stealth-dashboard.service
systemctl daemon-reload
systemctl enable stealth-dashboard
systemctl restart stealth-dashboard
log "stealth-dashboard: $(systemctl is-active stealth-dashboard)"

# ── 7b. First-boot WiFi provisioning system ──────────────────
log "Installing first-boot provisioning system..."
curl -fsSL "$REPO_RAW/src/razz-provision.sh"  -o /usr/local/bin/razz-provision.sh
curl -fsSL "$REPO_RAW/src/razz-setup-ui.py"   -o /usr/local/bin/razz-setup-ui.py
curl -fsSL "$REPO_RAW/src/razz-provision.service" \
    -o /etc/systemd/system/razz-provision.service
chmod +x /usr/local/bin/razz-provision.sh
chmod +x /usr/local/bin/razz-setup-ui.py
systemctl daemon-reload
systemctl enable razz-provision 2>/dev/null || true
# Note: DO NOT start the service now — it runs on next boot.
# It will auto-skip if WiFi is already connected (e.g., during dev setup).
log "  razz-provision.service enabled (runs on next boot)"

# Create razz-wifi.txt template on boot partition for documentation
# (delete this file if you don't want to pre-seed WiFi on new images)
WIFI_TMPL="/boot/razz-wifi.txt.example"
if [[ ! -f "$WIFI_TMPL" ]]; then
cat > "$WIFI_TMPL" << 'WIFIEOF'
# Razz Bridge WiFi pre-seed file
# Rename this file to razz-wifi.txt (remove .example) and fill in your credentials.
# Place on the boot partition (first FAT32 partition of the SD card).
# The Pi will read this on first boot, connect to WiFi, and delete the file.
#
SSID=YourNetworkName
PASSWORD=YourWiFiPassword
TAILSCALE_KEY=tskey-auth-xxxxxxxxxxxxxxxxx
WIFIEOF
    log "  razz-wifi.txt.example written to /boot/"
fi

# mac-spoof.sh placeholder (populated by dashboard when MAC spoofing is used)
if [[ ! -f /usr/local/bin/mac-spoof.sh ]]; then
    cat > /usr/local/bin/mac-spoof.sh << 'MACEOF'
#!/bin/bash
# Managed by Razz Bridge stealth dashboard -- do not edit by hand
spoof_mac() {
    local i="$1" m="$2"
    [[ -n "$m" ]] || return
    ip link set "$i" down         2>/dev/null || true
    ip link set "$i" address "$m" 2>/dev/null || true
    ip link set "$i" up           2>/dev/null || true
}
# Entries below are written automatically when spoofing is applied
MACEOF
    chmod +x /usr/local/bin/mac-spoof.sh
fi

# ── 8. USB device identity (Logitech USB Keyboard K120) ─────
log "Applying USB identity --> Logitech USB Keyboard K120"
USB_MFR="Logitech"
USB_PROD="USB Keyboard K120"
USB_SER="$(python3 -c "import random; print('046D20'+''.join(random.choices('0123456789ABCDEF',k=10)))")"
USB_SYS="/sys/kernel/config/usb_gadget/g1"
GADGET_INIT="/opt/tinypilot-privileged/init-usb-gadget"

# Write to live sysfs (immediate effect if USB gadget is running)
for _kv in "manufacturer:$USB_MFR" "product:$USB_PROD" "serialnumber:$USB_SER"; do
    _k="${_kv%%:*}"; _v="${_kv#*:}"
    echo "$_v" > "$USB_SYS/strings/0x409/$_k" 2>/dev/null || true
done

# VID/PID + bcdDevice for Logitech K120 (046D:C31C, firmware 1.10)
USB_VID="0x046d"
USB_PID="0xc31c"
USB_BCD="0x0110"   # bcdDevice firmware version — matches real K120

# Write VID/PID to live sysfs (requires UDC rebind to take effect)
USB_UDC=$(cat "$USB_SYS/UDC" 2>/dev/null || true)
if [[ -n "$USB_UDC" ]]; then
    echo "" > "$USB_SYS/UDC" 2>/dev/null || true
    sleep 0.3
fi
echo "$USB_VID" > "$USB_SYS/idVendor"  2>/dev/null || true
echo "$USB_PID" > "$USB_SYS/idProduct" 2>/dev/null || true
echo "$USB_BCD" > "$USB_SYS/bcdDevice" 2>/dev/null || true
# Full USB device descriptor — match K120 (USB 2.0, class defined at interface level)
echo "0x0200" > "$USB_SYS/bcdUSB"          2>/dev/null || true
echo "0x00"   > "$USB_SYS/bDeviceClass"    2>/dev/null || true
echo "0x00"   > "$USB_SYS/bDeviceSubClass" 2>/dev/null || true
echo "0x00"   > "$USB_SYS/bDeviceProtocol" 2>/dev/null || true
echo "0x08"   > "$USB_SYS/bMaxPacketSize0" 2>/dev/null || true
if [[ -n "$USB_UDC" ]]; then
    sleep 0.2
    echo "$USB_UDC" > "$USB_SYS/UDC" 2>/dev/null || true
fi

# Backup gadget init script before first patch
if [[ -f "$GADGET_INIT" && ! -f "${GADGET_INIT}.orig" ]]; then
    cp "$GADGET_INIT" "${GADGET_INIT}.orig"
    log "init-usb-gadget backed up --> ${GADGET_INIT}.orig"
fi

# Patch the gadget init script so identity survives reboots
if [[ -f "$GADGET_INIT" ]]; then
    _MFR="$USB_MFR" _PROD="$USB_PROD" _SER="$USB_SER" \
    _VID="$USB_VID" _PID="$USB_PID"  _BCD="$USB_BCD" python3 << 'PYEOF'
import re, os
mfr, prod, ser = os.environ['_MFR'], os.environ['_PROD'], os.environ['_SER']
vid, pid, bcd  = os.environ['_VID'], os.environ['_PID'], os.environ['_BCD']
p = "/opt/tinypilot-privileged/init-usb-gadget"
with open(p) as f: c = f.read()
c = re.sub(r'echo "[^"]*" > "\$\{USB_STRINGS_DIR\}/manufacturer"',
           f'echo "{mfr}" > "${{USB_STRINGS_DIR}}/manufacturer"', c)
c = re.sub(r'echo "[^"]*" > "\$\{USB_STRINGS_DIR\}/product"',
           f'echo "{prod}" > "${{USB_STRINGS_DIR}}/product"', c)
c = re.sub(r'echo "[^"]*" > "\$\{USB_STRINGS_DIR\}/serialnumber"',
           f'echo "{ser}" > "${{USB_STRINGS_DIR}}/serialnumber"', c)
c = re.sub(r'echo \S+ > "\$\{GADGET_DIR\}/idVendor"',
           f'echo {vid}  > "${{GADGET_DIR}}/idVendor"', c)
c = re.sub(r'echo \S+ > "\$\{GADGET_DIR\}/idProduct"',
           f'echo {pid} > "${{GADGET_DIR}}/idProduct"', c)
c = re.sub(r'echo \S+ > "\$\{GADGET_DIR\}/bcdDevice"',
           f'echo {bcd} > "${{GADGET_DIR}}/bcdDevice"', c)
# Patch bcdUSB to 0x0200 (USB 2.0) if present
c = re.sub(r'echo \S+ > "\$\{GADGET_DIR\}/bcdUSB"',
           'echo 0x0200 > "${GADGET_DIR}/bcdUSB"', c)
# Patch device class to 0x00 (class defined at interface level, like a real K120)
# Only replace if the script explicitly sets non-zero values — 0xEF/0x02/0x01 = IAD composite
c = re.sub(r'echo 0x[Ee][Ff] > "\$\{GADGET_DIR\}/bDeviceClass"',
           'echo 0x00 > "${GADGET_DIR}/bDeviceClass"', c)
c = re.sub(r'echo 0x0[12] > "\$\{GADGET_DIR\}/bDeviceSubClass"',
           'echo 0x00 > "${GADGET_DIR}/bDeviceSubClass"', c)
c = re.sub(r'echo 0x0[12] > "\$\{GADGET_DIR\}/bDeviceProtocol"',
           'echo 0x00 > "${GADGET_DIR}/bDeviceProtocol"', c)
with open(p, "w") as f: f.write(c)
print("  USB init script patched (strings + VID/PID + bcdDevice + bcdUSB + device class)")
PYEOF
    systemctl restart tinypilot 2>/dev/null || true
    sleep 2
fi

# Write stealth config (auth always defaults to "lol" via bcrypt; dashboard handles this on startup too)
_MFR="$USB_MFR" _PROD="$USB_PROD" _SER="$USB_SER" \
_VID="$USB_VID" _PID="$USB_PID" \
_ETH0="$ETH0_MAC" _WLAN0="$WLAN0_MAC" python3 << 'PYEOF'
import json, os, secrets
path = "/etc/stealth-config.json"
try:
    with open(path) as f: cfg = json.load(f)
except Exception:
    cfg = {}
if not cfg.get("usb", {}).get("enabled"):
        "enabled":      True,
        "manufacturer": os.environ["_MFR"],
        "product":      os.environ["_PROD"],
        "serial":       os.environ["_SER"],
        "idVendor":     os.environ["_VID"],
        "idProduct":    os.environ["_PID"],
        "profile_idx":  0,
    }
cfg.setdefault("safe_mode", False)
cfg.setdefault("mac", {
    "enabled": False,
    "eth0":    os.environ.get("_ETH0", ""),
    "wlan0":   os.environ.get("_WLAN0", ""),
})
# Auth: default password "lol" set by stealth-dashboard.py on first startup.
# Only ensure secret_key exists here so Flask can start.
if not cfg.get("auth", {}).get("secret_key"):
    cfg.setdefault("auth", {})["secret_key"] = secrets.token_hex(32)
    print("  secret_key generated")
with open(path, "w") as f: json.dump(cfg, f, indent=2)
print("  stealth config written  (default panel password: lol)")
PYEOF

# ── 9. Hide SSH OS fingerprint + move port ───────────────────
sed -i '/^DebianBanner/d; /^Port /d' /etc/ssh/sshd_config
{
    echo "DebianBanner no"
    echo "Port $RAZZ_SSH_PORT"
} >> /etc/ssh/sshd_config
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
log "SSH: fingerprint hidden, port --> $RAZZ_SSH_PORT"

# ── 9b. DHCP naturalness — stop broadcasting hostname + vendor class ──
# Keyboards don't send DHCP hostnames or Linux vendor class strings
DHCPCD="/etc/dhcpcd.conf"
if [[ -f "$DHCPCD" ]]; then
    # Remove any existing hostname / vendorclassid lines
    sed -i '/^\(hostname\|vendorclassid\|clientid\)/d' "$DHCPCD"
    # nohook hostname = don't send hostname in DHCP requests
    echo "nohook hostname"  >> "$DHCPCD"
    # Empty vendorclassid = don't reveal "dhcpcd:Linux:armv8..."
    echo 'vendorclassid ""' >> "$DHCPCD"
    log "DHCP: hostname + vendor class suppressed"
    systemctl restart dhcpcd 2>/dev/null || true
fi

# ── 9. Razz theme files ───────────────────────────────────────
log "Installing theme..."
curl -fsSL "$REPO_RAW/src/razz-theme.css" -o /opt/razz-theme.css
curl -fsSL "$REPO_RAW/src/razz-brand.js"  -o /opt/razz-brand.js

# ── 10. nginx patch ───────────────────────────────────────────
log "Patching nginx config..."
_RAZZ_HOST="$RAZZ_HOST" python3 << 'PYEOF'
import re, sys, os
rh   = os.environ["_RAZZ_HOST"]
path = "/etc/nginx/conf.d/tinypilot.conf"

try:
    c = open(path).read()
except FileNotFoundError:
    print("  [warn] tinypilot.conf not found -- nginx patch skipped")
    sys.exit(0)

changed = False

# 10a. server_tokens off
if "server_tokens" not in c:
    c = re.sub(r"(server\s*\{)", r"\1\n    server_tokens off;", c, count=1)
    changed = True

# 10b. Add RAZZ_HOST.local to server_name
rh_local = rh + ".local"
if rh_local not in c:
    def add_hostname(m):
        names = m.group(2)
        if rh_local in names:
            return m.group(0)
        stripped = names.strip()
        if "tinypilot" in stripped or stripped == "_":
            return m.group(1) + names.rstrip() + " " + rh_local + m.group(3)
        return m.group(0)
    c, n = re.subn(r"(server_name\s+)([^;]+)(;)", add_hostname, c)
    if n:
        print(f"  server_name: added {rh_local}")
        changed = True

# 10c. sub_filter injection in location / (injects CSS+JS into every HTML response)
if "razz-theme.css" not in c:
    injected = [False]
    def inject_sub(m):
        block = m.group(0)
        if "proxy_pass http://tinypilot" not in block:
            return block
        if "sub_filter" in block:
            return block
        old = "proxy_pass http://tinypilot;"
        ins = (
            "\n        proxy_set_header Accept-Encoding \"\";"
            "\n        sub_filter_once on;"
            "\n        sub_filter_types text/html;"
            "\n        sub_filter '</head>'"
            " '<link rel=\"stylesheet\" href=\"/razz-theme.css\">"
            "<script src=\"/razz-brand.js\"></script></head>';"
        )
        injected[0] = True
        return block.replace(old, old + ins, 1)
    c = re.sub(r"location\s*/\s*\{[^}]+\}", inject_sub, c)
    if injected[0]:
        print("  sub_filter injected into location /")
        changed = True
    elif "razz-theme.css" not in c:
        print("  [WARN] location / block not matched -- check that proxy_pass http://tinypilot; exists")

# 10d. Rate-limit zone for stealth panel (5 req/s per IP, burst 12)
if "razz_stealth_zone" not in c:
    c = "limit_req_zone $binary_remote_addr zone=razz_stealth_zone:4m rate=5r/s;\n\n" + c
    print("  rate-limit zone added")
    changed = True

# 10e. Stealth panel, WiFi API, and static asset location blocks
if "/stealth/" not in c:
    blk = """
    location /stealth/ {
        limit_req zone=razz_stealth_zone burst=12 nodelay;
        limit_req_status 429;
        proxy_pass http://127.0.0.1:7777/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_read_timeout 60s;
    }
    location /api/wifi/ {
        # WiFi management API — no auth, accessible from main KVM page
        proxy_pass http://127.0.0.1:7777/api/wifi/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_read_timeout 30s;
    }
    location = /razz-theme.css {
        alias /opt/razz-theme.css;
        add_header Cache-Control "no-cache, no-store";
    }
    location = /razz-brand.js {
        alias /opt/razz-brand.js;
        add_header Cache-Control "no-cache, no-store";
    }
"""
    idx = c.rfind("}")
    c = c[:idx] + blk + "\n}"
    print("  location blocks added")
    changed = True
elif "/api/wifi/" not in c:
    # Already have /stealth/ but missing /api/wifi/ — add it
    blk = """
    location /api/wifi/ {
        proxy_pass http://127.0.0.1:7777/api/wifi/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_read_timeout 30s;
    }
"""
    idx = c.rfind("}")
    c = c[:idx] + blk + "\n}"
    print("  /api/wifi/ location added")
    changed = True

if changed:
    open(path, "w").write(c)
    print("  tinypilot.conf saved")
else:
    print("  nginx conf already up to date")
PYEOF

# ── 11. SSL cert for RAZZ_HOST.local ─────────────────────────
CERT="/etc/ssl/certs/tinypilot-nginx.crt"
KEY="/etc/ssl/private/tinypilot-nginx.key"
if [[ -f "$CERT" ]] && openssl x509 -in "$CERT" -text 2>/dev/null | grep -q "${RAZZ_HOST}\.local"; then
    log "SSL cert already includes ${RAZZ_HOST}.local -- skipping"
else
    log "Generating SSL cert for ${RAZZ_HOST}.local..."
    [[ -f "$CERT" ]] && cp "$CERT" "${CERT}.bak"
    [[ -f "$KEY"  ]] && cp "$KEY"  "${KEY}.bak"
    openssl req -x509 -newkey rsa:2048 \
        -keyout /tmp/razz.key -out /tmp/razz.crt \
        -days 3650 -nodes \
        -subj "/CN=${RAZZ_HOST}.local" \
        -addext "subjectAltName=DNS:${RAZZ_HOST}.local,DNS:tinypilot,DNS:localhost,IP:127.0.0.1" \
        2>/dev/null
    cp /tmp/razz.crt "$CERT"
    cp /tmp/razz.key "$KEY"
    rm -f /tmp/razz.crt /tmp/razz.key
fi

# ── 12. Test and reload nginx ─────────────────────────────────
if nginx -t 2>/tmp/razz-nginx-test.out; then
    systemctl reload nginx
    log "nginx reloaded OK"
else
    cat /tmp/razz-nginx-test.out
    die "nginx config test failed -- see errors above"
fi

# ── 13. Tailscale ────────────────────────────────────────────
if ! command -v tailscale >/dev/null 2>&1; then
    log "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | bash - 2>/dev/null \
        || warn "Tailscale install failed -- run manually later"
    systemctl enable tailscaled 2>/dev/null || true
    systemctl start  tailscaled 2>/dev/null || true
else
    log "Tailscale already installed: $(tailscale version 2>/dev/null | head -1)"
fi

# Auto-authenticate if TAILSCALE_AUTHKEY is set
#   Usage:  TAILSCALE_AUTHKEY=tskey-auth-xxx curl ... | sudo bash
if [[ -n "${TAILSCALE_AUTHKEY:-}" ]]; then
    log "Tailscale: authenticating with provided auth key..."
    tailscale up --authkey="$TAILSCALE_AUTHKEY" --accept-routes 2>/dev/null \
        && log "Tailscale: connected -- IP: $(tailscale ip -4 2>/dev/null || echo '?')" \
        || warn "Tailscale: auth failed -- check key and try 'sudo tailscale up' manually"
else
    log "Tailscale: no TAILSCALE_AUTHKEY set -- run 'sudo tailscale up' to authenticate"
fi

# ── 14. Log files ─────────────────────────────────────────────
log "Initializing log files..."
touch /var/log/razz-auth.log /var/log/razz-sessions.log 2>/dev/null || true
chmod 640 /var/log/razz-auth.log /var/log/razz-sessions.log 2>/dev/null || true
# Progressive login delay is handled in-process by stealth-dashboard.py.
# No external blocking is used — the panel never locks anyone out.

# ── 14b. MAC boot-persistence service (managed by stealth panel) ─────────────
# The service is empty on first install; the panel writes entries into
# stealth-config.json and regenerates this file whenever a MAC is applied.
if [[ ! -f /etc/systemd/system/razz-mac.service ]]; then
cat > /etc/systemd/system/razz-mac.service << 'SVCEOF'
[Unit]
Description=Razz Bridge persistent MAC addresses
Before=network.target dhcpcd.service

[Service]
Type=oneshot
ExecStart=/bin/true
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF
    systemctl daemon-reload
    systemctl enable razz-mac 2>/dev/null || true
    log "razz-mac.service registered (will populate when MAC is applied from panel)"
fi

# ── 15. Firewall — default-deny inbound, allow only what's needed ─────────────
log "Configuring iptables firewall..."
apt-get install -y -q iptables-persistent 2>/dev/null || true

# Flush + start fresh
iptables -F; iptables -X; iptables -Z

# Default policies
iptables -P INPUT   DROP
iptables -P FORWARD DROP
iptables -P OUTPUT  ACCEPT    # outbound unrestricted

# Loopback (required for Flask + local services)
iptables -A INPUT -i lo -j ACCEPT

# Established / related connections
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# HTTP + HTTPS (TinyPilot KVM UI + stealth panel)
iptables -A INPUT -p tcp --dport 80  -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -j ACCEPT

# SSH on custom port
iptables -A INPUT -p tcp --dport "${RAZZ_SSH_PORT}" -j ACCEPT

# Tailscale (WireGuard UDP + tailscale0 interface)
iptables -A INPUT -i tailscale0 -j ACCEPT
iptables -A INPUT -p udp --dport 41641 -j ACCEPT

# mDNS (avahi — needed for .local hostname)
iptables -A INPUT -p udp --dport 5353 -j ACCEPT

# ICMP ping (useful for diagnostics; drop to block if desired)
iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT

# SSDP/UPnP discovery — explicitly drop (already caught by default DROP, but explicit)
iptables -A INPUT  -p udp --dport 1900 -j DROP
iptables -A OUTPUT -p udp --dport 1900 -j DROP

# Persist across reboots
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4
log "Firewall applied (default-deny; allowed: 80, 443, SSH:${RAZZ_SSH_PORT}, Tailscale, mDNS)"

# ── Done ─────────────────────────────────────────────────────
echo ""
echo -e "${G}==> Setup complete!${N}"
echo ""
echo "  Main:          https://${RAZZ_HOST}.local/"
echo "  Panel:         https://${RAZZ_HOST}.local/stealth/"
echo "  Alt hostname:  https://${RAZZ_HOST}-alt.local/  (fallback)"
echo ""
echo -e "  ${Y}Panel password: lol${N}"
echo "  To change it, contact the developer."
echo ""
echo "  SSH:       ssh <user>@${RAZZ_HOST}.local -p ${RAZZ_SSH_PORT}"
if [[ -z "${TAILSCALE_AUTHKEY:-}" ]]; then
echo "  Tailscale: run 'sudo tailscale up' to authenticate remote access"
else
echo "  Tailscale: authenticated -- IP: $(tailscale ip -4 2>/dev/null || echo '?')"
fi
echo ""
echo "  First visit: click Advanced --> Proceed past the self-signed cert warning."
echo "  Windows:     install Bonjour (via iTunes) if .local does not resolve."
echo ""
echo -e "  ${Y}First-boot WiFi setup:${N}"
echo "   · On a fresh image (no saved WiFi), the Pi starts a 'Bridge-Setup' AP."
echo "   · Connect your phone/laptop to 'Bridge-Setup' (password: bridge1234)"
echo "   · Open any browser page — the setup page appears automatically."
echo "   · Or pre-seed: copy /boot/razz-wifi.txt.example to /boot/razz-wifi.txt"
echo "     and fill in your network credentials before first boot."
echo ""

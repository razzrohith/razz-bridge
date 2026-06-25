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

# ── 6. Flask ─────────────────────────────────────────────────
python3 -c "import flask" 2>/dev/null || apt-get install -y -q python3-flask

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
if [[ -n "$USB_UDC" ]]; then
    sleep 0.2
    echo "$USB_UDC" > "$USB_SYS/UDC" 2>/dev/null || true
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
with open(p, "w") as f: f.write(c)
print("  USB init script patched (strings + VID/PID + bcdDevice)")
PYEOF
    systemctl restart tinypilot 2>/dev/null || true
    sleep 2
fi

# Generate stealth panel password (first install only)
STEALTH_PASS="$(python3 -c "import secrets; print(secrets.token_urlsafe(12))")"

# Write stealth config with USB + auth
_MFR="$USB_MFR" _PROD="$USB_PROD" _SER="$USB_SER" \
_VID="$USB_VID" _PID="$USB_PID" \
_ETH0="$ETH0_MAC" _WLAN0="$WLAN0_MAC" \
_PASS="$STEALTH_PASS" python3 << 'PYEOF'
import json, os, hashlib, secrets
path = "/etc/stealth-config.json"
try:
    with open(path) as f: cfg = json.load(f)
except Exception:
    cfg = {}
if not cfg.get("usb", {}).get("enabled"):
    cfg["usb"] = {
        "enabled":      True,
        "manufacturer": os.environ["_MFR"],
        "product":      os.environ["_PROD"],
        "serial":       os.environ["_SER"],
        "idVendor":     os.environ["_VID"],
        "idProduct":    os.environ["_PID"],
        "profile_idx":  0,
    }
cfg.setdefault("ssh_banner", True)
cfg.setdefault("mac", {
    "enabled": False,
    "eth0":    os.environ.get("_ETH0", ""),
    "wlan0":   os.environ.get("_WLAN0", ""),
})
cfg.setdefault("razz_block", False)
cfg.setdefault("safe_mode", False)
# Auth: only set on first install (don't overwrite existing password)
if "auth" not in cfg or not cfg["auth"].get("password_hash"):
    pw = os.environ.get("_PASS", "razz")
    cfg["auth"] = {
        "password_hash": hashlib.sha256(pw.encode()).hexdigest(),
        "secret_key":    secrets.token_hex(32),
    }
    print(f"  panel auth initialized")
else:
    print("  panel auth already set -- preserving existing password")
with open(path, "w") as f: json.dump(cfg, f, indent=2)
print("  stealth config written")
PYEOF

# ── 9. Hide SSH OS fingerprint + move port ───────────────────
sed -i '/^DebianBanner/d; /^Port /d' /etc/ssh/sshd_config
{
    echo "DebianBanner no"
    echo "Port $RAZZ_SSH_PORT"
} >> /etc/ssh/sshd_config
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
log "SSH: fingerprint hidden, port --> $RAZZ_SSH_PORT"

# Update fail2ban SSH port (in case it was set earlier with port 22)
sed -i "s/^port\s*=.*/port = $RAZZ_SSH_PORT/" /etc/fail2ban/jail.local 2>/dev/null || true

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
path = "/
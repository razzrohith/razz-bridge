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

# ── 6. Flask + bcrypt ────────────────────────────────────────
python3 -c "import flask"  2>/dev/null || apt-get install -y -q python3-flask
python3 -c "import bcrypt" 2>/dev/null || apt-get install -y -q python3-bcrypt

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
    cfg["usb"] = {
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
    
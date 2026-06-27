#!/bin/bash
# ============================================================
#  Razz Bridge — Uninstaller
#
#  Removes all Razz Bridge additions and returns the device to
#  a stock TinyPilot community edition state.
#
#  Run as root:  sudo bash uninstall.sh
#  Safe to run even if install was partial.
# ============================================================
set -e

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
log()  { echo -e "${G}[razz-uninstall]${N} $*"; }
warn() { echo -e "${Y}[warn]${N} $*"; }

[[ $EUID -eq 0 ]] || { echo -e "${R}[fail]${N} Run as root: sudo bash uninstall.sh"; exit 1; }

echo -e "${Y}"
echo "  ╔══════════════════════════════════════════╗"
echo "  ║  Razz Bridge Uninstaller                 ║"
echo "  ║  Reverting to stock TinyPilot state      ║"
echo "  ╚══════════════════════════════════════════╝"
echo -e "${N}"
echo "  This will remove:"
echo "    · Stealth dashboard service + files"
echo "    · Razz Bridge nginx additions"
echo "    · Firewall rules"
echo "    · mDNS alt-hostname service"
echo "    · DHCP naturalness overrides"
echo "    · Razz config file + log files"
echo "    · DuckDNS cron"
echo "    · USB gadget script (restored from .orig if available)"
echo ""
read -r -p "  Continue? [y/N] " CONFIRM
[[ "${CONFIRM,,}" == "y" ]] || { echo "Aborted."; exit 0; }
echo ""

# ── 1. Stop + remove stealth dashboard ───────────────────────
log "Removing stealth dashboard..."
systemctl stop    stealth-dashboard 2>/dev/null || true
systemctl disable stealth-dashboard 2>/dev/null || true
rm -f /etc/systemd/system/stealth-dashboard.service
rm -f /usr/local/bin/stealth-dashboard.py
systemctl daemon-reload

# ── 2. Remove Razz Bridge nginx additions ────────────────────
log "Reverting nginx config..."
NGINX_CONF="/etc/nginx/conf.d/tinypilot.conf"
if [[ -f "$NGINX_CONF" ]]; then
    python3 << 'PYEOF'
import re, sys
path = "/etc/nginx/conf.d/tinypilot.conf"
try:
    c = open(path).read()
except Exception:
    sys.exit(0)

orig = c

# Remove rate-limit zone line at the top
c = re.sub(r'^limit_req_zone[^\n]*\n\n?', '', c, flags=re.M)

# Remove /stealth/ and /api/wifi/ location blocks
c = re.sub(r'\s*location\s+/stealth/\s*\{[^}]+\}', '', c)
c = re.sub(r'\s*location\s+/api/wifi/\s*\{[^}]+\}', '', c)

# Remove /razz-theme.css and /razz-brand.js location blocks
c = re.sub(r'\s*location\s*=\s*/razz-theme\.css\s*\{[^}]+\}', '', c)
c = re.sub(r'\s*location\s*=\s*/razz-brand\.js\s*\{[^}]+\}',  '', c)

# Remove sub_filter + Accept-Encoding lines injected into location /
c = re.sub(r'\s*proxy_set_header Accept-Encoding\s+""\s*;', '', c)
c = re.sub(r'\s*sub_filter_once\s+\w+\s*;', '', c)
c = re.sub(r'\s*sub_filter_types\s+[^;]+;', '', c)
c = re.sub(r'\s*sub_filter\s+[^;]+;', '', c)

# Remove server_tokens off (added by razz)
c = re.sub(r'\s*server_tokens\s+off\s*;', '', c)

if c != orig:
    open(path, "w").write(c)
    print("  tinypilot.conf cleaned")
else:
    print("  tinypilot.conf unchanged")
PYEOF
    nginx -t 2>/dev/null && systemctl reload nginx && log "nginx reloaded" \
        || warn "nginx config test failed -- check /etc/nginx/conf.d/tinypilot.conf"
else
    warn "tinypilot.conf not found -- nginx cleanup skipped"
fi

# ── 3. Remove Razz theme static files ────────────────────────
log "Removing theme files..."
rm -f /opt/razz-theme.css /opt/razz-brand.js

# ── 4. Remove DuckDNS cron ───────────────────────────────────
log "Removing DuckDNS cron..."
rm -f /etc/cron.d/razz-duckdns

# ── 4b. Remove provisioning system ───────────────────────────
log "Removing first-boot provisioning system..."
systemctl stop    razz-provision 2>/dev/null || true
systemctl disable razz-provision 2>/dev/null || true
rm -f /etc/systemd/system/razz-provision.service
rm -f /usr/local/bin/razz-provision.sh
rm -f /usr/local/bin/razz-setup-ui.py
rm -f /etc/razz-provisioned
rm -f /boot/razz-wifi.txt.example
rm -f /var/log/razz-provision.log
rm -f /etc/NetworkManager/dnsmasq-shared.d/razz-captive.conf
systemctl daemon-reload

# ── 5. Remove mDNS alt-hostname service ──────────────────────
log "Removing alt-mDNS service..."
systemctl stop    razz-mdns-alt 2>/dev/null || true
systemctl disable razz-mdns-alt 2>/dev/null || true
rm -f /etc/systemd/system/razz-mdns-alt.service
systemctl daemon-reload

# ── 6. Remove config + log files ─────────────────────────────
log "Removing config + log files..."
rm -f /etc/stealth-config.json
rm -f /var/log/razz-auth.log /var/log/razz-sessions.log /var/log/razz-duckdns.log

# ── 7. Restore USB gadget init script ────────────────────────
GADGET_INIT="/opt/tinypilot-privileged/init-usb-gadget"
log "Restoring USB gadget init script..."
if [[ -f "${GADGET_INIT}.orig" ]]; then
    cp "${GADGET_INIT}.orig" "$GADGET_INIT"
    rm -f "${GADGET_INIT}.orig"
    log "  restored from .orig backup"
    systemctl restart tinypilot 2>/dev/null || true
else
    warn "  no .orig backup found -- USB gadget script not restored"
    warn "  original TinyPilot identity may need manual restore"
fi

# ── 8. Flush iptables firewall ────────────────────────────────
log "Flushing iptables rules..."
iptables -F 2>/dev/null || true
iptables -X 2>/dev/null || true
iptables -P INPUT   ACCEPT 2>/dev/null || true
iptables -P FORWARD ACCEPT 2>/dev/null || true
iptables -P OUTPUT  ACCEPT 2>/dev/null || true
rm -f /etc/iptables/rules.v4
log "  iptables flushed (default ACCEPT)"

# ── 9. Revert DHCP naturalness overrides ─────────────────────
DHCPCD="/etc/dhcpcd.conf"
log "Reverting DHCP config..."
if [[ -f "$DHCPCD" ]]; then
    sed -i '/^nohook hostname/d; /^vendorclassid/d' "$DHCPCD"
    systemctl restart dhcpcd 2>/dev/null || true
    log "  dhcpcd.conf cleaned"
fi

# ── 10. Revert avahi hardening ────────────────────────────────
log "Reverting avahi config..."
python3 << 'PYEOF'
import re
p = "/etc/avahi/avahi-daemon.conf"
try:
    c = open(p).read()
except Exception:
    exit(0)
# Re-enable settings that were turned off
for k, v in [("publish-hinfo","yes"), ("publish-workstation","yes"),
             ("publish-domain","yes"),  ("use-ipv6","yes")]:
    c = re.sub(r'^' + k + r'=\w+', k + '=' + v, c, flags=re.M)
open(p, "w").write(c)
print("  avahi settings restored")
PYEOF
systemctl restart avahi-daemon 2>/dev/null || true

# ── 11. Remove mac-spoof placeholder ─────────────────────────
log "Removing mac-spoof script..."
rm -f /usr/local/bin/mac-spoof.sh

# ── 12. SSH — restore default port + banner ───────────────────
log "Restoring SSH defaults..."
SSHD="/etc/ssh/sshd_config"
# Remove razz-added lines
sed -i '/^DebianBanner no/d; /^Port /d' "$SSHD"
# Add back standard port 22 (TinyPilot default)
echo "Port 22" >> "$SSHD"
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
log "  SSH restored to port 22"

# ── Done ───────────────────
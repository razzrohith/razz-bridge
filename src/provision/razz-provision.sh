#!/bin/bash
# ============================================================
#  Razz Bridge — First-boot WiFi provisioning
#
#  Runs on every boot, self-skips if this Pi is already
#  provisioned (identified by Pi serial number in flag file).
#
#  Flow A: /boot/razz-wifi.txt found  → configure WiFi from file
#  Flow B: No WiFi config found       → start Bridge-Setup AP
#          User connects to AP, opens browser, enters WiFi + Tailscale
#          Pi connects, provisioning done, AP tears down
# ============================================================
set -uo pipefail

FLAG="/etc/razz-provisioned"
WIFI_FILE="/boot/razz-wifi.txt"
LOG="/var/log/razz-provision.log"
AP_SSID="Bridge-Setup"
AP_PASS="bridge1234"
AP_IP="192.168.4.1"
SETUP_PORT=7779
TS_KEY_TMP="/tmp/razz-ts-key"

# ── Per-device provisioning check (serial-based) ──────────────────────
SERIAL=$(grep -m1 Serial /proc/cpuinfo 2>/dev/null | awk '{print $NF}' || echo "unknown")
if [[ -f "$FLAG" ]]; then
    STORED=$(cat "$FLAG" 2>/dev/null || true)
    [[ "$STORED" == "$SERIAL" ]] && exit 0
    # Different Pi — re-provision
fi

mkdir -p "$(dirname "$LOG")"
exec >> "$LOG" 2>&1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

log "=== Razz Bridge first-boot provisioning (serial: $SERIAL) ==="

# ── Wait for NetworkManager ───────────────────────────────────────────
sleep 12
for i in 1 2 3 4 5; do
    nmcli general status &>/dev/null && break
    log "Waiting for NetworkManager… ($i/5)"
    sleep 5
done

# ── Helpers ───────────────────────────────────────────────────────────

nm_add_wifi() {
    local ssid="$1" pass="$2" prio="${3:-100}"
    nmcli connection delete "$ssid" &>/dev/null || true
    if [[ -n "$pass" ]]; then
        nmcli connection add \
            type wifi ifname wlan0 \
            con-name "$ssid" ssid "$ssid" \
            wifi-sec.key-mgmt wpa-psk \
            wifi-sec.psk "$pass" \
            connection.autoconnect yes \
            connection.autoconnect-priority "$prio" &>/dev/null \
            && log "Saved WiFi: $ssid" || log "Warning: could not save $ssid"
    else
        nmcli connection add \
            type wifi ifname wlan0 \
            con-name "$ssid" ssid "$ssid" \
            connection.autoconnect yes \
            connection.autoconnect-priority "$prio" &>/dev/null \
            && log "Saved open WiFi: $ssid" || log "Warning: could not save $ssid"
    fi
}

wifi_connected() {
    nmcli -t -f STATE general status 2>/dev/null | grep -q "^connected$"
}

wait_wifi() {
    log "Waiting for WiFi (up to 40s)…"
    for i in $(seq 1 20); do
        sleep 2
        wifi_connected && return 0
    done
    return 1
}

try_tailscale() {
    local key="${1:-}"
    [[ -z "$key" ]] && return 0
    log "Authenticating Tailscale…"
    tailscale up --authkey="$key" --accept-routes &>/dev/null \
        && log "Tailscale connected: $(tailscale ip -4 2>/dev/null || echo ok)" \
        || log "Tailscale auth failed — configure later from the stealth panel"
}

mark_done() {
    echo "$SERIAL" > "$FLAG"
    log "Provisioning complete — flag written for serial $SERIAL"
}

start_ap() {
    log "Starting Bridge-Setup AP (SSID: $AP_SSID, pass: $AP_PASS, IP: $AP_IP)"

    # Captive portal DNS: all queries from AP clients → AP IP
    mkdir -p /etc/NetworkManager/dnsmasq-shared.d
    cat > /etc/NetworkManager/dnsmasq-shared.d/razz-captive.conf << EOF
# Captive portal — redirect all DNS to AP IP
address=/#/${AP_IP}
EOF
    systemctl reload NetworkManager &>/dev/null || true
    sleep 2

    # Create AP connection (NM handles DHCP via shared mode)
    nmcli connection delete "$AP_SSID" &>/dev/null || true
    nmcli connection add \
        type wifi ifname wlan0 \
        con-name "$AP_SSID" \
        ssid "$AP_SSID" \
        mode ap \
        ipv4.method shared \
        ipv4.addresses "${AP_IP}/24" \
        wifi-sec.key-mgmt wpa-psk \
        wifi-sec.psk "$AP_PASS" \
        connection.autoconnect no &>/dev/null
    nmcli connection up "$AP_SSID" &>/dev/null
    sleep 4

    # HTTP/HTTPS → setup UI port (captive portal)
    iptables -t nat -I PREROUTING -i wlan0 -p tcp --dport 80  \
        -j REDIRECT --to-port $SETUP_PORT &>/dev/null || true
    iptables -t nat -I PREROUTING -i wlan0 -p tcp --dport 443 \
        -j REDIRECT --to-port $SETUP_PORT &>/dev/null || true
    # Allow setup UI port through default-deny firewall
    iptables -I INPUT   -i wlan0 -p tcp --dport $SETUP_PORT -j ACCEPT &>/dev/null || true
    # Allow NM AP shared NAT forwarding
    iptables -I FORWARD -i wlan0 -j ACCEPT &>/dev/null || true
    iptables -I FORWARD -o wlan0 -j ACCEPT &>/dev/null || true

    log "Bridge-Setup AP active — SSID: '$AP_SSID' / Password: '$AP_PASS'"
    log "User: connect to '$AP_SSID', open browser → setup page appears"
}

stop_ap() {
    log "Tearing down Bridge-Setup AP…"
    iptables -t nat -D PREROUTING -i wlan0 -p tcp --dport 80  \
        -j REDIRECT --to-port $SETUP_PORT &>/dev/null || true
    iptables -t nat -D PREROUTING -i wlan0 -p tcp --dport 443 \
        -j REDIRECT --to-port $SETUP_PORT &>/dev/null || true
    iptables -D INPUT   -i wlan0 -p tcp --dport $SETUP_PORT -j ACCEPT &>/dev/null || true
    iptables -D FORWARD -i wlan0 -j ACCEPT &>/dev/null || true
    iptables -D FORWARD -o wlan0 -j ACCEPT &>/dev/null || true
    rm -f /etc/NetworkManager/dnsmasq-shared.d/razz-captive.conf
    nmcli connection down "$AP_SSID" &>/dev/null || true
    nmcli connection delete "$AP_SSID" &>/dev/null || true
    systemctl reload NetworkManager &>/dev/null || true
}

# ════════════════════════════════════════════════════════════════════
# FLOW A: razz-wifi.txt on boot partition
# ════════════════════════════════════════════════════════════════════
if [[ -f "$WIFI_FILE" ]]; then
    log "Found $WIFI_FILE — applying WiFi config"

    SSID=$(grep -m1 '^SSID='          "$WIFI_FILE" | cut -d= -f2- | tr -d '\r\n')
    PASS=$(grep -m1 '^PASSWORD='      "$WIFI_FILE" | cut -d= -f2- | tr -d '\r\n')
    TS=$(  grep -m1 '^TAILSCALE_KEY=' "$WIFI_FILE" | cut -d= -f2- | tr -d '\r\n' || true)

    if [[ -n "$SSID" ]]; then
        nm_add_wifi "$SSID" "$PASS"
        nmcli connection up "$SSID" &>/dev/null || true
        if wait_wifi; then
            log "Connected: $SSID"
        else
            log "Warning: could not connect to $SSID — check credentials in razz-wifi.txt"
        fi
        try_tailscale "$TS"
    else
        log "Warning: SSID line not found in razz-wifi.txt"
    fi

    rm -f "$WIFI_FILE"
    mark_done
    log "=== Provisioning done (boot-file method) ==="
    exit 0
fi

# ════════════════════════════════════════════════════════════════════
# SMART CHECK: if WiFi is already connected (e.g. eth0 or a known
# network is already saved), skip AP mode and just mark done.
# ════════════════════════════════════════════════════════════════════
if wifi_connected; then
    log "WiFi already connected — skipping AP provisioning"
    mark_done
    exit 0
fi

# ════════════════════════════════════════════════════════════════════
# FLOW B: Bridge-Setup AP — interactive provisioning
# ════════════════════════════════════════════════════════════════════
start_ap

log "Starting setup web UI (port $SETUP_PORT)…"
python3 /usr/local/bin/razz-setup-ui.py &
SETUP_PID=$!

# Wait until the setup UI creates the flag file
log "Waiting for user to complete WiFi setup via Bridge-Setup AP…"
while true; do
    if [[ -f "$FLAG" ]]; then
        STORED=$(cat "$FLAG" 2>/dev/null || true)
        [[ "$STORED" == "$SERIAL" ]] && break
    fi
    # Restart setup UI if it crashed
    if ! kill -0 $SETUP_PID 2>/dev/null; then
        log "Setup UI stopped — restarting…"
        python3 /usr/local/bin/razz-setup-ui.py &
        SETUP_PID=$!
    fi
    sleep 3
done

log "Provisioning done — tearing down Bridge-Setup AP"

kill $SETUP_PID 2>/dev/null || true
stop_ap

# Wait for WiFi client mode to reconnect
sleep 6

if wifi_connected; then
    log "WiFi connected after provisioning"
else
    log "Warning: no WiFi connection — user may need to check credentials"
fi

# Setup UI may have saved Tailscale key
TS_KEY_VAL=$(cat "$TS_KEY_TMP" 2>/dev/null || true)
rm -f "$TS_KEY_TMP"
try_tailscale "$TS_KEY_VAL"

log "=== First-boot provisioning complete ==="

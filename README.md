# Razz Bridge

Personal KVM-over-IP built on [TinyPilot](https://github.com/tiny-pilot/tinypilot) community edition, running on a Raspberry Pi 4.

---

## Install

Flash **Raspberry Pi OS 64-bit** with Raspberry Pi Imager. In the imager settings enable SSH and set your username/password. Boot the Pi, SSH in, then run:

```bash
curl -fsSL https://raw.githubusercontent.com/razzrohith/razz-bridge/main/install.sh | sudo bash
```

First run installs TinyPilot + all Razz Bridge additions (~10 min). Safe to re-run — all steps are idempotent.

**Options:**

```bash
# Custom hostname (default: razz → https://razz.local/)
RAZZ_HOST=mybox curl -fsSL https://raw.githubusercontent.com/razzrohith/razz-bridge/main/install.sh | sudo bash

# With Tailscale pre-auth key
TAILSCALE_AUTHKEY=tskey-auth-xxx curl -fsSL https://raw.githubusercontent.com/razzrohith/razz-bridge/main/install.sh | sudo bash
```

---

## First-boot WiFi setup

If the Pi has no saved WiFi on first boot, it starts a setup access point:

- **SSID:** `Bridge-Setup`  **Password:** `bridge1234`
- Connect your phone or laptop to `Bridge-Setup`
- Open any browser — the setup page appears automatically
- Enter your home WiFi credentials + optional Tailscale auth key
- Pi connects, AP disappears

**Pre-seed option** — copy `/boot/razz-wifi.txt.example` to `/boot/razz-wifi.txt`, fill in credentials, place on the boot partition before first boot. Pi reads it automatically and skips AP mode.

---

## Access

| What | URL |
|---|---|
| KVM interface | `https://razz.local/` |
| Admin panel | `https://razz.local/stealth/` |
| Alt hostname | `https://razz-alt.local/` |

Accept the self-signed cert warning on first visit (Advanced → Proceed).

**Windows:** install Bonjour (via iTunes or [standalone](https://support.apple.com/kb/DL999)) if `.local` names don't resolve.

---

## Features

**KVM page**
- Full TinyPilot remote control (keyboard, mouse, video)
- 📶 WiFi button (bottom-left) — view connection, scan, add/switch/remove networks
- Paste speed control (bottom-right) — instant / fast / natural / careful

**Admin panel** (`/stealth/`, password: `lol`)
- USB identity spoofing — impersonate any keyboard (Logitech K120 default)
- MAC address spoofing with boot persistence
- Tailscale remote-access tunnel + Funnel (public HTTPS URL)
- DuckDNS dynamic DNS
- Live CPU temp, uptime, IP, KVM access log
- Log viewer, config backup/restore, safe mode

**Security**
- Default-deny iptables firewall (80, 443, SSH, Tailscale, mDNS only)
- bcrypt auth with progressive login delay, CSRF protection
- 30-minute session timeout
- SSH fingerprint hidden, port moved to 2222

---

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/razzrohith/razz-bridge/main/uninstall.sh | sudo bash
```

Removes all Razz Bridge additions and returns to stock TinyPilot state.

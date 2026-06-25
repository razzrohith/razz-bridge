# Razz Bridge

## Install

Flash **Raspberry Pi OS 64-bit** with Raspberry Pi Imager (set your username/password in OS settings), boot the Pi, SSH in, then run:

```bash
curl -fsSL https://raw.githubusercontent.com/razzrohith/razz-bridge/main/install.sh | sudo bash
```

Custom hostname (default is `razz` → `razz.local`):

```bash
RAZZ_HOST=myname curl -fsSL https://raw.githubusercontent.com/razzrohith/razz-bridge/main/install.sh | sudo bash
```

First install takes ~10 min. Re-running is safe — all steps are idempotent.

## Access

- Main interface: `https://razz.local/`
- Admin panel: `https://razz.local/stealth/`

Accept the self-signed cert warning on first visit (Advanced → Proceed).

**Windows:** install Bonjour (via iTunes or [standalone](https://support.apple.com/kb/DL999)) if `.local` names don't resolve.

## Troubleshooting

**Admin panel shows "Reconnecting"**
```bash
ssh raj@razz.local "sudo systemctl status stealth-dashboard"
```

**Re-run installer** (safe to repeat):
```bash
curl -fsSL https://raw.githubusercontent.com/razzrohith/razz-bridge/main/install.sh | sudo bash
```

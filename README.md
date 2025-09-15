# Raspberry Pi – Tailscale Exit Node + Time Machine (SMB) Setup

Turn a fresh Raspberry Pi OS (Bookworm, 64‑bit) into a **Tailscale exit node** and a **macOS Time Machine target over SMB** in one go.

**What the setup script does:**
- Installs **Tailscale** (with SSH) and optionally advertises the **Exit Node**
- Detects the largest USB disk, creates a partition if missing, formats **ext4**, mounts at **/srv/tm**
- Configures **Samba** for Time Machine (APFS-over-SMB via `vfs_fruit`) with a **capacity limit** (default: 99 %)
- Enables **unattended-upgrades** and the **hardware watchdog** for stability
- (Optional) Binds Samba to `tailscale0` only, reducing LAN exposure

> ⚠️ The target partition will be **formatted**. All data on it will be lost.

## Requirements

- Raspberry Pi with Raspberry Pi OS Bookworm (64‑bit)
- Internet access for package installation
- External USB SSD/HDD (will be formatted)
- Optional: Tailscale Auth Key (for non‑interactive login)

## Quick start

```bash
git clone https://github.com/<your-org>/raspi-tm-exitnode.git
cd raspi-tm-exitnode
cp .env.example .env
# Fill .env with your values (TS_AUTHKEY, TM_SMB_PASS, …)
export $(grep -v '^#' .env | xargs) && sudo -E bash ./setup_tm_exitnode.sh
```

Without a `.env`, the script runs **interactively** and asks for missing values (e.g., SMB password).

## Configuration via environment variables

| Variable                   | Default                | Purpose |
|---------------------------|------------------------|---------|
| `TS_AUTHKEY`              | (empty)                | Tailscale auth key; if unset, `tailscale up` will open an interactive login |
| `TS_HOSTNAME`             | `pi-tm-$(hostname)`    | Hostname shown in Tailscale |
| `ADVERTISE_EXIT_NODE`     | `yes`                  | Advertise Exit Node (`yes`/`no`) |
| `TM_SHARE_NAME`           | `TimeMachine`          | SMB share name |
| `TM_USER`                 | `timemachine`          | SMB user |
| `TM_SMB_PASS`             | (empty)                | SMB password; if empty, you’ll be prompted |
| `DESIRED_PCT`             | `99`                   | Time Machine capacity limit in percent of the partition |
| `TIMEZONE`                | `Europe/Zurich`        | System timezone |
| `SMB_BIND_TAILSCALE_ONLY` | `yes`                  | Bind Samba to `lo` + `tailscale0` only (`yes`/`no`) |
| `AUTO_PARTITION`          | `yes`                  | If no partition exists, auto‑create GPT + one primary partition |
| `AUTO_FORMAT`             | `yes`                  | Format the largest USB partition as **ext4** without asking |

## What gets configured

- **/srv/tm** (ext4) mounted by **UUID** in `/etc/fstab`
- `smb.conf` with `vfs_fruit`, `fruit:time machine = yes`, and a fixed `fruit:time machine max size = …`
- The ext4 system folder **lost+found** is **hidden** inside the share (`hide files = /lost+found/`)
- **Unattended upgrades** and **watchdog** enabled
- **Tailscale** started with `--ssh` and optional `--advertise-exit-node`

## Using it from macOS

1. Finder → **Go → Connect to Server…** → `smb://<Pi-IP>/TimeMachine`  
2. Log in with the credentials configured in `.env`  
3. System Settings → **Time Machine** → **Add Backup Disk** → choose **TimeMachine**

## Exit Node

- The script runs `tailscale up --ssh` and, by default, `--advertise-exit-node`.
- Allow the Exit Node in the Tailscale admin console (depending on your tailnet settings).
- On client devices, enable **Use exit node** (optionally allow LAN access).

## Customization

- **Change the TM limit:** edit `/etc/samba/smb.conf` `fruit:time machine max size = …` → `sudo systemctl restart smbd`
- **Allow LAN access to SMB:** set `SMB_BIND_TAILSCALE_ONLY=no` in `.env` (otherwise it’s bound to `tailscale0` only)

## Troubleshooting

Common issues and commands are documented in **[docs/troubleshooting.md](docs/troubleshooting.md)**.
Security hardening tips live in **[docs/hardening.md](docs/hardening.md)**.

## License

MIT — see **LICENSE**.

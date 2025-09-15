# Hardening

Practical steps to further lock down the Raspberry Pi.

## Bind Samba to Tailscale only (default)

By default the setup binds Samba to `lo` and `tailscale0`.  
If you want to expose SMB on the local LAN as well, set in `.env`:

```
SMB_BIND_TAILSCALE_ONLY=no
```

**Note:** This makes SMB visible on the LAN. Consider a host firewall and strong passwords.

## Firewall (optional)

You can use `ufw` on Raspberry Pi OS:

```bash
sudo apt-get install -y ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
# For LAN exposure, explicitly allow SMB ports if required:
# sudo ufw allow 445/tcp
# sudo ufw allow 139/tcp
# sudo ufw allow 137/udp
# sudo ufw allow 138/udp
sudo ufw enable
sudo ufw status
```

Because Tailscale peers are authenticated and encrypted, it’s usually better to rely on **Tailscale ACLs** rather than opening SMB to the wider LAN or internet.

## Tailscale ACLs

Use the Tailscale admin console to restrict who can reach this host (by tag or hostname) and which ports/services they can use.

## Updates & reboots

`unattended-upgrades` is enabled. Best practice:
- Regularly check `sudo apt-get update && sudo apt-get upgrade -y`
- Reboot after kernel updates

## Watchdog

The hardware watchdog makes the Pi reboot if it hangs. Config lives in `/etc/watchdog.conf`.

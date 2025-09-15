# Troubleshooting

## Mount / fstab

```bash
cat /etc/fstab
lsblk -f
sudo dmesg | tail -n 50
```

- Ensure the UUID in `/etc/fstab` matches `/dev/sdXn`.
- `mount -a` should complete without errors.
- For a dirty filesystem: `sudo fsck -f /dev/sdXn` (must be unmounted).

## Samba

```bash
testparm -s
sudo systemctl status smbd --no-pager
journalctl -u smbd -e
```

- Is the share visible? `smbclient -L //127.0.0.1 -U timemachine`
- Permissions on the mount point: `ls -ld /srv/tm`

## Time Machine reports “disk full”

- Temporarily increase the limit in `smb.conf` (`fruit:time machine max size = …`), then `sudo systemctl restart smbd`.
- Compact the sparsebundle from the Mac to reclaim server space:
  ```bash
  hdiutil compact "/Volumes/<Share>/<Computer>.sparsebundle"
  ```

## Tailscale

```bash
tailscale status
tailscale ip -4
sudo systemctl status tailscaled --no-pager
```

- Non‑interactive login with auth key:
  ```bash
  sudo tailscale up --authkey=tskey-... --ssh --advertise-exit-node
  ```
- In the admin console, allow the Exit Node; on clients, enable “Use exit node”.

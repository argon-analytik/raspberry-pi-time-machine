#!/usr/bin/env bash
set -euo pipefail

# ===== Konfigurierbare Defaults via ENV =====
TS_AUTHKEY="${TS_AUTHKEY:-}"                # optional: Tailscale Auth-Key für non-interaktives Login
TS_HOSTNAME="${TS_HOSTNAME:-pi-tm-$(hostname)}"
ADVERTISE_EXIT_NODE="${ADVERTISE_EXIT_NODE:-yes}"   # yes|no
TM_SHARE_NAME="${TM_SHARE_NAME:-TimeMachine}"
TM_USER="${TM_USER:-timemachine}"
TM_SMB_PASS="${TM_SMB_PASS:-}"              # optional: SMB-Passwort (leer = interaktiv fragen)
DESIRED_PCT="${DESIRED_PCT:-99}"            # TimeMachine-Limit in % der Partition (z.B. 99)
TIMEZONE="${TIMEZONE:-Europe/Zurich}"
SMB_BIND_TAILSCALE_ONLY="${SMB_BIND_TAILSCALE_ONLY:-yes}"  # Samba nur an tailscale0 binden
AUTO_PARTITION="${AUTO_PARTITION:-yes}"     # yes: fehlende Partition automatisch anlegen
AUTO_FORMAT="${AUTO_FORMAT:-yes}"           # yes: grösste USB-Partition ohne Rückfrage ext4 formatieren

# ===== Root-Rechte sicherstellen =====
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  exec sudo -E bash "$0" "$@"
fi

echo "==> Update & Pakete installieren"
apt-get update
apt-get install -y curl gnupg ca-certificates parted e2fsprogs   samba samba-vfs-modules unattended-upgrades watchdog

if ! command -v tailscale >/dev/null 2>&1; then
  echo "==> Tailscale-Repo hinzufügen"
  curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.gpg     | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
  curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list     | tee /etc/apt/sources.list.d/tailscale.list >/dev/null
  apt-get update
  apt-get install -y tailscale
fi
systemctl enable --now tailscaled

echo "==> Zeitzone setzen: $TIMEZONE"
timedatectl set-timezone "$TIMEZONE" || true

echo "==> IP-Forwarding (für Exit-Node) aktivieren"
cat >/etc/sysctl.d/99-exitnode.conf <<EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sysctl --system >/dev/null 2>&1 || true

echo "==> Unattended-Upgrades aktivieren"
mkdir -p /etc/apt/apt.conf.d
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
dpkg-reconfigure -f noninteractive unattended-upgrades || true

echo "==> Watchdog aktivieren"
modprobe bcm2835_wdt 2>/dev/null || true
sed -i -E 's@^#?\s*watchdog-device.*@watchdog-device = /dev/watchdog@' /etc/watchdog.conf || true
systemctl enable --now watchdog || true

echo "==> USB-Datenträger ermitteln"
DEV_LINE="$(lsblk -bdnpo NAME,TRAN,TYPE,SIZE | awk '$2=="usb"&&$3=="disk"{print $0}' | sort -k4 -nr | head -1 || true)"
[ -n "$DEV_LINE" ] || { echo "Kein USB-Datenträger gefunden."; exit 1; }
DEV="$(awk '{print $1}' <<<"$DEV_LINE")"
echo "    Gerät: $DEV"

PARTS="$(lsblk -lnpo NAME,TYPE,SIZE "$DEV" | awk '$2=="part"{print $1" "$3}')"
if [ -z "$PARTS" ]; then
  if [ "$AUTO_PARTITION" = "yes" ]; then
    echo "==> Keine Partition gefunden – erstelle GPT + eine primäre Partition"
    umount -f "$DEV"* 2>/dev/null || true
    wipefs -a "$DEV" || true
    parted -s "$DEV" mklabel gpt
    parted -s "$DEV" mkpart primary ext4 1MiB 100%
    partprobe "$DEV" || true
    sleep 2
  else
    echo "Fehlende Partition und AUTO_PARTITION!=yes – Abbruch."; exit 1
  fi
fi

PART="$(lsblk -lbnp -o NAME,TYPE,SIZE "$DEV" | awk '$2=="part"{print $1" "$3}' | sort -k2 -n | tail -1 | awk '{print $1}')"
[ -n "$PART" ] || { echo "Partition konnte nicht bestimmt werden."; exit 1; }
ROOTSRC="$(findmnt -rn -o SOURCE /)"
[ "$PART" != "$ROOTSRC" ] || { echo "Sicherheitscheck: $PART ist Root – Abbruch."; exit 1; }
echo "    Ziel-Partition: $PART"

echo "==> Partition formatieren (ext4)"
if [ "$AUTO_FORMAT" = "yes" ]; then
  umount -f "$PART" 2>/dev/null || true
  wipefs -a "$PART" || true
  mkfs.ext4 -L TM "$PART"
  tune2fs -m 0 "$PART"
else
  read -r -p "Formatiere $PART als ext4 (ALLE Daten gehen verloren). Tippe YES: " C; [ "${C:-}" = "YES" ] || { echo "Abgebrochen."; exit 1; }
  umount -f "$PART" 2>/dev/null || true
  wipefs -a "$PART" || true
  mkfs.ext4 -L TM "$PART"
  tune2fs -m 0 "$PART"
fi

echo "==> Mounten nach /srv/tm und fstab setzen"
UUID="$(blkid -s UUID -o value "$PART")"
mkdir -p /srv/tm
cp /etc/fstab /etc/fstab.bak.$(date +%F-%H%M%S)
sed -i -E '/[[:space:]]\/srv\/tm[[:space:]]/d' /etc/fstab
printf 'UUID=%s  /srv/tm  ext4  defaults,noatime,acl,user_xattr  0 2\n' "$UUID" >> /etc/fstab
systemctl daemon-reload
mount -a
df -hT /srv/tm

echo "==> SMB-Benutzer «$TM_USER» anlegen (falls fehlt)"
id "$TM_USER" &>/dev/null || adduser --disabled-password --gecos "" "$TM_USER"
if ! pdbedit -L 2>/dev/null | grep -q "^$TM_USER:"; then
  if [ -n "$TM_SMB_PASS" ]; then
    (echo "$TM_SMB_PASS"; echo "$TM_SMB_PASS") | smbpasswd -s -a "$TM_USER"
  else
    smbpasswd -a "$TM_USER"
  fi
fi
chown -R "$TM_USER:$TM_USER" /srv/tm
chmod 0775 /srv/tm

echo "==> TimeMachine-Limit berechnen"
CAP_G="$(df -BG --output=size /srv/tm | tail -1 | tr -dc 0-9)"
LIMIT_G=$(( CAP_G * DESIRED_PCT / 100 ))
[ "$LIMIT_G" -ge "$CAP_G" ] && LIMIT_G=$(( CAP_G - 1 ))
echo "    Limit: ${LIMIT_G}G von ${CAP_G}G (≈${DESIRED_PCT}%)"

echo "==> Samba global hardenen (optional Bind an tailscale0)"
cp /etc/samba/smb.conf /etc/samba/smb.conf.bak.$(date +%F-%H%M%S)
if [ "$SMB_BIND_TAILSCALE_ONLY" = "yes" ]; then
  awk '
    BEGIN{in_global=0}
    /^\[global\]/{in_global=1; print; next}
    /^\[/{in_global=0; print; next}
    {
      if(in_global){
        if($0 ~ /interfaces =/){next}
        if($0 ~ /bind interfaces only =/){next}
      }
      print
    }
  ' /etc/samba/smb.conf > /etc/samba/smb.conf.new
  mv /etc/samba/smb.conf.new /etc/samba/smb.conf
  sed -i '/^\[global\]/a interfaces = lo tailscale0\nbind interfaces only = yes' /etc/samba/smb.conf
fi

echo "==> Samba-Share «$TM_SHARE_NAME» schreiben"
awk 'BEGIN{skip=0} /^\['"$TM_SHARE_NAME"'\]/{skip=1} skip&&/^\[/{skip=0} !skip{print}' /etc/samba/smb.conf >/etc/samba/smb.conf.new
mv /etc/samba/smb.conf.new /etc/samba/smb.conf
cat >>/etc/samba/smb.conf <<EOC

[$TM_SHARE_NAME]
  path = /srv/tm
  read only = no
  browseable = yes
  valid users = $TM_USER
  force user  = $TM_USER
  ea support = yes
  vfs objects = catia fruit streams_xattr
  fruit:metadata = stream
  fruit:resource  = stream
  fruit:time machine = yes
  fruit:time machine max size = ${LIMIT_G}G
  hide files = /lost+found/
EOC

testparm -s >/dev/null
systemctl enable --now smbd

echo "==> Tailscale hochfahren"
TS_FLAGS="--ssh --hostname=${TS_HOSTNAME}"
[ "$ADVERTISE_EXIT_NODE" = "yes" ] && TS_FLAGS="$TS_FLAGS --advertise-exit-node"
if [ -n "$TS_AUTHKEY" ]; then
  tailscale up --authkey="$TS_AUTHKEY" $TS_FLAGS || true
else
  tailscale up $TS_FLAGS || true
fi

IP_LOCAL="$(hostname -I | awk '{print $1}')"
TS_IP="$(ip -o -4 addr show tailscale0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
echo
echo "===== FERTIG ====="
echo "SMB-Share:  smb://$IP_LOCAL/$TM_SHARE_NAME  ${TS_IP:+oder smb://$TS_IP/$TM_SHARE_NAME}"
echo "Benutzer:   $TM_USER   (Passwort wie gesetzt)"
echo "Limit:      ${LIMIT_G}G  (anpassbar in /etc/samba/smb.conf)"
echo "Mount:      /srv/tm  (fstab, UUID=$UUID)"
echo "Tailscale:  ${TS_IP:-—}  Hostname: $TS_HOSTNAME  Exit-Node: $ADVERTISE_EXIT_NODE"
echo "Jetzt am Mac: Finder → «Mit Server verbinden…» → smb://<IP>/$TM_SHARE_NAME → in Time Machine als Ziel wählen."

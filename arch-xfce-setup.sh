#!/usr/bin/env bash
set -euo pipefail

TARGET_DISK="${TARGET_DISK:-/dev/vda}"
USERNAME="${USERNAME:-chris}"
SYSTEM_HOSTNAME="${SYSTEM_HOSTNAME:-arch-xfce}"
TIMEZONE="${TIMEZONE:-Europe/London}"
LOCALE="${LOCALE:-en_GB.UTF-8}"
KEYMAP="${KEYMAP:-uk}"
VG_NAME="${VG_NAME:-archxfce}"
SLOT_GB="${SLOT_GB:-32}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "Error: $*" >&2; exit 1; }
partition_path() {
  if [[ "$1" =~ [0-9]$ ]]; then printf '%sp%s' "$1" "$2";
  else printf '%s%s' "$1" "$2"; fi
}

[[ ${EUID} -eq 0 ]] || die "Run as root from the Arch live ISO"
[[ -d /sys/firmware/efi/efivars ]] || die "Boot the live ISO in UEFI mode"
[[ "${USERNAME}" =~ ^[a-z_][a-z0-9_-]*$ && "${USERNAME}" != root ]] || die "Invalid USERNAME"
[[ "${SYSTEM_HOSTNAME}" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ ]] || die "Invalid SYSTEM_HOSTNAME"
[[ "${VG_NAME}" =~ ^[a-zA-Z][a-zA-Z0-9_]*$ ]] || die "Invalid VG_NAME"
[[ "${SLOT_GB}" =~ ^[1-9][0-9]*$ ]] || die "Invalid SLOT_GB"
[[ -f "/usr/share/zoneinfo/${TIMEZONE}" && "${TIMEZONE}" != *..* ]] || die "Invalid TIMEZONE"
[[ "${LOCALE}" =~ ^[a-z][a-z]_[A-Z][A-Z]\.UTF-8$ ]] || die "Invalid LOCALE"
grep -Fq "${LOCALE} UTF-8" /etc/locale.gen || die "Locale not available"
[[ "${KEYMAP}" =~ ^[a-zA-Z0-9_-]+$ ]] || die "Invalid KEYMAP"
[[ -x "${SCRIPT_DIR}/arch-xfce-slot-update" ]] || die "Slot updater missing or not executable"
for command in cryptsetup sfdisk partprobe udevadm pvcreate vgcreate lvcreate \
  vgs blockdev loadkeys timedatectl mkfs.fat mkfs.ext4 pacstrap genfstab \
  arch-chroot rsync lsblk findmnt mount mountpoint umount blkid install; do
  command -v "${command}" >/dev/null || die "Missing live ISO command: ${command}"
done
[[ -b "${TARGET_DISK}" ]] || die "Not a block device: ${TARGET_DISK}"
[[ "$(lsblk -dnro TYPE "${TARGET_DISK}")" == disk ]] || die "Target must be a whole disk"
MOUNTPOINTS="$(lsblk -nrpo MOUNTPOINTS "${TARGET_DISK}")"
if grep -q '[^[:space:]]' <<< "${MOUNTPOINTS}"; then
  die "Target disk has mounted filesystems"
fi
DEVICE_TYPES="$(lsblk -nrpo TYPE "${TARGET_DISK}")"
if grep -Evq '^(disk|part)$' <<< "${DEVICE_TYPES}"; then
  die "Target disk has active mappings; close them before installing"
fi
if findmnt -rnR /mnt >/dev/null; then die "/mnt is already mounted"; fi
[[ ! -e /dev/mapper/archxfce_crypt ]] || die "archxfce_crypt mapping already exists"
VOLUME_GROUPS="$(vgs --noheadings -o vg_name)"
if grep -Eq "^[[:space:]]*${VG_NAME}[[:space:]]*$" <<< "${VOLUME_GROUPS}"; then
  die "Volume group ${VG_NAME} already exists"
fi
DISK_BYTES="$(blockdev --getsize64 "${TARGET_DISK}")"
(( DISK_BYTES >= (2 * SLOT_GB + 14) * 1024 * 1024 * 1024 )) ||
  die "Disk too small: allow 2 GiB EFI, two ${SLOT_GB} GiB roots, and at least 12 GiB home"
loadkeys "${KEYMAP}"
timedatectl set-ntp true
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS "${TARGET_DISK}"
echo "ALL DATA on ${TARGET_DISK} will be erased. Encryption passphrase is requested by cryptsetup."
read -r -p "Type the full disk path to confirm: " confirmation
[[ "${confirmation}" == "${TARGET_DISK}" ]] || die "Installation cancelled"

sfdisk --wipe always "${TARGET_DISK}" <<EOF
label: gpt
size=2GiB type=U name="EFI"
type=L name="Encrypted_System"
EOF
partprobe "${TARGET_DISK}"
udevadm settle
ESP="$(partition_path "${TARGET_DISK}" 1)"
CRYPT_PART="$(partition_path "${TARGET_DISK}" 2)"
cryptsetup luksFormat --type luks2 "${CRYPT_PART}"
cryptsetup open "${CRYPT_PART}" archxfce_crypt
pvcreate /dev/mapper/archxfce_crypt
vgcreate "${VG_NAME}" /dev/mapper/archxfce_crypt
lvcreate -L "${SLOT_GB}G" -n root_a "${VG_NAME}"
lvcreate -L "${SLOT_GB}G" -n root_b "${VG_NAME}"
lvcreate -l 100%FREE -n home "${VG_NAME}"
udevadm settle
ROOT_A="/dev/${VG_NAME}/root_a"
ROOT_B="/dev/${VG_NAME}/root_b"
HOME_LV="/dev/${VG_NAME}/home"
mkfs.fat -F32 -n EFI "${ESP}"
mkfs.ext4 -L Slot_A "${ROOT_A}"
mkfs.ext4 -L Slot_B "${ROOT_B}"
mkfs.ext4 -L Shared_Home "${HOME_LV}"
mount "${ROOT_A}" /mnt
mkdir -p /mnt/efi /mnt/home
mount "${ESP}" /mnt/efi
mount "${HOME_LV}" /mnt/home

CACHE_BOUND=false
cleanup_cache() {
  if "${CACHE_BOUND}"; then
    umount /mnt/var/cache/pacman/pkg
  fi
}
trap cleanup_cache EXIT
if mountpoint -q /work; then
  mkdir -p /pacman-cache /mnt/var/cache/pacman/pkg
  if ! mountpoint -q /pacman-cache; then
    mount -t virtiofs pacman-cache /pacman-cache
  fi
  [[ "$(findmnt -nro FSTYPE -M /pacman-cache)" == virtiofs ]] ||
    die "/pacman-cache must be the host virtiofs cache share"
  mount --bind /pacman-cache /mnt/var/cache/pacman/pkg
  CACHE_BOUND=true
  echo "Using shared host pacman cache at /pacman-cache"
else
  echo "/work is not mounted; using target-local pacman cache (bare-metal install)"
fi

pacstrap -K /mnt base linux linux-firmware intel-ucode amd-ucode \
  lvm2 cryptsetup arch-install-scripts sudo rsync vim git networkmanager \
  xorg-server xfce4 xfce4-goodies lightdm lightdm-gtk-greeter \
  mesa intel-media-driver firefox sof-firmware \
  pipewire pipewire-alsa pipewire-pulse wireplumber fwupd \
  bluez bluez-utils cups avahi nss-mdns \
  qemu-guest-agent spice-vdagent
cleanup_cache
CACHE_BOUND=false
trap - EXIT
genfstab -U /mnt > /mnt/etc/fstab
CRYPT_UUID="$(blkid -s UUID -o value "${CRYPT_PART}")"
cat > /mnt/etc/arch-xfce.conf <<EOF
VG_NAME=${VG_NAME}
CRYPT_UUID=${CRYPT_UUID}
EOF
chmod 600 /mnt/etc/arch-xfce.conf
printf '%s\n' "${SYSTEM_HOSTNAME}" > /mnt/etc/hostname
printf 'LANG=%s\n' "${LOCALE}" > /mnt/etc/locale.conf
printf 'KEYMAP=%s\n' "${KEYMAP}" > /mnt/etc/vconsole.conf
sed -i "s/^#${LOCALE} UTF-8/${LOCALE} UTF-8/" /mnt/etc/locale.gen
arch-chroot /mnt locale-gen
arch-chroot /mnt ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
arch-chroot /mnt hwclock --systohc
arch-chroot /mnt useradd -m -G wheel -s /bin/bash "${USERNAME}"
install -Dm440 /dev/stdin /mnt/etc/sudoers.d/10-wheel <<'EOF'
%wheel ALL=(ALL:ALL) ALL
EOF
arch-chroot /mnt visudo -cf /etc/sudoers
echo "Set the login password for ${USERNAME}:"
arch-chroot /mnt passwd "${USERNAME}"
arch-chroot /mnt passwd -l root
arch-chroot /mnt systemctl enable NetworkManager lightdm bluetooth cups avahi-daemon qemu-guest-agent
mkdir -p /mnt/etc/X11/xorg.conf.d
cat > /mnt/etc/X11/xorg.conf.d/00-keyboard.conf <<EOF
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "$(if [[ "${KEYMAP}" == uk ]]; then echo gb; else echo "${KEYMAP}"; fi)"
EndSection
EOF
mkdir -p /mnt/etc/mkinitcpio.conf.d
# Omit autodetect so the image also contains drivers for a different laptop.
cat > /mnt/etc/mkinitcpio.conf.d/arch-xfce.conf <<'EOF'
HOOKS=(base systemd microcode modconf keyboard sd-vconsole block sd-encrypt lvm2 filesystems fsck)
EOF
arch-chroot /mnt mkinitcpio -P
arch-chroot /mnt bootctl --esp-path=/efi --no-variables install
mkdir -p /mnt/efi/loader
cat > /mnt/efi/loader/loader.conf <<'EOF'
default arch-xfce-a.conf
timeout 5
editor no
EOF
install -Dm755 "${SCRIPT_DIR}/arch-xfce-slot-update" /mnt/usr/local/sbin/arch-xfce-slot-update

# The updater publishes A's boot files, then creates a fully bootable initial B.
arch-chroot /mnt arch-xfce-slot-update --publish-current
arch-chroot /mnt arch-xfce-slot-update --clone-only
sync
echo "Installation complete. Root is locked; log in as ${USERNAME} using LightDM."
echo "Power off, eject the ISO, then boot and test BOTH slots. See README.md."
echo "Target remains mounted at /mnt for inspection. Never expose the LUKS passphrase or backup header."

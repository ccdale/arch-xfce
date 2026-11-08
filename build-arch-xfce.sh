#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM_NAME="${VM_NAME:-arch-xfce}"
ARCH_ISO="${ARCH_ISO:-${HOME}/Downloads/archlinux-x86_64.iso}"
DISK_DIR="${DISK_DIR:-${HOME}/.local/share/gnome-boxes/images}"
RAM_MB="${RAM_MB:-4096}"
VCPUS="${VCPUS:-2}"
DISK_GB="${DISK_GB:-128}"
URI="qemu:///session"
WORK="${SCRIPT_DIR}/work"
PACMAN_CACHE_DIR="${PACMAN_CACHE_DIR:-${SCRIPT_DIR}/../druidhtpc/work/pacman-cache}"

die() { echo "Error: $*" >&2; exit 1; }
[[ $# -eq 0 || ( $# -eq 1 && $1 == --recreate ) ]] ||
  die "Usage: $0 [--recreate]"
[[ "${VM_NAME}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || die "Invalid VM_NAME"
for value in "${RAM_MB}" "${VCPUS}" "${DISK_GB}"; do
  [[ "${value}" =~ ^[1-9][0-9]*$ ]] || die "Resource sizes must be positive integers"
done
(( DISK_GB >= 80 )) || die "DISK_GB must be at least 80 for the default slot layout"
for command in virsh virt-install virt-viewer qemu-img install; do
  command -v "${command}" >/dev/null || die "Missing host command: ${command}"
done
[[ -r "${ARCH_ISO}" ]] || die "Arch ISO not readable: ${ARCH_ISO}"
mkdir -p "${PACMAN_CACHE_DIR}"
PACMAN_CACHE_DIR="$(cd "${PACMAN_CACHE_DIR}" && pwd -P)"
[[ -r "${PACMAN_CACHE_DIR}" && -w "${PACMAN_CACHE_DIR}" && -x "${PACMAN_CACHE_DIR}" ]] ||
  die "Pacman cache must be readable and writable: ${PACMAN_CACHE_DIR}"
DISK="${DISK_DIR}/${VM_NAME}.qcow2"
DOMAINS="$(virsh --connect "${URI}" list --all --name)"
EXISTS=false
if grep -Fxq "${VM_NAME}" <<< "${DOMAINS}"; then
  EXISTS=true
fi
if "${EXISTS}" || [[ -e "${DISK}" ]]; then
  [[ "${1:-}" == --recreate ]] || die "VM/disk already exists; use --recreate to replace it"
  echo "This will destroy VM ${VM_NAME} and erase ${DISK}."
  read -r -p "Type ${VM_NAME} to confirm: " confirmation
  [[ "${confirmation}" == "${VM_NAME}" ]] || die "Rebuild cancelled"
  if "${EXISTS}"; then
    STATE="$(LC_ALL=C virsh --connect "${URI}" domstate "${VM_NAME}")"
    if [[ "${STATE}" != "shut off" ]]; then
      virsh --connect "${URI}" destroy "${VM_NAME}"
    fi
    virsh --connect "${URI}" undefine "${VM_NAME}" --nvram
  fi
  rm -f -- "${DISK}"
fi

mkdir -p "${DISK_DIR}" "${WORK}/arch-xfce"
for script in arch-xfce-setup.sh arch-xfce-slot-update; do
  install -m 0755 "${SCRIPT_DIR}/${script}" "${WORK}/arch-xfce/${script}"
done
qemu-img create -f qcow2 "${DISK}" "${DISK_GB}G"
if virsh --connect "${URI}" net-info default >/dev/null 2>&1; then
  NETWORK=(--network network=default)
else
  echo "No session default network; using user-mode NAT."
  NETWORK=(--network user)
fi
virt-install \
  --connect "${URI}" --name "${VM_NAME}" \
  --ram "${RAM_MB}" --vcpus "${VCPUS}" --cpu host-passthrough \
  --memorybacking access.mode=shared --boot uefi --os-variant archlinux \
  --disk "path=${DISK},format=qcow2,bus=virtio,cache=none,boot.order=2" \
  --disk "path=${ARCH_ISO},device=cdrom,bus=sata,boot.order=1" \
  --filesystem "source=${WORK},target=work,driver.type=virtiofs" \
  --filesystem "source=${PACMAN_CACHE_DIR},target=pacman-cache,driver.type=virtiofs" \
  "${NETWORK[@]}" --graphics spice,listen=127.0.0.1 \
  --video virtio --channel spicevmc --channel unix,target.type=virtio,target.name=org.qemu.guest_agent.0 \
  --noautoconsole
echo "VM started. Mount the work share and run the installer as described in README.md."
echo "After installation, power off and eject the ISO before starting the VM again."
virt-viewer --connect "${URI}" --wait "${VM_NAME}"

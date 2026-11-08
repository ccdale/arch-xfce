# Framework Laptop 13 Pro hardware notes

Target: Framework Laptop 13 Pro DIY Edition (Intel Core Ultra Series 3),
Core Ultra 5 325, 16 GB LPCAMM2 LPDDR5X, SANDISK SN7100 1 TB PCIe 4.0 NVMe,
British English keyboard, two USB-C cards, one second-generation USB-A card,
and an Ethernet expansion card.

## Linux support

Checked against Framework's documentation on 2026-11-08:

- [Official specifications](https://frame.work/laptop13pro?slug=laptop13pro-intel-ultra-3&tab=specs)
- [Official Linux compatibility](https://frame.work/laptop13pro?slug=laptop13pro-intel-ultra-3&tab=linux)
- [Framework's Fedora setup notes for this generation](https://github.com/FrameworkComputer/linux-docs/blob/main/framework13/FW-13-Pro-Fedora-all-Intel-Core-Ultra-Series-3.md)

Framework lists Linux 6.19 as the minimum, recommends 7.0 or newer, and recommends
the latest kernel for the best experience. The VM test used `7.2.14-arch1-1`,
which exceeds that stated requirement. Keep the installation ISO, Arch kernel,
Mesa, and firmware current: this is new hardware, and VM success does not prove
physical-device compatibility.

No unusual proprietary or out-of-tree driver requirement is indicated by these
sources. Arch is not guaranteed to behave identically to Framework's tested
distributions; verify the actual laptop before relying on it.

| Component | Expected Linux support and caveats |
| --- | --- |
| Ultra 5 325 Intel graphics, 4 Xe cores | Upstream kernel graphics support, Mesa and Intel firmware; no separate proprietary display driver expected. |
| Intel Wi-Fi 7 BE211 and Bluetooth | Current upstream Intel wireless support and firmware; NetworkManager and BlueZ are already installed. Test connectivity and resume on arrival. |
| LPCAMM2 LPDDR5X and SN7100 NVMe SSD | No special distribution packages expected; use the standard NVMe driver. |
| USB-C and USB-A expansion cards | Standard USB support. All four laptop slots support Thunderbolt 4, DisplayPort 2.1 and USB-PD according to Framework. |
| Ethernet expansion card | An upstream USB Ethernet driver is expected; confirm the actual chipset/device ID and driver when the card arrives. |
| Haptic touchpad and touchscreen | Framework advertises Linux compatibility; test clicking, gestures, touch, and resume on the actual device. XFCE/X11 scaling may need adjustment for the 2880 x 1920 display. |
| Speakers, headphone jack and microphones | Modern Intel audio may need SOF DSP firmware in addition to PipeWire. Test every output/input separately; VM audio uses different hardware. |
| Fingerprint reader | Framework explicitly lists libfprint compatibility. Optional fingerprint login requires separate setup; it does not automatically unlock LUKS. |
| NPU | Not required for the XFCE desktop; accelerator applications and their runtime requirements are outside this build's scope. |

Framework currently lists Dolby Atmos support on Windows 11 only. Ordinary
Linux stereo playback is separate and does not imply Dolby Atmos support.

## Included additional packages

The guest installer, [arch-xfce-setup.sh](../arch-xfce-setup.sh), now installs:

- [`sof-firmware`](https://archlinux.org/packages/extra/x86_64/sof-firmware/):
  Sound Open Firmware for modern Intel audio DSPs. PipeWire does not supply this.
- [`fwupd`](https://archlinux.org/packages/extra/x86_64/fwupd/):
  firmware-update tooling. Framework advertises LVFS integration; actual update
  availability depends on the device and released firmware.
- [`intel-media-driver`](https://archlinux.org/packages/extra/x86_64/intel-media-driver/):
  Intel VA-API video acceleration. Installing it does not by itself guarantee
  that Firefox uses hardware decoding; check this on the laptop.

Existing packages already include `linux-firmware`, `intel-ucode`, `mesa`,
NetworkManager, BlueZ, PipeWire and WirePlumber. Fingerprint login is optional:
`fprintd` is not installed or configured, and PAM configuration is unchanged.
Firmware is not automatically flashed by the installer.

These additions apply to new builds, not the already-installed VM. For an
existing system, install them with a full upgrade:

```bash
sudo pacman -Syu sof-firmware fwupd intel-media-driver
sudo arch-xfce-slot-update --publish-current
```

The second command republishes the active slot's boot files in case the upgrade
changed its kernel or initramfs. After verifying that slot, the normal
`sudo arch-xfce-slot-update` workflow can propagate the packages to the other
slot. Do not run package operations and slot cloning concurrently.

## Laptop validation checklist

- Check `uname -r`, `lspci -k` and `lsusb` for hardware and bound drivers.
- Test Wi-Fi, Bluetooth, Ethernet and connectivity after suspend/resume.
- Test speakers, left/right stereo, headphones, microphone recording and mute/
  privacy switches. VM playback does not validate these devices.
- Test the touchpad, touch display, keyboard backlight, brightness controls and
  usable XFCE scaling.
- Test USB cards, charging and any external display in the intended slots.
- Test suspend/resume repeatedly, battery reporting and idle power consumption.
- Check `systemctl --failed` and kernel logs for device/firmware errors.
- Run `fwupdmgr get-devices` and check available updates with
  `fwupdmgr refresh` and `fwupdmgr get-updates`. Follow Framework's update
  instructions, use AC power, and do not interrupt firmware installation.
- Boot both encrypted root slots and confirm shared-home persistence.

The broad initramfs omits `autodetect`, which can produce missing-firmware
warnings for drivers unrelated to this laptop. Determine whether a warned-about
driver matches actual hardware rather than assuming all warnings are harmless.

Secure Boot and hibernation remain unconfigured. Fingerprint enrollment, NPU
applications, and laptop-specific power-policy tuning are separate follow-ups.

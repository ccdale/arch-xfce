import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]

# Commands operate only on a temporary fixture, never on host disks or libvirt.
MOCK = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shutil
import sys

root = Path(os.environ["TEST_ROOT"])
command = Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / "commands.jsonl").open("a") as log:
    log.write(json.dumps([command, *args]) + "\n")
if command == "virsh":
    if "list" in args:
        if os.environ.get("VIRSH_FAIL"):
            sys.exit(1)
        print(os.environ.get("EXISTING_VM", ""))
    elif "net-info" in args:
        sys.exit(1)
    elif "domstate" in args:
        print("shut off")
elif command == "qemu-img":
    Path(args[-2]).touch()
elif command == "findmnt":
    if "-M" in args and "FSTYPE" in args:
        print("vfat")
    elif "SOURCE" in args:
        slot = os.environ.get("ACTIVE_SLOT", "a")
        print(root / f"dev/archxfce/root_{slot}")
    elif any(arg.startswith("-rnS") for arg in args):
        sys.exit(0 if os.environ.get("INACTIVE_MOUNTED") else 1)
elif command == "mount":
    (root / "mounted").touch()
elif command == "mountpoint":
    sys.exit(0 if (root / "mounted").exists() else 1)
elif command == "umount":
    mount = Path(args[-1])
    if (mount / "etc/fstab").exists():
        (root / "cloned-fstab").write_text((mount / "etc/fstab").read_text())
    contents = root / "unmounted-contents"
    contents.mkdir()
    for child in mount.iterdir():
        shutil.move(str(child), contents / child.name)
    (root / "mounted").unlink()
elif command == "blkid":
    print("uuid-b" if args[-1].endswith("root_b") else "uuid-a")
elif command == "rsync":
    if os.environ.get("RSYNC_FAIL"):
        sys.exit(23)
    destination = Path(args[-1])
    for name in ("etc", "boot"):
        shutil.copytree(root / name, destination / name, dirs_exist_ok=True)
elif command == "arch-chroot":
    if os.environ.get("UPDATE_FAIL") and "pacman" in args:
        sys.exit(42)
    if "pacman" in args:
        (Path(args[0]) / "boot/vmlinuz-linux").write_text("updated kernel")
'''


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        mock = self.bin / "mock"
        mock.write_text(MOCK)
        mock.chmod(0o755)
        for name in (
            "virsh", "virt-install", "virt-viewer", "qemu-img",
            "findmnt", "mount", "mountpoint", "umount", "blkid",
            "rsync", "arch-chroot",
        ):
            (self.bin / name).symlink_to(mock)
        self.env = {
            **os.environ,
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "TEST_ROOT": str(self.root),
            "VM_NAME": "arch-xfce",
            "DISK_DIR": str(self.root / "images"),
            "ARCH_ISO": str(self.root / "arch.iso"),
            "DISK_GB": "128",
            "RAM_MB": "4096",
            "VCPUS": "2",
        }
        (self.root / "arch.iso").touch()
        for name in ("etc", "boot", "efi/loader/entries", "mnt", "run",
                     "var/lib/pacman", "dev/archxfce"):
            (self.root / name).mkdir(parents=True, exist_ok=True)
        (self.root / "etc/arch-xfce.conf").write_text(
            "VG_NAME=archxfce\nCRYPT_UUID=01234567-abcd-1234-abcd-0123456789ab\n"
        )
        (self.root / "etc/fstab").write_text(
            "UUID=uuid-a / ext4 defaults 0 1\nUUID=home /home ext4 defaults 0 2\n"
        )
        (self.root / "boot/vmlinuz-linux").write_text("original kernel")
        (self.root / "boot/initramfs-linux.img").write_text("encrypted initramfs")
        for slot in ("a", "b"):
            (self.root / f"dev/archxfce/root_{slot}").touch()
            (self.root / f"efi/loader/entries/arch-xfce-{slot}.conf").write_text(
                f"original {slot}"
            )
        # Only the test copy bypasses privilege/block-device guards and redirects
        # absolute system paths. Production scripts remain unmodified.
        source = (PROJECT / "arch-xfce-slot-update").read_text()
        source = source.replace('[[ ${EUID} -eq 0 ]]', "true")
        source = source.replace('[[ -b "${INACTIVE}"', '[[ -f "${INACTIVE}"')
        source = re.sub(
            r"(?<![\w}])/(etc|efi|dev|mnt|run|var)(?=/)",
            lambda match: f"{self.root}/{match[1]}",
            source,
        )
        source = source.replace(" /efi ", f" {self.root}/efi ")
        source = source.replace(" /efi\n", f" {self.root}/efi\n")
        source = source.replace('publish ""', 'publish "${TEST_ROOT}"')
        self.updater = self.root / "updater"
        self.updater.write_text(source)
        self.host = self.root / "host"
        self.host.mkdir()
        for name in ("build-arch-xfce.sh", "arch-xfce-setup.sh", "arch-xfce-slot-update"):
            shutil.copyfile(PROJECT / name, self.host / name)

    def run_script(self, script, *args, input=""):
        return subprocess.run(
            ["bash", str(script), *args], env=self.env, input=input,
            text=True, capture_output=True, timeout=10,
        )

    def commands(self):
        import json
        log = self.root / "commands.jsonl"
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    def test_host_build_wires_single_disk_and_share(self):
        result = self.run_script(self.host / "build-arch-xfce.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        invocation = next(row for row in self.commands() if row[0] == "virt-install")
        self.assertIn("--boot", invocation)
        self.assertIn("uefi", invocation)
        self.assertIn("user", invocation)
        self.assertTrue(any("bus=virtio" in arg for arg in invocation))
        self.assertTrue(any("driver.type=virtiofs" in arg for arg in invocation))
        self.assertEqual(invocation.count("--disk"), 2)  # OS disk and ISO only
        self.assertTrue((self.host / "work/arch-xfce/arch-xfce-setup.sh").exists())

    def test_host_existing_disk_requires_confirmation(self):
        disk = self.root / "images/arch-xfce.qcow2"
        disk.parent.mkdir()
        disk.write_text("keep me")
        for args in ((), ("--recreate",)):
            result = self.run_script(self.host / "build-arch-xfce.sh", *args, input="wrong\n")
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(disk.read_text(), "keep me")
        self.assertFalse(any(row[0] == "qemu-img" for row in self.commands()))

    def test_host_recreate_only_after_explicit_confirmation(self):
        self.env["EXISTING_VM"] = "arch-xfce"
        result = self.run_script(
            self.host / "build-arch-xfce.sh", "--recreate", input="arch-xfce\n"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any("undefine" in row for row in self.commands()))

    def test_host_libvirt_failure_does_not_create_disk(self):
        self.env["VIRSH_FAIL"] = "1"
        result = self.run_script(self.host / "build-arch-xfce.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(row[0] == "qemu-img" for row in self.commands()))

    def test_host_missing_iso_fails_before_provisioning(self):
        self.env["ARCH_ISO"] = str(self.root / "missing.iso")
        result = self.run_script(self.host / "build-arch-xfce.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ISO not readable", result.stderr)
        self.assertEqual(self.commands(), [])

    def test_publish_current_has_encrypted_boot_options(self):
        result = self.run_script(self.updater, "--publish-current")
        self.assertEqual(result.returncode, 0, result.stderr)
        entry = (self.root / "efi/loader/entries/arch-xfce-a.conf").read_text()
        self.assertIn("rd.luks.name=01234567-abcd-1234-abcd-0123456789ab=archxfce_crypt", entry)
        self.assertIn("root=/dev/archxfce/root_a", entry.replace(str(self.root), ""))
        self.assertEqual((self.root / "efi/loader/entries/arch-xfce-b.conf").read_text(), "original b")
        self.assertFalse(any(row[0] == "rsync" for row in self.commands()))
        # Repeat publication must remove only the superseded generation.
        result = self.run_script(self.updater, "--publish-current")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(list((self.root / "efi/arch-xfce").glob("a-*"))), 1)

    def test_clone_seeds_other_slot_and_corrects_fstab(self):
        result = self.run_script(self.updater, "--clone-only")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(row[0] == "arch-chroot" for row in self.commands()))
        entry = (self.root / "efi/loader/entries/arch-xfce-b.conf").read_text()
        self.assertIn("root_b", entry)
        self.assertEqual((self.root / "efi/loader/entries/arch-xfce-a.conf").read_text(), "original a")
        self.assertFalse((self.root / "mounted").exists())
        self.assertEqual(list((self.root / "mnt").iterdir()), [])
        fstab = (self.root / "cloned-fstab").read_text()
        self.assertIn("UUID=uuid-b / ext4", fstab)
        self.assertIn("UUID=home /home ext4", fstab)

    def test_update_from_b_targets_only_a(self):
        self.env["ACTIVE_SLOT"] = "b"
        result = self.run_script(self.updater)
        self.assertEqual(result.returncode, 0, result.stderr)
        entry = (self.root / "efi/loader/entries/arch-xfce-a.conf").read_text()
        self.assertIn("root_a", entry)
        self.assertEqual((self.root / "efi/loader/entries/arch-xfce-b.conf").read_text(), "original b")
        self.assertTrue(any("pacman" in row and "-Syu" in row for row in self.commands()))
        kernel = next((self.root / "efi/arch-xfce").glob("a-*/vmlinuz-linux"))
        self.assertEqual(kernel.read_text(), "updated kernel")
        self.assertEqual((self.root / "boot/vmlinuz-linux").read_text(), "original kernel")
        self.assertIn("UUID=uuid-a / ext4", (self.root / "cloned-fstab").read_text())

    def test_upgrade_failure_hides_inactive_entry_and_preserves_active(self):
        self.env["UPDATE_FAIL"] = "1"
        result = self.run_script(self.updater)
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertFalse((self.root / "efi/loader/entries/arch-xfce-b.conf").exists())
        self.assertEqual((self.root / "efi/loader/entries/arch-xfce-a.conf").read_text(), "original a")
        self.assertFalse((self.root / "mounted").exists())

    def test_clone_failure_hides_inactive_entry(self):
        self.env["RSYNC_FAIL"] = "1"
        result = self.run_script(self.updater, "--clone-only")
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertFalse((self.root / "efi/loader/entries/arch-xfce-b.conf").exists())
        self.assertFalse((self.root / "mounted").exists())

    def test_mounted_inactive_slot_and_package_lock_are_refused(self):
        self.env["INACTIVE_MOUNTED"] = "1"
        result = self.run_script(self.updater)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Inactive root is mounted", result.stderr)
        self.env.pop("INACTIVE_MOUNTED")
        (self.root / "var/lib/pacman/db.lck").touch()
        result = self.run_script(self.updater)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("package operation", result.stderr)
        self.assertFalse(any(row[0] == "rsync" for row in self.commands()))

    def test_updater_rejects_unknown_arguments(self):
        result = self.run_script(self.updater, "--root=/")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Usage:", result.stderr)

    def test_partition_names_support_vm_and_laptop_disks(self):
        source = (PROJECT / "arch-xfce-setup.sh").read_text()
        helper = source.split("partition_path() {", 1)[1].split("\n}\n", 1)[0]
        for disk, expected in (
            ("/dev/vda", "/dev/vda2"),
            ("/dev/sda", "/dev/sda2"),
            ("/dev/nvme0n1", "/dev/nvme0n1p2"),
            ("/dev/mmcblk0", "/dev/mmcblk0p2"),
        ):
            result = subprocess.run(
                ["bash", "-c", f"partition_path() {{{helper}\n}}\npartition_path \"$1\" 2",
                 "test", disk],
                text=True, capture_output=True, check=True,
            )
            self.assertEqual(result.stdout, expected)


if __name__ == "__main__":
    unittest.main()

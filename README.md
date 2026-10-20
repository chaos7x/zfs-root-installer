# zfs-root-installer

Install **Debian** or **Devuan** on a native **ZFS root** (BIOS/UEFI, optional separate GRUB-compatible boot pool, Secure Boot via shim), with a **live ISO builder** and **rollback / chroot rescue scripts**.

🇩🇪 [Deutsche Version](README.de.md)

> ⚠️ **The installer wipes the selected disks completely.** Read the options and test in a VM first.

## Contents

| File | Purpose |
|---|---|
| `debian-zfs-root.sh` | Installer for Debian (Bookworm, Trixie, Forky), amd64 and arm64 |
| `devuan_debian-zfs-root.sh` | Installer for Devuan (sysvinit): Excalibur, Daedalus, Ceres |
| `build-zfs-live-iso.sh` | Builds a Debian live ISO with prebuilt ZFS module and the installer |
| `devuan_build-zfs-live-iso.sh` | Same for Devuan (debootstrap + `grub-mkrescue`, amd64 and arm64) |
| `zfs-rollback-system` | Roll all system datasets back to a common snapshot (run from the live system) |
| `zfs-chroot-system` | Import, mount and enter an installed ZFS system in a chroot (rescue) |
| `zfs-generator-setup` | Debian/systemd: convert legacy fstab ZFS mounts to native mountpoints |

Keep the scripts in one directory: the ISO builders pick up the installer and the two rescue scripts next to themselves and put them into `/usr/local/bin` of the image.

## Features

- Native ZFS root, pool layout `root/ROOT/<name>`, `root/var`, `root/var/log`, `root/var/tmp`, `root/tmp`
- Optional separate **boot pool** (`compatibility=grub2`, mirrored over all disks), root pool with all features, zstd, `dnodesize=auto`
- RAID levels: single/raid0, mirror, raidz, raidz2, raidz3
- BIOS and EFI, **Secure Boot** (shim-signed, signed GRUB, MOK for DKMS) on Debian Trixie
- Swap as partition, ZVOL or none, optional zram
- Interactive dialogs or fully unattended (`--disk … --yes`)
- Live ISO with ZFS module built via DKMS, rescue tools (`mc`, `smartmontools`, `cryptsetup`, `gddrescue`, `gdisk`, `mdadm`, `zstd`, …)

## Quick start

Build the live ISO (on a system of the same Debian/Devuan family and architecture, ~5 GB free space):

```
sudo ./build-zfs-live-iso.sh -d trixie              # Debian: bookworm | trixie | forky
sudo ./devuan_build-zfs-live-iso.sh -d excalibur    # Devuan: excalibur | daedalus | ceres
```

Boot the ISO and install:

```
debian-zfs-root                                     # interactive
debian-zfs-root --disk nvme0n1 --raid raid0 --swap 4G --zram yes \
                --bpool boot --hostname myhost --yes
```

`debian-zfs-root --help` lists all options.

## Rescue: rollback and chroot

Take snapshots with the same name on all system datasets before a risky change, e.g. a release upgrade:

```
for ds in root/ROOT/debian root/var root/var/tmp root/var/log boot/BOOT/debian; do
    zfs snapshot "$ds@before-upgrade"
done
```

Later, boot the live ISO:

```
zfs-rollback-system -n before-upgrade     # dry run: checks snapshots, shows what gets deleted
zfs-rollback-system before-upgrade        # roll back, then rebuild initramfs and GRUB
zfs-chroot-system                         # import, mount and enter the system for manual repairs
```

Notes:

- A running root dataset cannot be rolled back, so this runs from the live system (ZFS ≥ 2.3 recommended).
- `zfs rollback -r` **deletes all newer snapshots** of the affected datasets.
- Pool features are not undone. After a `zpool upgrade` an older ZFS may no longer import the pool.
- Data pools (e.g. `daten`) are never imported or touched by the rollback script.
- Defaults in the scripts (`vor-trixie`, `root/ROOT/debian`, …) can be changed via environment variables, see the script headers.
- The first boot after a rollback may need a one-time `zpool import -f root` in the initramfs (host ID of the live system).

## Test status

| Area | Status |
|---|---|
| Debian Bookworm / Trixie install, BIOS and EFI | tested (Proxmox VM, VMware Fusion arm64, real hardware) |
| Secure Boot (shim, signed GRUB, MOK) | works on **Trixie**; fails on Bookworm (cause not verified) |
| Debian Forky | untested (zfs-dkms 2.4 vs. kernel 7.x may be a problem) |
| Devuan Excalibur install + ISO | tested in a VM |
| Devuan Daedalus / Ceres | untested |
| `zfs-rollback-system` | tested in a VM and on real hardware (BIOS); EFI branch untested |
| `zfs-chroot-system` | lightly tested |

## Proxmox / Secure Boot hint

For Secure Boot in a Proxmox VM the EFI disk needs pre-enrolled keys (`pre-enrolled-keys=1`); `qm enroll-efi-keys` cannot add keys afterwards. DKMS modules are signed with a MOK that you import on first boot (`mokutil --import /var/lib/dkms/mok.pub`).

## License and credits

GPL v3, see [LICENSE](LICENSE).
The installer is derived from [hn/debian-buster-zfs-root](https://github.com/hn/debian-buster-zfs-root) by Hajo Noerenberg (GPL v3.0).

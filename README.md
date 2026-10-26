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
- Optional separate **boot pool** (`compatibility=grub2`, mirrored over all disks), root pool with all features, zstd or lz4 (`--compression`), `dnodesize=auto`
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

## Newer ZFS in the live ISO (backports)

The Bookworm ISO always takes ZFS (and GRUB 2.12) from `bookworm-backports`. For Trixie you can do the same with `ZFS_BACKPORTS=yes`, for example once Forky is released and its ZFS version is in `trixie-backports`:

```
sudo ZFS_BACKPORTS=yes ./build-zfs-live-iso.sh -d trixie
```

Note: pools created by the installer in such a live system enable the features of the live system's ZFS version. Enabled but unused features do not block an import by an older ZFS, but the installed system should run the same ZFS version or newer (otherwise it cannot use the pool's newer features once they become active).

## Ubuntu as live system (untested)

`debian-zfs-root` also accepts an Ubuntu live system (Desktop or Server live ISO) as the environment. The target is still a Debian system, so `--dist bookworm|trixie|forky` is mandatory. The installer pulls `debian-archive-keyring` for `debootstrap`. Pools get the features of the live system's ZFS; if the target's ZFS is older, limit them with `--compat openzfs-2.x`. Ubuntu's own server installer has no ZFS option (tested on arm64, 22.04 to 26.04), and there is no Ubuntu live ISO builder yet.


Both live ISOs have an extra boot menu entry "... im RAM (toram)". It copies the whole system image into RAM (live-boot `toram`), so the USB stick or CD can be removed afterwards. The RAM must be larger than the image (about the size of the ISO, plus working space). With another ISO, add `toram` to the kernel command line by hand.

## Secure Boot with the live ISO (Trixie / Forky)

The Debian live ISO contains `shim-signed` and `mokutil` (also for Bookworm, where the signed boot chain stays off). Built for Trixie or newer, live-build uses shim and Debian's signed GRUB, and the ISO adds MokManager so a key can be enrolled. The ZFS module is built by DKMS and signed with the DKMS key, which is not trusted yet. Enroll it once per machine:

```
mokutil --import /var/lib/dkms/mok.pub
```

Reboot, confirm "Enroll MOK" in the blue MOK manager (password from the import), then boot the ISO again. The key is generated per ISO build; the private key is removed from the image. A new ISO build means a new key to enroll. Devuan ISOs are unaffected (no Secure Boot).

## Network boot (iPXE)

Besides the ISO, both builders write a folder `netboot-<release>-<arch>/` (in the work directory, e.g. `netboot-bookworm-amd64/`) with `vmlinuz`, `initrd.img`, `filesystem.squashfs` and an example `boot.ipxe`. Everything is also packed into an uncompressed `netboot-<release>-<arch>.tar` (squashfs and kernel are already compressed). Put the folder on a web server and replace `SERVER` in `boot.ipxe`. live-boot downloads the squashfs into RAM (`fetch=`), so the machine needs more RAM than the squashfs. Booting the ISO itself with iPXE `sanboot` is unreliable for Linux live systems, because the kernel cannot see the drive iPXE provides.

## Test status

| Area | Status |
|---|---|
| Debian Bookworm / Trixie install, BIOS and EFI | tested (Proxmox VM, VMware Fusion arm64, real hardware) |
| Secure Boot (shim, signed GRUB, MOK) | works on **Trixie**; fails on Bookworm (cause not verified) |
| Debian Forky | upgrade of an installed Trixie system works (kernel 7.2 + zfs-dkms 2.4.4, in a VM); fresh install and live ISO on Forky untested |
| Devuan Excalibur install + ISO | tested in a VM |
| Devuan Daedalus install + ISO | tested in a VM |
| Devuan Ceres | untested |
| Secure Boot on Devuan | not supported |
| `zfs-rollback-system` | tested in a VM and on real hardware (BIOS); EFI branch untested |
| `zfs-chroot-system` | lightly tested |
| Ubuntu live system as installer environment | untested |
| `ZFS_BACKPORTS=yes` (Trixie live ISO) | untested |
| iPXE network boot (`netboot-<release>-<arch>/`) | untested |
| Debian live ISO with Secure Boot (shim, MokManager, signed ZFS module) | untested (hook checked against dummy files only; needs a Secure Boot VM) |
| ISO menu entry "im RAM (toram)" | Debian Bookworm, BIOS (syslinux): tested; Debian EFI (GRUB), Trixie and Devuan: untested |

## Proxmox / Secure Boot hint

For Secure Boot in a Proxmox VM the EFI disk needs pre-enrolled keys (`pre-enrolled-keys=1`); `qm enroll-efi-keys` cannot add keys afterwards. DKMS modules are signed with a MOK that you import on first boot (`mokutil --import /var/lib/dkms/mok.pub`).

## License and credits

GPL v3, see [LICENSE](LICENSE).
The installer is derived from [hn/debian-buster-zfs-root](https://github.com/hn/debian-buster-zfs-root) by Hajo Noerenberg (GPL v3.0).

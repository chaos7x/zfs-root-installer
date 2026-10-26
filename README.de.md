# zfs-root-installer

**Debian** oder **Devuan** auf ein natives **ZFS-Root** installieren (BIOS/UEFI, optional eigener GRUB-kompatibler Boot-Pool, Secure Boot über shim), dazu ein **Live-ISO-Builder** sowie **Rollback- und Chroot-Rettungsscripts**.

🇬🇧 [English version](README.md)

> ⚠️ **Der Installer löscht die ausgewählten Platten komplett.** Optionen vorher lesen und zuerst in einer VM testen.

## Inhalt

| Datei | Zweck |
|---|---|
| `debian-zfs-root.sh` | Installer für Debian (Bookworm, Trixie, Forky), amd64 und arm64 |
| `devuan_debian-zfs-root.sh` | Installer für Devuan (sysvinit): Excalibur, Daedalus, Ceres |
| `build-zfs-live-iso.sh` | Baut ein Debian-Live-ISO mit vorgebautem ZFS-Modul und dem Installer |
| `devuan_build-zfs-live-iso.sh` | Dasselbe für Devuan (debootstrap + `grub-mkrescue`, amd64 und arm64) |
| `zfs-rollback-system` | Alle Systemdatasets auf einen gemeinsamen Snapshot zurückrollen (vom Live-System) |
| `zfs-chroot-system` | Installiertes ZFS-System importieren, einhängen und per chroot betreten (Rettung) |
| `zfs-generator-setup` | Debian/systemd: Legacy-ZFS-Mounts aus der fstab auf native Mountpoints umstellen |

Die Scripts gehören in ein Verzeichnis: Die ISO-Builder nehmen den Installer und die beiden Rettungsscripts, die neben ihnen liegen, und legen sie nach `/usr/local/bin` im Image.

## Funktionen

- Natives ZFS-Root, Layout `root/ROOT/<name>`, `root/var`, `root/var/log`, `root/var/tmp`, `root/tmp`
- Optional eigener **Boot-Pool** (`compatibility=grub2`, über alle Platten gespiegelt), Root-Pool mit allen Features, zstd oder lz4 (`--compression`), `dnodesize=auto`
- RAID-Level: single/raid0, Mirror, raidz, raidz2, raidz3
- BIOS und EFI, **Secure Boot** (shim-signed, signiertes GRUB, MOK für DKMS) unter Debian Trixie
- Swap als Partition, ZVOL oder keiner, optional zram
- Interaktiv per Dialog oder komplett unbeaufsichtigt (`--disk … --yes`)
- Live-ISO mit per DKMS gebautem ZFS-Modul und Rettungswerkzeugen (`mc`, `smartmontools`, `cryptsetup`, `gddrescue`, `gdisk`, `mdadm`, `zstd`, …)

## Schnellstart

Live-ISO bauen (auf einem System derselben Debian-/Devuan-Familie und Architektur, ca. 5 GB frei):

```
sudo ./build-zfs-live-iso.sh -d trixie              # Debian: bookworm | trixie | forky
sudo ./devuan_build-zfs-live-iso.sh -d excalibur    # Devuan: excalibur | daedalus | ceres
```

ISO booten und installieren:

```
debian-zfs-root                                     # interaktiv
debian-zfs-root --disk nvme0n1 --raid raid0 --swap 4G --zram yes \
                --bpool boot --hostname meinhost --yes
```

`debian-zfs-root --help` listet alle Optionen.

## Rettung: Rollback und Chroot

Vor riskanten Änderungen, z. B. einem Release-Upgrade, auf allen Systemdatasets Snapshots mit demselben Namen anlegen:

```
for ds in root/ROOT/debian root/var root/var/tmp root/var/log boot/BOOT/debian; do
    zfs snapshot "$ds@vor-upgrade"
done
```

Später vom Live-ISO booten:

```
zfs-rollback-system -n vor-upgrade     # Trockenlauf: prüft Snapshots, zeigt, was gelöscht wird
zfs-rollback-system vor-upgrade        # zurückrollen, danach initramfs und GRUB neu schreiben
zfs-chroot-system                      # System importieren, einhängen und für Handarbeit betreten
```

Hinweise:

- Eine laufende Root lässt sich nicht zurückrollen, deshalb läuft das vom Live-System (ZFS ≥ 2.3 empfohlen).
- `zfs rollback -r` **löscht alle neueren Snapshots** der betroffenen Datasets.
- Pool-Features werden nicht rückgängig gemacht. Nach einem `zpool upgrade` kann ein älteres ZFS den Pool eventuell nicht mehr importieren.
- Datenpools (z. B. `daten`) werden vom Rollback-Script weder importiert noch angefasst.
- Vorgaben in den Scripts (`vor-trixie`, `root/ROOT/debian`, …) lassen sich per Umgebungsvariable ändern, siehe Script-Köpfe.
- Der erste Start nach einem Rollback kann einmalig ein `zpool import -f root` in der initramfs brauchen (Host-ID des Live-Systems).

## Neueres ZFS im Live-ISO (Backports)

Das Bookworm-ISO nimmt ZFS (und GRUB 2.12) immer aus `bookworm-backports`. Für Trixie geht das mit `ZFS_BACKPORTS=yes` genauso, zum Beispiel sobald Forky erschienen ist und dessen ZFS-Version in `trixie-backports` liegt:

```
sudo ZFS_BACKPORTS=yes ./build-zfs-live-iso.sh -d trixie
```

Hinweis: Pools, die der Installer in so einem Live-System anlegt, schalten die Features der ZFS-Version des Live-Systems ein. Eingeschaltete, aber unbenutzte Features hindern ein älteres ZFS nicht am Import. Das installierte System sollte aber dieselbe ZFS-Version oder eine neuere haben, sonst kann es die neueren Features des Pools nicht nutzen, sobald sie aktiv werden.

## Ubuntu als Live-System (ungetestet)

`debian-zfs-root` akzeptiert auch ein Ubuntu-Live-System (Desktop oder Server) als Umgebung. Das Ziel bleibt ein Debian-System, deshalb ist `--dist bookworm|trixie|forky` Pflicht. Für `debootstrap` installiert der Installer `debian-archive-keyring` nach. Die Pools bekommen die Features der ZFS-Version des Live-Systems; ist das ZFS im Ziel älter, begrenzt man sie mit `--compat openzfs-2.x`. Der Server-Installer von Ubuntu hat keine ZFS-Option (getestet auf arm64, 22.04 bis 26.04), und einen Ubuntu-Live-ISO-Builder gibt es noch nicht.


Beide Live-ISOs haben einen zusätzlichen Boot-Menüeintrag „... im RAM (toram)“. Er kopiert das ganze System-Image in den RAM (live-boot `toram`), danach lässt sich USB-Stick oder CD entfernen. Der RAM muss größer sein als das Image (etwa so groß wie das ISO, plus Arbeitsspeicher). Bei einem anderen ISO `toram` von Hand an die Kernel-Zeile hängen.

## Secure Boot mit dem Live-ISO (Trixie / Forky)

Das Debian-Live-ISO enthält `shim-signed` und `mokutil` (auch unter Bookworm, dort bleibt die signierte Bootkette aus). Wird es für Trixie oder neuer gebaut, nimmt live-build shim und das von Debian signierte GRUB, und das ISO legt den MokManager dazu, damit ein Schlüssel eingetragen werden kann. Das ZFS-Modul baut DKMS und signiert es mit dem DKMS-Schlüssel, dem noch nicht vertraut wird. Einmal pro Rechner eintragen:

```
mokutil --import /var/lib/dkms/mok.pub
```

Neu starten, im blauen MOK-Manager „Enroll MOK“ bestätigen (Passwort vom Import), danach das ISO erneut starten. Der Schlüssel entsteht bei jedem ISO-Bau neu; der private Teil wird aus dem Image entfernt. Ein neu gebautes ISO braucht also einen neuen Eintrag. Devuan-ISOs sind nicht betroffen (kein Secure Boot).

## Netzwerkstart (iPXE)

Neben dem ISO schreiben beide Builder einen Ordner `netboot-<Release>-<Arch>/` (im Arbeitsverzeichnis, z. B. `netboot-bookworm-amd64/`) mit `vmlinuz`, `initrd.img`, `filesystem.squashfs` und einem Beispiel `boot.ipxe`. Alles liegt zusätzlich in einem unkomprimierten `netboot-<Release>-<Arch>.tar` (squashfs und Kernel sind schon komprimiert). Den Ordner auf einen Webserver legen und `SERVER` in `boot.ipxe` ersetzen. live-boot lädt das squashfs per `fetch=` in den RAM; der Rechner braucht also mehr RAM als das squashfs. Das ISO selbst per iPXE-`sanboot` zu starten ist bei Linux-Live-Systemen unzuverlässig, weil der Kernel das von iPXE bereitgestellte Laufwerk nicht sieht.

## Teststatus

| Bereich | Status |
|---|---|
| Debian Bookworm / Trixie Installation, BIOS und EFI | getestet (Proxmox-VM, VMware Fusion arm64, echte Hardware) |
| Secure Boot (shim, signiertes GRUB, MOK) | funktioniert unter **Trixie**; unter Bookworm nicht (Ursache nicht geklärt) |
| Debian Forky | Upgrade eines installierten Trixie-Systems funktioniert (Kernel 7.2 + zfs-dkms 2.4.4, in einer VM); Neuinstallation und Live-ISO unter Forky ungetestet |
| Devuan Excalibur Installation + ISO | in einer VM getestet |
| Devuan Daedalus Installation + ISO | in einer VM getestet |
| Devuan Ceres | ungetestet |
| Secure Boot unter Devuan | nicht unterstützt |
| `zfs-rollback-system` | in VM und auf echter Hardware (BIOS) getestet; EFI-Zweig ungetestet |
| `zfs-chroot-system` | kurz getestet |
| Ubuntu-Live-System als Installer-Umgebung | ungetestet |
| `ZFS_BACKPORTS=yes` (Trixie-Live-ISO) | ungetestet |
| iPXE-Netzwerkstart (`netboot-<Release>-<Arch>/`) | ungetestet |
| Debian-Live-ISO mit Secure Boot (shim, MokManager, signiertes ZFS-Modul) | ungetestet (Hook nur gegen Dummy-Dateien geprüft; braucht eine VM mit Secure Boot) |
| ISO-Menüeintrag „im RAM (toram)“ | Debian Bookworm, BIOS (syslinux): getestet; Debian EFI (GRUB), Trixie und Devuan: ungetestet |

## Hinweis Proxmox / Secure Boot

Für Secure Boot in einer Proxmox-VM braucht die EFI-Disk vorab eingetragene Schlüssel (`pre-enrolled-keys=1`); `qm enroll-efi-keys` kann sie nachträglich nicht hinzufügen. DKMS-Module werden mit einem MOK signiert, den du beim ersten Start importierst (`mokutil --import /var/lib/dkms/mok.pub`).

## Lizenz und Herkunft

GPL v3, siehe [LICENSE](LICENSE).
Der Installer ist abgeleitet von [hn/debian-buster-zfs-root](https://github.com/hn/debian-buster-zfs-root) von Hajo Noerenberg (GPL v3.0).

# CLAUDE.md

Bash-Scripts zum Installieren von Debian/Devuan auf ZFS-Root, ein Live-ISO-Builder und Rettungsscripts. Sprache der Meldungen und Kommentare: Deutsch. READMEs: Deutsch und Englisch, beide synchron halten.

## Aufbau

- `debian-zfs-root.sh`, `devuan_debian-zfs-root.sh`: Installer (Debian mit systemd, Devuan mit sysvinit)
- `build-zfs-live-iso.sh`, `devuan_build-zfs-live-iso.sh`: ISO-Builder; legen Installer, `zfs-rollback-system` und `zfs-chroot-system` neben sich ins Image
- `zfs-rollback-system`, `zfs-chroot-system`: laufen im Live-System, nie im installierten System
- `zfs-generator-setup`: nur Debian/systemd

Die Scripts müssen im selben Verzeichnis liegen. Die Devuan-Fassungen sind getrennte Dateien, keine Varianten per Schalter: Änderungen am Installer oder Builder immer auf beiden Seiten prüfen und, wo sinnvoll, nachziehen.

## Regeln

- Vor jedem Commit `bash -n` auf jedes geänderte Script.
- Kein `set -e`-Verhalten brechen: Installer laufen mit `bash -e`, Rettungsscripts mit `set -eu`.
- Locale-abhängige Ausgaben nur mit `LC_ALL=C` auswerten (z. B. `apt-cache policy`).
- Keine festen Plattennamen oder Host-spezifischen Werte in die Scripts schreiben.
- Alles, was Platten löscht oder Pools verändert, muss vorher anzeigen, was passiert, und Rückfrage oder `--yes` verlangen.
- Teststatus in beiden READMEs ehrlich halten: Nur als getestet eintragen, was wirklich gelaufen ist.
- Sicherungskopien (`*.vor-*`, `*.orig`) gehören nicht ins Repo (`.gitignore`).

## Bekannte Eigenheiten

- Secure Boot funktioniert nur unter Trixie; unter Bookworm nicht (Ursache nicht geklärt).
- `/var`, `/var/tmp`, `/var/log` sind `mountpoint=legacy` und stehen in der fstab. Bei sysvinit ist das nötig, weil das ZFS-Mount-Script zu spät läuft.
- Rollback: `zfs rollback -r` löscht neuere Snapshots; der Daten-Pool wird nie angefasst.

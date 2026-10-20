#!/bin/bash -e
#
# devuan_debian-zfs-root.sh  -  Devuan-Fassung von debian-zfs-root.sh
#
# Installiert Devuan GNU/Linux (Standard: 6.0 "excalibur", Trixie-Basis) auf ein natives
# ZFS-Root. Gedacht fuer ein DEVUAN-Live-System mit ZFS (Devuan unter Devuan, kein Cross-Build;
# siehe devuan_build-zfs-live-iso.sh). UNGETESTET, erster Entwurf.
#
# Unterschiede zur Debian-Fassung:
#  - Release, Mirror (deb.devuan.org/merged) und Security-Zeile (<release>-security) fuer Devuan
#  - kein systemd: kein zfs-generator-setup, kein x-systemd in der fstab; die ZFS-Dienste laufen
#    ueber die sysv-Skripte aus zfsutils-linux (zfs-import, zfs-mount, zfs-zed)
#  - zram: zram-tools bringt nur eine systemd-Unit mit, deshalb ein eigenes sysv-Skript (zramswap)
#  - Secure Boot, Boot-Pool, Swap, /var/log-Dataset usw. unveraendert
#
# --- Urspruenglicher Kopf (Debian) ---
# debian-bookworm-zfs-root.sh
#
# Install Debian GNU/Linux 12 Bookworm to a native ZFS root filesystem
# (arm64 oder amd64, BIOS oder EFI)
#
# Abgeleitet von https://github.com/hn/debian-buster-zfs-root
# Original (C) 2018-2020 Hajo Noerenberg, GPL v3.0
#
# Gedacht fuer ein Bookworm-Live-System mit vorgebautem ZFS-Modul
# (siehe build-zfs-live-iso.sh). Aenderungen gegenueber der Buster-Fassung:
#  - Live-System und Ziel sind Bookworm (ZFS 2.1.x, Kernel 6.1, GRUB 2.06)
#  - Mirror deb.debian.org, Komponenten main,contrib,non-free-firmware
#  - Pool kann per TARGET_COMPAT auf ein aelteres Feature-Set begrenzt werden.
#    Standard: zol-0.7 (= Buster-Stand, Pool bleibt auf Buster importierbar).
#    Ohne Begrenzung: TARGET_COMPAT= (leer)
#  - Grosse erste Partition (Standard 243M):
#      BIOS-Modus: Typ EF02, spaeter per gdisk auf EF00 + mkfs.vfat -F32 -> ESP
#      EFI-Modus:  Typ EF00, wird als ESP formatiert (arm64 immer EFI)
#  - Tastatur: uebernimmt das Layout aus dem Live-System (select-keyboard), sonst de;
#    per TARGET_KEYMAP / TARGET_KEYVARIANT ueberschreibbar
#  - Swap: Abfrage nach Swap-Partition (je Platte am Plattenende, Partition 3 bzw. 4 mit Boot-Pool, Standard 4G),
#    Swap-ZVOL oder keinem Swap. Vorgabe per TARGET_SWAPPART=4G (Partition),
#    TARGET_SWAPPART=0 (ZVOL) oder TARGET_SWAPPART=none (kein Swap).
#  - zram: Abfrage, ob komprimierter Swap im RAM (Paket zram-tools) eingerichtet wird.
#    Vorgabe per TARGET_ZRAM=1/0, Groesse per TARGET_ZRAMPERCENT (Standard 50 = % vom RAM).
#  - KEIN dnodesize=auto setzen: /boot liegt im Pool, GRUB kennt large_dnode nicht.
#    (Ausnahme: mit --bpool liegt /boot in einem eigenen Boot-Pool, der Root-Pool darf alles.)
#
# ACHTUNG: Die ausgewaehlten Platten werden komplett geloescht.
#

### Kommandozeilen-Parameter (haben Vorrang vor TARGET_*-Umgebungsvariablen)
usage() {
	cat <<'USAGE'
Aufruf: debian-zfs-root [OPTIONEN]

Ohne Optionen laeuft alles interaktiv per Dialog. Mit --disk und --yes
laeuft die Installation ohne Rueckfragen (nur das root-Passwort wird
abgefragt, ausser --root-password-hash ist gesetzt).

Platten und Pool:
  --disk DEV          Platte, z.B. nvme0n1 oder /dev/disk/by-id/... (mehrfach
                      oder kommagetrennt)                  [Dialog]
  --raid LEVEL        raid0, raid1, raidz, raidz2, raidz3
                      [Standard mit --disk: 1 Platte raid0, sonst raid1]
  --boot MODE         efi oder bios (arm64: immer efi)    [Dialog, mit --yes: EFI wenn verfuegbar]
  --pool NAME         Name des Pools                       [root]
  --rootds NAME       Root-Dataset unter <pool>/ROOT       [debian]
  --compat PROFIL     Feature-Profil, z.B. zol-0.7; "off" = alle Features [zol-0.7]
  --bootsize GROESSE  Boot-Partition (BIOS-Boot/ESP)       [243M]
  --secureboot yes|no GRUB ueber shim starten (shim-signed, von Debian signiertes GRUB,
                      mokutil; nur EFI, auch ohne aktives Secure Boot unschaedlich)
                                                           [Dialog, mit --yes: yes]
  --bpool NAME        eigener Boot-Pool fuer /boot (GRUB-kompatibel, ueber alle Platten
                      gespiegelt, z.B. --bpool boot). Der Root-Pool bekommt dann alle
                      Features (compat off, zstd, dnodesize=auto). "none" = kein
                      Boot-Pool                  [Dialog (Vorschlag: boot), mit --yes: aus]
  --bpool-size GR.    Groesse der Boot-Pool-Partition      [1G]
  --bpool-compat PROF Feature-Profil des Boot-Pools        [grub2]

Swap:
  --swap WERT         Groesse der Swap-Partition je Platte (z.B. 4G),
                      "zvol" fuer Swap im Pool, "none" fuer keinen    [Dialog, mit --yes: 4G]
  --zvol-size GROESSE Groesse des Swap-ZVOL (nur bei --swap zvol)     [2G]
  --zram yes|no       zram-Swap (Paket zram-tools)                    [Dialog, mit --yes: yes]
  --zram-percent N    zram-Groesse in % vom RAM                       [50]

System:
  --hostname NAME     Hostname                             [debian-<hostid>]
  --dist NAME         Devuan-Release des Zielsystems       [Release des Live-Systems: excalibur, daedalus oder ceres]
  --mirror URL        Mirror fuer debootstrap              [http://deb.devuan.org/merged/]
  --components LISTE  Archivbereiche                       [main,contrib,non-free-firmware]
  --backports yes|no  ZFS und GRUB aus <release>-backports     [yes bei daedalus, sonst no]
  --locale LOCALE     Systemsprache                        [de_DE.UTF-8]
  --keymap LAYOUT     Tastaturlayout                       [aus Live-System, sonst de]
  --keyvariant VAR    Tastaturvariante                     [aus Live-System]
  --timezone ZONE     Zeitzone                             [Europe/Berlin]
  --dns "A B"         Nameserver                           [8.8.8.8 8.8.4.4]
  --tmp-size GROESSE  Quota fuer /tmp                      [3G]
  --vartmp-size GR.   Quota fuer /var/tmp                  [3G]
  --varlog yes|no     eigenes Dataset fuer /var/log (Logs bleiben beim
                      Rollback von /var erhalten)                  [yes]
  --varlog-size GR.   Quota fuer /var/log                  [5G]
  --root-password-hash HASH
                      fertiger Passwort-Hash (z.B. von mkpasswd -m yescrypt);
                      sonst wird das Passwort abgefragt
  --debootstrap-opts "OPTS"   Zusatzoptionen fuer debootstrap, z.B. --no-check-gpg

Sonstiges:
  -y, --yes           Bestaetigungsdialog und Standardfragen ueberspringen
  -h, --help          Diese Hilfe

Beispiel (eine NVMe, 4G Swap, zram, ohne Rueckfragen):
  debian-zfs-root --disk nvme0n1 --raid raid0 --swap 4G --zram yes --hostname fs --yes
USAGE
}

OPT_DISKS=()
OPT_RAID=
OPT_BOOT=
OPT_YES=
while [ $# -gt 0 ]; do
	opt=$1
	val=
	hasval=0
	if [[ "$opt" == --*=* ]]; then
		val=${opt#*=}
		opt=${opt%%=*}
		hasval=1
	fi
	shift
	case "$opt" in
	-h | --help)
		usage
		exit 0
		;;
	-y | --yes)
		OPT_YES=1
		continue
		;;
	--*) ;;
	*)
		echo "Unbekannte Option: $opt" >&2
		usage >&2
		exit 1
		;;
	esac
	if [ $hasval -eq 0 ]; then
		if [ $# -lt 1 ]; then
			echo "Option $opt braucht einen Wert" >&2
			exit 1
		fi
		val=$1
		shift
	fi
	case "$opt" in
	--disk)
		IFS=, read -r -a _d <<<"$val"
		OPT_DISKS+=("${_d[@]}")
		;;
	--raid) OPT_RAID=$val ;;
	--boot) OPT_BOOT=$val ;;
	--pool) TARGET_ZPOOL=$val ;;
	--rootds) TARGET_ROOTDS=$val ;;
	--compat)
		case "$val" in
		off | none | "") TARGET_COMPAT= ;;
		*) TARGET_COMPAT=$val ;;
		esac
		;;
	--bootsize) TARGET_SIZEBOOT=$val ;;
	--bpool)
		case "$val" in
		none | no | off | "") TARGET_BPOOL= ;;
		*) TARGET_BPOOL=$val ;;
		esac
		;;
	--secureboot)
		case "$val" in
		yes | 1 | on) TARGET_SECUREBOOT=1 ;;
		no | 0 | off) TARGET_SECUREBOOT=0 ;;
		*)
			echo "--secureboot erwartet yes oder no" >&2
			exit 1
			;;
		esac
		;;
	--bpool-size) TARGET_SIZEBPOOL=$val ;;
	--bpool-compat) TARGET_BCOMPAT=$val ;;
	--swap)
		case "$val" in
		zvol) TARGET_SWAPPART=0 ;;
		none | no) TARGET_SWAPPART=none ;;
		*) TARGET_SWAPPART=$val ;;
		esac
		;;
	--zvol-size) TARGET_SIZESWAP=$val ;;
	--zram)
		case "$val" in
		yes | 1 | on) TARGET_ZRAM=1 ;;
		no | 0 | off) TARGET_ZRAM=0 ;;
		*)
			echo "--zram erwartet yes oder no" >&2
			exit 1
			;;
		esac
		;;
	--zram-percent) TARGET_ZRAMPERCENT=$val ;;
	--hostname) TARGET_HOSTNAME=$val ;;
	--dist) TARGET_DIST=$val ;;
	--mirror) TARGET_MIRROR=$val ;;
	--components) TARGET_COMPONENTS=$val ;;
	--backports)
		case "$val" in
		yes | 1 | on) TARGET_BACKPORTS=1 ;;
		no | 0 | off) TARGET_BACKPORTS=0 ;;
		*)
			echo "--backports erwartet yes oder no" >&2
			exit 1
			;;
		esac
		;;
	--locale) TARGET_LOCALE=$val ;;
	--keymap) TARGET_KEYMAP=$val ;;
	--keyvariant) TARGET_KEYVARIANT=$val ;;
	--timezone) TARGET_TIMEZONE=$val ;;
	--dns) TARGET_DNS=$val ;;
	--tmp-size) TARGET_SIZETMP=$val ;;
	--vartmp-size) TARGET_VARTMP=$val ;;
	--varlog)
		case "$val" in
		yes | 1 | on) TARGET_VARLOG=1 ;;
		no | 0 | off) TARGET_VARLOG=0 ;;
		*)
			echo "--varlog erwartet yes oder no" >&2
			exit 1
			;;
		esac
		;;
	--varlog-size) TARGET_SIZEVARLOG=$val ;;
	--root-password-hash) TARGET_ROOTHASH=$val ;;
	--debootstrap-opts) TARGET_DEBOOTSTRAP_OPTS=$val ;;
	*)
		echo "Unbekannte Option: $opt" >&2
		usage >&2
		exit 1
		;;
	esac
done

### Static settings, overridable by TARGET_* environment variables
ZPOOL=${TARGET_ZPOOL:-root}
# Name des Root-Datasets (versionsneutral, damit er ein Release-Upgrade ueberlebt)
ROOTDS=${TARGET_ROOTDS:-debian}
# Standard-Ziel ist das Release des Live-Systems. Devuan traegt den Codenamen in
# /etc/os-release (VERSION_CODENAME) und in /etc/devuan_version ("excalibur/ceres" o.ae.).
LIVEDIST=
if [ -r /etc/os-release ]; then
	LIVEDIST=$(. /etc/os-release && echo "${VERSION_CODENAME:-}")
fi
if [ -z "$LIVEDIST" ] && [ -r /etc/devuan_version ]; then
	LIVEDIST=$(head -n1 /etc/devuan_version | cut -d/ -f1)
fi
TARGETDIST=${TARGET_DIST:-${LIVEDIST:-excalibur}}
MIRROR=${TARGET_MIRROR:-http://deb.devuan.org/merged/}
COMPONENTS=${TARGET_COMPONENTS:-main,contrib,non-free-firmware}
# Daedalus (Bookworm-Basis): ZFS und GRUB aus den Backports, wie bei Debian Bookworm.
# Excalibur (Trixie-Basis) braucht das nicht.
if [ -n "${TARGET_BACKPORTS:-}" ]; then
	BACKPORTS=$TARGET_BACKPORTS
elif [ "$TARGETDIST" = daedalus ]; then
	BACKPORTS=1
else
	BACKPORTS=0
fi
# BPOOL und COMPAT werden erst nach der Plattenauswahl festgelegt (Dialog, siehe unten)
BCOMPAT=${TARGET_BCOMPAT:-grub2}
SIZEBPOOL=${TARGET_SIZEBPOOL:-1G}
RCOMP=lz4
RDNODE=
PARTBOOT=${TARGET_PARTBOOT:-1}
SIZEBOOT=${TARGET_SIZEBOOT:-243M}
SIZESWAP=${TARGET_SIZESWAP:-2G}
SIZETMP=${TARGET_SIZETMP:-3G}
SIZEVARTMP=${TARGET_VARTMP:-3G}
VARLOG=${TARGET_VARLOG:-1}
SIZEVARLOG=${TARGET_SIZEVARLOG:-5G}
NEWHOST=${TARGET_HOSTNAME}
NEWDNS=${TARGET_DNS:-8.8.8.8 8.8.4.4}
LOCALE=${TARGET_LOCALE:-de_DE.UTF-8}
KEYMAP=${TARGET_KEYMAP:-}
KEYVARIANT=${TARGET_KEYVARIANT:-}
# Standard: das Layout uebernehmen, das im Live-System per select-keyboard gewaehlt wurde
if [ -z "$KEYMAP" ] && [ -f /etc/default/keyboard ]; then
	KEYMAP=$(sed -n 's/^XKBLAYOUT="\([^",]*\).*/\1/p' /etc/default/keyboard | head -n1)
	KEYVARIANT=$(sed -n 's/^XKBVARIANT="\([^",]*\).*/\1/p' /etc/default/keyboard | head -n1)
fi
KEYMAP=${KEYMAP:-de}
DEBOOTSTRAP_OPTS=${TARGET_DEBOOTSTRAP_OPTS:-}
TIMEZONE=${TARGET_TIMEZONE:-Europe/Berlin}
ROOTHASH=${TARGET_ROOTHASH:-}

if [ "$(id -u)" -ne 0 ]; then
	echo "Bitte als root ausfuehren (sudo -i)" >&2
	exit 1
fi

ARCH=$(dpkg --print-architecture)
case "$ARCH" in
amd64)
	EFIPKG=grub-efi-amd64
	EFITARGET=x86_64-efi
	;;
arm64)
	EFIPKG=grub-efi-arm64
	EFITARGET=arm64-efi
	;;
*)
	echo "Unsupported architecture: $ARCH" >&2
	exit 1
	;;
esac

# Nur Devuan-Live-Systeme (Devuan unter Devuan, kein Cross-Build)
if [ ! -e /etc/devuan_version ]; then
	echo "Dies ist kein Devuan-Live-System (/etc/devuan_version fehlt). Fuer Debian: debian-zfs-root.sh" >&2
	exit 1
fi
DEVRELEASE=$(head -n1 /etc/devuan_version)
case "$LIVEDIST$DEVRELEASE" in
*excalibur* | *daedalus* | *ceres* | 6* | 5*) ;;
*)
	echo "Unsupported Devuan Live release: $DEVRELEASE (erwartet: 6.x excalibur, 5.x daedalus oder ceres)" >&2
	exit 1
	;;
esac

### User settings
declare -A BYID

while read -r IDLINK; do
	BYID["$(basename "$(readlink "$IDLINK")")"]="$IDLINK"
done < <(find /dev/disk/by-id/ -type l)

for DISK in $(lsblk -I8,254,259 -dn -o name); do
	if [ -z "${BYID[$DISK]}" ]; then
		SELECT+=("$DISK" "(no /dev/disk/by-id persistent device name available)" off)
	else
		SELECT+=("$DISK" "${BYID[$DISK]}" off)
	fi
done

TMPFILE=$(mktemp)
if [ ${#OPT_DISKS[@]} -gt 0 ]; then
	: >"$TMPFILE"
	for D in "${OPT_DISKS[@]}"; do
		D=$(basename "$(readlink -f "$D")")
		if ! lsblk -I8,254,259 -dn -o name | grep -qx "$D"; then
			echo "Platte '$D' nicht gefunden (lsblk -d zeigt die verfuegbaren)" >&2
			exit 1
		fi
		echo "$D" >>"$TMPFILE"
	done
else
	whiptail --backtitle "$0" --title "Drive selection" --separate-output \
		--checklist "\nPlease select ZFS drives\n" 20 74 8 "${SELECT[@]}" 2>"$TMPFILE" || exit 1
fi

SELDISKS=()
while read -r DISK; do
	SELDISKS+=("$DISK")
done <"$TMPFILE"

if [ ${#SELDISKS[@]} -eq 0 ]; then
	echo "No disk selected" >&2
	exit 1
fi

# Boot-Pool: Option, sonst Dialog (mit --yes ohne Dialog: kein Boot-Pool).
# Ohne Doppelpunkt: "gesetzt" zaehlt auch, wenn die Variable leer ist (--bpool none).
if [ -n "${TARGET_BPOOL+x}" ]; then
	BPOOL=$TARGET_BPOOL
elif [ -n "$OPT_YES" ]; then
	BPOOL=
elif whiptail --backtitle "$0" --title "Boot-Pool" \
	--yesno "\nEigenen Boot-Pool fuer /boot anlegen (empfohlen)?\n\nDer Boot-Pool ist GRUB-kompatibel (Profil $BCOMPAT) und ueber alle Platten gespiegelt. Der Root-Pool bekommt dann alle ZFS-Features (zstd, dnodesize=auto).\n" 16 74; then
	whiptail --backtitle "$0" --title "Boot-Pool" \
		--inputbox "\nName des Boot-Pools:\n" 10 60 "boot" 2>"$TMPFILE" || exit 1
	BPOOL=$(head -n1 "$TMPFILE")
else
	BPOOL=
fi
if [ -n "$BPOOL" ] && ! [[ "$BPOOL" =~ ^[A-Za-z][A-Za-z0-9_.-]*$ ]]; then
	echo "Ungueltiger Pool-Name '$BPOOL' (erlaubt: Buchstaben, Ziffern, _ . -; Anfang ein Buchstabe)" >&2
	exit 1
fi
if [ -n "$BPOOL" ]; then
	# Mit separatem Boot-Pool muss der Root-Pool nicht GRUB-kompatibel sein
	COMPAT=${TARGET_COMPAT-}
	if [ -z "$COMPAT" ]; then
		RCOMP=zstd
		RDNODE=1
	fi
	if [ "$BPOOL" = "$ZPOOL" ]; then
		echo "Boot-Pool und Root-Pool duerfen nicht gleich heissen ($BPOOL)" >&2
		exit 1
	fi
else
	COMPAT=${TARGET_COMPAT-zol-0.7}
fi

# Partitionsnummern in der Reihenfolge auf der Platte:
#   ohne Boot-Pool: 1 Boot/ESP, 2 Root, 3 Swap
#   mit Boot-Pool:  1 Boot/ESP, 2 Boot-Pool, 3 Root, 4 Swap
if [ -n "$BPOOL" ]; then
	PARTBPOOL=${TARGET_PARTBPOOL:-2}
	PARTZFS=${TARGET_PARTZFS:-3}
	PARTSWAP=${TARGET_PARTSWAP:-4}
else
	PARTBPOOL=
	PARTZFS=${TARGET_PARTZFS:-2}
	PARTSWAP=${TARGET_PARTSWAP:-3}
fi

for DISK in "${SELDISKS[@]}"; do
	if [ -z "${BYID[$DISK]}" ]; then
		DISKS+=("/dev/$DISK")
		case "$DISK" in
		*[0-9]) P="p" ;; # nvme0n1 -> nvme0n1p1
		*) P="" ;;
		esac
		PARTPREFIX="/dev/$DISK$P"
	else
		DISKS+=("${BYID[$DISK]}")
		PARTPREFIX="${BYID[$DISK]}-part"
	fi
	ZFSPARTITIONS+=("$PARTPREFIX$PARTZFS")
	BOOTPARTITIONS+=("$PARTPREFIX$PARTBOOT")
	if [ -n "$BPOOL" ]; then
		BPOOLPARTITIONS+=("$PARTPREFIX$PARTBPOOL")
	fi
done

if [ -z "$OPT_RAID" ] && [ ${#OPT_DISKS[@]} -gt 0 ]; then
	if [ ${#DISKS[@]} -eq 1 ]; then OPT_RAID=raid0; else OPT_RAID=raid1; fi
fi
if [ -n "$OPT_RAID" ]; then
	case "${OPT_RAID,,}" in
	raid0 | raid1 | raidz | raidz2 | raidz3) echo "$OPT_RAID" >"$TMPFILE" ;;
	*)
		echo "Unbekanntes RAID-Level '$OPT_RAID' (raid0, raid1, raidz, raidz2, raidz3)" >&2
		exit 1
		;;
	esac
else
	whiptail --backtitle "$0" --title "RAID level selection" --separate-output \
		--radiolist "\nPlease select ZFS RAID level\n" 20 74 8 \
		"RAID0" "Striped disks or single disk" off \
		"RAID1" "Mirrored disks (RAID10 for n>=4)" on \
		"RAIDZ" "Distributed parity, one parity block" off \
		"RAIDZ2" "Distributed parity, two parity blocks" off \
		"RAIDZ3" "Distributed parity, three parity blocks" off 2>"$TMPFILE" || exit 1
fi

RAIDLEVEL=$(head -n1 "$TMPFILE" | tr '[:upper:]' '[:lower:]')

case "$RAIDLEVEL" in
raid0)
	RAIDDEF="${ZFSPARTITIONS[*]}"
	;;
raid1)
	if [ $((${#ZFSPARTITIONS[@]} % 2)) -ne 0 ]; then
		echo "Need an even number of disks for RAID level '$RAIDLEVEL': ${ZFSPARTITIONS[*]}" >&2
		exit 1
	fi
	I=0
	for ZFSPARTITION in "${ZFSPARTITIONS[@]}"; do
		if [ $((I % 2)) -eq 0 ]; then
			RAIDDEF+=" mirror"
		fi
		RAIDDEF+=" $ZFSPARTITION"
		((I++)) || true
	done
	;;
*)
	if [ ${#ZFSPARTITIONS[@]} -lt 3 ]; then
		echo "Need at least 3 disks for RAID level '$RAIDLEVEL': ${ZFSPARTITIONS[*]}" >&2
		exit 1
	fi
	RAIDDEF="$RAIDLEVEL ${ZFSPARTITIONS[*]}"
	;;
esac

# Swap: Standard ist eine eigene Partition je Platte am Plattenende. Das ist robuster
# als ein ZVOL (kein Deadlock unter Speicherdruck). Bei mehreren Platten liegt auf
# jeder ein Swap mit gleicher Prioritaet.
SWAPMODE=ZVOL
SWAPPARTSIZE=
if [ -n "${TARGET_SWAPPART+x}" ]; then
	case "$TARGET_SWAPPART" in
	0) ;;
	none) SWAPMODE=NONE ;;
	*)
		SWAPMODE=PART
		SWAPPARTSIZE=$TARGET_SWAPPART
		;;
	esac
elif [ -n "$OPT_YES" ]; then
	SWAPMODE=PART
	SWAPPARTSIZE=4G
else
	whiptail --backtitle "$0" --title "Swap" \
		--menu "\nWie soll Swap eingerichtet werden?\n" 20 74 8 \
		"PART" "Swap-Partition am Plattenende, je Platte eine (empfohlen)" \
		"ZVOL" "Swap als ZVOL im Pool (${SIZESWAP})" \
		"NONE" "Kein Swap" 2>"$TMPFILE" || exit 1
	SWAPMODE=$(head -n1 "$TMPFILE")
	if [ "$SWAPMODE" == "PART" ]; then
		whiptail --backtitle "$0" --title "Swap-Partition" \
			--inputbox "\nGroesse der Swap-Partition je Platte (z.B. 4G, 8G):\n" 12 60 "4G" 2>"$TMPFILE" || exit 1
		SWAPPARTSIZE=$(head -n1 "$TMPFILE")
	fi
fi
if [ "$SWAPMODE" == "PART" ] && ! [[ "$SWAPPARTSIZE" =~ ^[0-9]+[KMGT]$ ]]; then
	echo "Ungueltige Swap-Groesse '$SWAPPARTSIZE' (erwartet z.B. 4G oder 512M)" >&2
	exit 1
fi
SWAPDEVS=()
if [ "$SWAPMODE" == "PART" ]; then
	# Partitionsnummer der Bootpartition am Ende durch die Swap-Nummer ersetzen
	for BOOTPART in "${BOOTPARTITIONS[@]}"; do
		SWAPDEVS+=("${BOOTPART%$PARTBOOT}$PARTSWAP")
	done
fi

# zram: komprimierter Swap im RAM, hoehere Prioritaet als die Platten-Swaps
ZRAMPERCENT=${TARGET_ZRAMPERCENT:-50}
if [ -n "${TARGET_ZRAM+x}" ]; then
	ZRAM=$TARGET_ZRAM
elif [ -n "$OPT_YES" ]; then
	ZRAM=1
elif whiptail --backtitle "$0" --title "zram" \
	--yesno "\nzram einrichten (komprimierter Swap im RAM, Groesse: ${ZRAMPERCENT}% vom RAM)?\n" 12 70; then
	ZRAM=1
else
	ZRAM=0
fi

# Boot mode: arm64 is EFI only, amd64 depends on the live system
BOOTMODE=BIOS
if [ "$ARCH" == "arm64" ]; then
	BOOTMODE=EFI
elif [ -n "$OPT_BOOT" ]; then
	case "${OPT_BOOT,,}" in
	efi) BOOTMODE=EFI ;;
	bios) BOOTMODE=BIOS ;;
	*)
		echo "--boot erwartet efi oder bios" >&2
		exit 1
		;;
	esac
elif [ -d /sys/firmware/efi ] && [ -n "$OPT_YES" ]; then
	BOOTMODE=EFI
elif [ -d /sys/firmware/efi ]; then
	whiptail --backtitle "$0" --title "EFI boot" --separate-output \
		--menu "\nYour hardware supports EFI. Which boot method should be used in the new to be installed system?\n" 20 74 8 \
		"EFI" "Extensible Firmware Interface boot" \
		"BIOS" "Legacy BIOS boot" 2>"$TMPFILE" || exit 1
	if grep -qi EFI "$TMPFILE"; then
		BOOTMODE=EFI
	fi
fi

if [ "$BOOTMODE" == "EFI" ]; then
	GRUBPKG=$EFIPKG
	BOOTTYPE=EF00
else
	GRUBPKG=grub-pc
	BOOTTYPE=EF02
fi

# Secure Boot: GRUB ueber shim starten (shim-signed + von Debian signiertes GRUB).
# Bei abgeschaltetem Secure Boot aendert das nichts, spaeteres Einschalten geht dann
# ohne Neuinstallation (nur der DKMS-Schluessel muss per MOK eingetragen werden).
SECUREBOOT=0
if [ "$BOOTMODE" == "EFI" ]; then
	if [ -n "${TARGET_SECUREBOOT+x}" ]; then
		SECUREBOOT=$TARGET_SECUREBOOT
	elif [ -n "$OPT_YES" ]; then
		SECUREBOOT=1
	elif whiptail --backtitle "$0" --title "Secure Boot" \
		--yesno "\nGRUB ueber shim starten (Secure Boot-faehig)?\n\nInstalliert shim-signed, das von Debian signierte GRUB und mokutil. Funktioniert auch bei abgeschaltetem Secure Boot. Ist Secure Boot aktiv, wird der DKMS-Schluessel fuer das ZFS-Modul beim ersten Start per MOK-Manager eingetragen.\n" 18 74; then
		SECUREBOOT=1
	fi
fi
SBTXT=no
if [ "$SECUREBOOT" = 1 ]; then SBTXT=shim; fi

if [ -z "$OPT_YES" ]; then
	whiptail --backtitle "$0" --title "Confirmation" \
		--yesno "\nAre you sure to destroy ZFS pool '$ZPOOL' (if existing), wipe all data of disks '${DISKS[*]}' and create a RAID '$RAIDLEVEL' (boot mode: $BOOTMODE, pool features: ${COMPAT:-all}, swap: $SWAPMODE${SWAPPARTSIZE:+ $SWAPPARTSIZE}, zram: $ZRAM, boot pool: ${BPOOL:-none}, secure boot: $SBTXT)?\n" 20 74 || exit 1
fi

### Start the real work

# https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=595790
if [ "$(hostid | cut -b-6)" == "007f01" ]; then
	dd if=/dev/urandom of=/etc/hostid bs=1 count=4
fi

# Fehlende Werkzeuge nachinstallieren (Netzwerk noetig). Mit dem selbstgebauten
# Live-ISO ist normalerweise alles schon an Bord.
NEED_PACKAGES=()
if ! modinfo zfs >/dev/null 2>&1; then NEED_PACKAGES+=(zfs-dkms "linux-headers-$(uname -r)"); fi
command -v zpool >/dev/null || NEED_PACKAGES+=(zfsutils-linux)
command -v debootstrap >/dev/null || NEED_PACKAGES+=(debootstrap)
command -v sgdisk >/dev/null || NEED_PACKAGES+=(gdisk)
command -v mkdosfs >/dev/null || NEED_PACKAGES+=(dosfstools)

if [ ${#NEED_PACKAGES[@]} -gt 0 ]; then
	echo "Need packages: ${NEED_PACKAGES[*]}"
	apt-get update
	DEBIAN_FRONTEND=noninteractive apt-get install --yes "${NEED_PACKAGES[@]}"
fi

if ! modprobe zfs; then
	echo "Unable to load ZFS kernel module" >&2
	LSBVAR=/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c
	if [ -r "$LSBVAR" ] && [ "$(od -An -tu1 -j4 -N1 "$LSBVAR" | tr -d ' ')" = 1 ]; then
		echo "Secure Boot ist aktiv: das ZFS-Modul des Live-Systems ist mit keinem eingetragenen" >&2
		echo "Schluessel signiert. Secure Boot in der Firmware/VM ausschalten und neu starten" >&2
		echo "(das Zielsystem kann danach mit --secureboot yes wieder Secure-Boot-faehig werden)." >&2
	fi
	exit 1
fi

if [ -n "$COMPAT" ] && [ ! -f "/usr/share/zfs/compatibility.d/$COMPAT" ] && [ ! -f "/etc/zfs/compatibility.d/$COMPAT" ]; then
	echo "Compatibility-Profil '$COMPAT' nicht gefunden (ls /usr/share/zfs/compatibility.d/)" >&2
	exit 1
fi

if [ -n "$BPOOL" ] && [ ! -f "/usr/share/zfs/compatibility.d/$BCOMPAT" ] && [ ! -f "/etc/zfs/compatibility.d/$BCOMPAT" ]; then
	echo "Compatibility-Profil '$BCOMPAT' (Boot-Pool) nicht gefunden (ls /usr/share/zfs/compatibility.d/)" >&2
	exit 1
fi

test -d /proc/spl/kstat/zfs/$ZPOOL && zpool destroy $ZPOOL
if [ -n "$BPOOL" ] && [ -d /proc/spl/kstat/zfs/$BPOOL ]; then zpool destroy $BPOOL; fi

# Zusaetzliche Partition fuer den Boot-Pool (direkt hinter der Boot/ESP-Partition)
BPARGS=()
if [ -n "$BPOOL" ]; then
	BPARGS=(-n$PARTBPOOL:0:+$SIZEBPOOL -t$PARTBPOOL:BF01)
fi

for DISK in "${DISKS[@]}"; do
	echo -e "\nPartitioning disk $DISK"
	sgdisk --zap-all "$DISK"
	if [ "$SWAPMODE" == "PART" ]; then
		# ZFS bleibt Partition $PARTZFS, die Swap-Partition kommt ans Plattenende
		sgdisk -n$PARTBOOT:2048:+$SIZEBOOT -t$PARTBOOT:$BOOTTYPE "${BPARGS[@]}" \
			-n$PARTZFS:0:-$SWAPPARTSIZE -t$PARTZFS:BF01 \
			-n$PARTSWAP:0:0 -t$PARTSWAP:8200 "$DISK"
	else
		sgdisk -n$PARTBOOT:2048:+$SIZEBOOT -t$PARTBOOT:$BOOTTYPE "${BPARGS[@]}" \
			-n$PARTZFS:0:0 -t$PARTZFS:BF01 "$DISK"
	fi
done

udevadm settle
sleep 2

if ! zpool create -f -o ashift=12 -o altroot=/target ${COMPAT:+-o compatibility=$COMPAT} \
	-O atime=off -O mountpoint=none \
	-O compression=$RCOMP ${RDNODE:+-O dnodesize=auto} -O xattr=sa -O acltype=posixacl \
	$ZPOOL $RAIDDEF; then
	echo "Unable to create zpool '$ZPOOL'" >&2
	exit 1
fi

zfs create $ZPOOL/ROOT
zfs create -o mountpoint=/ $ZPOOL/ROOT/$ROOTDS
zpool set bootfs=$ZPOOL/ROOT/$ROOTDS $ZPOOL

if [ -n "$BPOOL" ]; then
	# Boot-Pool: GRUB-kompatibel, bei mehreren Platten ein Mirror ueber alle
	if [ ${#BPOOLPARTITIONS[@]} -eq 1 ]; then
		BPOOLDEF="${BPOOLPARTITIONS[*]}"
	else
		BPOOLDEF="mirror ${BPOOLPARTITIONS[*]}"
	fi
	# shellcheck disable=SC2086
	if ! zpool create -f -o ashift=12 -o altroot=/target -o compatibility=$BCOMPAT \
		-O atime=off -O mountpoint=none -O canmount=off -O devices=off \
		-O compression=lz4 -O xattr=sa -O acltype=posixacl \
		$BPOOL $BPOOLDEF; then
		echo "Unable to create boot zpool '$BPOOL'" >&2
		exit 1
	fi
	zfs create -o canmount=off -o mountpoint=none $BPOOL/BOOT
	# wird nach /target/boot gemountet, bevor debootstrap den Kernel installiert
	zfs create -o mountpoint=/boot $BPOOL/BOOT/$ROOTDS
fi

zfs create -o mountpoint=/tmp -o setuid=off -o exec=off -o devices=off -o com.sun:auto-snapshot=false -o quota=$SIZETMP $ZPOOL/tmp
chmod 1777 /target/tmp

# /var needs to be mounted via fstab, the ZFS mount script runs too late during boot
zfs create -o mountpoint=legacy $ZPOOL/var
mkdir -v /target/var
mount -t zfs $ZPOOL/var /target/var

# /var/tmp needs to be mounted via fstab, the ZFS mount script runs too late during boot
zfs create -o mountpoint=legacy -o com.sun:auto-snapshot=false -o quota=$SIZEVARTMP $ZPOOL/var/tmp
mkdir -v -m 1777 /target/var/tmp
mount -t zfs $ZPOOL/var/tmp /target/var/tmp
chmod 1777 /target/var/tmp

# /var/log als eigenes Dataset: bleibt beim Rollback von root/var erhalten, eigene Quota.
# Muss vor debootstrap angelegt werden, sonst verdeckt der Mount schon vorhandene Logs.
# Wie /var legacy mit fstab-Eintrag, damit das Journal rechtzeitig einen Mount hat.
if [ "$VARLOG" = 1 ]; then
	zfs create -o mountpoint=legacy -o compression=zstd -o com.sun:auto-snapshot=false -o quota=$SIZEVARLOG $ZPOOL/var/log
	mkdir -v /target/var/log
	mount -t zfs $ZPOOL/var/log /target/var/log
fi

SWAPFSTAB=
case "$SWAPMODE" in
PART)
	for SWAPDEV in "${SWAPDEVS[@]}"; do
		mkswap -f "$SWAPDEV"
		SWAPFSTAB+="UUID=$(blkid -s UUID -o value "$SWAPDEV") none swap sw,pri=10 0 0"$'\n'
	done
	SWAPFSTAB=${SWAPFSTAB%$'\n'}
	;;
ZVOL)
	zfs create -V $SIZESWAP -b "$(getconf PAGESIZE)" -o primarycache=metadata -o com.sun:auto-snapshot=false -o logbias=throughput -o sync=always $ZPOOL/swap
	# sometimes needed to wait for /dev/zvol/$ZPOOL/swap to appear
	sleep 2
	mkswap -f /dev/zvol/$ZPOOL/swap
	SWAPFSTAB="/dev/zvol/$ZPOOL/swap none swap defaults 0 0"
	;;
esac

zpool status
zfs list

# shellcheck disable=SC2086
# Ein aelteres debootstrap (z.B. Bookworm) kennt neuere Releases wie forky nicht;
# deren Skript ist ohnehin ein Link auf "sid".
DBSCRIPT=
if [ ! -e /usr/share/debootstrap/scripts/$TARGETDIST ] && [ -e /usr/share/debootstrap/scripts/sid ]; then
	echo "debootstrap kennt '$TARGETDIST' nicht, nehme das Skript von sid" >&2
	DBSCRIPT=/usr/share/debootstrap/scripts/sid
fi
debootstrap $DEBOOTSTRAP_OPTS --include=openssh-server,ifupdown,isc-dhcp-client,locales,linux-headers-$ARCH,linux-image-$ARCH,bash-completion,rsync,sharutils,psmisc,htop,patch,less,aptitude,task-ssh-server,zstd,locales-all --components $COMPONENTS $TARGETDIST /target $MIRROR $DBSCRIPT

test -n "$NEWHOST" || NEWHOST=debian-$(hostid)
echo "$NEWHOST" >/target/etc/hostname
sed -i "1s/^/127.0.1.1\t$NEWHOST\n/" /target/etc/hosts

# Copy hostid as the target system will otherwise not be able to mount the misleadingly foreign file system
cp -va /etc/hostid /target/etc/

cat <<EOF >/target/etc/fstab
# /etc/fstab: static file system information.
#
# Use 'blkid' to print the universally unique identifier for a
# device; this may be used with UUID= as a more robust way to name devices
# that works even if disks are added and removed. See fstab(5).
#
# <file system> <mount point> <type> <options> <dump> <pass>
$SWAPFSTAB
$ZPOOL/var /var zfs defaults 0 0
$ZPOOL/var/tmp /var/tmp zfs defaults 0 0
EOF
if [ "$VARLOG" = 1 ]; then
	echo "$ZPOOL/var/log /var/log zfs defaults 0 0" >>/target/etc/fstab
fi

sed -i '/^$/d' /target/etc/fstab

mount --rbind /dev /target/dev
mount --rbind /proc /target/proc
mount --rbind /sys /target/sys
ln -sf /proc/mounts /target/etc/mtab

perl -i -pe "s/# ($LOCALE)/\$1/" /target/etc/locale.gen
echo "LANG=\"$LOCALE\"" >/target/etc/default/locale
chroot /target /usr/sbin/locale-gen

# Paketquellen: debootstrap schreibt nur das Hauptarchiv. Sicherheitsupdates und
# <release>-updates kommen dazu; Release-Name und Komponenten aus --dist / --components.
cat <<EOF >/target/etc/apt/sources.list
deb $MIRROR $TARGETDIST ${COMPONENTS//,/ }

deb $MIRROR $TARGETDIST-security ${COMPONENTS//,/ }

deb $MIRROR $TARGETDIST-updates ${COMPONENTS//,/ }
EOF

chroot /target /usr/bin/apt-get update

# Tastaturlayout fuer Konsole (und spaeter X11/Wayland)
chroot /target env DEBIAN_FRONTEND=noninteractive /usr/bin/apt-get install --yes console-setup keyboard-configuration
cat <<EOF >/target/etc/default/keyboard
XKBMODEL="pc105"
XKBLAYOUT="$KEYMAP"
XKBVARIANT="$KEYVARIANT"
XKBOPTIONS=""
BACKSPACE="guess"
EOF
chroot /target env DEBIAN_FRONTEND=noninteractive dpkg-reconfigure -f noninteractive keyboard-configuration
chroot /target env DEBIAN_FRONTEND=noninteractive dpkg-reconfigure -f noninteractive console-setup

# Deutsche Handbuecher und Woerterbuecher (task-german: manpages-de, ingerman, wngerman, aspell-de, iswiss).
# Das Paket stellt weder Locale noch Tastatur ein, das geschieht oben. Nur bei deutscher Systemsprache.
case "$LOCALE" in
de_*)
	chroot /target env DEBIAN_FRONTEND=noninteractive /usr/bin/apt-get install --yes task-german
	;;
esac

if [ "$ZRAM" == "1" ]; then
	# zram-tools bringt nur eine systemd-Unit mit; unter sysvinit fehlt der Dienst.
	# Deshalb ein eigenes, kleines Init-Skript mit derselben Konfigurationsdatei.
	cat <<EOF >/target/etc/default/zramswap
# Konfiguration fuer das zramswap-Init-Skript
ALGO=zstd
PERCENT=$ZRAMPERCENT
PRIORITY=100
EOF
	cat <<'ZRAMEOF' >/target/etc/init.d/zramswap
#!/bin/sh
### BEGIN INIT INFO
# Provides:          zramswap
# Required-Start:    $local_fs
# Required-Stop:     $local_fs
# Default-Start:     S
# Default-Stop:      0 1 6
# Short-Description: Komprimierter Swap im RAM (zram)
### END INIT INFO
ALGO=zstd
PERCENT=50
PRIORITY=100
[ -r /etc/default/zramswap ] && . /etc/default/zramswap
case "$1" in
start)
	modprobe zram || exit 1
	MEMKB=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
	SIZE=$((MEMKB * 1024 * PERCENT / 100))
	DEV=$(zramctl --find --size "$SIZE" --algorithm "$ALGO") || exit 1
	mkswap "$DEV" >/dev/null && swapon --priority "$PRIORITY" "$DEV"
	;;
stop)
	for DEV in $(awk '/^\/dev\/zram/ { print $1 }' /proc/swaps); do
		swapoff "$DEV" && zramctl --reset "$DEV"
	done
	;;
restart | force-reload)
	"$0" stop
	"$0" start
	;;
*)
	echo "Aufruf: $0 {start|stop|restart}" >&2
	exit 1
	;;
esac
exit 0
ZRAMEOF
	chmod 755 /target/etc/init.d/zramswap
	chroot /target /usr/sbin/update-rc.d zramswap defaults
fi

BPOPT=
if [ "$BACKPORTS" = 1 ]; then
	# Quelle <release>-backports; ZFS und GRUB werden unten mit "-t <release>-backports"
	# installiert (ein Pinning ueber preferences.d griff im Test nicht). Spaetere
	# Updates kommen trotzdem aus den Backports, weil dort ButAutomaticUpgrades gesetzt ist.
	echo "deb $MIRROR $TARGETDIST-backports ${COMPONENTS//,/ }" >/target/etc/apt/sources.list.d/backports.list
	chroot /target /usr/bin/apt-get update
	BPOPT="-t $TARGETDIST-backports"
fi

# Modul nach jedem DKMS-Build ins Initramfs uebernehmen
mkdir -p /target/etc/dkms
echo REMAKE_INITRD=yes >/target/etc/dkms/zfs.conf

# Secure Boot: shim und signiertes GRUB (Version muss zu grub-efi-*-bin passen, daher
# ebenfalls mit $BPOPT). Fehlt ein Paket im Archiv, geht es ohne Secure Boot weiter.
SBPKGS=
if [ "$SECUREBOOT" = 1 ]; then
	SBOK=1
	for PKG in shim-signed grub-efi-$ARCH-signed; do
		# LC_ALL=C: auf deutschen Systemen steht sonst "Kandidat:" statt "Candidate:"
		if ! chroot /target env LC_ALL=C apt-cache policy $PKG | grep -q 'Candidate: [^(]'; then
			echo "Paket $PKG nicht im Archiv, Secure Boot (shim) wird uebersprungen" >&2
			SBOK=0
		fi
	done
	if [ "$SBOK" = 1 ]; then
		SBPKGS="shim-signed grub-efi-$ARCH-signed mokutil"
	elif [ -n "${TARGET_SECUREBOOT+x}" ]; then
		# --secureboot yes war ausdruecklich verlangt: nicht still ohne Secure Boot weitermachen
		echo "Abbruch: --secureboot yes verlangt, aber shim-signed/grub-efi-$ARCH-signed fehlen im Archiv." >&2
		exit 1
	else
		SECUREBOOT=0
	fi
fi

chroot /target env DEBIAN_FRONTEND=noninteractive /usr/bin/apt-get install --yes $BPOPT grub2-common $GRUBPKG $SBPKGS zfs-initramfs zfs-dkms

if [ -n "$BPOOL" ]; then
	# Die initramfs importiert nur den Root-Pool. Der Boot-Pool wird beim Start aus
	# /etc/zfs/zpool.cache importiert, deshalb muss er (und der Root-Pool) dort stehen.
	chroot /target zpool set cachefile=/etc/zfs/zpool.cache $BPOOL
	chroot /target zpool set cachefile=/etc/zfs/zpool.cache $ZPOOL
	zpool sync $BPOOL $ZPOOL
	test -s /target/etc/zfs/zpool.cache || { echo "zpool.cache im Zielsystem ist leer" >&2; exit 1; }
	chroot /target /usr/sbin/update-initramfs -u -k all
fi

grep -q zfs /target/etc/default/grub || perl -i -pe 's/quiet/boot=zfs quiet/' /target/etc/default/grub

# update-grub im Chroot liefert teils keinen Pool-Namen (root=ZFS=/ROOT/debian),
# daher das Root-Dataset fest eintragen
if grep -q '^GRUB_CMDLINE_LINUX=' /target/etc/default/grub; then
	sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"root=ZFS=$ZPOOL/ROOT/$ROOTDS\"|" /target/etc/default/grub
else
	echo "GRUB_CMDLINE_LINUX=\"root=ZFS=$ZPOOL/ROOT/$ROOTDS\"" >>/target/etc/default/grub
fi

# ZPOOL_VDEV_NAME_PATH hilft grub-probe, Pool-Geraete mit by-id/nvme-Namen aufzuloesen
chroot /target env ZPOOL_VDEV_NAME_PATH=YES /usr/sbin/update-grub

if [ "$BOOTMODE" == "BIOS" ]; then
	# GRUB in die MBR-Luecke bzw. die BIOS-Boot-Partition jeder Platte
	for DISK in "${DISKS[@]}"; do
		chroot /target env ZPOOL_VDEV_NAME_PATH=YES /usr/sbin/grub-install --target=i386-pc --recheck --no-floppy "$DISK"
	done
fi

if [ "$BOOTMODE" == "EFI" ]; then
	SBOPT=--no-uefi-secure-boot
	if [ "$SECUREBOOT" = 1 ]; then SBOPT=--uefi-secure-boot; fi
	# "This is arguably a mis-design in the UEFI specification - the ESP is a single point of failure on one disk."
	# https://wiki.debian.org/UEFI#RAID_for_the_EFI_System_Partition
	mkdir -pv /target/boot/efi
	I=0
	for EFIPARTITION in "${BOOTPARTITIONS[@]}"; do
		mkdosfs -F 32 -n EFI-$I "$EFIPARTITION"
		mount "$EFIPARTITION" /target/boot/efi
		# Bootloader-ID = Verzeichnisname unter EFI/ und Name des Boot-Eintrags.
		# Erste Platte "debian" (wie der Debian-Standard), weitere "debian-2", "debian-3" ...
		BOOTID=debian
		if [ $I -gt 0 ]; then BOOTID=debian-$((I + 1)); fi
		chroot /target env ZPOOL_VDEV_NAME_PATH=YES /usr/sbin/grub-install --target=$EFITARGET $SBOPT --efi-directory=/boot/efi --bootloader-id="$BOOTID" --recheck --no-floppy
		# zusaetzlich unter dem Standardpfad EFI/BOOT/, damit auch VMs/Boards ohne NVRAM-Eintrag booten
		chroot /target env ZPOOL_VDEV_NAME_PATH=YES /usr/sbin/grub-install --target=$EFITARGET $SBOPT --efi-directory=/boot/efi --removable --recheck --no-floppy
		if [ "$SECUREBOOT" = 1 ]; then
			# Der Fallback-Pfad EFI/BOOT/ bekommt nur shim als BOOTX64.EFI. MokManager (mm) und
			# Fallback (fb) fehlen dort; ohne mm meldet shim "MokManager is missing on removable
			# media", sobald ein MOK-Eintrag ansteht. Aus shim-helpers-<arch>-signed nachlegen.
			case "$ARCH" in
			amd64) SHIMSUFFIX=x64 ;;
			arm64) SHIMSUFFIX=aa64 ;;
			esac
			for SHIMHELPER in mm$SHIMSUFFIX fb$SHIMSUFFIX; do
				if [ ! -e /target/boot/efi/EFI/BOOT/$SHIMHELPER.efi ] && [ -e /target/usr/lib/shim/$SHIMHELPER.efi.signed ]; then
					cp -v /target/usr/lib/shim/$SHIMHELPER.efi.signed /target/boot/efi/EFI/BOOT/$SHIMHELPER.efi
				fi
			done
		fi
		if [ "$SECUREBOOT" = 1 ] && [ ! -e /target/boot/efi/EFI/$BOOTID/shim$SHIMSUFFIX.efi ]; then
			echo "FEHLER: shim fehlt in EFI/$BOOTID, grub-install hat kein signiertes GRUB geschrieben." >&2
			exit 1
		fi
		umount "$EFIPARTITION"
		if [ $I -gt 0 ]; then
			EFIBAKPART="#"
		fi
		echo "${EFIBAKPART}PARTUUID=$(blkid -s PARTUUID -o value "$EFIPARTITION") /boot/efi vfat defaults 0 1" >>/target/etc/fstab
		((I++)) || true
	done
fi

if [ -d /proc/acpi ]; then
	chroot /target /usr/bin/apt-get install --yes acpi acpid
	chroot /target service acpid stop
fi

ETHDEV=$(udevadm info -e | grep "ID_NET_NAME_ONBOARD=" | head -n1 | cut -d= -f2)
test -n "$ETHDEV" || ETHDEV=$(udevadm info -e | grep "ID_NET_NAME_PATH=" | head -n1 | cut -d= -f2)
test -n "$ETHDEV" || ETHDEV=enp0s1
echo -e "\nauto $ETHDEV\niface $ETHDEV inet dhcp\n" >>/target/etc/network/interfaces

for DNS in $NEWDNS; do
	echo -e "nameserver $DNS" >>/target/etc/resolv.conf
done

if [ -n "$ROOTHASH" ]; then
	chroot /target /usr/sbin/usermod -p "$ROOTHASH" root
else
	chroot /target /usr/bin/passwd
fi
# Secure Boot aktiv: DKMS-Schluessel fuers ZFS-Modul zum Eintragen beim ersten Start
# vormerken (MOK-Manager, Passwort = root-Passwort). Bei abgeschaltetem Secure Boot
# waere das nur ein unnoetiger blauer Bildschirm, dann entfaellt es.
MOKDONE=0
if [ "$SECUREBOOT" = 1 ]; then
	SBVAR=/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c
	if [ -r "$SBVAR" ] && [ "$(od -An -tu1 -j4 -N1 "$SBVAR" | tr -d ' ')" = 1 ]; then
		if [ -f /target/var/lib/dkms/mok.pub ] && chroot /target /usr/bin/mokutil --import /var/lib/dkms/mok.pub --root-pw; then
			MOKDONE=1
		else
			echo "MOK-Import fehlgeschlagen oder kein DKMS-Schluessel vorhanden." >&2
			echo "Nach dem ersten Start: mokutil --import /var/lib/dkms/mok.pub" >&2
		fi
	fi
fi
if [ ! -e "/target/usr/share/zoneinfo/$TIMEZONE" ]; then
	echo "Zeitzone '$TIMEZONE' nicht gefunden, bitte nachtraeglich mit dpkg-reconfigure tzdata setzen" >&2
else
	echo "$TIMEZONE" >/target/etc/timezone
	rm -f /target/etc/localtime
	chroot /target env DEBIAN_FRONTEND=noninteractive /usr/sbin/dpkg-reconfigure -f noninteractive tzdata
fi

# (Der ZFS-Mount-Generator ist systemd-spezifisch und entfaellt unter Devuan.)

sync

echo
echo "Fertig. Zum Neustart:"
echo "  umount -R /target   (falls noetig mehrfach, dann: zfs umount -a)"
echo "  zpool export $ZPOOL${BPOOL:+ $BPOOL}"
echo "  reboot"
echo
if [ "$MOKDONE" = 1 ]; then
	echo "Secure Boot ist aktiv: beim ersten Start erscheint der blaue MOK-Manager."
	echo "  Enroll MOK -> Continue -> Yes -> Passwort = root-Passwort -> Reboot"
	echo
fi
if [ "$BOOTMODE" == "BIOS" ]; then
	echo "Spaeter auf UEFI umziehen: gdisk -> Typ von Partition $PARTBOOT auf EF00,"
	echo "mkfs.vfat -F32, grub-efi-$ARCH installieren, ESP nach /boot/efi mounten, grub-install --removable."
fi

#!/bin/bash -e
#
# build-zfs-live-iso.sh
#
# Baut ein Debian-Live-ISO (Bookworm, Trixie oder Forky, per DIST) mit vorgebautem
# ZFS-Modul (zfs-dkms) und dem Installer debian-zfs-root.sh.
#
# Voraussetzungen:
#  - als root auf einem Rechner derselben Architektur bauen (arm64-Host fuer arm64-ISO),
#    am besten in einem Bookworm-System. Ein aelteres live-build (z.B. aus Bullseye)
#    kennt das Bookworm-Layout (security-Repo, non-free-firmware) teils nicht.
#  - Netzwerk (Pakete kommen von deb.debian.org)
#  - ca. 5 GB freier Platz, der Bau dauert wegen dkms eine Weile
#
# Aufruf:  sudo ./build-zfs-live-iso.sh --dist bookworm|trixie|forky    (kurz: -d)
# Ergebnis: $WORKDIR/zfs-live-<release>-<arch>.iso
#

usage() {
	cat <<'USAGE'
Aufruf: build-zfs-live-iso.sh -d RELEASE [OPTIONEN]

  -d, --dist RELEASE   Debian-Release des Live-ISO: bookworm, trixie oder forky (Pflicht)
                       (forky ist noch Testing und nur zum Ausprobieren gedacht)
  -a, --arch ARCH      Zielarchitektur: amd64 oder arm64   [Architektur des Rechners]
  -m, --mirror URL     Debian-Mirror                       [http://deb.debian.org/debian/]
  -h, --help           Diese Hilfe

Weitere Einstellungen per Umgebungsvariable:
  WORKDIR    Arbeitsverzeichnis                           [./zfs-live-<release>-<arch>]
  INSTALLER  Pfad zum Installer-Script                    [debian-zfs-root.sh neben diesem Script]
  ZFS_BACKPORTS  yes|no: ZFS (zfs-dkms, zfsutils-linux) aus <release>-backports   [bookworm: yes, sonst no]

Beispiele:
  sudo ./build-zfs-live-iso.sh -d bookworm
  sudo ./build-zfs-live-iso.sh --dist trixie --arch arm64
  sudo ./build-zfs-live-iso.sh -d trixie -m http://ftp.de.debian.org/debian/
  sudo ./build-zfs-live-iso.sh -d forky
USAGE
}

DIST=
# ARCH und MIRROR gelten nur, wenn sie per Option gesetzt werden
ARCH=
MIRROR=
while [ $# -gt 0 ]; do
	case "$1" in
	-d | --dist)
		if [ $# -lt 2 ]; then
			echo "Option $1 braucht einen Wert (bookworm, trixie oder forky)" >&2
			exit 1
		fi
		DIST=$2
		shift 2
		;;
	--dist=*)
		DIST=${1#*=}
		shift
		;;
	-a | --arch)
		if [ $# -lt 2 ]; then
			echo "Option $1 braucht einen Wert (amd64 oder arm64)" >&2
			exit 1
		fi
		ARCH=$2
		shift 2
		;;
	--arch=*)
		ARCH=${1#*=}
		shift
		;;
	-m | --mirror)
		if [ $# -lt 2 ]; then
			echo "Option $1 braucht einen Wert (URL)" >&2
			exit 1
		fi
		MIRROR=$2
		shift 2
		;;
	--mirror=*)
		MIRROR=${1#*=}
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "Unbekannte Option: $1" >&2
		usage >&2
		exit 1
		;;
	esac
done

case "$DIST" in
bookworm | trixie | forky) ;;
"")
	echo "Bitte das Release angeben: --dist bookworm, --dist trixie oder --dist forky" >&2
	usage >&2
	exit 1
	;;
*)
	echo "Nicht unterstuetztes Release '$DIST' (erwartet: bookworm, trixie oder forky)" >&2
	exit 1
	;;
esac

if [ "$(id -u)" -ne 0 ]; then
	echo "Bitte als root ausfuehren" >&2
	exit 1
fi

ARCH=${ARCH:-$(dpkg --print-architecture)}
HERE=$(dirname "$(readlink -f "$0")")
INSTALLER=${INSTALLER:-$HERE/debian-zfs-root.sh}
WORKDIR=${WORKDIR:-$PWD/zfs-live-$DIST-$ARCH}
MIRROR=${MIRROR:-http://deb.debian.org/debian/}

if [ ! -f "$INSTALLER" ]; then
	echo "Installer-Skript nicht gefunden: $INSTALLER" >&2
	exit 1
fi

# Secure Boot (shim + von Debian signiertes GRUB): unter Bookworm gibt es kein signiertes
# GRUB 2.12 (die Backports liefern keins), dort bleibt es aus. Sonst nimmt live-build die
# signierten Pakete, wenn sie da sind (auto), und baut sonst ohne weiter.
case "$DIST" in
bookworm) SBMODE=disable ;;
*) SBMODE=auto ;;
esac

# ZFS aus den Backports: unter Bookworm Pflicht (ZFS 2.3, dazu GRUB 2.12, siehe unten). Unter
# Trixie optional (ZFS_BACKPORTS=yes), z.B. sobald Forky stabil ist und die neuere ZFS-Version
# in trixie-backports liegt. Bei Forky gibt es keine Backports.
case "${ZFS_BACKPORTS:-auto}" in
auto) if [ "$DIST" = bookworm ]; then ZFSBP=1; else ZFSBP=0; fi ;;
yes | 1) ZFSBP=1 ;;
no | 0) ZFSBP=0 ;;
*)
	echo "ZFS_BACKPORTS erwartet yes oder no" >&2
	exit 1
	;;
esac
if [ "$DIST" = forky ] && [ "$ZFSBP" = 1 ]; then
	echo "Fuer forky gibt es keine Backports (ZFS_BACKPORTS=yes nicht moeglich)" >&2
	exit 1
fi

case "$ARCH" in
arm64)
	FLAVOUR=arm64
	BOOTLOADERS=grub-efi
	;;
amd64)
	FLAVOUR=amd64
	BOOTLOADERS=grub-efi,syslinux
	;;
*)
	echo "Nicht unterstuetzte Architektur: $ARCH" >&2
	exit 1
	;;
esac

if ! command -v lb >/dev/null; then
	apt-get update
	apt-get install --yes live-build debootstrap xorriso squashfs-tools
fi
# mtools und dosfstools braucht der Hook, der das EFI-Image um MokManager erweitert
if ! command -v mcopy >/dev/null || ! command -v mkfs.msdos >/dev/null; then
	apt-get install --yes mtools dosfstools
fi
echo "lb: $(command -v lb)"
lb --version || true

# Auf Nicht-Debian-Rechnern (z.B. Devuan) fehlt oft der Debian-Schluesselbund, ohne den
# debootstrap die Debian-Pakete nicht pruefen kann.
if ! dpkg -s debian-archive-keyring >/dev/null 2>&1; then
	echo "debian-archive-keyring fehlt, installiere ihn"
	apt-get install --yes debian-archive-keyring
fi

# Ein aelteres debootstrap kennt neue Releases (z.B. forky) noch nicht. Deren Skript
# ist ohnehin ein Link auf "sid"; fehlt es, wird dieser Link hier angelegt.
if [ ! -e "/usr/share/debootstrap/scripts/$DIST" ] && [ -e /usr/share/debootstrap/scripts/sid ]; then
	echo "debootstrap kennt '$DIST' nicht, lege Link /usr/share/debootstrap/scripts/$DIST -> sid an"
	ln -s sid "/usr/share/debootstrap/scripts/$DIST"
fi

mkdir -p "$WORKDIR"
WORKDIR=$(readlink -f "$WORKDIR")

# Reste eines abgebrochenen Laufs aufraeumen: Prozesse im Chroot beenden und
# Mounts darunter loesen. Sonst scheitert lb mit "umount: ... target is busy".
cleanup_stale_chroot() {
	local root="$WORKDIR/chroot" p
	[ -d "$root" ] || return 0
	for p in /proc/[0-9]*; do
		if [ "$(readlink "$p/root" 2>/dev/null)" = "$root" ]; then
			echo "Beende Prozess ${p#/proc/} ($(cat "$p/comm" 2>/dev/null)) im Chroot"
			kill "${p#/proc/}" 2>/dev/null || true
		fi
	done
	sleep 2
	awk -v r="$root/" 'index($2, r) == 1 { print $2 }' /proc/mounts | sort -r |
		while read -r m; do umount -l "$m" 2>/dev/null || true; done
}
cleanup_stale_chroot

cd "$WORKDIR"

# lb scheitert in Chroot-Stufe "chroot_sysfs remove" gelegentlich mit
# "umount: .../chroot/sys: target is busy". Ein umount-Wrapper versucht es
# mehrmals, schreibt eine Diagnose (verschachtelte Mounts, offene Dateien) ins
# Log und loest den Mount zuletzt lazy (-l). Es werden KEINE Prozesse beendet.
WRAPDIR=$(mktemp -d)
trap 'rm -rf "$WRAPDIR"' EXIT
REAL_UMOUNT=$(command -v umount)
export REAL_UMOUNT
cat >"$WRAPDIR/umount" <<'WRAPEOF'
#!/bin/sh
for i in 1 2 3; do
	"$REAL_UMOUNT" "$@" && exit 0
	sleep 1
done
for t in "$@"; do
	case "$t" in
	-*) ;;
	*)
		echo "umount-Wrapper: Diagnose fuer $t" >&2
		findmnt -R "$t" >&2 2>/dev/null || true
		fuser -vm "$t" >&2 2>/dev/null || true
		;;
	esac
done
exec "$REAL_UMOUNT" -l "$@"
WRAPEOF
chmod +x "$WRAPDIR/umount"
PATH="$WRAPDIR:$PATH"
export PATH

lb clean --purge 2>/dev/null || true

lb config \
	--distribution "$DIST" \
	--architectures "$ARCH" \
	--linux-flavours "$FLAVOUR" \
	--archive-areas "main contrib non-free-firmware" \
	--mirror-bootstrap "$MIRROR" \
	--mirror-chroot "$MIRROR" \
	--mirror-binary "$MIRROR" \
	--bootloaders "$BOOTLOADERS" \
	--uefi-secure-boot "$SBMODE" \
	--binary-images iso-hybrid \
	--debian-installer none \
	--firmware-chroot false \
	--firmware-binary false \
	--apt-options "--yes --allow-remove-essential" \
	--iso-volume "debian-zfs-live" \
	--bootappend-live "boot=live components locales=de_DE.UTF-8 keyboard-layouts=de timezone=Europe/Berlin"

# Bookworm: ZFS 2.3 und GRUB 2.12 aus den Backports. Ein Pinning ueber
# /etc/apt/preferences.d griff beim Bau nicht; deshalb werden die Pakete unten
# per Hook mit "apt-get install -t bookworm-backports" installiert.
if [ "$ZFSBP" = 1 ]; then
	mkdir -p config/archives
	echo "deb $MIRROR $DIST-backports main contrib non-free-firmware" >config/archives/backports.list.chroot
fi

# Pakete: Kernel, Headers und zfs-dkms zusammen, damit das Modul beim Bau kompiliert wird
mkdir -p config/package-lists
cat >config/package-lists/zfs.list.chroot <<EOF
linux-image-$FLAVOUR
linux-headers-$FLAVOUR
dkms
zfs-dkms
zfsutils-linux
grub-common
debootstrap
gdisk
dosfstools
whiptail
rsync
mdadm
lvm2
btrfs-progs
parted
openssh-server
sudo
console-setup
keyboard-configuration
kbd
less
htop
mc
smartmontools
cryptsetup
gddrescue
zstd
eject
shim-signed
mokutil
EOF

# Bookworm: zfs-dkms, zfsutils-linux und grub-common aus den Backports (Hook nach den
# Paketlisten, Kernel und Headers sind dann schon installiert; dkms baut das Modul hier)
if [ "$DIST" = bookworm ] && [ "$ZFSBP" = 1 ]; then
	sed -i '/^zfs-dkms$/d;/^zfsutils-linux$/d;/^grub-common$/d' config/package-lists/zfs.list.chroot
	mkdir -p config/hooks/normal
	cat >config/hooks/normal/0100-zfs-backports.hook.chroot <<'HOOKEOF'
#!/bin/sh
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
# Alle GRUB-Pakete muessen dieselbe Version haben (grub-common = ...). Die Bootloader-
# Pakete fuer das ISO installiert live-build erst NACH diesem Hook (aus Bookworm, 2.06) und
# wuerde mit grub-common 2.12 kollidieren. Deshalb hier schon aus den Backports holen;
# live-build findet sie dann installiert vor. Signierte Pakete gibt es dort nicht.
case "$(dpkg --print-architecture)" in
amd64) BOOTBIN="grub-efi-amd64-bin grub-efi-ia32-bin grub-pc-bin" ;;
arm64) BOOTBIN="grub-efi-arm64-bin" ;;
*) BOOTBIN="" ;;
esac
GRUBPKGS=$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'grub*' | awk '$1 == "ii" { print $2 }' | grep -v -e '-signed$' || true)
apt-get install --yes -t bookworm-backports zfs-dkms zfsutils-linux grub-common grub2-common $BOOTBIN $GRUBPKGS
HOOKEOF
	chmod +x config/hooks/normal/0100-zfs-backports.hook.chroot
fi

# Trixie: nur ZFS aus trixie-backports (GRUB 2.12 und signiertes GRUB kommen schon aus Trixie)
if [ "$DIST" = trixie ] && [ "$ZFSBP" = 1 ]; then
	sed -i '/^zfs-dkms$/d;/^zfsutils-linux$/d' config/package-lists/zfs.list.chroot
	mkdir -p config/hooks/normal
	cat >config/hooks/normal/0100-zfs-backports.hook.chroot <<'HOOKEOF'
#!/bin/sh
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install --yes -t trixie-backports zfs-dkms zfsutils-linux
HOOKEOF
	chmod +x config/hooks/normal/0100-zfs-backports.hook.chroot
fi

# Installer ins Image legen
mkdir -p config/includes.chroot/usr/local/bin
install -m 0755 "$INSTALLER" config/includes.chroot/usr/local/bin/debian-zfs-root
# Rollback der Systemdatasets auf einen Snapshot (neben dem Script, falls vorhanden)
if [ -f "$HERE/zfs-rollback-system" ]; then
	install -m 0755 "$HERE/zfs-rollback-system" config/includes.chroot/usr/local/bin/zfs-rollback-system
fi
# System einhaengen und per chroot betreten (neben dem Script, falls vorhanden)
if [ -f "$HERE/zfs-chroot-system" ]; then
	install -m 0755 "$HERE/zfs-chroot-system" config/includes.chroot/usr/local/bin/zfs-chroot-system
fi

# Tastaturauswahl beim ersten Login auf tty1 (wie bei Gentoo), Standard: Deutsch
mkdir -p config/includes.chroot/usr/local/bin config/includes.chroot/etc/profile.d
cat >config/includes.chroot/usr/local/bin/select-keyboard <<'KBEOF'
#!/bin/bash
# Tastaturlayout waehlen und sofort aktivieren. Kann jederzeit erneut aufgerufen werden.
if [ "$(id -u)" -ne 0 ]; then exec sudo "$0" "$@"; fi
touch /run/keyboard-selected

CHOICE=$(whiptail --backtitle "select-keyboard" --title "Tastaturlayout / Keyboard layout" \
	--default-item "de:" --menu "\nBitte Layout waehlen (Enter = Deutsch)\nPlease select a layout (Enter = German)\n" 22 70 12 \
	"de:" "Deutsch" \
	"de:nodeadkeys" "Deutsch (ohne Akzent-Tasten)" \
	"ch:" "Schweiz (Deutsch)" \
	"at:" "Oesterreich" \
	"us:" "US English" \
	"gb:" "UK English" \
	"fr:" "Francais" \
	"es:" "Espanol" \
	"it:" "Italiano" \
	"dk:" "Dansk" \
	"se:" "Svenska" \
	"other" "Anderes Layout eingeben (z.B. pl, cz, ru)" 3>&1 1>&2 2>&3) || exit 0

if [ "$CHOICE" = other ]; then
	CHOICE=$(whiptail --inputbox "Layout[:Variante], z.B. pl oder us:intl" 10 60 "de" 3>&1 1>&2 2>&3) || exit 0
fi

LAYOUT=${CHOICE%%:*}
VARIANT=
case "$CHOICE" in *:*) VARIANT=${CHOICE#*:} ;; esac

cat >/etc/default/keyboard <<EOF
XKBMODEL="pc105"
XKBLAYOUT="$LAYOUT"
XKBVARIANT="$VARIANT"
XKBOPTIONS=""
BACKSPACE="guess"
EOF

setupcon --keyboard-only --force 2>/dev/null || loadkeys "$LAYOUT" 2>/dev/null || true
echo "Tastaturlayout: $LAYOUT ${VARIANT:+($VARIANT)}"
KBEOF
chmod +x config/includes.chroot/usr/local/bin/select-keyboard

cat >config/includes.chroot/etc/profile.d/zz-select-keyboard.sh <<'PROFEOF'
# Einmalige Tastaturauswahl beim ersten Login auf tty1
case $- in
*i*)
	if [ "$(tty 2>/dev/null)" = "/dev/tty1" ] && [ ! -e /run/keyboard-selected ]; then
		/usr/local/bin/select-keyboard
	fi
	;;
esac
PROFEOF

# Zusaetzlicher Menueeintrag "im RAM" (live-boot: toram). Der Hook laeuft nach der Erzeugung
# von grub.cfg und live.cfg und dupliziert dort den ersten Live-Eintrag mit "toram".
# Das squashfs wird dann komplett in den RAM kopiert, das Medium kann danach entfernt werden.
mkdir -p config/hooks/normal
cat >config/hooks/normal/9100-toram-menu.hook.binary <<'TORAMEOF'
#!/bin/sh
set -e
# live-build startet Binary-Hooks im Verzeichnis binary/
GRUBCFG=boot/grub/grub.cfg
LIVECFG=isolinux/live.cfg
if [ ! -f "$GRUBCFG" ] && [ ! -f "$LIVECFG" ]; then
	echo "toram-Hook: weder $GRUBCFG noch $LIVECFG gefunden (Verzeichnis: $(pwd))" >&2
	exit 1
fi

if [ -f "$GRUBCFG" ]; then
	awk '
	/^menuentry / && !done && /Live system/ && !/fail-safe/ { inblk = 1 }
	{ print }
	inblk { buf = buf $0 "\n" }
	inblk && /^}/ {
		inblk = 0
		done = 1
		n = split(buf, L, "\n")
		for (i = 1; i < n; i++) {
			line = L[i]
			if (line ~ /^menuentry /) {
				match(line, /"[^"]*"/)
				lbl = substr(line, RSTART + 1, RLENGTH - 2)
				sub(/"[^"]*"/, "\"" lbl " - im RAM (toram)\"", line)
				sub(/ --hotkey=[a-z]/, "", line)
			} else if (line ~ /^[ \t]*linux[ \t]/) {
				line = line " toram"
			}
			print line
		}
		print ""
	}' "$GRUBCFG" >"$GRUBCFG.neu"
	grep -q toram "$GRUBCFG.neu" || { echo "toram-Eintrag fuer GRUB nicht erzeugt" >&2; exit 1; }
	mv "$GRUBCFG.neu" "$GRUBCFG"
fi

if [ -f "$LIVECFG" ]; then
	awk '
	/^label / && !done && !/failsafe/ { inblk = 1 }
	inblk && /^$/ { inblk = 0; done = 1; emit = 1 }
	inblk { buf = buf $0 "\n" }
	{ print }
	END { if (inblk) emit = 1 }
	emit {
		n = split(buf, L, "\n")
		for (i = 1; i < n; i++) {
			line = L[i]
			if (line ~ /^label /) line = line "-toram"
			else if (line ~ /menu label/) { sub(/\^/, "", line); line = line " - im RAM (toram)" }
			else if (line ~ /menu default/) continue
			else if (line ~ /^[ \t]*append[ \t]/) line = line " toram"
			print line
		}
		print ""
		emit = 0
	}' "$LIVECFG" >"$LIVECFG.neu"
	grep -q toram "$LIVECFG.neu" || { echo "toram-Eintrag fuer syslinux nicht erzeugt" >&2; exit 1; }
	mv "$LIVECFG.neu" "$LIVECFG"
fi
TORAMEOF
chmod +x config/hooks/normal/9100-toram-menu.hook.binary

# Pruefung: ist das ZFS-Modul wirklich gebaut worden?
mkdir -p config/hooks/normal
cat >config/hooks/normal/9000-check-zfs.hook.chroot <<'EOF'
#!/bin/sh
set -e
echo "== dkms status =="
dkms status
if ! find /lib/modules -name 'zfs.ko*' | grep -q .; then
	echo "FEHLER: zfs.ko wurde nicht gebaut (siehe /var/lib/dkms/zfs/*/build/make.log)" >&2
	exit 1
fi
echo "== ZFS-Modul vorhanden =="
# Secure Boot: das Modul ist nur ladbar, wenn es mit einem eingetragenen Schluessel signiert
# ist. dkms signiert mit /var/lib/dkms/mok.key, der oeffentliche Teil ist mok.pub. Nur Hinweis,
# kein Abbruch (ohne Secure Boot ist ein unsigniertes Modul unproblematisch).
ZFSKO=$(find /lib/modules -name 'zfs.ko*' | head -n1)
SIGNER=$(modinfo -F signer "$ZFSKO" 2>/dev/null || true)
if [ -n "$SIGNER" ] && [ -f /var/lib/dkms/mok.pub ]; then
	echo "== ZFS-Modul signiert von: $SIGNER =="
else
	echo "HINWEIS: ZFS-Modul ist nicht signiert (oder mok.pub fehlt): unter Secure Boot nicht ladbar" >&2
fi
EOF
chmod +x config/hooks/normal/9000-check-zfs.hook.chroot

# Den privaten dkms-Schluessel nicht mit ins Image geben: wer das ISO hat, koennte sonst Module
# signieren, denen ein Rechner mit eingetragenem Schluessel vertraut. mok.pub bleibt fuer
# "mokutil --import /var/lib/dkms/mok.pub" im Live-System.
cat >config/hooks/normal/9050-remove-mok-key.hook.chroot <<'EOF'
#!/bin/sh
rm -f /var/lib/dkms/mok.key
EOF
chmod +x config/hooks/normal/9050-remove-mok-key.hook.chroot

# Secure Boot: live-build legt nur shim und GRUB auf das EFI-Image. MokManager (mm) und
# Fallback (fb) fehlen, dann meldet shim "MokManager is missing", sobald ein Schluessel per
# mokutil eingetragen werden soll. Der Hook legt sie nach EFI/boot und baut efi.img neu (die
# Groesse ist von live-build knapp bemessen, mcopy ins vorhandene Image wuerde nicht passen).
# Er tut nichts, wenn live-build ohne signiertes GRUB gebaut hat (kein grub<arch>.efi).
cat >config/hooks/normal/9060-efi-mokmanager.hook.binary <<'MOKEOF'
#!/bin/sh
set -e
# live-build startet Binary-Hooks im Verzeichnis binary/
EFIIMG=boot/grub/efi.img
for S in x64 aa64; do
	[ -f EFI/boot/grub$S.efi ] || continue
	echo "Secure-Boot-Image ($S): ergaenze MokManager und Fallback"
	for H in mm fb; do
		SRC=../chroot/usr/lib/shim/$H$S.efi.signed
		if [ -f "$SRC" ]; then
			cp -v "$SRC" EFI/boot/$H$S.efi
		else
			echo "WARNUNG: $SRC fehlt" >&2
		fi
	done
	TMP=$(mktemp -d)
	mcopy -i "$EFIIMG" ::boot/grub/grub.cfg "$TMP/grub.cfg"
	SIZE=$(cat EFI/boot/*.efi "$TMP/grub.cfg" | wc -c)
	BLOCKS=$(( (SIZE / 1024 + 256) / 32 * 32 ))
	rm -f "$EFIIMG"
	mkfs.msdos -C "$EFIIMG" "$BLOCKS" -i "$(printf '%08x' "$(( ${SOURCE_DATE_EPOCH:-$(date +%s)} % 4294967296 ))")" >/dev/null
	mmd -i "$EFIIMG" ::EFI ::EFI/boot ::boot ::boot/grub
	mcopy -m -o -i "$EFIIMG" EFI/boot/*.efi ::EFI/boot
	mcopy -m -o -i "$EFIIMG" "$TMP/grub.cfg" ::boot/grub
	rm -rf "$TMP"
	mdir -i "$EFIIMG" ::EFI/boot
done
MOKEOF
chmod +x config/hooks/normal/9060-efi-mokmanager.hook.binary

lb build 2>&1 | tee build.log

# live-build nennt das ISO live-image-<arch>.hybrid.iso; mit Release im Namen ist es eindeutig
ISO=$WORKDIR/zfs-live-$DIST-$ARCH.iso
mv -v ./live-image-*.hybrid.iso "$ISO"
ls -lh "$ISO"

# Netboot: Kernel, Initrd und squashfs einzeln (iPXE: kernel/initrd + live-boot fetch=)
NETDIR=$WORKDIR/netboot-$DIST-$ARCH
rm -rf "$NETDIR"
mkdir -p "$NETDIR"
NETKERNEL=$(ls -1 binary/live/vmlinuz-* | sort -V | tail -n1)
NETINITRD=$(ls -1 binary/live/initrd.img-* | sort -V | tail -n1)
cp -v "$NETKERNEL" "$NETDIR/vmlinuz"
cp -v "$NETINITRD" "$NETDIR/initrd.img"
cp -v binary/live/filesystem.squashfs "$NETDIR/"
cat >"$NETDIR/boot.ipxe" <<IPXEEOF
#!ipxe
# Adresse des Webservers anpassen, auf dem dieser Ordner liegt
set base http://SERVER/netboot-$DIST-$ARCH
dhcp
kernel \${base}/vmlinuz boot=live components ip=dhcp fetch=\${base}/filesystem.squashfs locales=de_DE.UTF-8 keyboard-layouts=de timezone=Europe/Berlin
initrd \${base}/initrd.img
boot
IPXEEOF
# Alles in einem unkomprimierten tar (squashfs und Kernel sind schon komprimiert)
tar -C "$WORKDIR" -cf "$NETDIR.tar" "$(basename "$NETDIR")"
echo "Netboot-Dateien (iPXE, live-boot fetch=): $NETDIR"
ls -lh "$NETDIR"
ls -lh "$NETDIR.tar"
echo
echo "Fertig. Im gebooteten Live-System: sudo -i; debian-zfs-root"

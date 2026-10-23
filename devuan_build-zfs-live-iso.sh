#!/bin/bash -e
#
# devuan_build-zfs-live-iso.sh
#
# Baut ein Devuan-Live-ISO (sysvinit, Standard: 6.0 "excalibur") mit vorgebautem ZFS-Modul
# (zfs-dkms) und dem Installer devuan_debian-zfs-root.sh. Getestet (VM): Excalibur, Daedalus; Ceres ungetestet. Kein Secure Boot.
#
# Unterschiede zum Debian-Bauskript (build-zfs-live-iso.sh):
#  - Devuan baut unter Devuan, kein Cross-Build.
#  - KEIN live-build: Devuans live-build (4.0.3, Stand 2016) kann nur BIOS-Boot. Stattdessen
#    debootstrap -> squashfs -> live-boot -> grub-mkrescue (BIOS + UEFI, ein Hybrid-ISO).
#  - Das ISO startet mit unsigniertem GRUB. Fuer einen Secure-Boot-Test des INSTALLIERTEN
#    Systems muss das Live-System mit abgeschaltetem Secure Boot laufen; der MOK-Import
#    (mokutil --import /var/lib/dkms/mok.pub) erfolgt dann nach dem ersten Start von Hand.
#  - amd64 oder arm64 (immer die Architektur des Bau-Rechners, kein Cross-Build); arm64 bootet nur per UEFI.
#
# Voraussetzungen:
#  - als root auf einem Devuan-Rechner (amd64 oder arm64), Netzwerk (deb.devuan.org), ca. 6 GB Platz
#  - der Bau dauert wegen dkms und squashfs (xz) eine Weile
#
# Aufruf:  sudo ./devuan_build-zfs-live-iso.sh -d excalibur
# Ergebnis: $WORKDIR/devuan-zfs-live-<arch>.iso
#

usage() {
	cat <<'USAGE'
Aufruf: devuan_build-zfs-live-iso.sh [OPTIONEN]

  -d, --dist RELEASE   Devuan-Release des Live-ISO: excalibur (6.0), daedalus (5.0) oder ceres [excalibur]
  -m, --mirror URL     Devuan-Mirror                        [http://deb.devuan.org/merged/]
  -h, --help           Diese Hilfe

Weitere Einstellungen per Umgebungsvariable:
  WORKDIR    Arbeitsverzeichnis                           [./devuan-zfs-live]
  INSTALLER  Pfad zum Installer-Script                    [devuan_debian-zfs-root.sh neben diesem Script]

Beispiele:
  sudo ./devuan_build-zfs-live-iso.sh
  sudo ./devuan_build-zfs-live-iso.sh -d excalibur -m http://deb.devuan.org/merged/
USAGE
}

DIST=excalibur
MIRROR=
while [ $# -gt 0 ]; do
	case "$1" in
	-d | --dist)
		if [ $# -lt 2 ]; then
			echo "Option $1 braucht einen Wert (excalibur, daedalus oder ceres)" >&2
			exit 1
		fi
		DIST=$2
		shift 2
		;;
	--dist=*)
		DIST=${1#*=}
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
excalibur | daedalus | ceres) ;;
*)
	echo "Nicht unterstuetztes Release '$DIST' (erwartet: excalibur, daedalus oder ceres)" >&2
	exit 1
	;;
esac

if [ "$(id -u)" -ne 0 ]; then
	echo "Bitte als root ausfuehren" >&2
	exit 1
fi

if [ ! -e /etc/devuan_version ]; then
	echo "Dies ist kein Devuan-Rechner (/etc/devuan_version fehlt)." >&2
	echo "Debian-ISOs baut build-zfs-live-iso.sh, Devuan baut unter Devuan." >&2
	exit 1
fi

ARCH=$(dpkg --print-architecture)
case "$ARCH" in
amd64)
	GRUBBINS="grub-pc-bin grub-efi-amd64-bin"
	;;
arm64)
	GRUBBINS="grub-efi-arm64-bin"
	;;
*)
	echo "Nur amd64 und arm64 werden unterstuetzt (Rechner: $ARCH)" >&2
	exit 1
	;;
esac

HERE=$(dirname "$(readlink -f "$0")")
INSTALLER=${INSTALLER:-$HERE/devuan_debian-zfs-root.sh}
WORKDIR=${WORKDIR:-$PWD/devuan-zfs-live}
MIRROR=${MIRROR:-http://deb.devuan.org/merged/}

if [ ! -f "$INSTALLER" ]; then
	echo "Installer-Skript nicht gefunden: $INSTALLER" >&2
	exit 1
fi

# Werkzeuge auf dem Bau-Rechner (grub-mkrescue braucht xorriso, mtools und beide GRUB-Pakete)
NEED=
for PKG in debootstrap devuan-keyring squashfs-tools xorriso mtools $GRUBBINS grub-common psmisc; do
	if ! dpkg -s "$PKG" >/dev/null 2>&1; then
		NEED="$NEED $PKG"
	fi
done
if [ -n "$NEED" ]; then
	echo "Installiere fehlende Werkzeuge:$NEED"
	apt-get update
	apt-get install --yes $NEED
fi

# Ein debootstrap ohne Skript fuer das Release (z.B. ceres in einer alten Version) bekommt "sid"
if [ ! -e "/usr/share/debootstrap/scripts/$DIST" ] && [ -e /usr/share/debootstrap/scripts/sid ]; then
	echo "debootstrap kennt '$DIST' nicht, lege Link /usr/share/debootstrap/scripts/$DIST -> sid an"
	ln -s sid "/usr/share/debootstrap/scripts/$DIST"
fi

mkdir -p "$WORKDIR"
WORKDIR=$(readlink -f "$WORKDIR")
CHROOT=$WORKDIR/chroot
IMAGE=$WORKDIR/image
ISO=$WORKDIR/devuan-zfs-live-$ARCH.iso

# Mounts unter dem Chroot loesen (auch Reste eines abgebrochenen Laufs)
unmount_chroot() {
	[ -d "$CHROOT" ] || return 0
	local p m
	for p in /proc/[0-9]*; do
		if [ "$(readlink "$p/root" 2>/dev/null)" = "$CHROOT" ]; then
			echo "Beende Prozess ${p#/proc/} ($(cat "$p/comm" 2>/dev/null)) im Chroot"
			kill "${p#/proc/}" 2>/dev/null || true
		fi
	done
	sleep 1
	awk -v r="$CHROOT/" 'index($2, r) == 1 { print $2 }' /proc/mounts | sort -r |
		while read -r m; do umount -l "$m" 2>/dev/null || true; done
}
unmount_chroot
trap unmount_chroot EXIT

rm -rf "$CHROOT" "$IMAGE" "$ISO"
mkdir -p "$CHROOT" "$IMAGE/live" "$IMAGE/boot/grub"

echo "=== 1. debootstrap $DIST ==="
KEYRING=/usr/share/keyrings/devuan-archive-keyring.gpg
KEYOPT=
if [ -e "$KEYRING" ]; then KEYOPT="--keyring=$KEYRING"; fi
debootstrap --arch="$ARCH" --variant=minbase $KEYOPT \
	--components=main,contrib,non-free-firmware \
	--include=udev,kmod,initramfs-tools,locales,sudo,ca-certificates \
	"$DIST" "$CHROOT" "$MIRROR"

echo "=== 2. Chroot vorbereiten ==="
mount -t proc proc "$CHROOT/proc"
mount -t sysfs sysfs "$CHROOT/sys"
mount --bind /dev "$CHROOT/dev"
mount -t devpts devpts "$CHROOT/dev/pts"
cp /etc/resolv.conf "$CHROOT/etc/resolv.conf"

# Keine Dienste im Chroot starten
cat >"$CHROOT/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
chmod 755 "$CHROOT/usr/sbin/policy-rc.d"

cat >"$CHROOT/etc/apt/sources.list" <<EOF
deb $MIRROR $DIST main contrib non-free-firmware

deb $MIRROR $DIST-security main contrib non-free-firmware

deb $MIRROR $DIST-updates main contrib non-free-firmware
EOF
echo "devuan-zfs-live" >"$CHROOT/etc/hostname"

run_chroot() {
	chroot "$CHROOT" env DEBIAN_FRONTEND=noninteractive LC_ALL=C "$@"
}

run_chroot apt-get update

echo "=== 3. Kernel, Live-Boot und Werkzeuge ==="
# Kernel und Headers zuerst, damit dkms das Modul beim naechsten Schritt gleich baut
run_chroot apt-get install --yes \
	linux-image-$ARCH linux-headers-$ARCH \
	live-boot live-boot-initramfs-tools live-config live-config-sysvinit \
	debootstrap gdisk dosfstools whiptail rsync mdadm lvm2 btrfs-progs parted \
	openssh-server sudo console-setup keyboard-configuration kbd less htop mc smartmontools cryptsetup gddrescue zstd eject \
	ifupdown isc-dhcp-client iproute2 iputils-ping grub-common psmisc

echo "=== 4. ZFS (dkms baut das Modul) ==="
run_chroot apt-get install --yes dkms zfs-dkms zfsutils-linux zfs-zed

# Pruefung: ist das ZFS-Modul wirklich gebaut worden?
run_chroot dkms status
if ! find "$CHROOT/lib/modules" -name 'zfs.ko*' | grep -q .; then
	echo "FEHLER: zfs.ko wurde nicht gebaut (siehe $CHROOT/var/lib/dkms/zfs/*/build/make.log)" >&2
	exit 1
fi
echo "== ZFS-Modul vorhanden =="

echo "=== 5. Installer und Tastaturauswahl ==="
install -m 0755 "$INSTALLER" "$CHROOT/usr/local/bin/debian-zfs-root"
# Rollback der Systemdatasets auf einen Snapshot (neben dem Script, falls vorhanden)
if [ -f "$HERE/zfs-rollback-system" ]; then
	install -m 0755 "$HERE/zfs-rollback-system" "$CHROOT/usr/local/bin/zfs-rollback-system"
fi
if [ -f "$HERE/zfs-chroot-system" ]; then
	install -m 0755 "$HERE/zfs-chroot-system" "$CHROOT/usr/local/bin/zfs-chroot-system"
fi

mkdir -p "$CHROOT/usr/local/bin" "$CHROOT/etc/profile.d"
cat >"$CHROOT/usr/local/bin/select-keyboard" <<'KBEOF'
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
chmod +x "$CHROOT/usr/local/bin/select-keyboard"

cat >"$CHROOT/etc/profile.d/zz-select-keyboard.sh" <<'PROFEOF'
# Einmalige Tastaturauswahl beim ersten Login auf tty1
case $- in
*i*)
	if [ "$(tty 2>/dev/null)" = "/dev/tty1" ] && [ ! -e /run/keyboard-selected ]; then
		/usr/local/bin/select-keyboard
	fi
	;;
esac
PROFEOF

# Netzwerk: Ohne NetworkManager startet rc.local auf jeder Schnittstelle einen DHCP-Client.
cat >"$CHROOT/etc/rc.local" <<'RCEOF'
#!/bin/sh
# Live-System: DHCP auf allen Netzwerkkarten (best effort)
for IF in $(ls /sys/class/net); do
	[ "$IF" = lo ] && continue
	ip link set "$IF" up 2>/dev/null
	dhclient -nw "$IF" 2>/dev/null
done
exit 0
RCEOF
chmod 755 "$CHROOT/etc/rc.local"

# Login: live-config legt beim Start den Benutzer "user" (Passwort "live") an. Zur Sicherheit
# bekommt auch root das Passwort "live", und der Login steht vor der Anmeldung auf dem Bildschirm.
echo "root:live" | run_chroot chpasswd
cat >"$CHROOT/etc/issue" <<'ISSUEEOF'
Devuan ZFS Live  -  Login: user / live   (oder root / live)
Installer: sudo -i ; debian-zfs-root

ISSUEEOF

echo "=== 6. Initramfs, Aufraeumen ==="
run_chroot update-initramfs -u -k all
run_chroot apt-get clean
rm -f "$CHROOT/usr/sbin/policy-rc.d" "$CHROOT/etc/resolv.conf"
rm -rf "$CHROOT/var/lib/apt/lists/"* "$CHROOT/tmp/"*

# Kernel und Initrd fuer das Image
KERNEL=$(ls "$CHROOT"/boot/vmlinuz-* | sort -V | tail -n1)
KVER=${KERNEL##*/vmlinuz-}
cp -v "$KERNEL" "$IMAGE/live/vmlinuz"
cp -v "$CHROOT/boot/initrd.img-$KVER" "$IMAGE/live/initrd.img"

unmount_chroot

echo "=== 7. squashfs ==="
# Kernel und Initrd liegen schon unter live/, im squashfs werden sie ausgelassen
mksquashfs "$CHROOT" "$IMAGE/live/filesystem.squashfs" -noappend -comp xz \
	-wildcards -e 'boot/vmlinuz-*' -e 'boot/initrd.img-*'

echo "=== 8. GRUB-Konfiguration und ISO ==="
cat >"$IMAGE/boot/grub/grub.cfg" <<'GRUBEOF'
set default=0
set timeout=5

menuentry "Devuan ZFS Live" {
	linux /live/vmlinuz boot=live components locales=de_DE.UTF-8 keyboard-layouts=de timezone=Europe/Berlin quiet
	initrd /live/initrd.img
}

menuentry "Devuan ZFS Live (ohne quiet)" {
	linux /live/vmlinuz boot=live components locales=de_DE.UTF-8 keyboard-layouts=de timezone=Europe/Berlin
	initrd /live/initrd.img
}

menuentry "Devuan ZFS Live (im RAM, Medium kann entfernt werden)" {
	linux /live/vmlinuz boot=live components locales=de_DE.UTF-8 keyboard-layouts=de timezone=Europe/Berlin quiet toram
	initrd /live/initrd.img
}
GRUBEOF
if [ "$ARCH" = arm64 ]; then
	# VMs und Boards ohne Grafik: zusaetzlich seriell (ttyAMA0)
	cat >>"$IMAGE/boot/grub/grub.cfg" <<'GRUBEOF'

menuentry "Devuan ZFS Live (serielle Konsole)" {
	linux /live/vmlinuz boot=live components locales=de_DE.UTF-8 keyboard-layouts=de timezone=Europe/Berlin console=tty0 console=ttyAMA0,115200
	initrd /live/initrd.img
}
GRUBEOF
fi

grub-mkrescue -o "$ISO" "$IMAGE" -- -volid DEVUAN_ZFS_LIVE

ls -lh "$ISO"
echo
echo "Fertig. Im gebooteten Live-System (Login: user / live oder root / live): sudo -i; debian-zfs-root"
echo "Hinweis: Das ISO startet mit unsigniertem GRUB, Secure Boot in der VM fuer den Live-Start abschalten."
if [ "$ARCH" = arm64 ]; then echo "arm64: Das ISO bootet nur per UEFI."; fi

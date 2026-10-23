#!/bin/bash
# mkiosroot-macos.sh -- build the SWEET iOS root on macOS.
#
# macOS counterpart of tools/mkiosroot.sh (which needs Linux + apfs-fuse +
# hfsprogs). Uses only Xcode CLT tools: hdiutil, newfs_hfs, rsync, python3.
#
#   sudo ./mkiosroot-macos.sh OS.dmg SYSTEMOS.dmg APPOS.dmg OUT.img [SIZE]
#
#   SIZE defaults to 16G. OUT.img is a sparse raw HFSX (case-sensitive,
#   journaled) volume holding the iOS OS volume plus the two cryptexes, ready
#   for tools/img2simg.py and `fastboot -S 512M flash userdata`.
#
# Which IPSW files to pass (iPhone X / iPhone10,3 / ios 16.7.16 / 20H392,
# from BuildManifest.plist):
#   087-86698-044.dmg  -> OS          (4.73 GB)
#   087-86593-047.dmg  -> SystemOS    (2.74 GB, Cryptex1,SystemOS)
#   087-86715-047.dmg  -> AppOS       (10 MB,   Cryptex1,AppOS)
# (RestoreRamDisk DMGs 087-86622 / 087-86719 are NOT used.)
#
# After this script, run the bring-up tweaks on the mounted volume (the script
# runs them for you if tools/sweet-root-tweaks.py is next to this script):
#   python3 tools/sweet-root-tweaks.py /Volumes/iOSRoot
# then detach and convert:
#   python3 tools/img2simg.py ios16-root.img ios16-root.simg
set -euo pipefail

[[ $# -ge 4 ]] || { sed -n '2,20p' "$0"; exit 2; }
os=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
sysos=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
appos=$(cd "$(dirname "$3")" && pwd)/$(basename "$3")
out=$4
size=${5:-16G}
[[ -e $out ]] && { echo "refusing to overwrite $out" >&2; exit 1; }
[[ $EUID -eq 0 ]] || { echo "run with sudo (needs mount + chown)" >&2; exit 1; }

here=$(cd "$(dirname "$0")" && pwd)
tweaks="$here/sweet-root-tweaks.py"
[[ -f $tweaks ]] || tweaks="$here/../tools/sweet-root-tweaks.py"

work=$(mktemp -d)
mnt="$work/root"
dmounts=()
dev=""
cleanup() {
	set +e
	for m in "${dmounts[@]}"; do
		umount "$m" 2>/dev/null && rmdir "$m" 2>/dev/null
	done
	umount "$mnt" 2>/dev/null && rmdir "$mnt" 2>/dev/null
	[[ -n $dev ]] && hdiutil detach "$dev" >/dev/null 2>&1
	rm -rf "$work"
}
trap cleanup EXIT

# ---- 1. sparse raw file + case-sensitive journaled HFSX -------------------
echo "== creating $out ($size, sparse)"
mkfile -n "$size" "$out"
dev=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$out" |
	awk 'NR==1{print $1}')
echo "== device $dev"
newfs_hfs -s -J -v iOSRoot "$dev"
mkdir -p "$mnt"
mount_hfs "$dev" "$mnt"

# ---- 2. attach the three IPSW images -------------------------------------
attach_dmg() { # file mountpoint
	local f=$1 m=$2
	mkdir -p "$m"
	if ! hdiutil attach "$f" -readonly -nobrowse -mountpoint "$m" >/dev/null 2>&1; then
		# raw APFS cryptex images need to be attached explicitly as raw disks
		hdiutil attach -imagekey diskimage-class=CRawDiskImage "$f" \
			-readonly -nobrowse -mountpoint "$m" >/dev/null
	fi
	dmounts+=("$m")
}
echo "== attaching IPSW images"
attach_dmg "$os" "$work/os"
attach_dmg "$sysos" "$work/sysos"
attach_dmg "$appos" "$work/appos"
for m in "$work/os" "$work/sysos" "$work/appos"; do
	[[ -d $m/root ]] || { echo "no /root under $m" >&2; exit 1; }
done

# ---- 3. copy the volumes together ----------------------------------------
copy() { # src dst
	echo "== copy ${1#"$work/"} -> ${2#"$mnt"}"
	mkdir -p "$2"
	rsync -aH --numeric-ids "$1/" "$2/"
}
copy "$work/os/root" "$mnt"
copy "$work/sysos/root" "$mnt/private/preboot/Cryptexes/OS"
copy "$work/appos/root" "$mnt/private/preboot/Cryptexes/App"

# ---- 4. dyld cache + cryptex hard links (same as mkiosroot.sh) -----------
dsc=private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld
echo "== linking dyld shared cache"
mkdir -p "$mnt/System/Library/Caches/com.apple.dyld"
for f in "$mnt/$dsc"/*; do
	[[ -e $f ]] || continue
	ln "$f" "$mnt/System/Library/Caches/com.apple.dyld/$(basename "$f")" 2>/dev/null || \
	cp -P "$f" "$mnt/System/Library/Caches/com.apple.dyld/$(basename "$f")"
done

echo "== linking cryptex files missing from the OS root"
for c in OS App; do
	(cd "$mnt/private/preboot/Cryptexes/$c" &&
	 find . ! -type d ! -path './System/Library/Caches/com.apple.dyld/*') |
	while IFS= read -r f; do
		f=${f#./}
		if [[ ! -e $mnt/$f && ! -L $mnt/$f ]]; then
			mkdir -p "$mnt/$(dirname "$f")"
			src="$mnt/private/preboot/Cryptexes/$c/$f"
			if [[ -L $src ]]; then cp -P "$src" "$mnt/$f"; else ln "$src" "$mnt/$f"; fi
		fi
	done
done

# ---- 5. logd stores + system keybag (same as mkiosroot.sh) ---------------
echo "== logd stores / keybag"
db="$mnt/private/var/db"
mkdir -p "$db"
install -d -o 272 -g 272 -m 0751 "$db/diagnostics"
install -d -o 272 -g 272 -m 0755 "$db/uuidtext" "$db/diagnostics/timesync"
for d in diagnostics uuidtext diagnostics/timesync; do
	install -o 272 -g 272 -m 0644 /dev/null "$db/$d/.migrated"
done
install -d -m 0700 -o 0 -g 0 "$mnt/private/var/keybags"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
	'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	'<plist version="1.0"><dict><key>KeyBagKeys</key><data>U1dFRVQ=</data></dict></plist>' |
	install -m 0600 -o 0 -g 0 /dev/stdin "$mnt/private/var/keybags/systembag.kb"

# ---- 6. bring-up tweaks (Setup skip, activation, launchd, daemons) -------
if [[ -f $tweaks ]]; then
	echo "== sweet-root-tweaks.py"
	python3 "$tweaks" "$mnt"
else
	echo "WARNING: sweet-root-tweaks.py not found; run it manually on the mounted volume" >&2
fi

# ---- 7. finish ------------------------------------------------------------
df -h "$mnt" || true
sync
umount "$mnt" || umount -f "$mnt"
rmdir "$mnt"
hdiutil detach "$dev" >/dev/null
dev=""

# HFS+ journal replay check (fsck_hfs may "repair" the journal; that is fine)
fsck_hfs -f -y "$out" 2>&1 | tail -3 || true
fsck_hfs -f -n "$out" 2>&1 | tail -3 || true

echo
echo "DONE: $out"
echo "next: python3 $(dirname "$0")/img2simg.py $out ${out%.img}.simg"

#!/bin/bash
# flash-and-boot.sh -- flash the iOS root to userdata and boot the shim, on macOS
# (or Linux) with android-platform-tools installed.
#
#   ./flash-and-boot.sh ios16-root.simg shim-ios-full.img
#
# WARNING: `fastboot flash userdata` ERASES the Android data partition.
# The script asks for confirmation and prints what to back up first.
set -euo pipefail

IMG=${1:-ios16-root.simg}
SHIM=${2:-shim-ios-full.img}
[[ -f $IMG ]] || { echo "missing $IMG" >&2; exit 2; }
[[ -f $SHIM ]] || { echo "missing $SHIM" >&2; exit 2; }

command -v fastboot >/dev/null || {
	echo "fastboot not found: brew install android-platform-tools" >&2
	exit 2
}

cat <<'EOF'
This will:
  1. check the phone is in fastboot
  2. flash the HFSX iOS root to the userdata partition  (ERASES ANDROID DATA)
  3. fastboot boot the shim (no other partition is written)

Before continuing, make sure you have:
  - backed up what you need from Android (photos etc.)
  - saved `fastboot getvar all` output (serial, product)
  - a MIUI fastboot ROM available if you want Android back later
EOF
read -r -p "Type EXACTLY 'erase userdata' to continue: " ans
[[ $ans == "erase userdata" ]] || { echo "aborted"; exit 1; }

fastboot devices
echo "== flashing $IMG (this takes ~7 minutes, do not unplug)"
fastboot -S 512M flash userdata "$IMG"

echo "== booting $SHIM"
fastboot boot "$SHIM"

cat <<'EOF'
Done. Expected sequence on the phone:
  - first boot: Apple logo for ~4-5 minutes (be patient)
  - then the lock screen; swipe up to unlock
If fastboot hangs after the large flash: hold Power+VolumeDown to re-enter
fastboot, then run:  fastboot boot <shim-img>
Kernel log: boot OrangeFox recovery and run tools/sweet-log-pull.sh logs/boot.txt
EOF

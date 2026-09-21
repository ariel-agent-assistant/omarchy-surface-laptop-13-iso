#!/bin/bash
# Surface Laptop 13 (Snapdragon X1P42100, SKU 2095)
# Runs on the INSTALLED system as root (rescue console is fine).
# 1) Prints 3 diagnostics that explain the black panel.
# 2) Builds a direct systemd-stub UKI (kernel + initramfs + patched Surface DTB
#    + clean cmdline) and schedules it for the NEXT BOOT ONLY via BootNext.
# Limine stays untouched as the automatic fallback.
set -Eeuo pipefail
trap 'rc=$?; set +x; echo; echo "##### DIRECT-UKI FAILED (rc=$rc) - PHOTO THIS SCREEN #####"; exit $rc' ERR

ESP=/boot
[ -d "$ESP/EFI" ] || { echo "ESP not mounted at /boot"; exit 1; }

echo '================ DIAGNOSTICS (photo this) ================'
echo '-- 1. live kernel device tree keep-edp properties (want 2 lines):'
find /proc/device-tree -name '*keep*' 2>/dev/null || true
echo '-- 2. keep-edp strings inside current UKI (want a number above 0):'
strings "$ESP/EFI/Linux/omarchy_linux-aarch64.efi" 2>/dev/null | grep -c 'keep' || echo 0
echo '-- 3. patched DTB on ESP:'
ls -la "$ESP/dtbs/qcom/" 2>/dev/null || echo 'MISSING /boot/dtbs/qcom'
echo '=========================================================='
set -x

# --- components ---
DTB="$ESP/dtbs/qcom/x1p42100-microsoft-surface-laptop-13.dtb"
[ -s "$DTB" ]
strings "$DTB" | grep -q 'microsoft,surface-laptop-13-2095'
strings "$DTB" | grep -q 'keep-edp-active-on-blank'
strings "$DTB" | grep -q 'keep-panel-prepared-on-disable'

KIMG=$(find "$ESP" -maxdepth 3 -type f \( -name 'Image' -o -name 'Image.gz' -o -name 'vmlinuz*' \) 2>/dev/null | head -n1)
INITRD=$(find "$ESP" -maxdepth 3 -type f -name 'initramfs-linux*.img' ! -name '*fallback*' 2>/dev/null | head -n1)
[ -s "$KIMG" ] && [ -s "$INITRD" ] || { echo "kernel/initramfs not found on ESP"; ls -la "$ESP"; exit 1; }

CMDLINE=$(sed -E 's/(^| )(nomodeset|msm\.modeset=0|plymouth\.enable=0|rd\.plymouth=0|quiet|splash|loglevel=[0-9]+|rd\.udev\.log_level=[0-9]+|systemd\.show_status=[a-z]+)( |$)/ /g; s/[[:space:]]+/ /g; s/^ //; s/ $//' /etc/kernel/cmdline)
CMDLINE="$CMDLINE ignore_loglevel drm.debug=0x117"

[ -n "$CMDLINE" ]
printf '%s\n' "$CMDLINE" > /tmp/direct-uki-cmdline

UKIFY=
for p in /usr/lib/systemd/ukify /usr/bin/ukify; do [ -x "$p" ] && UKIFY=$p && break; done
[ -n "$UKIFY" ] || { echo 'ukify missing (systemd-ukify should be installed)'; exit 1; }

OUT="$ESP/EFI/Linux/surface-direct.efi"
NEEDED=$(( $(stat -c %s "$KIMG") + $(stat -c %s "$INITRD") + $(stat -c %s "$DTB") + 16777216 ))
AVAIL=$(df -B1 --output=avail "$ESP" | tail -n1 | tr -d ' ')
[ "$AVAIL" -gt "$NEEDED" ] || { echo "ESP needs $NEEDED free bytes, has $AVAIL"; exit 1; }

"$UKIFY" build \
  --linux "$KIMG" \
  --initrd "$INITRD" \
  --devicetree "$DTB" \
  --cmdline "$CMDLINE" \
  --output "$OUT"
[ -s "$OUT" ]

# --- one-shot firmware boot entry ---
SRC=$(findmnt -n -o SOURCE "$ESP")            # e.g. /dev/sda1
DISK=/dev/$(lsblk -n -o PKNAME "$SRC")
PART=$(lsblk -n -o PARTN "$SRC")
efibootmgr --create --disk "$DISK" --part "$PART" \
  --label 'Omarchy Surface Direct' \
  --loader '\EFI\Linux\surface-direct.efi'
BN=$(efibootmgr | awk '/Omarchy Surface Direct/{gsub(/Boot|\*/,"",$1); print $1; exit}')
[ -n "$BN" ]
efibootmgr --bootnext "$BN"
set +x
echo
echo '################## DIRECT UKI READY ##################'
echo "# BootNext = $BN (one boot only). Limine stays default."
echo '# Now type:  reboot'
echo '# PANEL LIGHTS (login screen)  -> photo it.'
echo '# STILL BLACK ~60s             -> hold power 10s. The next'
echo '# boot automatically returns to Limine (your console entry'
echo '# keeps working). Photo nothing, just report black.'
echo '######################################################'

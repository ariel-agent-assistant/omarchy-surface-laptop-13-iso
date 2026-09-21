#!/bin/bash
# Surface Laptop 13 (X1P42100, SKU 2095) - direct systemd-stub UKI builder v3.
# v3: esplog mkinitcpio hook (dmesg -> /blackboot.log on the ESP from early
#     initramfs), objcopy initrd fallback, efibootmgr skipped when EFI
#     runtime variables are unavailable (use the limine menu entry instead).
set -Eeuo pipefail
trap 'rc=$?; set +x; echo; echo "##### DIRECT-UKI FAILED (rc=$rc) - PHOTO THIS SCREEN #####"; exit $rc' ERR

ESP=/boot
[ -d "$ESP/EFI" ] || { echo "ESP not mounted at /boot"; exit 1; }

echo '================ DIAGNOSTICS (photo this) ================'
echo '-- 1. live kernel device tree keep-edp properties (want 2 lines):'
find /proc/device-tree -name '*keep*' 2>/dev/null || true
echo '-- 2. keep-edp strings inside current limine UKI (above 0 = patched DTB embedded):'
strings "$ESP/EFI/Linux/omarchy_linux-aarch64.efi" 2>/dev/null | grep -c 'keep' || echo 0
echo '-- 3. patched DTB on ESP:'
ls -la "$ESP/dtbs/qcom/" 2>/dev/null || echo 'MISSING /boot/dtbs/qcom'
echo '=========================================================='
set -x

DTB="$ESP/dtbs/qcom/x1p42100-microsoft-surface-laptop-13.dtb"
[ -s "$DTB" ]
strings "$DTB" | grep 'microsoft,surface-laptop-13-2095' >/dev/null
strings "$DTB" | grep 'keep-edp-active-on-blank' >/dev/null
strings "$DTB" | grep 'keep-panel-prepared-on-disable' >/dev/null

KIMG=$(find "$ESP" -maxdepth 3 -type f \( -name 'Image' -o -name 'Image.gz' -o -name 'vmlinuz*' \) -print -quit 2>/dev/null)
INITRD=$(find "$ESP" -maxdepth 3 -type f -name 'initramfs-linux*.img' ! -name '*fallback*' -print -quit 2>/dev/null)
if [ -z "$INITRD" ] || [ ! -s "$INITRD" ]; then
  CUR=$(find "$ESP/EFI/Linux" -maxdepth 1 -type f -name 'omarchy_linux-aarch64*.efi' -print -quit)
  [ -s "$CUR" ]
  objcopy -O binary --only-section=.initrd "$CUR" "$ESP/initramfs-linux.img"
  INITRD="$ESP/initramfs-linux.img"
fi
[ -s "$KIMG" ] && [ -s "$INITRD" ] || { echo "kernel/initramfs not found"; ls -la "$ESP"; exit 1; }

# --- esplog hook: continuous dmesg -> ESP blackboot.log from early initramfs ---
cat > /etc/initcpio/install/esplog <<'H1'
build() {
    add_module vfat
    add_module nls_cp437
    add_module nls_iso8859-1
    add_runscript
}
help() { echo 'dmesg logger to ESP blackboot.log'; }
H1
cat > /etc/initcpio/hooks/esplog <<'H2'
run_earlyhook() {
    local i
    mkdir -p /esplog
    for i in 1 2 3 4 5 6 7 8 9 10; do
        [ -b /dev/sda1 ] && break
        sleep 1
    done
    if mount -t vfat -o rw /dev/sda1 /esplog 2>/dev/null; then
        ( while :; do dmesg > /esplog/blackboot.log 2>/dev/null; sync; sleep 1; done ) &
        echo 'esplog: writing /blackboot.log on ESP'
    else
        echo 'esplog: ESP mount FAILED'
    fi
}
H2
grep -q 'esplog' /etc/mkinitcpio.conf || sed -i 's/\bencrypt\b/esplog encrypt/' /etc/mkinitcpio.conf
grep -q 'esplog' /etc/mkinitcpio.conf || { echo 'HOOKS has no encrypt token - PHOTO this:'; grep '^HOOKS' /etc/mkinitcpio.conf; exit 1; }
mkinitcpio -P
INITRD="$ESP/initramfs-linux.img"
[ -s "$INITRD" ]

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

mount -t efivarfs efivarfs /sys/firmware/efi/efivars 2>/dev/null || true
if efibootmgr -v >/dev/null 2>&1; then
  SRC=$(findmnt -n -o SOURCE "$ESP")
  DISK=/dev/$(lsblk -n -o PKNAME "$SRC")
  PART=$(lsblk -n -o PARTN "$SRC")
  efibootmgr --create --disk "$DISK" --part "$PART" \
    --label 'Omarchy Surface Direct' \
    --loader '\EFI\Linux\surface-direct.efi'
  BN=$(efibootmgr | awk '/Omarchy Surface Direct/{gsub(/Boot|\*/,"",$1); print $1}' | sed -n '1p')
  [ -n "$BN" ] && efibootmgr --bootnext "$BN" && echo "BootNext=$BN"
else
  echo 'NOTE: no EFI runtime vars here - boot via the limine menu entry "/Surface Direct".'
fi
set +x
echo
echo '################## DIRECT UKI v3 READY ##################'
echo '# Reboot, pick "/Surface Direct" in the limine menu.'
echo '# PANEL LIGHTS  -> photo.'
echo '# BLACK         -> power hold 10s, console boot, then:'
echo '#   tail -80 /boot/blackboot.log    (photo)'
echo '# No blackboot.log file = kernel died before initramfs.'
echo '# Log ending at the LUKS prompt = boot fine, input dead.'
echo '#########################################################'

#!/bin/bash
# Surface Laptop 13 (X1P42100, SKU 2095) - DT-bisect UKIs for the msm hang.
# Builds TWO extra limine entries, each a full-msm debug boot with ONE
# display node disabled in the DT, to bracket which subsystem kills boot:
#
#   /Surface Bisect NoPanel : aux-bus panel node disabled.
#       DPU + DP controller + eDP PHY still probe and power up; the panel
#       driver (prepare/power sequencing) never runs.
#   /Surface Bisect NoDP    : displayport-controller@aea0000 disabled.
#       DPU probes alone; no DP, no PHY, no panel at all.
#
# Both reuse the esplog-enabled initramfs extracted from
# surface-debug-log.efi when present, so they also dump dmesg to the ESP.
# Cmdline matches the debug-log entry (full msm, verbose, panic=30) plus a
# per-variant tag (s13bisect=...) so photos/logs are attributable.
#
# Default console entry untouched. Run as root on the installed system.
set -Eeuo pipefail
trap 'rc=$?; set +x; echo; echo "##### BISECT BUILD FAILED (rc=$rc) - PHOTO THIS SCREEN #####"; exit $rc' ERR

ESP=/boot
[ -d "$ESP/EFI" ] || { echo "ESP not mounted at /boot"; exit 1; }
command -v dtc >/dev/null 2>&1 || pacman -Sy --noconfirm dtc
set -x

BASE_DTB="$ESP/dtbs/qcom/x1p42100-microsoft-surface-laptop-13.dtb"
[ -s "$BASE_DTB" ]
strings "$BASE_DTB" | grep -q 'microsoft,surface-laptop-13-2095'

KIMG=$(find "$ESP" -maxdepth 3 -type f \( -name 'Image' -o -name 'Image.gz' -o -name 'vmlinuz*' \) -print -quit 2>/dev/null)
[ -s "$KIMG" ] || { echo "kernel image not found"; ls -la "$ESP"; exit 1; }

# initramfs: prefer the esplog-enabled one baked into surface-debug-log.efi
INITRD=/tmp/bisect-initramfs.img
if [ -s "$ESP/EFI/Linux/surface-debug-log.efi" ]; then
  objcopy -O binary --only-section=.initrd "$ESP/EFI/Linux/surface-debug-log.efi" "$INITRD"
else
  SRC=$(find "$ESP" -maxdepth 3 -type f -name 'initramfs-linux*.img' ! -name '*fallback*' -print -quit 2>/dev/null)
  if [ -n "$SRC" ] && [ -s "$SRC" ]; then
    cp "$SRC" "$INITRD"
  else
    CUR=$(find "$ESP/EFI/Linux" -maxdepth 1 -type f -name 'omarchy_linux-aarch64*.efi' -print -quit)
    [ -s "$CUR" ]
    objcopy -O binary --only-section=.initrd "$CUR" "$INITRD"
  fi
fi
[ -s "$INITRD" ]

CMDLINE_BASE=$(sed -E 's/(^| )(nomodeset|msm\.modeset=0|plymouth\.enable=0|rd\.plymouth=0|quiet|splash|loglevel=[0-9]+|rd\.udev\.log_level=[0-9]+|systemd\.show_status=[a-z]+|initcall_blacklist=[^ ]+)( |$)/ /g; s/[[:space:]]+/ /g; s/^ //; s/ $//' /etc/kernel/cmdline)
[ -n "$CMDLINE_BASE" ]
DEBUG="loglevel=8 ignore_loglevel initcall_debug drm.debug=0x117 panic=30 panic_on_oops=1"

UKIFY=
for p in /usr/lib/systemd/ukify /usr/bin/ukify; do [ -x "$p" ] && UKIFY=$p && break; done
[ -n "$UKIFY" ] || { echo 'ukify missing'; exit 1; }

# ESP space for two UKIs
NEEDED=$(( ($(stat -c %s "$KIMG") + $(stat -c %s "$INITRD") + $(stat -c %s "$BASE_DTB") + 16777216) * 2 ))
AVAIL=$(df -B1 --output=avail "$ESP" | tail -n1 | tr -d ' ')
[ "$AVAIL" -gt "$NEEDED" ] || { echo "ESP needs $NEEDED free bytes, has $AVAIL"; exit 1; }

W=/tmp/bisect-dts
rm -rf "$W"; mkdir -p "$W"
dtc -I dtb -O dts -o "$W/base.dts" "$BASE_DTB" 2>/dev/null

# sanity: exactly one aux-bus panel node; aea0000 present
[ "$(grep -c '^[[:space:]]*panel {$' "$W/base.dts")" = 1 ]
grep -q 'displayport-controller@aea0000 {' "$W/base.dts"

# --- variant 1: panel disabled ---
sed '/^[[:space:]]*panel {$/a\\t\t\t\t\t\tstatus = "disabled";' "$W/base.dts" > "$W/nopanel.dts"
[ "$(diff "$W/base.dts" "$W/nopanel.dts" | grep -c '^>')" = 1 ]
[ "$(diff "$W/base.dts" "$W/nopanel.dts" | grep -c '^<')" = 0 ]
dtc -I dts -O dtb -q -o "$W/nopanel.dtb" "$W/nopanel.dts" 2>/dev/null
dtc -I dtb -O dts "$W/nopanel.dtb" 2>/dev/null | sed -n '/panel {/,/};/p' | grep -q 'status = "disabled"'

# --- variant 2: dp controller disabled ---
sed '/displayport-controller@aea0000 {/,/^\t\t\t};$/ s/status = "okay";/status = "disabled";/' "$W/base.dts" > "$W/nodp.dts"
[ "$(diff "$W/base.dts" "$W/nodp.dts" | grep -c '^<')" = 1 ]
[ "$(diff "$W/base.dts" "$W/nodp.dts" | grep -c '^>')" = 1 ]
dtc -I dts -O dtb -q -o "$W/nodp.dtb" "$W/nodp.dts" 2>/dev/null
V=$(dtc -I dtb -O dts "$W/nodp.dtb" 2>/dev/null | sed -n '/displayport-controller@aea0000 {/,/^\t\t\t};$/p')
echo "$V" | grep -q 'status = "disabled"'
! echo "$V" | grep -q 'status = "okay"'

# --- build both UKIs ---
"$UKIFY" build --linux "$KIMG" --initrd "$INITRD" --devicetree "$W/nopanel.dtb" \
  --cmdline "$CMDLINE_BASE $DEBUG s13bisect=nopanel" \
  --output "$ESP/EFI/Linux/surface-bisect-nopanel.efi"
"$UKIFY" build --linux "$KIMG" --initrd "$INITRD" --devicetree "$W/nodp.dtb" \
  --cmdline "$CMDLINE_BASE $DEBUG s13bisect=nodp" \
  --output "$ESP/EFI/Linux/surface-bisect-nodp.efi"
[ -s "$ESP/EFI/Linux/surface-bisect-nopanel.efi" ]
[ -s "$ESP/EFI/Linux/surface-bisect-nodp.efi" ]

grep -q 'Surface Bisect NoPanel' "$ESP/limine.conf" || printf '\n/Surface Bisect NoPanel\n    protocol: efi\n    path: boot():/EFI/Linux/surface-bisect-nopanel.efi\n' >> "$ESP/limine.conf"
grep -q 'Surface Bisect NoDP' "$ESP/limine.conf" || printf '\n/Surface Bisect NoDP\n    protocol: efi\n    path: boot():/EFI/Linux/surface-bisect-nodp.efi\n' >> "$ESP/limine.conf"

set +x
echo
echo '################# BISECT UKIS READY #################'
echo '# Two new limine entries: /Surface Bisect NoPanel,'
echo '# /Surface Bisect NoDP. Black screen is EXPECTED even on'
echo '# success - success = machine stays ALIVE (SSH comes back).'
echo '#'
echo '# Per entry: boot it, wait ~90s.'
echo '#  - frozen text/panic -> photo, power off (or panic=30'
echo '#    auto-reboots)'
echo '#  - LUKS prompt       -> SURVIVED probe; passphrase, then'
echo '#    SSH in for dmesg'
echo '# After each dead test, boot the default entry and copy'
echo '# /boot/esplog-alive.txt aside BEFORE the next test boot'
echo '# (the hook overwrites it every boot).'
echo '#####################################################'

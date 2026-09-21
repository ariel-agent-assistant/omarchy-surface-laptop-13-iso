#!/bin/bash
# Surface Laptop 13 (X1P42100, SKU 2095) - "photo the dying kernel" UKI.
#
# Why this works: the death is inside the built-in msm probe, BEFORE the
# initramfs runs (proven: ESP-logging hook never fired). No logging to disk,
# netconsole, or SSH is possible that early - but the PANEL ITSELF is a
# working kernel console here (CONFIG_FB_EFI=y + FRAMEBUFFER_CONSOLE=y).
# So we boot the FULL msm modeset path with maximum kernel verbosity and
# let the panel show its own dying words. Photo the final frozen frame.
#
# Outcomes:
#   A) Panel scrolls kernel text, then FREEZES  -> photo the frozen frame.
#      The last lines name the dying subsystem (msm/dpu/dp/phy/panel/...).
#      Power-hold 10s: default console entry comes back (msm.modeset=0).
#   B) Panel shows a panic backtrace            -> photo it. Machine
#      auto-reboots after 30s back to the safe default entry.
#   C) LUKS passphrase prompt appears           -> msm probe SURVIVED.
#      Type the passphrase; the boot continues (likely to sddm/desktop).
#   D) Screen black with NO kernel text at all  -> efifb/panel died at or
#      before the modeset kick. Different bug class; report "black-no-text".
#
# This script only ADDS a limine entry. The default entry (visible console)
# stays untouched. Zero risk to the working boot path.
set -Eeuo pipefail
trap 'rc=$?; set +x; echo; echo "##### PHOTO-UKI SETUP FAILED (rc=$rc) - PHOTO THIS SCREEN #####"; exit $rc' ERR

ESP=/boot
[ -d "$ESP/EFI" ] || { echo "ESP not mounted at /boot"; exit 1; }
set -x

DTB="$ESP/dtbs/qcom/x1p42100-microsoft-surface-laptop-13.dtb"
[ -s "$DTB" ]
strings "$DTB" | grep 'microsoft,surface-laptop-13-2095' >/dev/null

KIMG=$(find "$ESP" -maxdepth 3 -type f \( -name 'Image' -o -name 'Image.gz' -o -name 'vmlinuz*' \) -print -quit 2>/dev/null)
INITRD=$(find "$ESP" -maxdepth 3 -type f -name 'initramfs-linux*.img' ! -name '*fallback*' -print -quit 2>/dev/null)
if [ -z "$INITRD" ] || [ ! -s "$INITRD" ]; then
  CUR=$(find "$ESP/EFI/Linux" -maxdepth 1 -type f -name 'omarchy_linux-aarch64*.efi' -print -quit)
  [ -s "$CUR" ]
  objcopy -O binary --only-section=.initrd "$CUR" "$ESP/initramfs-linux.img"
  INITRD="$ESP/initramfs-linux.img"
fi
[ -s "$KIMG" ] && [ -s "$INITRD" ] || { echo "kernel/initramfs not found"; ls -la "$ESP"; exit 1; }

# Base cmdline with ALL display/verbosity suppressors stripped, then:
#  loglevel=8 ignore_loglevel initcall_debug  - every printk reaches fbcon,
#      and every initcall is announced (pins the dying one exactly)
#  drm.debug=0x117                            - CORE|DRIVER|KMS|ATOMIC|DP trace
#  panic=30 panic_on_oops=1                   - crash = readable backtrace,
#      30s to photo, then SELF-RECOVERY reboot into the safe default entry
#  NO msm.modeset=0                           - the whole point: full msm probe
CMDLINE=$(sed -E 's/(^| )(nomodeset|msm\.modeset=0|plymouth\.enable=0|rd\.plymouth=0|quiet|splash|loglevel=[0-9]+|rd\.udev\.log_level=[0-9]+|systemd\.show_status=[a-z]+|initcall_blacklist=[^ ]+)( |$)/ /g; s/[[:space:]]+/ /g; s/^ //; s/ $//' /etc/kernel/cmdline)
CMDLINE="$CMDLINE loglevel=8 ignore_loglevel initcall_debug drm.debug=0x117 panic=30 panic_on_oops=1"
[ -n "$CMDLINE" ]
printf '%s\n' "$CMDLINE" > /tmp/photo-uki-cmdline
echo "final cmdline: $CMDLINE"

UKIFY=
for p in /usr/lib/systemd/ukify /usr/bin/ukify; do [ -x "$p" ] && UKIFY=$p && break; done
[ -n "$UKIFY" ] || { echo 'ukify missing'; exit 1; }

OUT="$ESP/EFI/Linux/surface-debug-photo.efi"
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

grep -q 'Surface Debug Photo' "$ESP/limine.conf" || printf '\n/Surface Debug Photo\n    protocol: efi\n    path: boot():/EFI/Linux/surface-debug-photo.efi\n' >> "$ESP/limine.conf"

set +x
echo
echo '################ PHOTO UKI READY ################'
echo '# reboot, pick:  /Surface Debug Photo'
echo '#'
echo '# Text will SCROLL FAST - that is normal. Wait for it to'
echo '# stop moving, then PHOTOGRAPH the final frame.'
echo '#'
echo '#  frozen scrolling text  -> photo, then power-hold 10s'
echo '#  panic backtrace        -> photo; it self-reboots in 30s'
echo '#  LUKS password prompt   -> SUCCESS, type the passphrase'
echo '#  pure black, no text    -> report "black-no-text"'
echo '#'
echo '# Default console entry stays safe either way.'
echo '#################################################'

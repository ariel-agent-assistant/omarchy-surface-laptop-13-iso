#!/bin/bash
# unwedge.sh - un-wedge the Kioxia UFS on Surface Laptop 13 (archiso live env).
# Usage: curl -L <raw-url> | bash   (as root)
# Photo-readable output throughout; safe to run more than once.

say() { printf '\n===== %s =====\n' "$*"; }

DRV=/sys/bus/platform/drivers/ufshcd-qcom
if [ ! -d "$DRV" ]; then
  cand=$(ls /sys/bus/platform/drivers/ 2>/dev/null | grep -i ufs | head -n1)
  [ -n "$cand" ] && DRV=/sys/bus/platform/drivers/$cand
fi
HOST=1d84000.ufshc
if [ ! -e "$DRV/$HOST" ]; then
  h=$(ls "$DRV" 2>/dev/null | grep -i ufshc | head -n1)
  [ -n "$h" ] && HOST=$h
fi
say "driver: $DRV   host: $HOST"

try_mount() { mount /dev/sda1 /mnt; }
bounce()  { echo "$HOST" > "$DRV/unbind" && sleep 3 && echo "$HOST" > "$DRV/bind" && sleep 4; }

ok=
say "STEP 1: bounce the UFS host, then mount"
if bounce && try_mount; then ok=1; fi

if [ -z "$ok" ]; then
  say "STEP 2: delete the half-probed disk, re-probe, mount"
  [ -e /sys/block/sda/device/delete ] && echo 1 > /sys/block/sda/device/delete
  sleep 2
  echo "$HOST" > "$DRV/bind"
  sleep 4
  blockdev --rereadpt /dev/sda 2>/dev/null
  sleep 1
  if try_mount; then ok=1; fi
fi

printf '\n'
if [ -n "$ok" ]; then
  echo '##########################################'
  echo '#   SUCCESS - DISK UNWEDGED AND MOUNTED  #'
  echo '##########################################'
  say "ESP file list (photo this)"
  find /mnt -type f | head -40
  say "/mnt/limine.conf (photo this)"
  cat /mnt/limine.conf
else
  echo '##########################################'
  echo '#  STILL WEDGED - PHOTO THE WHOLE SCREEN #'
  echo '##########################################'
fi
say "/proc/cmdline (photo this)"
cat /proc/cmdline

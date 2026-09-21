#!/bin/bash
# Surface Laptop 13 display-hang diagnostics, round 1 (run over SSH as root).
# Collects, then uploads its own output to paste.rs and prints the link.
OUT=/tmp/s13-diag-1.txt
: > "$OUT"
command -v dtc >/dev/null 2>&1 || pacman -Sy --noconfirm dtc >/dev/null 2>&1
mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null
{
echo '===== uname -a ====='; uname -a
echo; echo '===== /proc/cmdline ====='; cat /proc/cmdline
echo; echo '===== /etc/kernel/cmdline ====='; cat /etc/kernel/cmdline 2>/dev/null
echo; echo '===== DT model / compatible ====='
tr '\0' '\n' < /proc/device-tree/model 2>/dev/null
tr '\0' '\n' < /proc/device-tree/compatible 2>/dev/null
echo; echo '===== keep-edp properties in LIVE dt (want 2 paths) ====='
find /proc/device-tree -name '*keep*' 2>/dev/null
echo; echo '===== /sys/class/drm ====='; ls -la /sys/class/drm 2>/dev/null
echo; echo '===== /sys/class/backlight ====='; ls -la /sys/class/backlight 2>/dev/null
echo; echo '===== fb0 state (efifb) ====='
for f in name modes state virtual_size; do echo "-- $f:"; cat "/sys/class/graphics/fb0/$f" 2>/dev/null; done
echo; echo '===== platform devices (display-ish) ====='
ls /sys/bus/platform/devices 2>/dev/null | grep -iE 'ae0000|display|edp|pwm|backlight|spmi|pmic'
echo; echo '===== devlinks involving display/panel/regulators ====='
for d in /sys/class/devlink/*; do
  tgt=$(readlink "$d" 2>/dev/null)
  case "$tgt" in
    *display*|*panel*|*regulator*|*phy*|*pwm*|*backlight*|*spm*|*pmic*)
      echo "$d -> $tgt"; echo -n '   status: '; cat "$d/status" 2>/dev/null;;
  esac
done
echo; echo '===== ALL devlink count by status ====='
for d in /sys/class/devlink/*/status; do cat "$d" 2>/dev/null; done | sort | uniq -c
echo; echo '===== regulator summary ====='
cat /sys/kernel/debug/regulator/regulator_summary 2>/dev/null || echo 'regulator_summary unavailable'
echo; echo '===== dmesg: display/power/cycle lines ====='
dmesg 2>/dev/null | grep -iE 'msm|dpu|drm|edp|panel|dsi|backlight|pwm|regulator|spmi|pmic|cycle|deferr'
echo; echo '===== FULL live device tree (dtc decompile) ====='
if command -v dtc >/dev/null 2>&1; then
  dtc -I fs -O dts /proc/device-tree 2>/dev/null || echo 'dtc decompile failed'
else
  echo 'dtc unavailable'
fi
echo; echo '===== FULL dmesg ====='
dmesg 2>/dev/null
} >> "$OUT" 2>&1
echo "collected $(wc -l < "$OUT") lines"
LINK=$(curl -fsS --data-binary @"$OUT" https://paste.rs 2>/dev/null || true)
echo
echo '################ DIAG LINK ################'
if [ -n "$LINK" ]; then
  echo "$LINK"
else
  echo "UPLOAD FAILED - file is at $OUT (scp it out)"
fi
echo '###########################################'

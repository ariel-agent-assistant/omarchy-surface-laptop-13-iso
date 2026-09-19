#!/bin/bash
# surface13-repair.sh - unattended post-install display fix for Surface Laptop 13.
# Runs once at live-ISO boot, logs every step with [OK]/[FAIL], ends in a
# SUCCESS/FAIL banner and holds the console. No interaction, no reboot.

exec > >(tee -a /run/surface13-repair.log) 2>&1
set -u
OVERALL=ok

say()  { printf '\n=== %s ===\n' "$*"; }
ok()   { printf '[OK] %s\n' "$*"; }
bad()  { printf '[FAIL] %s\n' "$*"; OVERALL=fail; }

say "Surface Laptop 13 repair - $(date)"

# --- 1. Revive the UFS host (Kioxia THGJFMT1E45BATVB fails in MCQ mode) ----
say "1/7 UFS revive"
echo 0 > /sys/module/ufshcd_core/parameters/use_mcq_mode \
  && ok "use_mcq_mode=0" || bad "could not write use_mcq_mode"
echo 1d84000.ufshc > /sys/bus/platform/drivers/ufshcd-qcom/unbind \
  && ok "unbind 1d84000.ufshc" || bad "unbind failed"
sleep 2
echo 1d84000.ufshc > /sys/bus/platform/drivers/ufshcd-qcom/bind \
  && ok "bind 1d84000.ufshc" || bad "bind failed"
for i in $(seq 1 30); do [ -b /dev/sda ] && break; sleep 1; done
if [ -b /dev/sda ]; then ok "/dev/sda present"; else bad "/dev/sda never appeared"; fi

# --- 2. Mount root + ESP ----------------------------------------------------
say "2/7 Mounts"
ROOTP=/dev/sda2; ESPP=/dev/sda1
[ "$(blkid -o value -s TYPE $ROOTP 2>/dev/null)" = "btrfs" ] || ROOTP=""
[ "$(blkid -o value -s TYPE $ESPP 2>/dev/null)" = "vfat" ]  || ESPP=""
if [ -z "$ROOTP" ]; then
  ROOTP=$(lsblk -lnpo NAME,FSTYPE | awk '$2=="btrfs"{print $1; exit}')
fi
if [ -z "$ESPP" ]; then
  ESPP=$(lsblk -lnpo NAME,FSTYPE | awk '$2=="vfat"{print $1; exit}')
fi
echo "root: ${ROOTP:-none}  esp: ${ESPP:-none}"
mkdir -p /mnt
mount "$ROOTP" /mnt && ok "root mounted at /mnt" || bad "root mount failed"
mount "$ESPP" /mnt/boot && ok "ESP mounted at /mnt/boot" || bad "ESP mount failed"
if [ ! -f /mnt/boot/limine.conf ] || [ ! -d /mnt/etc/mkinitcpio.conf.d ]; then
  bad "target layout not recognized (limine.conf or mkinitcpio.conf.d missing)"
fi

# --- 3. mkinitcpio drop-in (with ESP space guard) ----------------------------
say "3/7 mkinitcpio drop-in"
FW=/mnt/usr/lib/firmware/qcom
fw_mb=$(du -sm "$FW" 2>/dev/null | cut -f1); fw_mb=${fw_mb:-0}
esp_free_mb=$(df -m --output=avail /mnt/boot | tail -1 | tr -d ' ')
echo "qcom firmware: ${fw_mb}M, ESP free: ${esp_free_mb}M"
DROP=/mnt/etc/mkinitcpio.conf.d/display.conf
if [ "$fw_mb" -gt 0 ] && [ $((fw_mb + 150)) -lt "$esp_free_mb" ]; then
  printf 'MODULES+=(msm)\nFILES+=(/usr/lib/firmware/qcom)\n' > "$DROP"
  ok "drop-in: whole qcom firmware dir"
else
  files=()
  while IFS= read -r f; do files+=("${f#/mnt}"); done < <(
    find "$FW" -iname '*gen70500*' -o -iname '*zap*' -o -iname '*x1p*' 2>/dev/null)
  if [ ${#files[@]} -gt 0 ]; then
    printf 'MODULES+=(msm)\nFILES+=(%s)\n' "${files[*]}" > "$DROP"
    ok "drop-in: targeted firmware (${#files[@]} files)"
  else
    printf 'MODULES+=(msm)\n' > "$DROP"
    bad "no qcom firmware found on target - drop-in has msm only"
  fi
fi
cat "$DROP"

# --- 4. Rebuild initramfs ----------------------------------------------------
say "4/7 mkinitcpio -P"
if arch-chroot /mnt mkinitcpio -P; then ok "initramfs rebuilt"; else bad "mkinitcpio failed"; fi

# --- 5. Verify image contents ------------------------------------------------
say "5/7 Verify initramfs"
IMG=/mnt/boot/initramfs-linux.img
n_fw=$(lsinitcpio "$IMG" 2>/dev/null | grep -c 'firmware/qcom')
n_msm=$(lsinitcpio "$IMG" 2>/dev/null | grep -ci 'drm/msm')
echo "qcom firmware files in image: $n_fw"
echo "msm module files in image: $n_msm"
[ "$n_msm" -gt 0 ] && ok "msm present" || bad "msm MISSING from image"
[ "$n_fw" -gt 0 ] && ok "qcom firmware present" || bad "qcom firmware MISSING from image"

# --- 6. limine.conf cleanup --------------------------------------------------
say "6/7 limine.conf"
sed -i 's/ nomodeset//' /mnt/boot/limine.conf && ok "nomodeset stripped"
grep -q 'ufshcd_core.use_mcq_mode=0' /mnt/boot/limine.conf \
  && ok "mcq workaround kept" || bad "mcq workaround MISSING from cmdline"
grep -q 'modprobe.blacklist=qcom_q6v5_pas' /mnt/boot/limine.conf \
  && ok "q6v5 blacklist kept" || bad "q6v5 blacklist MISSING from cmdline"
echo "final cmdline:"
grep 'cmdline:' /mnt/boot/limine.conf

# --- 7. Diagnostics to the ESP ------------------------------------------------
say "7/7 Diagnostics"
DIAG=/mnt/boot/surface13-repair.txt
{
  echo "=== lsblk -f ==="; lsblk -f
  echo; echo "=== target firmware/qcom ==="; ls -la /mnt/usr/lib/firmware/qcom 2>/dev/null
  echo; echo "=== live vs target initramfs diff (display/firmware) ==="
  LIVE_IMG=/run/archiso/bootmnt/arch/boot/aarch64/initramfs-linux-aarch64.img
  if [ -f "$LIVE_IMG" ]; then
    diff <(lsinitcpio "$LIVE_IMG" 2>/dev/null) <(lsinitcpio "$IMG" 2>/dev/null) \
      | grep -i 'msm\|drm\|panel\|qcom\|firmware\|regulator'
  else
    echo "live initramfs not found at $LIVE_IMG"
  fi
  echo; echo "=== dmesg (ufs + drm) ==="; dmesg | grep -i 'ufs\|msm\|drm' | tail -60
  echo; echo "=== repair log ==="; cat /run/surface13-repair.log
} > "$DIAG" 2>&1
ok "diagnostics at EFI surface13-repair.txt ($DIAG)"
sync

# --- Banner -------------------------------------------------------------------
clear
printf '\n\n'
if [ "$OVERALL" = ok ]; then
  printf '  ########################################################\n'
  printf '  #                                                      #\n'
  printf '  #     REPAIR COMPLETE - ALL STEPS OK                   #\n'
  printf '  #                                                      #\n'
  printf '  #     1. Photograph this screen (optional)             #\n'
  printf '  #     2. Pull the USB stick                            #\n'
  printf '  #     3. Reboot with the power button                  #\n'
  printf '  #                                                      #\n'
  printf '  #     If the screen still goes black after the penguin #\n'
  printf '  #     logo, WAIT 10 MINUTES once before giving up.     #\n'
  printf '  #                                                      #\n'
  printf '  ########################################################\n'
else
  printf '  ########################################################\n'
  printf '  #     REPAIR INCOMPLETE - SOME STEPS FAILED            #\n'
  printf '  #     Photograph this whole screen and send it.        #\n'
  printf '  #     Diagnostics are saved on the EFI partition as    #\n'
  printf '  #     surface13-repair.txt                             #\n'
  printf '  #     Do NOT reboot yet if you can photo first.        #\n'
  printf '  ########################################################\n'
fi
printf '\n  Full log: /run/surface13-repair.log and on the ESP.\n\n'
grep -E '^\[(OK|FAIL)\]' /run/surface13-repair.log | tail -30
sync
while :; do sleep 3600; done

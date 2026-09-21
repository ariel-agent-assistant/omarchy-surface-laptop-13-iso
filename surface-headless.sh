#!/bin/bash
# Surface Laptop 13 (X1P42100, SKU 2095) - headless-but-alive boot setup.
# Proven: kernel dies inside the built-in msm modeset path (pre-initramfs).
# This script: (1) makes the modeset=0 rescue console the PERMANENT default,
# (2) enables SSH root login, (3) builds surface-headless.efi whose cmdline
# skips msm entirely (initcall_blacklist=msm_drm_register, symbol verified
# against linux-7.2.6 msm_drv.c:1155) + msm.modeset=0 as fallback, and
# (4) adds a "/Surface Headless" limine entry. Console stays VISIBLE either way.
set -Eeuo pipefail
trap 'rc=$?; set +x; echo; echo "##### HEADLESS SETUP FAILED (rc=$rc) - PHOTO THIS SCREEN #####"; exit $rc' ERR

ESP=/boot
[ -d "$ESP/EFI" ] || { echo "ESP not mounted at /boot"; exit 1; }
set -x

# 1. permanent modeset=0 on the default boot path (idempotent)
grep -q 'msm.modeset=0' "$ESP/limine.conf" || sed -i '/^cmdline:/s/$/ msm.modeset=0/' "$ESP/limine.conf"
grep -q 'msm.modeset=0' /etc/default/limine 2>/dev/null || sed -i '/^KERNEL_CMDLINE/s/"$/ msm.modeset=0"/' /etc/default/limine 2>/dev/null || true

# 2. sshd with root password login
command -v sshd >/dev/null 2>&1 || pacman -Sy --noconfirm openssh
systemctl enable --now sshd
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
grep -q '^PermitRootLogin yes' /etc/ssh/sshd_config || echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
grep -q '^PasswordAuthentication yes' /etc/ssh/sshd_config || echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config
systemctl restart sshd

# 3. headless UKI (msm fully skipped)
DTB="$ESP/dtbs/qcom/x1p42100-microsoft-surface-laptop-13.dtb"
[ -s "$DTB" ]
KIMG=$(find "$ESP" -maxdepth 3 -type f \( -name 'Image' -o -name 'Image.gz' -o -name 'vmlinuz*' \) -print -quit 2>/dev/null)
INITRD=$(find "$ESP" -maxdepth 3 -type f -name 'initramfs-linux*.img' ! -name '*fallback*' -print -quit 2>/dev/null)
if [ -z "$INITRD" ] || [ ! -s "$INITRD" ]; then
  CUR=$(find "$ESP/EFI/Linux" -maxdepth 1 -type f -name 'omarchy_linux-aarch64*.efi' -print -quit)
  [ -s "$CUR" ]
  objcopy -O binary --only-section=.initrd "$CUR" "$ESP/initramfs-linux.img"
  INITRD="$ESP/initramfs-linux.img"
fi
[ -s "$KIMG" ] && [ -s "$INITRD" ] || { echo "kernel/initramfs not found"; ls -la "$ESP"; exit 1; }

CMDLINE=$(sed -E 's/(^| )(nomodeset|msm\.modeset=0|plymouth\.enable=0|rd\.plymouth=0|quiet|splash|loglevel=[0-9]+|rd\.udev\.log_level=[0-9]+|systemd\.show_status=[a-z]+)( |$)/ /g; s/[[:space:]]+/ /g; s/^ //; s/ $//' /etc/kernel/cmdline)
CMDLINE="$CMDLINE initcall_blacklist=msm_drm_register msm.modeset=0"
[ -n "$CMDLINE" ]
printf '%s\n' "$CMDLINE" > /tmp/headless-uki-cmdline

UKIFY=
for p in /usr/lib/systemd/ukify /usr/bin/ukify; do [ -x "$p" ] && UKIFY=$p && break; done
[ -n "$UKIFY" ] || { echo 'ukify missing'; exit 1; }

"$UKIFY" build \
  --linux "$KIMG" \
  --initrd "$INITRD" \
  --devicetree "$DTB" \
  --cmdline "$CMDLINE" \
  --output "$ESP/EFI/Linux/surface-headless.efi"
[ -s "$ESP/EFI/Linux/surface-headless.efi" ]

# 4. limine menu entry (idempotent)
grep -q 'Surface Headless' "$ESP/limine.conf" || printf '\n/Surface Headless\n    protocol: efi\n    path: boot():/EFI/Linux/surface-headless.efi\n' >> "$ESP/limine.conf"

set +x
IP=$(hostname -I 2>/dev/null | awk '{print $1}')
echo
echo '################## HEADLESS SETUP DONE ##################'
echo "# sshd enabled, root login on. LAN IP now: $IP"
echo '# Default boot entry is now the PERMANENT visible console'
echo '# (msm.modeset=0 baked in). Optional: "/Surface Headless"'
echo '# menu entry skips msm completely - console also visible.'
echo '#'
echo '# NEXT: reboot (normal default entry is fine).'
echo '# From the Retroid Termux:  ssh root@<IP>'
echo '# (IP shows on screen after boot: run  hostname -I  once.)'
echo '#########################################################'

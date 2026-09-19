#!/bin/bash
# Surface Laptop 13 (SKU 2095, Snapdragon X Plus X1P42100) support for the
# Snapdragon aarch64 ISO: stage the board DTB, teach systemd-stub its hardware
# IDs, and supply the ARM packages the published channels do not carry yet.
set -euo pipefail

build_cache_dir=$1
PACMAN_ONLINE_CONF=${2:?surface13: usage: surface-laptop-13.sh <build_cache_dir> <pacman-online-conf>}

# 1. Compile and stage the board DTB with the kernel's own DTBs. live-uki.sh
#    embeds every /boot/dtbs/qcom/x1*.dtb into the live UKI, and the patched
#    mkarchiso copies the tree into the ISO for the GRUB devicetree entry.
install -d "$build_cache_dir/airootfs/boot/dtbs/qcom"
dtb="$build_cache_dir/airootfs/boot/dtbs/qcom/x1p42100-microsoft-surface-laptop-13.dtb"
dtc -O dtb -o "$dtb" /configs/aarch64/dtbs/surface-laptop-13-typec.dts
echo "surface13: staged $(stat -c %s "$dtb") byte DTB"

# 2. systemd-stub selects a .dtbauto entry through the .hwids section; the JSON
#    maps the laptop's SMBIOS CHIDs to the DTB's compatible string.
install -Dm644 /configs/aarch64/hwids/x1p42100-microsoft-surface-laptop-13.json \
  "$build_cache_dir/airootfs/usr/lib/systemd/boot/hwids/aa64/x1p42100-microsoft-surface-laptop-13.json"
echo "surface13: staged systemd-stub hwids"

# 3. Build locally whichever ARM packages the synced repositories lack, and
#    serve them from a file:// repo appended to the online pacman config so
#    they land in the offline mirror like any published package.
local_repo=/var/cache/omarchy-local
mkdir -p "$local_repo"

have_package() {
  pacman --config "$PACMAN_ONLINE_CONF" --dbpath /tmp/surface13-probedb \
    -Si "$1" &>/dev/null
}

pacman --config "$PACMAN_ONLINE_CONF" --dbpath /tmp/surface13-probedb -Sy >/dev/null

if ! id builder &>/dev/null; then
  useradd -m -s /bin/bash builder
fi
echo 'builder ALL=(ALL) NOPASSWD: /usr/bin/pacman' > /etc/sudoers.d/99-omarchy-pkg-builder
chmod 440 /etc/sudoers.d/99-omarchy-pkg-builder

built=0
for pkg in linux-aarch64-pkgbase-shim qcom-firmware-extract; do
  if have_package "$pkg"; then
    echo "surface13: $pkg available from synced repositories"
    continue
  fi
  echo "surface13: $pkg missing from repositories, building locally"
  src="/builder/local-pkgs/$pkg"
  work="/tmp/surface13-pkg-$pkg"
  rm -rf "$work"
  cp -r "$src" "$work"
  chown -R builder:builder "$work"
  (cd "$work" && sudo -u builder makepkg --noconfirm --nodeps -f)
  cp "$work"/$pkg-*.pkg.tar.* "$local_repo/"
  built=1
done

if (( built )); then
  repo-add "$local_repo/omarchy-local.db.tar.gz" "$local_repo"/*.pkg.tar.*
  if ! grep -q '^\[omarchy-local\]' "$PACMAN_ONLINE_CONF"; then
    cat >> "$PACMAN_ONLINE_CONF" <<'CONF'

[omarchy-local]
SigLevel = Never
Server = file:///var/cache/omarchy-local
CONF
  fi
  # Re-sync so the new repo is visible to the offline-mirror transaction.
  pacman --config "$PACMAN_ONLINE_CONF" --dbpath /tmp/surface13-probedb -Sy >/dev/null
  for pkg in linux-aarch64-pkgbase-shim qcom-firmware-extract; do
    have_package "$pkg" || { echo "surface13: $pkg STILL unresolvable" >&2; exit 1; }
  done
  echo "surface13: local repo ready at $local_repo"
fi
rm -rf /tmp/surface13-probedb

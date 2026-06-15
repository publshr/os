#!/usr/bin/env bash
# ============================================================================
#  NOVA OS — live/installer ISO builder.
#  Runs on an Ubuntu host (GitHub Actions ubuntu-latest). Builds a fully
#  rebranded Ubuntu 24.04 ("noble") live ISO whose only purpose is to run the
#  NOVA (Calamares) graphical installer. Boots BIOS + UEFI (signed Secure Boot
#  chain). Nothing here says "Ubuntu" to the end user.
#
#  Layout produced:
#     build/chroot   — the root filesystem (becomes the squashfs / installed OS)
#     build/image    — the ISO staging tree (/casper, /boot/grub, /EFI ...)
#     build/nova.iso — the final image
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"      # repo root
WORK="${WORK:-$HERE/build}"
CHROOT="$WORK/chroot"
IMG="$WORK/image"
SUITE="noble"
MIRROR="${MIRROR:-http://archive.ubuntu.com/ubuntu/}"
ISO_OUT="${ISO_OUT:-$WORK/nova.iso}"
ISO_LABEL="NOVA"

msg() { printf '\n\033[1;35m▶ %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
# 0. Host tools
# ---------------------------------------------------------------------------
host_deps() {
  msg "Installing build-host tools"
  sudo apt-get update -q
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    debootstrap squashfs-tools xorriso \
    grub-pc-bin grub-efi-amd64-bin mtools dosfstools rsync ca-certificates
}

# ---------------------------------------------------------------------------
# 1. Bootstrap the base root filesystem
# ---------------------------------------------------------------------------
bootstrap() {
  msg "debootstrap $SUITE"
  sudo mkdir -p "$CHROOT" "$IMG/casper" "$IMG/boot/grub" "$IMG/EFI/boot"
  sudo debootstrap --arch=amd64 --variant=minbase \
    --components=main,restricted,universe,multiverse \
    "$SUITE" "$CHROOT" "$MIRROR"

  # apt sources inside the chroot (all four components, updates + security)
  sudo tee "$CHROOT/etc/apt/sources.list" >/dev/null <<EOF
deb $MIRROR $SUITE main restricted universe multiverse
deb $MIRROR $SUITE-updates main restricted universe multiverse
deb $MIRROR $SUITE-security main restricted universe multiverse
EOF
}

# ---------------------------------------------------------------------------
# 2. Stage our files into the chroot, then run the in-chroot setup
# ---------------------------------------------------------------------------
configure() {
  msg "Staging NOVA overlay + branding into the rootfs"
  # Overlay = files that land verbatim in the OS (/, /etc, /usr ...).
  sudo rsync -a "$HERE/overlay/" "$CHROOT/"
  # Branding + the in-chroot setup script go to a scratch dir we delete later.
  sudo mkdir -p "$CHROOT/nova-build"
  sudo rsync -a "$HERE/branding/" "$CHROOT/nova-build/branding/"
  sudo cp "$HERE/build/chroot-setup.sh" "$CHROOT/nova-build/chroot-setup.sh"
  sudo cp /etc/resolv.conf "$CHROOT/etc/resolv.conf"

  msg "Entering chroot for package install + branding"
  sudo mount --bind /dev  "$CHROOT/dev"
  sudo mount --bind /run  "$CHROOT/run"
  sudo chroot "$CHROOT" /bin/bash -c "
    set -e
    mount -t proc none /proc
    mount -t sysfs none /sys
    mount -t devpts none /dev/pts || true
    export HOME=/root LC_ALL=C DEBIAN_FRONTEND=noninteractive
    /nova-build/chroot-setup.sh
    umount /proc /sys /dev/pts || true
  "
  sudo rm -rf "$CHROOT/nova-build" "$CHROOT/etc/resolv.conf"
  sudo umount "$CHROOT/dev" "$CHROOT/run" || true
}

# ---------------------------------------------------------------------------
# 3. Kernel, initrd, manifests, squashfs
# ---------------------------------------------------------------------------
squashfs() {
  msg "Extracting kernel + initrd"
  sudo cp "$CHROOT"/boot/vmlinuz-*  "$IMG/casper/vmlinuz"
  sudo cp "$CHROOT"/boot/initrd.img-* "$IMG/casper/initrd"

  msg "Writing package manifest"
  sudo chroot "$CHROOT" dpkg-query -W --showformat='${Package} ${Version}\n' \
    | sudo tee "$IMG/casper/filesystem.manifest" >/dev/null

  msg "Building squashfs (this is the slow part)"
  sudo rm -f "$IMG/casper/filesystem.squashfs"
  sudo mksquashfs "$CHROOT" "$IMG/casper/filesystem.squashfs" \
    -noappend -no-duplicates -no-recovery -wildcards \
    -comp zstd -b 1M -Xcompression-level 19 \
    -e "boot/*" -e "var/cache/apt/archives/*" -e "root/*" -e "tmp/*" \
    -e "nova-build/*" -e "etc/resolv.conf"
  printf "%s" "$(sudo du -sx --block-size=1 "$CHROOT" | cut -f1)" \
    | sudo tee "$IMG/casper/filesystem.size" >/dev/null
  sudo touch "$IMG/ubuntu"   # marker the grub.cfg searches for
}

# ---------------------------------------------------------------------------
# 4. Bootloaders — signed Secure Boot EFI chain + BIOS core
# ---------------------------------------------------------------------------
bootloaders() {
  msg "Assembling boot chain (signed EFI + BIOS)"

  # The live boot menu (hidden, boots straight into casper).
  sudo tee "$IMG/boot/grub/grub.cfg" >/dev/null <<EOF
search --set=root --file /ubuntu
set default=0
set timeout=0
set gfxpayload=keep
menuentry "NOVA" {
    linux /casper/vmlinuz boot=casper quiet splash ---
    initrd /casper/initrd
}
EOF

  # Signed Secure Boot binaries live in the rootfs at version-specific paths;
  # find them rather than hardcoding (they shift across point releases).
  local shim grubsigned mm
  shim="$(sudo find "$CHROOT/usr/lib/shim" -name 'shimx64.efi.signed*' | head -1)"
  mm="$(sudo find "$CHROOT/usr/lib/shim" -name 'mmx64.efi.signed*' -o -name 'mmx64.efi' | head -1)"
  grubsigned="$(sudo find "$CHROOT/usr/lib/grub/x86_64-efi-signed" -name 'grubx64.efi.signed*' | head -1)"
  [ -n "$shim" ] && [ -n "$grubsigned" ] || { echo "FATAL: signed EFI binaries not found"; exit 1; }
  echo "shim=$shim"; echo "grub(signed)=$grubsigned"; echo "mm=$mm"

  sudo cp "$shim"       "$IMG/EFI/boot/bootx64.efi"
  sudo cp "$grubsigned" "$IMG/EFI/boot/grubx64.efi"
  [ -n "$mm" ] && sudo cp "$mm" "$IMG/EFI/boot/mmx64.efi" || true

  # The signed Ubuntu grub has an embedded prefix of /EFI/ubuntu — give it a
  # config there that hands off to the real menu on the ISO.
  sudo mkdir -p "$IMG/EFI/ubuntu"
  sudo tee "$IMG/EFI/ubuntu/grub.cfg" >/dev/null <<'EOF'
search --set=root --file /ubuntu
configfile /boot/grub/grub.cfg
EOF

  # EFI El Torito image: a FAT image holding /EFI/boot/*.efi
  local efimg="$WORK/efiboot.img"
  sudo rm -f "$efimg"
  dd if=/dev/zero of="$efimg" bs=1M count=16 status=none
  mkfs.vfat -n NOVA_EFI "$efimg" >/dev/null
  mmd   -i "$efimg" ::EFI ::EFI/boot ::EFI/ubuntu
  mcopy -i "$efimg" "$IMG/EFI/boot/bootx64.efi" ::EFI/boot/BOOTX64.EFI
  mcopy -i "$efimg" "$IMG/EFI/boot/grubx64.efi" ::EFI/boot/grubx64.efi
  [ -f "$IMG/EFI/boot/mmx64.efi" ] && mcopy -i "$efimg" "$IMG/EFI/boot/mmx64.efi" ::EFI/boot/mmx64.efi
  mcopy -i "$efimg" "$IMG/EFI/ubuntu/grub.cfg" ::EFI/ubuntu/grub.cfg
  sudo cp "$efimg" "$IMG/boot/grub/efiboot.img"

  # BIOS core image (grub for legacy boot off the ISO).
  grub-mkstandalone --format=i386-pc \
    --modules="linux normal iso9660 biosdisk search part_msdos part_gpt" \
    --install-modules="linux normal iso9660 biosdisk search configfile ls cat echo test part_msdos part_gpt all_video gfxterm" \
    --locales="" --fonts="" \
    --output="$WORK/core.img" \
    "boot/grub/grub.cfg=$IMG/boot/grub/grub.cfg"
  cat /usr/lib/grub/i386-pc/cdboot.img "$WORK/core.img" > "$WORK/bios.img"
  sudo cp "$WORK/bios.img" "$IMG/boot/grub/bios.img"
}

# ---------------------------------------------------------------------------
# 5. Pack the hybrid ISO (BIOS + UEFI, USB-writable)
# ---------------------------------------------------------------------------
pack() {
  msg "Creating $ISO_OUT"
  sudo xorriso -as mkisofs \
    -iso-level 3 -full-iso9660-filenames -volid "$ISO_LABEL" -J -joliet-long \
    -output "$ISO_OUT" \
    -eltorito-boot boot/grub/bios.img \
      -no-emul-boot -boot-load-size 4 -boot-info-table \
      --eltorito-catalog boot/grub/boot.cat \
      --grub2-mbr /usr/lib/grub/i386-pc/boot_hybrid.img \
      -partition_offset 16 --mbr-force-bootable \
    -eltorito-alt-boot \
      -e boot/grub/efiboot.img -no-emul-boot \
      -append_partition 2 0xef "$IMG/boot/grub/efiboot.img" -appended_part_as_gpt \
    "$IMG"
  msg "Done → $ISO_OUT"
  ls -lh "$ISO_OUT"
}

main() {
  host_deps
  bootstrap
  configure
  squashfs
  bootloaders
  pack
}
main "$@"

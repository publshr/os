#!/usr/bin/env bash
# ============================================================================
#  Runs INSIDE the chroot. Installs packages, turns plain Ubuntu into NOVA:
#  branding, GNOME desktop, Calamares installer, Plymouth silent boot, Wine
#  (.exe), post-login driver setup, and silent auto-updates.
#  Anything that must say "Ubuntu" to apt is allowed; nothing the USER sees does.
# ============================================================================
set -euo pipefail
B=/nova-build/branding
soft() { "$@" || echo "WARN: non-fatal step failed: $*"; }

export DEBIAN_FRONTEND=noninteractive
echo "==> apt update + locales (minbase has no locale-gen until 'locales' is in)"
apt-get update -q
apt-get install -y --no-install-recommends locales
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8
echo "nova" > /etc/hostname

echo "==> base live system + bootloaders (signed Secure Boot chain)"
# grub-install for UEFI needs efibootmgr (to write the boot entry) and the
# install needs the filesystem tools (mkfs.vfat for the ESP, mkfs.ext4 for /).
# These are 'Recommends', so they MUST be listed explicitly under
# --no-install-recommends or the bootloader/format step fails (error code 1).
# Use the grub *-bin packages (not the grub-pc/grub-efi metapackages, which
# conflict with each other and run disk-install postinst).
apt-get install -y --no-install-recommends \
  sudo ubuntu-standard casper discover laptop-detect os-prober \
  network-manager network-manager-gnome wpasupplicant locales \
  grub-common grub2-common grub-pc-bin \
  grub-efi-amd64-bin grub-efi-amd64-signed shim-signed efibootmgr \
  dosfstools e2fsprogs parted gdisk \
  ca-certificates curl gnupg

echo "==> kernel (HWE for best support on newer hardware)"
apt-get install -y --no-install-recommends linux-generic-hwe-24.04 \
  || apt-get install -y --no-install-recommends linux-generic

echo "==> GNOME desktop + full graphics stack (so the session actually starts)"
# NOTE: deliberately NOT --no-install-recommends here — a stripped GNOME boots
# to a frozen blank because session pieces (settings-daemon, portals, Xorg,
# mesa) are 'recommends'. gnome-core is the curated, known-good functional set.
apt-get install -y \
  gnome-core gdm3 nautilus gnome-control-center gnome-system-monitor \
  network-manager-gnome \
  xserver-xorg xwayland dbus-x11 \
  libgl1-mesa-dri mesa-vulkan-drivers \
  linux-firmware \
  plymouth plymouth-themes zenity \
  xdg-user-dirs dconf-cli librsvg2-bin \
  software-properties-gtk unattended-upgrades

# Nice-to-haves (never fail the build if a package name drifts)
soft apt-get install -y \
  gnome-disk-utility gnome-text-editor file-roller fonts-inter \
  gnome-shell-extension-dashtodock gnome-maps

echo "==> Calamares installer"
apt-get install -y --no-install-recommends calamares || apt-get install -y calamares

echo "==> Browser: GNOME Web always present, plus try Firefox (.deb) from Mozilla"
# A browser that is GUARANTEED to exist (universe .deb, no snap).
soft apt-get install -y --no-install-recommends epiphany-browser
# Firefox as a real .deb (not snap) — best effort; GNOME Web is the fallback.
install -d -m0755 /etc/apt/keyrings
if curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg -o /etc/apt/keyrings/packages.mozilla.org.asc; then
  echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" \
    > /etc/apt/sources.list.d/mozilla.list
  printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' \
    > /etc/apt/preferences.d/mozilla
  apt-get update -q || true
  soft apt-get install -y firefox
fi

echo "==> Software app + updates (so 'Software' actually opens and updates work)"
soft apt-get install -y gnome-software packagekit

echo "==> Wine + .exe support (WineHQ, i386 multiarch)"
dpkg --add-architecture i386
if curl -fsSL https://dl.winehq.org/wine-builds/winehq.key -o /etc/apt/keyrings/winehq-archive.key; then
  curl -fsSL https://dl.winehq.org/wine-builds/ubuntu/dists/noble/winehq-noble.sources \
    -o /etc/apt/sources.list.d/winehq-noble.sources || true
  apt-get update -q || true
  soft apt-get install -y --install-recommends winehq-stable
fi
# Fallback to the distro wine if WineHQ didn't take.
command -v wine >/dev/null || soft apt-get install -y --install-recommends wine wine64 wine32:i386
soft apt-get install -y --no-install-recommends winetricks

# ---------------------------------------------------------------------------
#  BRANDING — make it NOVA everywhere a person can see.
# ---------------------------------------------------------------------------
echo "==> branding: identity files"
ln -sf ../usr/lib/os-release /etc/os-release   # overlay shipped /usr/lib/os-release
# (os-release, lsb-release, issue, grub default, dconf, mimeapps all arrive via overlay)

echo "==> branding: logo + wallpaper assets"
install -d /usr/share/nova
rsvg-convert -w 512 -h 512 "$B/logo.svg" -o /usr/share/nova/logo.png 2>/dev/null \
  || cp "$B/logo.png" /usr/share/nova/logo.png
rsvg-convert -w 2560 -h 1440 "$B/wallpaper.svg" -o /usr/share/nova/wallpaper.png 2>/dev/null || true
install -d /usr/share/backgrounds
cp -f /usr/share/nova/wallpaper.png /usr/share/backgrounds/nova.png 2>/dev/null || true

echo "==> branding: Plymouth silent boot theme"
install -d /usr/share/plymouth/themes/nova
cp -r "$B/plymouth/nova/." /usr/share/plymouth/themes/nova/
cp -f /usr/share/nova/logo.png /usr/share/plymouth/themes/nova/logo.png
# robust framebuffer for the splash (no tiny/garbled splash)
echo "FRAMEBUFFER=y" > /etc/initramfs-tools/conf.d/splash
update-alternatives --install /usr/share/plymouth/themes/default.plymouth \
  default.plymouth /usr/share/plymouth/themes/nova/nova.plymouth 200
update-alternatives --set default.plymouth /usr/share/plymouth/themes/nova/nova.plymouth || true
soft plymouth-set-default-theme -R nova
# CRUCIAL: bake the NOVA splash INTO the initramfs, or the live boot (which
# runs from the initramfs) still shows Ubuntu's splash from the first frame.
soft update-initramfs -u -k all

echo "==> branding: GRUB (hidden menu, NOVA name)"
soft update-grub

echo "==> NOVA shell: custom top bar + launcher extension"
install -d /usr/share/gnome-shell/extensions
cp -r "$B/shell/novalogo@nova.local" /usr/share/gnome-shell/extensions/

echo "==> branding: distributor logo icon (About / greeter / LOGO=)"
install -d /usr/share/icons/hicolor/scalable/apps /usr/share/pixmaps
cp "$B/logo.svg" /usr/share/icons/hicolor/scalable/apps/nova-logo.svg || true
cp "$B/logo.svg" /usr/share/pixmaps/nova-logo.svg || true
gtk-update-icon-cache -f /usr/share/icons/hicolor 2>/dev/null || true

# Drop Yaru/Ubuntu look if anything pulled it in (gnome-core usually doesn't).
soft apt-get purge -y yaru-theme-gtk yaru-theme-icon yaru-theme-sound yaru-theme-gnome-shell

echo "==> branding: compile GNOME defaults (wallpaper, dark, dock, NOVA shell + greeter)"
dconf update || true

echo "==> de-Ubuntu: remove snap + nags"
systemctl disable --now motd-news.timer 2>/dev/null || true
touch /var/lib/update-notifier/hide-esm-in-motd 2>/dev/null || true
soft apt-get purge -y snapd ubuntu-report popularity-contest
printf 'Package: snapd\nPin: release a=*\nPin-Priority: -10\n' > /etc/apt/preferences.d/nosnap.pref

# ---------------------------------------------------------------------------
#  CALAMARES — branded config (welcome → account → erase-install → done)
# ---------------------------------------------------------------------------
echo "==> Calamares config + branding"
install -d /etc/calamares/branding/nova
cp -f "$B/calamares/settings.conf" /etc/calamares/settings.conf
cp -rf "$B/calamares/modules/." /etc/calamares/modules/
cp -rf "$B/calamares/branding/nova/." /etc/calamares/branding/nova/
rsvg-convert -w 96  -h 96  "$B/logo.svg" -o /etc/calamares/branding/nova/logo.png 2>/dev/null \
  || cp "$B/logo.png" /etc/calamares/branding/nova/logo.png
cp -f /usr/share/nova/wallpaper.png /etc/calamares/branding/nova/welcome.png 2>/dev/null || true

# ---------------------------------------------------------------------------
#  AUTO-UPDATES — silent, from our own apt origin (key shipped via overlay/CI)
# ---------------------------------------------------------------------------
echo "==> auto-updates"
systemctl enable unattended-upgrades 2>/dev/null || true

echo "==> services"
systemctl set-default graphical.target || true
systemctl enable gdm3 2>/dev/null || systemctl enable gdm 2>/dev/null || true
systemctl enable NetworkManager 2>/dev/null || true

echo "==> permissions on our scripts"
chmod +x /usr/local/bin/nova-* 2>/dev/null || true

echo "==> cleanup"
apt-get autoremove -y
apt-get clean
rm -rf /tmp/* /var/lib/apt/lists/* /var/tmp/*
echo "==> chroot setup complete"

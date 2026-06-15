# NOVA

A fast, beautiful consumer operating system. Built on a hardened Ubuntu 24.04
LTS base, fully rebranded — boot, installer, and desktop all say NOVA.

## What it is
- **Silent branded boot** — a clean NOVA splash, no code, on power-on and off.
- **Beautiful graphical installer** (Calamares) — welcome → create your account
  → it erases and installs → restarts into NOVA. No technical screens.
- **Driver setup after first login** — detects your PC's graphics and offers to
  install the best driver in one click.
- **Windows apps** — double-click a `.exe` and it opens (Wine), with a clear
  message if something goes wrong.
- **Silent auto-updates**.

## How it's built
`build/build.sh` runs on an Ubuntu host (GitHub Actions) and produces a hybrid
BIOS+UEFI live ISO:

1. `debootstrap` a Noble rootfs
2. `build/chroot-setup.sh` installs the desktop, Calamares, Wine, branding
3. squashfs + casper + signed Secure Boot chain → `xorriso` hybrid ISO

Every build is **boot-tested in QEMU (UEFI + BIOS)** and screenshotted in CI
before release — see `build/qemu-smoke.sh`.

## Layout
- `build/` — ISO build scripts
- `branding/` — logo, wallpaper, Plymouth theme, Calamares branding + config
- `overlay/` — files copied verbatim into the OS (identity, dconf, scripts)
- `.github/workflows/build.yml` — CI: build → QEMU boot-test → publish

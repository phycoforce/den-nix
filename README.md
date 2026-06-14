# Den Desktop Starter

This is an isolated Den-based NixOS starter for the desktop currently running CachyOS with Niri and Noctalia Shell.

It intentionally does not modify the old root flake in this repository.

## Decisions

- Host output: `temperantia`
- User: `aaron`
- Bootloader: `systemd-boot`
- Secure Boot: skipped; disable it in firmware before booting the installed system
- Main disk: unencrypted Btrfs
- Kernel: CachyOS kernel from Chaotic Nyx, `pkgs.linuxPackages_cachyos`
- GPU: NVIDIA open kernel module for RTX 4080 SUPER
- Desktop: Niri, launched by `greetd`/`tuigreet`
- Shell: Noctalia Shell v4, `git+https://github.com/noctalia-dev/noctalia?ref=legacy-v4`
- Extra disk: keep existing Btrfs filesystem labeled `SSD2`, mounted at `/mnt/SSD2`

## Layout

```text
flake.nix
modules/
  dendritic.nix        # Den framework import
  defaults.nix         # global Den defaults
  hosts.nix            # host/user declaration
  temperantia.nix      # host aspect
  aaron.nix            # user aspect
  _nixos/              # regular NixOS modules, ignored by import-tree
  _home/               # regular Home Manager modules, ignored by import-tree
```

The underscore directories follow Den's documented migration pattern: `import-tree` ignores them, and the host/user aspects import them explicitly.

## Pre-Install Checks

Boot a recent NixOS graphical or minimal installer ISO in UEFI mode.

Disable Secure Boot in firmware. This starter does not sign boot files.

Become root:

```sh
sudo -i
```

Confirm disks before formatting:

```sh
lsblk -f
```

Expected current desktop shape:

```text
/dev/nvme0n1       main OS disk, will be wiped
/dev/nvme1n1p1     existing SSD2 Btrfs disk, must not be formatted
```

## Format Main Disk

These commands wipe the selected disk. Set `DISK` carefully.

```sh
export DISK=/dev/nvme0n1

wipefs -af "$DISK"
sgdisk --zap-all "$DISK"
sgdisk -n1:1M:+2G -t1:EF00 -c1:NIXBOOT "$DISK"
sgdisk -n2:0:0 -t2:8300 -c2:NIXROOT "$DISK"
partprobe "$DISK"
udevadm settle
```

Create filesystems:

```sh
mkfs.fat -F32 -n NIXBOOT /dev/disk/by-partlabel/NIXBOOT
mkfs.btrfs -f -L NIXROOT /dev/disk/by-partlabel/NIXROOT
```

Create Btrfs subvolumes:

```sh
mount /dev/disk/by-label/NIXROOT /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@srv
btrfs subvolume create /mnt/@cache
btrfs subvolume create /mnt/@tmp
btrfs subvolume create /mnt/@log
umount /mnt
```

Mount the install target:

```sh
export BTRFS_OPTS=noatime,compress=zstd:1,ssd,discard=async

mount -o subvol=@,$BTRFS_OPTS /dev/disk/by-label/NIXROOT /mnt
mkdir -p /mnt/{boot,home,srv,var/cache,var/tmp,var/log,mnt/SSD2,etc/nixos}
mount -o subvol=@home,$BTRFS_OPTS /dev/disk/by-label/NIXROOT /mnt/home
mount -o subvol=@srv,$BTRFS_OPTS /dev/disk/by-label/NIXROOT /mnt/srv
mount -o subvol=@cache,$BTRFS_OPTS /dev/disk/by-label/NIXROOT /mnt/var/cache
mount -o subvol=@tmp,$BTRFS_OPTS /dev/disk/by-label/NIXROOT /mnt/var/tmp
mount -o subvol=@log,$BTRFS_OPTS /dev/disk/by-label/NIXROOT /mnt/var/log
mount /dev/disk/by-label/NIXBOOT /mnt/boot
```

Mount existing `SSD2` without formatting it:

```sh
mount -o $BTRFS_OPTS /dev/disk/by-label/SSD2 /mnt/mnt/SSD2
```

## Get This Config Onto The Installer

Clone this repo into the target. Replace the URL if this repo lives somewhere else.

```sh
nix --extra-experimental-features "nix-command flakes" shell nixpkgs#git -c \
  git clone https://github.com/phycoforce/den-nix /mnt/etc/nixos/den-desktop
```

If the repo is not pushed anywhere, copy it onto the installer via USB, SSH, or another local method so that this file exists:

```text
/mnt/etc/nixos/den-desktop/flake.nix
```

## Install

Build and install the Den host:

```sh
nixos-install \
  --flake /mnt/etc/nixos/den-desktop#temperantia \
  --option accept-flake-config true \
  --option extra-substituters "https://nyx-cache.chaotic.cx/ https://noctalia.cachix.org https://nix-community.cachix.org" \
  --option extra-trusted-public-keys "nyx-cache.chaotic.cx:dJxTrgMC3V3cFfyIiBQDQorG6k1LsqurH/srpMSq7qk= noctalia.cachix.org-1:pCOR47nnMEo5thcxNDtzWpOxNFQsBRglJzxWPp3dkU4= nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
```

Set the user password before rebooting:

```sh
nixos-enter --root /mnt -c 'passwd aaron'
```

Reboot:

```sh
reboot
```

## First Boot

In firmware, keep Secure Boot disabled.

Select the NixOS/systemd-boot entry. Log in as `aaron` through `tuigreet`; it should start `niri-session`.

Niri should autostart:

- `xwayland-satellite`
- KDE polkit agent
- `noctalia-shell`

Useful checks after login:

```sh
uname -r
systemctl status scx.service
nvidia-smi
findmnt /mnt/SSD2
pgrep -a 'niri|noctalia|xwayland-satellite'
```

## Rebuilds After Install

After edits:

```sh
sudo nixos-rebuild switch --flake /etc/nixos/den-desktop#temperantia
```

Or with `nh`, if you later enable/configure it:

```sh
nh os switch /etc/nixos/den-desktop
```

## Notes

- This starter intentionally avoids `disko` so the first install remains transparent and easy to audit.
- The root filesystem is unencrypted. If you later want encryption back, add LUKS in a separate iteration.
- The Noctalia v4 settings are intentionally light. The Catppuccin-like colors are declarative, while most shell behavior is left at upstream defaults so the first login is less brittle.
- The current Niri keybinds are migrated to `noctalia-shell ipc call ...`; on CachyOS they were `qs -c noctalia-shell ipc call ...`.

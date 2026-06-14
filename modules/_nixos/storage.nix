{ lib, ... }:
let
  rootOptions = [
    "noatime"
    "compress=zstd:1"
    "ssd"
    "discard=async"
  ];
in
{
  fileSystems."/" = {
    device = "/dev/disk/by-label/NIXROOT";
    fsType = "btrfs";
    options = [ "subvol=@" ] ++ rootOptions;
  };

  fileSystems."/home" = {
    device = "/dev/disk/by-label/NIXROOT";
    fsType = "btrfs";
    options = [ "subvol=@home" ] ++ rootOptions;
  };

  fileSystems."/srv" = {
    device = "/dev/disk/by-label/NIXROOT";
    fsType = "btrfs";
    options = [ "subvol=@srv" ] ++ rootOptions;
  };

  fileSystems."/var/cache" = {
    device = "/dev/disk/by-label/NIXROOT";
    fsType = "btrfs";
    options = [ "subvol=@cache" ] ++ rootOptions;
  };

  fileSystems."/var/tmp" = {
    device = "/dev/disk/by-label/NIXROOT";
    fsType = "btrfs";
    options = [ "subvol=@tmp" ] ++ rootOptions;
  };

  fileSystems."/var/log" = {
    device = "/dev/disk/by-label/NIXROOT";
    fsType = "btrfs";
    options = [ "subvol=@log" ] ++ rootOptions;
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/NIXBOOT";
    fsType = "vfat";
    options = [
      "fmask=0077"
      "dmask=0077"
    ];
  };

  fileSystems."/mnt/SSD2" = {
    device = "/dev/disk/by-label/SSD2";
    fsType = "btrfs";
    options = rootOptions ++ [ "nofail" ];
  };

  swapDevices = [ ];

  networking.useDHCP = lib.mkDefault true;
}

{ lib, ... }:
let
  mainDisk = "/dev/disk/by-id/nvme-eui.000000000000000100a0752448c2bd18";

  rootOptions = [
    "noatime"
    "compress=zstd:1"
    "ssd"
    "discard=async"
  ];
in
{
  assertions = [
    {
      assertion = lib.hasPrefix "/dev/disk/by-id/" mainDisk;
      message = "temperantia main disk must use a stable /dev/disk/by-id/... path before running disko.";
    }
  ];

  disko.devices.disk.main = {
    type = "disk";
    device = mainDisk;
    content = {
      type = "gpt";
      partitions = {
        NIXBOOT = {
          label = "NIXBOOT";
          priority = 1;
          start = "1M";
          size = "2G";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            extraArgs = [
              "-F"
              "32"
              "-n"
              "NIXBOOT"
            ];
            mountpoint = "/boot";
            mountOptions = [
              "fmask=0077"
              "dmask=0077"
            ];
          };
        };

        NIXROOT = {
          label = "NIXROOT";
          size = "100%";
          content = {
            type = "btrfs";
            extraArgs = [
              "-f"
              "-L"
              "NIXROOT"
            ];
            subvolumes = {
              "@" = {
                mountpoint = "/";
                mountOptions = rootOptions;
              };
              "@home" = {
                mountpoint = "/home";
                mountOptions = rootOptions;
              };
              "@srv" = {
                mountpoint = "/srv";
                mountOptions = rootOptions;
              };
              "@cache" = {
                mountpoint = "/var/cache";
                mountOptions = rootOptions;
              };
              "@tmp" = {
                mountpoint = "/var/tmp";
                mountOptions = rootOptions;
              };
              "@log" = {
                mountpoint = "/var/log";
                mountOptions = rootOptions;
              };
            };
          };
        };
      };
    };
  };

  fileSystems."/mnt/SSD2" = {
    device = "/dev/disk/by-label/SSD2";
    fsType = "btrfs";
    options = rootOptions ++ [ "nofail" ];
  };

  swapDevices = [ ];

  networking.useDHCP = lib.mkDefault true;
}

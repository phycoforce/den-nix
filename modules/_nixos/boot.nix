{
  boot.loader = {
    efi.canTouchEfiVariables = true;
    systemd-boot = {
      enable = true;
      configurationLimit = 10;
    };
    timeout = 5;
  };

  boot.supportedFilesystems = [
    "btrfs"
    "vfat"
  ];

  boot.consoleLogLevel = 3;
  boot.initrd.verbose = false;

  boot.initrd.availableKernelModules = [
    "ahci"
    "nvme"
    "sd_mod"
    "usb_storage"
    "usbhid"
    "xhci_pci"
  ];
  boot.kernelModules = [ "kvm-amd" ];
  boot.kernelParams = [
    "quiet"
    "udev.log_level=3"
    "rd.udev.log_level=3"
    "rd.systemd.show_status=auto"
  ];

  zramSwap.enable = true;
}

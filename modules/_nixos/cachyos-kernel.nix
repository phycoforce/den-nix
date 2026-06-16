{ pkgs, ... }:
{
  boot.kernelPackages = pkgs.linuxPackages_cachyos;

  # CachyOS kernels support sched-ext; Chaotic's module provides the service.
  services.scx.enable = true;
  services.scx.scheduler = "scx_rustland";
  services.scx.extraArgs = [ ];
}

{ pkgs, ... }:
{
  boot.kernelPackages = pkgs.cachyosKernels.linuxPackages-cachyos-latest-x86_64-v4;

  # Usable only because CachyOS kernels carry sched-ext.
  services.scx.enable = true;
  services.scx.scheduler = "scx_rustland";
}

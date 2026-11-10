{ pkgs, ... }:
{
  boot.kernelPackages = pkgs.cachyosKernels.linuxPackages-cachyos-latest-x86_64-v4;

  # Usable only because CachyOS kernels carry sched-ext.
  services.scx-loader.enable = true;
  services.scx-loader.config.default_sched = "scx_rustland";
}

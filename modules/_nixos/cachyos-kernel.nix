{ pkgs, ... }:
{
  boot.kernelPackages = pkgs.cachyosKernels.linuxPackages-cachyos-latest-x86_64-v4;

  # CachyOS kernels support sched-ext; Chaotic's module provides the service.
  services.scx.enable = true;
  services.scx.scheduler = "scx_rustland";
  services.scx.extraArgs = [ ];
}

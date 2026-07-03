{ pkgs, ... }:
{
  boot.kernelPackages = pkgs.cachyosKernels.linuxPackages-cachyos-latest-x86_64-v4;

  # CachyOS kernels support sched-ext; nixpkgs provides the service module.
  services.scx.enable = true;
  services.scx.scheduler = "scx_rustland";
}

{ config, ... }:
{
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  services.xserver.videoDrivers = [
    "amdgpu"
    "nvidia"
  ];

  hardware.nvidia = {
    modesetting.enable = true;
    nvidiaPersistenced = true;
    nvidiaSettings = true;
    open = true;
    package = config.boot.kernelPackages.nvidiaPackages.latest;
    powerManagement.enable = false;
    powerManagement.finegrained = false;
  };

  # Generate a CDI spec at boot via nvidia-ctk so podman containers can access
  # the GPU with `--device nvidia.com/gpu=all`. Provides nvidia-container-toolkit.
  hardware.nvidia-container-toolkit.enable = true;
}

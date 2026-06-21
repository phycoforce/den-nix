{ den, inputs, ... }:
{
  den.aspects.temperantia = {
    includes = [ den.batteries.hostname ];

    nixos = {
      imports = [
        inputs.chaotic.nixosModules.default
        inputs.disko.nixosModules.disko
        inputs.qylock.nixosModules.default
        { nixpkgs.overlays = [ inputs.nix-cachyos-kernel.overlays.pinned ]; }

        ./_nixos/base-system.nix
        ./_nixos/boot.nix
        ./_nixos/cachyos-kernel.nix
        ./_nixos/cachyos-settings.nix
        ./_nixos/niri.nix
        ./_nixos/noctalia-support.nix
        ./_nixos/nvidia.nix
        ./_nixos/storage.nix
      ];
    };
  };
}

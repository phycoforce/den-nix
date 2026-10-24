{ den, inputs, ... }:
{
  flake-file.inputs = {
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Must NOT follow nixpkgs: its binary cache depends on its own pin.
    nix-cachyos-kernel.url = "github:xddxdd/nix-cachyos-kernel/release";

    qylock = {
      url = "github:Darkkal44/qylock";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  den.aspects.temperantia = {
    includes = [
      den.batteries.hostname
      (den.batteries.unfree [
        "nvidia-x11"
        "nvidia-settings"
        "unrar"
      ])
    ];

    nixos = {
      imports = [
        inputs.disko.nixosModules.disko
        inputs.qylock.nixosModules.default
        { nixpkgs.overlays = [ inputs.nix-cachyos-kernel.overlays.pinned ]; }

        ./_nixos/base-system.nix
        ./_nixos/boot.nix
        ./_nixos/cachyos-kernel.nix
        ./_nixos/cachyos-settings.nix
        ./_nixos/nix-ld.nix
        ./_nixos/nvidia.nix
        ./_nixos/storage.nix
      ];
    };
  };
}

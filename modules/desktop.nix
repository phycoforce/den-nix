_: {
  den.aspects.desktop = {
    provides.to-hosts.nixos.imports = [
      ./_nixos/niri.nix
      ./_nixos/noctalia-support.nix
    ];

    homeManager.imports = [
      ./_home/ghostty.nix
      ./_home/niri.nix
      ./_home/noctalia.nix
    ];
  };
}

{ inputs, ... }:
{
  flake-file.inputs = {
    # Kept ONLY for the programs.noctalia HM module; the package comes from
    # nixpkgs (see _home/noctalia.nix). Upstream's cachix can never serve our
    # build — `follows` changes the drv hash, and a second nixpkgs universe is
    # forbidden by tests.nix lock-no-private-nixpkgs — so `follows` is free
    # here: the input's package thunk is never evaluated.
    noctalia = {
      url = "git+https://github.com/noctalia-dev/noctalia?ref=main";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  den.aspects.desktop = {
    provides.to-hosts.nixos.imports = [
      ./_nixos/niri.nix
      ./_nixos/noctalia-support.nix
    ];

    homeManager.imports = [
      inputs.noctalia.homeModules.default

      ./_home/niri.nix
      ./_home/noctalia.nix
    ];
  };
}

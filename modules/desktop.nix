{ inputs, ... }:
{
  flake-file.inputs = {
    # Current CachyOS setup uses Noctalia Shell v4 via Quickshell.
    # Do not make noctalia follow nixpkgs; noctalia.cachix.org binaries are
    # built against its own pinned nixpkgs (follows would force source
    # rebuilds of quickshell/noctalia-shell).
    noctalia.url = "git+https://github.com/noctalia-dev/noctalia?ref=legacy-v4";
  };

  den.aspects.desktop = {
    provides.to-hosts.nixos.imports = [
      ./_nixos/niri.nix
      ./_nixos/noctalia-support.nix
    ];

    homeManager.imports = [
      inputs.noctalia.homeModules.default

      ./_home/niri.nix
      ./_home/noctalia-shell.nix
    ];
  };
}

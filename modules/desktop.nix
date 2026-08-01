{ inputs, ... }:
{
  flake-file.inputs = {
    # Kept ONLY for the programs.noctalia-shell HM module. The package itself
    # comes from nixpkgs (see _home/noctalia-shell.nix), which Hydra caches -
    # verified 2026-08-01: noctalia.cachix.org never carried the legacy-v4
    # noctalia-shell build (its cachix.yml triggers on main only; the branch is
    # frozen/EOL since 2026-07-02), so pinning a private nixpkgs universe here
    # bought a stale 1.4 GiB duplicate Qt6+quickshell closure and no cache
    # hits. With no packages consumed from this input, `follows` is free.
    noctalia = {
      url = "git+https://github.com/noctalia-dev/noctalia?ref=legacy-v4";
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
      ./_home/noctalia-shell.nix
    ];
  };
}

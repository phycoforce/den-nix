{ inputs, ... }:
{
  flake-file.inputs = {
    # Kept ONLY for the programs.noctalia HM module (v5; main). The package
    # itself comes from nixpkgs (attr `noctalia`, Hydra-cached — see
    # _home/noctalia.nix), same pattern as the v4 era. Upstream's cachix now
    # DOES carry main builds, but only against its own lock: any `follows`
    # changes the drv hash, so cachix hits require a second nixpkgs universe
    # (tests.nix lock-no-private-nixpkgs forbids exactly that). Since our
    # explicit `package` means the input's package thunk is never evaluated,
    # `follows` stays free. validateConfig catches module/package skew at
    # build time (module tracks main; nixpkgs ships tagged betas).
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

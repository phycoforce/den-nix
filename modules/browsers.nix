{ inputs, ... }:
{
  # Zen is not in nixpkgs (checked 2026-08-02); this community flake wraps
  # upstream's release tarballs with wrapFirefox. Both inputs follow ours so
  # the lock keeps a single nixpkgs universe (tests.nix
  # lock-no-private-nixpkgs). Unlike noctalia that costs nothing here: the
  # 130 MiB zen-beta-bin-unwrapped is served by nix-community.cachix.org
  # (already a substituter in dendritic.nix), and the only local work is the
  # wrapper plus its .desktop file, both preferLocalBuild - plan-gate reports
  # 0 violations, so no baseline entry is needed.
  flake-file.inputs.zen-browser = {
    url = "github:0xc000022070/zen-browser-flake";
    inputs.nixpkgs.follows = "nixpkgs";
    inputs.home-manager.follows = "home-manager";
  };

  den.aspects.browsers = {
    homeManager =
      { pkgs, ... }:
      {
        # `default` is the beta variant, i.e. Zen's ordinary release channel
        # (twilight is the nightly one). The bare package, not the flake's HM
        # module: this installs Zen next to firefox and nothing else - BROWSER
        # in _home/core.nix and the Mod+B keybind in _home/niri.nix both still
        # say firefox. Note _home/core.nix deliberately has no xdg.mimeApps
        # block, so the http/https default is whatever the installed .desktop
        # files resolve to at runtime; Zen may win it the way chromium once did.
        home.packages = [ inputs.zen-browser.packages.${pkgs.stdenv.hostPlatform.system}.default ];
      };
  };
}

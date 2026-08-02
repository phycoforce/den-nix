{ pkgs, ... }:
{
  # Noctalia v5 (C++ rewrite). Deliberately close to upstream defaults: the
  # v4 theming/config surface was not ported (see modules/_archive/noctalia-v4).
  programs.noctalia = {
    enable = true;

    # nixpkgs' v5 package (attr `noctalia`, Hydra-cached — narinfo verified
    # 2026-08-02). Overrides the flake module's mkDefault of its own package,
    # so the input's package thunk is never evaluated (v4-era pattern kept).
    package = pkgs.noctalia;

    # Rendered to ~/.config/noctalia/config.toml and validated at build time
    # by `noctalia config validate` (validateConfig default). Runtime tweaks
    # from the settings UI land in a separate overrides file, so this stays
    # the declarative baseline. Module (input main) may run ahead of the
    # nixpkgs beta package; the build-time validation catches any skew.
    settings = {
      # DDC/CI brightness for the external monitor (needs ddcutil + i2c from
      # _nixos/noctalia-support.nix); v5 ships no other external tool deps.
      brightness.enable_ddcutil = true;

      # The only theme templates kept from v4 — both are load-bearing for
      # existing config in this repo, not cosmetics:
      #  - niri: regenerates ~/.config/niri/noctalia.kdl (accent colors),
      #    which niri/config.kdl includes; seeded by _home/niri.nix.
      #  - starship: injects a palette block into the config at
      #    STARSHIP_CONFIG between the same markers _home/core.nix manages.
      # gtk/qt/ghostty app theming from v4 was dropped (upstream default).
      theme.templates.builtin_ids = [
        "niri"
        "starship"
      ];
    };
  };
}

# Noctalia v4 archive (retired 2026-08-02)

Frozen copy of the Noctalia Shell v4 Home Manager config, kept for reference
after the migration to v5. Nothing in `_archive/` is loaded by import-tree.

What v4 looked like here:

- `noctalia-shell-home.nix` — `programs.noctalia-shell` (quickshell/QML v4 HM
  module) with a custom Catppuccin Mocha 16-token color scheme, plus a jq
  activation script that merged `~/.config/noctalia/settings.json` in place
  (active templates gtk/ghostty/code/niri/qt/starship, Noto fonts,
  auto-location, session-menu power options with number keybinds).
- The package came from nixpkgs (`noctalia-shell` 4.7.x, Hydra-cached); the
  flake input pinned `?ref=legacy-v4` only for its HM module.
- `_nixos/noctalia-support.nix` shipped v4's helper stack: brightnessctl,
  cliphist, imagemagick, playerctl, wl-clipboard, wlr-randr, wlsunset,
  geoclue2 and evolution-data-server. v5 (C++ rewrite) does all of that
  natively, so the module now only keeps ddcutil/i2c and upower.

v5 uses `~/.config/noctalia/config.toml` (TOML, managed declaratively via
`programs.noctalia.settings`); it never reads v4's `settings.json`, which can
stay on disk (inert) or be deleted. Runtime tweaks made in the v5 settings UI
land in a separate overrides file, not in the HM-managed config.toml.

Keybind translation (niri binds, v4 `noctalia-shell ipc call …` →
v5 `noctalia msg …`) lives in `_home/niri.nix`; the v4↔v5 command mapping is
recorded in the migration commit message.

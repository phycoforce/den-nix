{ config, pkgs, ... }:
let
  # Wallpapers live in the repo (../../wallpapers) so a fresh install carries
  # them; home.file below materializes them under $HOME as individual symlinks
  # (recursive = true), which keeps the directory itself writable — dropping an
  # extra image in by hand still works, it is just not tracked.
  wallpaperRelPath = "Pictures/Wallpapers";
  wallpaperDir = "${config.home.homeDirectory}/${wallpaperRelPath}";
in
{
  home.file.${wallpaperRelPath} = {
    source = ../../wallpapers;
    recursive = true;
  };

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
    # from the settings UI land in the state overrides file
    # (~/.local/state/noctalia/settings.toml) and SHADOW these keys — a value
    # changed in the UI must be mirrored here to stay declarative. Module
    # (input main) may run ahead of the nixpkgs beta package; the build-time
    # validation catches any skew.
    settings = {
      # DDC/CI brightness for the external monitor (needs ddcutil + i2c from
      # _nixos/noctalia-support.nix); v5 ships no other external tool deps.
      brightness.enable_ddcutil = true;

      bar.default = {
        margin_ends = 0;
        # start section; center/end stay upstream defaults.
        start = [
          "launcher"
          "wallpaper"
          "workspaces"
          "ram"
        ];
      };

      # Bar list entries resolve by name against [widget.<name>] definitions,
      # so these attach settings to entries in the default end section without
      # restating the list.
      widget = {
        network.show_label = false;
        # Collapse the system tray into a drawer panel behind a toggle button
        # instead of spilling every icon across the bar.
        tray.drawer = true;
      };

      wallpaper = {
        directory = wallpaperDir;
        # Rotate through the directory on the upstream default schedule
        # (random order, every 1800s, recursive).
        automation.enabled = true;
      };

      # IP geolocation for weather/night-light instead of a fixed address.
      location.auto_locate = true;

      shell = {
        # WAN IP in the network panel (Settings > Security > Network).
        external_ip_enabled = true;
        # Noctalia registers as the session polkit agent; the standalone
        # polkit-kde-agent autostart was dropped from _home/niri.nix — only
        # one agent can register per session.
        polkit_agent = true;
        panel = {
          session_placement = "floating";
          session_position = "center";
        };
        session.grid = true;
      };

      theme = {
        # Colors are derived from the current wallpaper. "faithful" keeps the
        # extracted hues close to the source image rather than re-mapping them
        # onto a tonal scheme. `builtin` still names the fallback palette used
        # when source is switched back to "builtin".
        builtin = "Catppuccin";
        source = "wallpaper";
        wallpaper_scheme = "faithful";
        templates = {
          #  - niri: regenerates ~/.config/niri/noctalia.kdl (accent colors),
          #    which niri/config.kdl includes; seeded by _home/niri.nix.
          #  - starship: injects a palette block into the config at
          #    STARSHIP_CONFIG between the same markers _home/core.nix manages.
          #  - ghostty: writes themes/noctalia; ~/.config/ghostty/config
          #    already carries `theme = noctalia`.
          #  - gtk3/gtk4: write gtk-*/noctalia.css (imported from gtk.css) on
          #    top of adw-gtk3-dark from _home/core.nix. Qt apps pick these
          #    colors up too via QT_QPA_PLATFORMTHEME=gtk3, which is also why
          #    the "qt" template stays off: its qt5ct/qt6ct color files would
          #    never be read.
          #  - btop: writes btop/themes/noctalia.theme and repoints
          #    color_theme (programs.btop is enabled in _home/core.nix).
          builtin_ids = [
            "btop"
            "ghostty"
            "gtk3"
            "gtk4"
            "niri"
            "starship"
          ];
          # vscode: writes a Noctalia theme extension into ~/.vscode;
          # select "Noctalia Theme" once inside VSCode to activate it.
          community_ids = [ "vscode" ];
        };
      };
    };
  };
}

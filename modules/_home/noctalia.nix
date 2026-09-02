{ config, pkgs, ... }:
let
  # Wallpapers ship in the repo so a fresh install carries them; `recursive`
  # symlinks them individually, keeping the directory itself writable for
  # hand-dropped (untracked) images.
  wallpaperRelPath = "Pictures/Wallpapers";
  wallpaperDir = "${config.home.homeDirectory}/${wallpaperRelPath}";

  # The .keep file exists only so Home Manager materializes the directory:
  # noctalia is not documented to create a missing screenshot save directory.
  screenshotRelPath = "Pictures/Screenshots";
  screenshotDir = "${config.home.homeDirectory}/${screenshotRelPath}";
in
{
  home.file = {
    ${wallpaperRelPath} = {
      source = ../../wallpapers;
      recursive = true;
    };

    "${screenshotRelPath}/.keep".text = "";
  };

  # Deliberately close to upstream v5 defaults.
  programs.noctalia = {
    enable = true;

    # HM's default is already pkgs.noctalia; kept explicit so a module-default
    # change upstream cannot silently move the package off the Hydra cache.
    package = pkgs.noctalia;

    # Runtime tweaks made in the settings UI land in
    # ~/.local/state/noctalia/settings.toml and SHADOW these keys — mirror any
    # UI change here to stay declarative. `noctalia config validate` runs at
    # build time and catches skew between the module and the package.
    settings = {
      # Needs ddcutil + i2c from _nixos/noctalia-support.nix.
      brightness.enable_ddcutil = true;

      bar.default = {
        margin_ends = 0;
        # center/end stay upstream defaults.
        start = [
          "launcher"
          "wallpaper"
          "screenshot"
          "workspaces"
          "ram"
        ];
      };

      # Bar entries resolve by name against [widget.<name>], so these attach
      # settings to default end-section entries without restating the list.
      widget = {
        network.show_label = false;
        tray.drawer = true;
      };

      wallpaper = {
        directory = wallpaperDir;
        automation.enabled = true;
      };

      # IP geolocation for weather/night-light instead of a fixed address.
      location.auto_locate = true;

      # Fires on every track change; the bar's media widget shows the same
      # state. Other OSD kinds (volume, brightness, ...) stay on.
      osd.kinds.media = false;

      shell = {
        external_ip_enabled = true;
        # Only one polkit agent can register per session, so the standalone
        # polkit-kde-agent autostart is deliberately absent from _home/niri.nix.
        polkit_agent = true;
        launcher = {
          app_grid = true;
          compact = true;
        };
        panel = {
          session_placement = "floating";
          session_position = "center";
        };
        screen_corners.enabled = true;

        # These also govern the Ctrl+Shift+1/2 binds in _home/niri.nix, which
        # go through the shell rather than niri's built-in screenshot actions;
        # the cost is that captures now need noctalia running.
        screenshot = {
          directory = screenshotDir;
          save_to_file = true;
          # Both at once — niri's screenshot-path could only do one or other.
          copy_to_clipboard = true;
        };

        session.grid = true;
      };

      theme = {
        # Colors come from the wallpaper; "faithful" keeps the extracted hues
        # close to the source image. `builtin` only names the fallback palette
        # for when source is switched back to "builtin".
        builtin = "Catppuccin";
        source = "wallpaper";
        wallpaper_scheme = "faithful";
        templates = {
          # Each id rewrites that app's own theme file; the counterpart that
          # selects it lives elsewhere: niri/noctalia.kdl (_home/niri.nix),
          # starship palette markers (_home/core.nix), `theme = noctalia` in
          # _home/ghostty.nix, and one UNMANAGED file — gtk.css's @import of
          # noctalia.css. "qt" stays off deliberately: with
          # QT_QPA_PLATFORMTHEME=gtk3, Qt apps read the gtk3/gtk4 output and
          # the qt5ct/qt6ct files would never be looked at.
          builtin_ids = [
            "btop"
            "ghostty"
            "gtk3"
            "gtk4"
            "niri"
            "starship"
          ];
          # Both need a client-side counterpart, because the engine renders
          # only where the output directory's parent already exists: discord
          # into ~/.config/vesktop/themes (created by modules/communication.nix
          # — the template's other clients therefore leave no stray dirs), and
          # vscode into an installed NoctaliaTheme extension (installed by
          # modules/development.nix). tests.nix guards both ids.
          community_ids = [
            "discord"
            "vscode"
          ];
        };
      };
    };
  };
}

{ pkgs, ... }:
{
  # Noctalia v5 covers clipboard history, brightness, MPRIS and screenshots
  # natively, and niri's built-in `screenshot*` actions never shelled out to
  # grim/slurp, so the v4-era helper stack (brightnessctl, cliphist, playerctl,
  # grim, slurp, swappy, hyprpicker) is gone. wl-clipboard stays: wl-copy is
  # useful on its own in a terminal. qt5ct/qt6ct are gone too — qt.platformTheme
  # in _home/core.nix and QT_QPA_PLATFORMTHEME in _home/niri.nix both pin Qt to
  # gtk3, so neither tool's config was ever read.
  home.packages = with pkgs; [
    firefox
    htop
    kdePackages.kcalc
    libnotify
    nautilus
    nano
    networkmanagerapplet
    obs-studio
    p7zip
    pavucontrol
    usbutils
    wl-clipboard
    xdg-utils
    xwayland-satellite
    zip
  ];
}

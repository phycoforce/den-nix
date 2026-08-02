{ pkgs, ... }:
{
  # Deliberately no clipboard/brightness/MPRIS/screenshot helpers: Noctalia
  # covers those natively. wl-clipboard stays only because wl-copy is useful
  # on its own in a terminal.
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

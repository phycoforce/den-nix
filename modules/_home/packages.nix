{ pkgs, ... }:
{
  home.packages = with pkgs; [
    _1password-gui
    brightnessctl
    cliphist
    firefox
    grim
    htop
    hyprpicker
    kdePackages.kcalc
    libnotify
    nautilus
    nano
    networkmanagerapplet
    p7zip
    pavucontrol
    playerctl
    slurp
    swappy
    usbutils
    wl-clipboard
    xdg-utils
    xwayland-satellite
    zip
  ];
}

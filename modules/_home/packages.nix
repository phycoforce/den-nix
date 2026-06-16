{ pkgs, ... }:
{
  home.packages = with pkgs; [
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
    obs-studio
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

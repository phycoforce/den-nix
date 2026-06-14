{ pkgs, ... }:
{
  home.packages = with pkgs; [
    alacritty
    brightnessctl
    cliphist
    docker-compose
    firefox
    grim
    htop
    hyprpicker
    kdePackages.kcalc
    libnotify
    nautilus
    networkmanagerapplet
    p7zip
    pavucontrol
    playerctl
    slurp
    swappy
    usbutils
    wineWow64Packages.wayland
    wl-clipboard
    xdg-utils
    xwayland-satellite
    zip
  ];
}

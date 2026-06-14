{ pkgs, ... }:
{
  hardware.i2c.enable = true;

  services = {
    geoclue2.enable = true;
    gnome.evolution-data-server.enable = true;
    upower.enable = true;
    udev.packages = [ pkgs.ddcutil ];
  };

  environment.systemPackages = with pkgs; [
    brightnessctl
    cliphist
    ddcutil
    imagemagick
    playerctl
    wl-clipboard
    wlr-randr
    wlsunset
  ];
}

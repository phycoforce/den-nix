{ pkgs, ... }:
{
  # Noctalia handles clipboard, night light, wallpaper, screenshots, MPRIS,
  # calendar and geolocation itself; ddcutil is the one external tool it still
  # shells out to (brightness.enable_ddcutil in _home/noctalia.nix).
  hardware.i2c.enable = true;

  services = {
    udev.packages = [ pkgs.ddcutil ];
    # Battery/UPS/peripheral state over D-Bus for the bar battery widget.
    upower.enable = true;
  };

  environment.systemPackages = [ pkgs.ddcutil ];
}

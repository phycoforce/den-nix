{ pkgs, ... }:
{
  # Noctalia v5 does clipboard history, night light (wlr-gamma), wallpaper,
  # screenshots, MPRIS, calendar (libical/CalDAV) and IP geolocation natively,
  # so the v4 helper stack (brightnessctl, cliphist, imagemagick, playerctl,
  # wl-clipboard, wlr-randr, wlsunset, geoclue2, evolution-data-server) is
  # gone (archived in modules/_archive/noctalia-v4). What remains:

  # DDC/CI brightness for external monitors — the one optional CLI tool v5
  # still shells out to (brightness.enable_ddcutil in _home/noctalia.nix).
  hardware.i2c.enable = true;

  services = {
    udev.packages = [ pkgs.ddcutil ];
    # Battery/UPS/peripheral state over D-Bus for the bar battery widget.
    upower.enable = true;
  };

  environment.systemPackages = [ pkgs.ddcutil ];
}

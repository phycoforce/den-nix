{ config, pkgs, ... }:
{
  programs.niri = {
    enable = true;
    useNautilus = true;
  };

  services.greetd = {
    enable = true;
    settings.default_session = {
      command = "${pkgs.tuigreet}/bin/tuigreet --time --remember --cmd ${config.programs.niri.package}/bin/niri-session";
      user = "greeter";
    };
  };

  environment.systemPackages = with pkgs; [
    ghostty
    kdePackages.polkit-kde-agent-1
    nautilus
    tuigreet
    xwayland-satellite
  ];
}

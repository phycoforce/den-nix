{ pkgs, ... }:
{
  programs.niri = {
    enable = true;
    useNautilus = true;
  };

  services = {
    displayManager = {
      defaultSession = "niri";
      sddm = {
        enable = true;
        wayland.enable = true;
      };
    };

    # Keep the keyring PAM hooks explicit for SDDM password-login auto-unlock.
    gnome.gnome-keyring.enable = true;
  };

  environment.systemPackages = with pkgs; [
    ghostty
    kdePackages.polkit-kde-agent-1
    nautilus
    xwayland-satellite
  ];
}

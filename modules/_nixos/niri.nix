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
        theme = "breeze";
        wayland.enable = true;
        extraPackages = with pkgs.kdePackages; [
          breeze-icons
          kirigami
          ksvg
          qqc2-breeze-style
          qqc2-desktop-style
        ];
      };
    };

    # Keep the keyring PAM hooks explicit for SDDM password-login auto-unlock.
    gnome.gnome-keyring.enable = true;
  };

  environment.systemPackages = with pkgs; [
    ghostty
    gnome-icon-theme
    hicolor-icon-theme
    kdePackages.polkit-kde-agent-1
    kdePackages.breeze
    kdePackages.breeze-icons
    mint-x-icons
    nautilus
    xwayland-satellite
  ];
}

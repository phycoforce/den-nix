{ pkgs, ... }:
{
  programs.niri = {
    enable = true;
    useNautilus = true;
  };

  programs.qylock = {
    enable = true;
    theme = "pixel-night-city";
    sddm.enable = true;
    quickshell.enable = false;
  };

  services = {
    xserver.enable = true;
    libinput.enable = true;

    displayManager = {
      defaultSession = "niri";
      sddm = {
        enable = true;
        theme = "pixel-night-city";
        # Keep the greeter on X11 for reliable mouse input before login.
        wayland.enable = false;
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
    adw-gtk3
    adwaita-icon-theme
    capitaine-cursors
    ghostty
    gnome-icon-theme
    hicolor-icon-theme
    kdePackages.polkit-kde-agent-1
    kdePackages.breeze
    kdePackages.breeze-icons
    nautilus
    xwayland-satellite
  ];
}

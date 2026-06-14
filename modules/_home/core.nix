{ pkgs, ... }:
{
  programs.home-manager.enable = true;

  home.sessionVariables = {
    BROWSER = "firefox";
    EDITOR = "vim";
    NIXOS_OZONE_WL = "1";
    TERMINAL = "alacritty";
  };

  xdg = {
    enable = true;
    userDirs = {
      enable = true;
      createDirectories = true;
    };
  };

  programs.git = {
    enable = true;
    settings = {
      user = {
        name = "phycoforce";
        email = "15784209+phycoforce@users.noreply.github.com";
      };
      core.sshCommand = "ssh -i ~/.ssh/ssh-key-2023-12-26.key";
    };
  };

  programs.ssh.enable = true;

  programs.tmux = {
    enable = true;
    clock24 = true;
    keyMode = "vi";
    extraConfig = "set -g mouse on";
  };

  programs.btop.enable = true;
  programs.eza.enable = true;
  programs.jq.enable = true;

  programs.starship = {
    enable = true;
    enableBashIntegration = true;
  };

  programs.alacritty.enable = true;

  programs.ghostty = {
    enable = true;
    settings = {
      background-opacity = 0.9;
      theme = "catppuccin-mocha";
    };
  };
}

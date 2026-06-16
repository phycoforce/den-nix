{ pkgs, ... }:
{
  programs.home-manager.enable = true;

  home.sessionVariables = {
    BROWSER = "firefox";
    EDITOR = "nano";
    NIXOS_OZONE_WL = "1";
    TERMINAL = "ghostty";
  };

  home.file = {
    ".bash_profile".force = true;
    ".bashrc".force = true;
    ".profile".force = true;
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
    };
  };

  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    settings."*" = {
      ForwardAgent = false;
      AddKeysToAgent = "no";
      Compression = false;
      ServerAliveInterval = 0;
      ServerAliveCountMax = 3;
      HashKnownHosts = false;
      UserKnownHostsFile = "~/.ssh/known_hosts";
      ControlMaster = "no";
      ControlPath = "~/.ssh/master-%r@%n:%p";
      ControlPersist = "no";
    };
  };

  programs.tmux = {
    enable = true;
    clock24 = true;
    keyMode = "vi";
    extraConfig = "set -g mouse on";
  };

  programs.btop.enable = true;
  programs.eza.enable = true;
  programs.jq.enable = true;

  programs.bash = {
    enable = true;
    shellAliases = {
      grep = "grep --color=auto";
      ls = "ls --color=auto";
    };
  };

  programs.starship = {
    enable = true;
    enableBashIntegration = true;
    settings = {
      add_newline = true;
      command_timeout = 200;
      format = "[$directory$git_branch$git_status]($style)$character";

      character = {
        error_symbol = "[✗](bold cyan)";
        success_symbol = "[❯](bold cyan)";
      };

      directory = {
        truncation_length = 2;
        truncation_symbol = "…/";
        repo_root_style = "bold cyan";
        repo_root_format = "[$repo_root]($repo_root_style)[$path]($style)[$read_only]($read_only_style) ";
      };

      git_branch = {
        format = "[$branch]($style) ";
        style = "italic cyan";
      };

      git_status = {
        format = "[$all_status]($style)";
        style = "cyan";
        ahead = "⇡\${count} ";
        diverged = "⇕⇡\${ahead_count}⇣\${behind_count} ";
        behind = "⇣\${count} ";
        conflicted = " ";
        up_to_date = " ";
        untracked = "? ";
        modified = " ";
        stashed = "";
        staged = "";
        renamed = "";
        deleted = "";
      };
    };
  };

  programs.ghostty = {
    enable = true;
    settings = {
      background-opacity = 0.9;
      theme = "catppuccin-mocha";
    };
  };
}

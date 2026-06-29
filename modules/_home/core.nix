{
  config,
  lib,
  pkgs,
  ...
}:
let
  starshipConfigPath = "${config.xdg.configHome}/noctalia/starship.toml";
  starshipSettings = {
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
  starshipBaseConfig = (pkgs.formats.toml { }).generate "starship-base.toml" starshipSettings;
in
{
  programs.home-manager.enable = true;

  home.pointerCursor = {
    enable = true;
    gtk.enable = true;
    x11.enable = true;
    name = "capitaine-cursors";
    package = pkgs.capitaine-cursors;
    size = 24;
  };

  gtk = {
    enable = true;
    theme = {
      name = "adw-gtk3-dark";
      package = pkgs.adw-gtk3;
    };
    iconTheme = {
      name = "Adwaita";
      package = pkgs.adwaita-icon-theme;
    };
  };

  qt = {
    enable = true;
    platformTheme.name = "gtk3";
  };

  home.sessionVariables = {
    BROWSER = "firefox";
    EDITOR = "nano";
    ICON_THEME = "Adwaita";
    NIXOS_OZONE_WL = "1";
    TERMINAL = "ghostty";
    XCURSOR_SIZE = "24";
    XCURSOR_THEME = "capitaine-cursors";
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

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
    enableBashIntegration = true;
  };

  programs.starship = {
    enable = true;
    enableBashIntegration = true;
    configPath = starshipConfigPath;
  };

  home.activation.starshipNoctaliaConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    configFile="${starshipConfigPath}"
    baseConfig="${starshipBaseConfig}"
    markerBegin='# >>> NOCTALIA STARSHIP PALETTE >>>'
    markerEnd='# <<< NOCTALIA STARSHIP PALETTE <<<'

    mkdir -p "$(dirname "$configFile")"
    tmp="$(${pkgs.coreutils}/bin/mktemp)"
    paletteBlock="$(${pkgs.coreutils}/bin/mktemp)"
    ${pkgs.coreutils}/bin/cp "$baseConfig" "$tmp"

    if [ -f "$configFile" ]; then
      if ${pkgs.gawk}/bin/awk -v begin="$markerBegin" -v end="$markerEnd" '
        $0 == begin { capture = 1 }
        capture { print }
        $0 == end { found = 1; exit }
        END { exit found ? 0 : 1 }
      ' "$configFile" > "$paletteBlock"; then
        if ${pkgs.gnugrep}/bin/grep -qE '^[[:space:]]*palette[[:space:]]*=' "$tmp"; then
          ${pkgs.gnused}/bin/sed -i -E 's/^([[:space:]]*)palette([[:space:]]*)=.*/\1palette\2= "noctalia"/' "$tmp"
        else
          ${pkgs.gnused}/bin/sed -i '1i palette = "noctalia"' "$tmp"
        fi

        printf '\n' >> "$tmp"
        ${pkgs.coreutils}/bin/cat "$paletteBlock" >> "$tmp"
      fi
    fi

    ${pkgs.coreutils}/bin/install -m 0644 "$tmp" "$configFile"
    rm -f "$tmp" "$paletteBlock"
  '';
}

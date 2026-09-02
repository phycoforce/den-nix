_: {
  # The package, its systemd unit and shell-integration injection all come from
  # ghostty itself via the desktop system aspect; only the config file is ours.
  programs.ghostty = {
    enable = true;
    package = null;
    systemd.enable = false;
    enableBashIntegration = false;

    settings = {
      background-opacity = 0.9;
      theme = "noctalia";
      # Remote ncurses has no xterm-ghostty entry, so backspace/arrows/clear
      # break over ssh: ssh-terminfo installs it on the host, ssh-env is the
      # xterm-256color fallback for hosts without tic.
      shell-integration-features = "ssh-env,ssh-terminfo";
    };
  };
}

{ den, ... }:
{
  den.aspects.development = {
    includes = [ (den.batteries.unfree [ "1password-cli" "vscode" "winbox" ]) ];

    provides.to-hosts.nixos = {
      virtualisation.podman.enable = true;
    };

    homeManager = { pkgs, ... }: {
      programs.gh.enable = true;

      programs.vscode = {
        enable = true;
        package = pkgs.vscode;
      };

      home.packages = with pkgs; [
        _1password-cli
        age
        cloudflared
        crane
        fluxcd
        go-task
        gum
        helmfile
        jq
        just
        k9s
        krew
        kubecolor
        kubeconform
        kubectl
        kubernetes-helm
        kustomize
        minijinja
        mise
        moreutils
        opencode
        podman
        podman-compose
        sops
        stern
        talhelper
        talosctl
        viddy
        winbox
        yq
      ];
    };
  };
}

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

      programs.mise = {
        enable = true;
        enableBashIntegration = true;
        package = pkgs.mise;
      };

      programs.bash = {
        shellAliases.k = "kubectl";
        initExtra = ''
          if command -v kubectl >/dev/null 2>&1; then
            source <(kubectl completion bash)
            complete -o default -F __start_kubectl k
          fi
        '';
      };

      home.packages = with pkgs; [
        _1password-cli
        age
        cloudflared
        codex
        crane
        distrobox
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

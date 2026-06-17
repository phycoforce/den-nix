{ den, inputs, ... }:
{
  den.aspects.development = {
    includes = [
      (den.batteries.unfree [
        "1password-cli"
        "vscode"
        "winbox"
      ])
    ];

    provides.to-hosts.nixos = {
      virtualisation.podman = {
        enable = true;
        dockerCompat = true;
        dockerSocket.enable = true;
      };
    };

    homeManager =
      {
        config,
        lib,
        pkgs,
        ...
      }:
      let
        codexDesktop = inputs.codex-desktop.packages.${pkgs.stdenv.hostPlatform.system}.codex-desktop;
        codexDesktopWayland = pkgs.symlinkJoin {
          name = "codex-desktop-wayland";
          paths = [ codexDesktop ];
          buildInputs = [ pkgs.makeWrapper ];
          postBuild = ''
            wrapProgram "$out/bin/codex-desktop" \
              --set CODEX_OZONE wayland \
              --set XCURSOR_THEME Bibata-Modern-Classic \
              --set XCURSOR_SIZE 32
          '';
        };
        krewRoot = "${config.home.homeDirectory}/.krew";
        krewPlugins = [
          "browse-pvc"
          "cert-manager"
          "cnpg"
          "node-shell"
          "rook-ceph"
          "view-secret"
        ];
        kubectlKrew = pkgs.writeShellScriptBin "kubectl-krew" ''
          exec ${pkgs.krew}/bin/krew "$@"
        '';
      in
      {
        home.sessionPath = [ "${krewRoot}/bin" ];
        home.sessionVariables.KREW_ROOT = krewRoot;

        home.activation.krewPlugins = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          export KREW_ROOT="${krewRoot}"
          export PATH="${krewRoot}/bin:${pkgs.krew}/bin:${pkgs.kubectl}/bin:$PATH"

          ${pkgs.coreutils}/bin/mkdir -p "$KREW_ROOT"

          installed="$(${pkgs.krew}/bin/krew list 2>/dev/null || true)"
          missing=()
          for plugin in ${lib.escapeShellArgs krewPlugins}; do
            if ! printf '%s\n' "$installed" | ${pkgs.gnugrep}/bin/grep -qx "$plugin"; then
              missing+=("$plugin")
            fi
          done

          if [ "''${#missing[@]}" -gt 0 ]; then
            ${pkgs.krew}/bin/krew update
            for plugin in "''${missing[@]}"; do
              ${pkgs.krew}/bin/krew install "$plugin"
            done
          fi
        '';

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
            export KREW_ROOT="${krewRoot}"
            case ":$PATH:" in
              *":$KREW_ROOT/bin:"*) ;;
              *) export PATH="$KREW_ROOT/bin:$PATH" ;;
            esac

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
          codexDesktopWayland
          crane
          distrobox
          fluxcd
          go-task
          gum
          helmfile
          jq
          just
          just-lsp
          k9s
          krew
          kubectlKrew
          kubecolor
          kubeconform
          kubectl
          kubernetes-helm
          kustomize
          minijinja
          moreutils
          nixd
          opencode
          opentofu
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

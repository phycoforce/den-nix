{ den, ... }:
{
  den.aspects.development = {
    includes = [
      den.aspects.foundation
      (den.batteries.unfree [
        "vscode"
        "winbox"
      ])
    ];

    user.extraGroups = [ "podman" ];

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
        krewRoot = "${config.home.homeDirectory}/.krew";
        # Extra krew indexes to register (index name -> git URL). Plugins from a
        # non-default index are referenced in krewPlugins as "<index>/<name>".
        krewIndexes = {
          kopiur = "https://github.com/home-operations/kopiur.git";
        };
        krewPlugins = [
          "browse-pvc"
          "cert-manager"
          "cnpg"
          "kopiur/kopiur"
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

          existingIndexes="$(${pkgs.krew}/bin/krew index list 2>/dev/null || true)"
          ${lib.concatStrings (
            lib.mapAttrsToList (name: url: ''
              if ! printf '%s\n' "$existingIndexes" | ${pkgs.gnugrep}/bin/grep -q '^${name}[[:space:]]'; then
                ${pkgs.krew}/bin/krew index add ${lib.escapeShellArg name} ${lib.escapeShellArg url}
              fi
            '') krewIndexes
          )}
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
          # nixpkgs' mise defaults node.compile to true, which forces a
          # from-source node build (and fails here: no C/C++ toolchain). The
          # prebuilt node tarball runs fine via nix-ld (see _nixos/nix-ld.nix,
          # which already provides libstdc++), so use it instead.
          globalConfig.settings.node.compile = false;
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
          age
          ansible
          cloudflared
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
          openssl
          opentofu
          podman
          podman-compose
          sops
          stern
          talhelper
          talosctl
          viddy
          winbox
          yq-go
        ];
      };
  };
}

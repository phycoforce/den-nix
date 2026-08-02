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
        # Plugins from a non-default index are named "<index>/<name>" below.
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
        # WinBox 4's prebuilt Qt only carries the xcb platform plugin, so it
        # aborts under the session-wide QT_QPA_PLATFORM=wayland set by niri.
        winbox = pkgs.winbox.overrideAttrs (old: {
          postInstall = (old.postInstall or "") + ''
            wrapProgram "$out/bin/WinBox" --set QT_QPA_PLATFORM xcb
          '';
        });

        # Marketplace id of the theme noctalia's `vscode` template renders into.
        vscodeThemeExtension = "Noctalia.noctaliatheme";
      in
      {
        home.sessionPath = [
          "${krewRoot}/bin"
          # mise activate only updates PATH from interactive prompt hooks, so
          # non-interactive shells (agents, editors, git hooks) need the shims
          # as a fallback; activate-mode paths still win interactively.
          "${config.home.homeDirectory}/.local/share/mise/shims"
        ];
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

        # noctalia's `vscode` template rewrites the color file inside an
        # installed NoctaliaTheme extension (see _home/noctalia.nix), so the
        # extension is installed imperatively: programs.vscode would symlink
        # the extensions dir read-only into the store, leaving the template
        # nowhere to write. The template's output path pins a version, so a
        # VSCode auto-update past it freezes the theme's colors.
        home.activation.vscodeNoctaliaTheme = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          extensions="${config.home.homeDirectory}/.vscode/extensions"

          # A directory the template made on its own has themes/ but no
          # manifest, and VSCode ignores it; that is the case to repair.
          installed=""
          for dir in "$extensions"/noctalia.noctaliatheme-*/; do
            [ -f "$dir/package.json" ] && installed=1
          done

          if [ -z "$installed" ]; then
            ${pkgs.coreutils}/bin/timeout 120 \
              ${config.programs.vscode.package}/bin/code \
              --install-extension ${lib.escapeShellArg vscodeThemeExtension} \
              || echo "vscode: could not install ${vscodeThemeExtension} (offline?); it is also installable from the Extensions view" >&2
          fi
        '';

        programs.mise = {
          enable = true;
          enableBashIntegration = true;
          package = pkgs.mise;
          # nixpkgs' mise defaults node.compile to true, which fails here (no
          # C/C++ toolchain); the prebuilt tarball runs fine via nix-ld.
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

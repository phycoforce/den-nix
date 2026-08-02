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
        # WinBox 4 ships a prebuilt Qt that only carries the xcb platform
        # plugin, so it aborts under the session-wide QT_QPA_PLATFORM=wayland
        # set by niri. Force xcb (via xwayland) for this program only.
        winbox = pkgs.winbox.overrideAttrs (old: {
          postInstall = (old.postInstall or "") + ''
            wrapProgram "$out/bin/WinBox" --set QT_QPA_PLATFORM xcb
          '';
        });

        # Marketplace id of the theme noctalia's `vscode` community template
        # renders into; see the activation script below.
        vscodeThemeExtension = "Noctalia.noctaliatheme";
      in
      {
        home.sessionPath = [
          "${krewRoot}/bin"
          # mise activate (below) only updates PATH from interactive prompt
          # hooks, so non-interactive shells (agents, editors, git hooks) see a
          # stale or incomplete tool set. Shims re-resolve per invocation and
          # act as the fallback; activate-mode paths still win interactively.
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

        # NoctaliaTheme is an ordinary marketplace extension. The `vscode`
        # community template (enabled in _home/noctalia.nix) does not ship it —
        # it only rewrites the color file inside an installed copy, at
        # ~/.vscode/extensions/noctalia.noctaliatheme-<version>/themes/, and
        # creates that path even when nothing is installed there. VSCode loads
        # only the extensions registered in extensions.json, so what the
        # template leaves behind on its own is a palette nothing reads. Install
        # it the way VSCode does, imperatively and idempotently, in the manner
        # of the krew block above; picking it is then one Ctrl+K Ctrl+T
        # ("NoctaliaTheme") away, and settings.json stays hand-edited.
        #
        # Declaring it through programs.vscode instead would symlink the
        # extension directory into the store, and the template could no longer
        # write the palette into it; it would also drag every other extension
        # (all installed by hand from the Extensions view) under Nix.
        #
        # The version in the template's output path is pinned upstream, so a
        # NoctaliaTheme release VSCode auto-updates past leaves the template
        # writing to a directory that no longer exists — the theme then freezes
        # at its shipped colors until upstream bumps the template.
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

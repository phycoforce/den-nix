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
        homeopsMcpConfigDir = "${config.xdg.configHome}/homeops-mcp";
        homeopsMcpSecretDomainPath = "${homeopsMcpConfigDir}/secret-domain";
        homeopsMcpMeminiApiKeyPath = "${homeopsMcpConfigDir}/memini-api-key";
        opnixTokenFile = "${config.xdg.configHome}/opnix/token";
        opnixPackage = inputs.opnix.packages.${pkgs.stdenv.hostPlatform.system}.default;
        homeopsMcpOpnixConfig = pkgs.writeText "homeops-mcp-opnix-secrets.json" (
          builtins.toJSON {
            secrets = [
              {
                path = ".config/homeops-mcp/secret-domain";
                reference = "op://kubernetes/cluster_secrets/SECRET_DOMAIN";
                owner = config.home.username;
                group = "aaron";
                mode = "0600";
              }
              {
                path = ".config/homeops-mcp/memini-api-key";
                reference = "op://kubernetes/memini/MEMINI_API_KEY";
                owner = config.home.username;
                group = "aaron";
                mode = "0600";
              }
            ];
          }
        );
        homeopsMcpEnvLoader = pkgs.writeText "homeops-mcp-env" ''
          if [ -r ${lib.escapeShellArg homeopsMcpSecretDomainPath} ]; then
            export HOMEOPS_SECRET_DOMAIN="$(${pkgs.coreutils}/bin/tr -d '\r\n' < ${lib.escapeShellArg homeopsMcpSecretDomainPath})"
          fi

          if [ -r ${lib.escapeShellArg homeopsMcpMeminiApiKeyPath} ]; then
            export MEMINI_API_KEY="$(${pkgs.coreutils}/bin/tr -d '\r\n' < ${lib.escapeShellArg homeopsMcpMeminiApiKeyPath})"
          fi
        '';
        sourceHomeopsMcpEnv = ". ${homeopsMcpEnvLoader}";
        codexDesktopRemoteMobileControl =
          inputs.codex-desktop-linux.packages.${pkgs.stdenv.hostPlatform.system}.codex-desktop-remote-mobile-control;
        codexDesktopRemoteMobileControlWrapped = pkgs.symlinkJoin {
          name = "codex-desktop-remote-mobile-control";
          paths = [ codexDesktopRemoteMobileControl ];
          buildInputs = [
            pkgs.makeWrapper
            pkgs.gnused
          ];
          postBuild = ''
            wrapProgram "$out/bin/codex-desktop" \
              --set XCURSOR_THEME Bibata-Modern-Classic \
              --set XCURSOR_SIZE 32 \
              --run ${lib.escapeShellArg sourceHomeopsMcpEnv}

            desktopFile="$out/share/applications/codex-desktop.desktop"
            if [ -f "$desktopFile" ]; then
              rm "$desktopFile"
              install -Dm0644 \
                "${codexDesktopRemoteMobileControl}/share/applications/codex-desktop.desktop" \
                "$desktopFile"
              substituteInPlace "$desktopFile" \
                --replace-fail "${codexDesktopRemoteMobileControl}/bin/codex-desktop" "$out/bin/codex-desktop"
            fi
          '';
        };
        codexWrapped = pkgs.writeShellScriptBin "codex" ''
          ${sourceHomeopsMcpEnv}
          exec ${pkgs.codex}/bin/codex "$@"
        '';
        opencodeWrapped = pkgs.writeShellScriptBin "opencode" ''
          ${sourceHomeopsMcpEnv}
          exec ${pkgs.opencode}/bin/opencode "$@"
        '';
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
        imports = [ inputs.opnix.homeManagerModules.default ];

        home.sessionPath = [ "${krewRoot}/bin" ];
        home.sessionVariables.KREW_ROOT = krewRoot;

        programs.onepassword-secrets = {
          enable = true;
          tokenFile = opnixTokenFile;
          secrets = {
            secretDomain = {
              reference = "op://kubernetes/cluster_secrets/SECRET_DOMAIN";
              path = ".config/homeops-mcp/secret-domain";
              group = "aaron";
              mode = "0600";
            };
            meminiApiKey = {
              reference = "op://kubernetes/memini/MEMINI_API_KEY";
              path = ".config/homeops-mcp/memini-api-key";
              group = "aaron";
              mode = "0600";
            };
          };
        };

        home.activation.retrieveOpnixSecrets = lib.mkForce (
          lib.hm.dag.entryAfter [ "createOpnixDirs" ] ''
            have_homeops_mcp_secrets() {
              [ -s ${lib.escapeShellArg homeopsMcpSecretDomainPath} ] \
                && [ -s ${lib.escapeShellArg homeopsMcpMeminiApiKeyPath} ]
            }

            if [ -n "''${DRY_RUN_CMD:-}" ]; then
              echo "Skipping OpNix secret retrieval during dry run"
            elif [ ! -f ${lib.escapeShellArg opnixTokenFile} ]; then
              echo "WARNING: Token file ${opnixTokenFile} does not exist!" >&2
              echo "INFO: Using existing HomeOps MCP secrets, skipping updates" >&2
              echo "INFO: Run 'opnix token set -path ${opnixTokenFile}' to configure the token" >&2
            elif [ ! -r ${lib.escapeShellArg opnixTokenFile} ]; then
              if have_homeops_mcp_secrets; then
                echo "WARNING: Token file ${opnixTokenFile} is not readable; using existing HomeOps MCP secrets" >&2
              else
                echo "ERROR: Cannot read OpNix token at ${opnixTokenFile}" >&2
                exit 1
              fi
            else
              echo "Processing config file: ${homeopsMcpOpnixConfig}"
              if ${opnixPackage}/bin/opnix secret \
                -token-file ${lib.escapeShellArg opnixTokenFile} \
                -config ${homeopsMcpOpnixConfig} \
                -output "$HOME"; then
                :
              elif have_homeops_mcp_secrets; then
                echo "WARNING: OpNix secret retrieval failed; using existing HomeOps MCP secrets" >&2
              else
                echo "ERROR: OpNix secret retrieval failed and no existing HomeOps MCP secrets are available" >&2
                exit 1
              fi
            fi
          ''
        );

        home.activation.homeopsMcpCodexConfig = lib.hm.dag.entryAfter [ "retrieveOpnixSecrets" ] ''
          if [ -n "''${DRY_RUN_CMD:-}" ]; then
            echo "Skipping HomeOps Codex MCP config during dry run"
          elif [ ! -r ${lib.escapeShellArg homeopsMcpSecretDomainPath} ]; then
            echo "WARNING: ${homeopsMcpSecretDomainPath} is missing; skipping HomeOps Codex MCP config" >&2
          else
            domain="$(${pkgs.coreutils}/bin/tr -d '\r\n' < ${lib.escapeShellArg homeopsMcpSecretDomainPath})"
            if [ -z "$domain" ]; then
              echo "WARNING: ${homeopsMcpSecretDomainPath} is empty; skipping HomeOps Codex MCP config" >&2
            else
              ${pkgs.codex}/bin/codex mcp remove homeops_toolhive >/dev/null 2>&1 || true
              ${pkgs.codex}/bin/codex mcp remove homeops_memini >/dev/null 2>&1 || true
              ${pkgs.codex}/bin/codex mcp add homeops_toolhive --url "https://mcp.$domain/mcp"
              ${pkgs.codex}/bin/codex mcp add homeops_memini --url "https://memini.$domain/mcp" --bearer-token-env-var MEMINI_API_KEY
            fi
          fi
        '';

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

        xdg.configFile."opencode/opencode.json".text = builtins.toJSON {
          "$schema" = "https://opencode.ai/config.json";
          mcp = {
            homeops_toolhive = {
              type = "remote";
              url = "https://mcp.{env:HOMEOPS_SECRET_DOMAIN}/mcp";
              enabled = true;
              timeout = 30000;
            };
            homeops_memini = {
              type = "remote";
              url = "https://memini.{env:HOMEOPS_SECRET_DOMAIN}/mcp";
              enabled = true;
              oauth = false;
              headers.Authorization = "Bearer {env:MEMINI_API_KEY}";
              timeout = 30000;
            };
          };
        };

        home.packages = with pkgs; [
          _1password-cli
          age
          cloudflared
          codexWrapped
          codexDesktopRemoteMobileControlWrapped
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
          opencodeWrapped
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
          yq
        ];
      };
  };
}

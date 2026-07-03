{ den, ... }:
{
  flake-file.inputs = {
    nixpkgs-codex.url = "github:NixOS/nixpkgs/master";

    codex-desktop-linux = {
      url = "github:ilysenko/codex-desktop-linux";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  den.aspects.agents = {
    includes = [
      den.aspects.foundation
      (den.batteries.unfree [
        "claude-code"
      ])
    ];

    homeManager =
      {
        config,
        inputs',
        lib,
        pkgs,
        ...
      }:
      let
        homeopsMcp = import ./_home/homeops-mcp-paths.nix config;
        homeopsMcpSecretDomainPath = homeopsMcp.secretDomain;
        homeopsMcpSecretDomain2Path = homeopsMcp.secretDomain2;
        homeopsMcpMeminiApiKeyPath = homeopsMcp.meminiApiKey;
        mcpNixosCommand = lib.getExe pkgs.mcp-nixos;
        # nixpkgs playwright-mcp defaults to downloading "chrome-for-testing" into its
        # read-only PLAYWRIGHT_BROWSERS_PATH (a /nix/store path), which fails. Pin it to the
        # version-matched Chromium that ships in pkgs.playwright-driver.browsers via
        # --executable-path so it never tries to provision a browser at runtime. Scratch
        # output goes to the XDG cache, never the project directory.
        playwrightMcpWrapped = pkgs.writeShellScriptBin "playwright-mcp-nix" ''
          set -eu
          browsers='${pkgs.playwright-driver.browsers}'
          chrome=$(set -- "$browsers"/chromium-*/chrome-linux*/chrome; printf '%s' "$1")
          exec ${lib.getExe pkgs.playwright-mcp} \
            --browser chrome \
            --executable-path "$chrome" \
            --headless \
            --isolated \
            --output-dir "''${XDG_CACHE_HOME:-$HOME/.cache}/playwright-mcp" \
            "$@"
        '';
        playwrightMcpCommand = lib.getExe playwrightMcpWrapped;
        codexHookPath = lib.makeBinPath [ pkgs.nodejs_22 ];
        codexPackage = inputs'.nixpkgs-codex.legacyPackages.codex;
        claudeMeminiCodexMarketplaceDir = "${config.xdg.configHome}/codex-plugin-marketplaces/claude-memini";
        claudeMeminiCodexMarketplaceJson = pkgs.writeText "claude-memini-marketplace.json" (
          builtins.toJSON {
            name = "claude-memini";
            interface.displayName = "Claude Code Memini";
            plugins = [
              {
                name = "memini";
                source = {
                  source = "local";
                  path = "./plugins/memini";
                };
                policy = {
                  installation = "AVAILABLE";
                  authentication = "ON_INSTALL";
                };
                category = "Developer Tools";
              }
            ];
          }
        );
        homeopsMcpEnvLoader = pkgs.writeText "homeops-mcp-env" ''
          if [ -r ${lib.escapeShellArg homeopsMcpSecretDomainPath} ]; then
            export HOMEOPS_SECRET_DOMAIN="$(${pkgs.coreutils}/bin/tr -d '\r\n' < ${lib.escapeShellArg homeopsMcpSecretDomainPath})"
          fi

          if [ -r ${lib.escapeShellArg homeopsMcpSecretDomain2Path} ]; then
            export HOMEOPS_SECRET_DOMAIN_2="$(${pkgs.coreutils}/bin/tr -d '\r\n' < ${lib.escapeShellArg homeopsMcpSecretDomain2Path})"
          fi

          if [ -r ${lib.escapeShellArg homeopsMcpMeminiApiKeyPath} ]; then
            export MEMINI_API_KEY="$(${pkgs.coreutils}/bin/tr -d '\r\n' < ${lib.escapeShellArg homeopsMcpMeminiApiKeyPath})"
            export MEMINI_TOKEN="$MEMINI_API_KEY"
          fi

          if [ -n "''${HOMEOPS_SECRET_DOMAIN:-}" ]; then
            export MEMINI_URL="https://memini.$HOMEOPS_SECRET_DOMAIN"
            export MEMINI_MCP_URL="$MEMINI_URL/mcp"
            export MEMINI_BASE_URL="$MEMINI_URL"
            export MEMINI_REQUIRE_HTTPS=1
          fi

          if [ -z "''${MEMINI_NAMESPACE:-}" ]; then
            memini_project="$(${pkgs.git}/bin/git remote get-url origin 2>/dev/null || true)"
            if [ -n "$memini_project" ]; then
              memini_project="''${memini_project%/}"
              memini_project="''${memini_project%.git}"
              memini_project="''${memini_project##*/}"
              memini_project="''${memini_project##*:}"
            fi

            if [ -z "$memini_project" ]; then
              memini_project="$(${pkgs.git}/bin/git rev-parse --show-toplevel 2>/dev/null || true)"
              memini_project="''${memini_project%/}"
              memini_project="''${memini_project##*/}"
            fi

            if [ -z "$memini_project" ]; then
              memini_project="$(${pkgs.coreutils}/bin/pwd -P)"
              memini_project="''${memini_project%/}"
              memini_project="''${memini_project##*/}"
            fi

            export MEMINI_NAMESPACE="$memini_project"
          fi
        '';
        sourceHomeopsMcpEnv = ". ${homeopsMcpEnvLoader}";
        codexDesktopRemoteMobileControl =
          inputs'.codex-desktop-linux.packages.codex-desktop-remote-mobile-control;
        codexDesktopRemoteMobileControlWrapped = pkgs.symlinkJoin {
          name = "codex-desktop-remote-mobile-control";
          paths = [ codexDesktopRemoteMobileControl ];
          buildInputs = [
            pkgs.makeWrapper
            pkgs.gnused
          ];
          postBuild = ''
            wrapProgram "$out/bin/codex-desktop" \
              --set XCURSOR_THEME capitaine-cursors \
              --set XCURSOR_SIZE 24 \
              --prefix PATH : ${lib.escapeShellArg codexHookPath} \
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
          export PATH=${lib.escapeShellArg codexHookPath}:$PATH
          exec ${codexPackage}/bin/codex "$@"
        '';
        claudeCodeWrapped = pkgs.writeShellScriptBin "claude" ''
          ${sourceHomeopsMcpEnv}
          export PATH=${lib.escapeShellArg codexHookPath}:$PATH
          export FORCE_AUTOUPDATE_PLUGINS=1
          exec ${pkgs.claude-code}/bin/claude "$@"
        '';
        opencodeWrapped = pkgs.writeShellScriptBin "opencode" ''
          ${sourceHomeopsMcpEnv}
          if [ "''${1-}" = "auth" ]; then
            shift
            exec ${pkgs.opencode}/bin/opencode --pure auth "$@"
          fi
          exec ${pkgs.opencode}/bin/opencode "$@"
        '';
        opencodeMeminiUpdate = pkgs.writeShellScriptBin "opencode-memini-update" ''
          set -eu
          opencode_config_dir="''${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
          if [ ! -r "$opencode_config_dir/package.json" ]; then
            echo "ERROR: $opencode_config_dir/package.json is missing" >&2
            exit 1
          fi

          if [ -d "$opencode_config_dir/node_modules/@eleboucher/opencode-memini" ]; then
            exec ${pkgs.bun}/bin/bun update --cwd "$opencode_config_dir" @eleboucher/opencode-memini
          fi

          exec ${pkgs.bun}/bin/bun install --cwd "$opencode_config_dir"
        '';
      in
      {
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
              ${codexPackage}/bin/codex mcp remove homeops_toolhive >/dev/null 2>&1 || true
              ${codexPackage}/bin/codex mcp remove homeops_memini >/dev/null 2>&1 || true
              ${codexPackage}/bin/codex mcp add homeops_toolhive --url "https://mcp.$domain/mcp"
            fi
          fi

          if [ -r ${lib.escapeShellArg homeopsMcpSecretDomain2Path} ]; then
            domain2="$(${pkgs.coreutils}/bin/tr -d '\r\n' < ${lib.escapeShellArg homeopsMcpSecretDomain2Path})"
            if [ -z "$domain2" ]; then
              echo "WARNING: ${homeopsMcpSecretDomain2Path} is empty; skipping konflate Codex MCP config" >&2
            else
              ${codexPackage}/bin/codex mcp remove konflate >/dev/null 2>&1 || true
              ${codexPackage}/bin/codex mcp add konflate --url "https://konflate.$domain2/mcp"
            fi
          else
            echo "WARNING: ${homeopsMcpSecretDomain2Path} is missing; skipping konflate Codex MCP config" >&2
          fi
        '';

        home.activation.homeopsMcpClaudeConfig = lib.hm.dag.entryAfter [ "retrieveOpnixSecrets" ] ''
          if [ -n "''${DRY_RUN_CMD:-}" ]; then
            echo "Skipping HomeOps Claude MCP config during dry run"
          elif [ ! -r ${lib.escapeShellArg homeopsMcpSecretDomainPath} ]; then
            echo "WARNING: ${homeopsMcpSecretDomainPath} is missing; skipping HomeOps Claude MCP config" >&2
          else
            domain="$(${pkgs.coreutils}/bin/tr -d '\r\n' < ${lib.escapeShellArg homeopsMcpSecretDomainPath})"
            if [ -z "$domain" ]; then
              echo "WARNING: ${homeopsMcpSecretDomainPath} is empty; skipping HomeOps Claude MCP config" >&2
            else
              ${pkgs.claude-code}/bin/claude mcp remove --scope user homeops_toolhive >/dev/null 2>&1 || true
              ${pkgs.claude-code}/bin/claude mcp add --scope user --transport http homeops_toolhive "https://mcp.$domain/mcp"
            fi
          fi

          if [ -r ${lib.escapeShellArg homeopsMcpSecretDomain2Path} ]; then
            domain2="$(${pkgs.coreutils}/bin/tr -d '\r\n' < ${lib.escapeShellArg homeopsMcpSecretDomain2Path})"
            if [ -z "$domain2" ]; then
              echo "WARNING: ${homeopsMcpSecretDomain2Path} is empty; skipping konflate Claude MCP config" >&2
            else
              ${pkgs.claude-code}/bin/claude mcp remove --scope user konflate >/dev/null 2>&1 || true
              ${pkgs.claude-code}/bin/claude mcp add --scope user --transport http konflate "https://konflate.$domain2/mcp"
            fi
          else
            echo "WARNING: ${homeopsMcpSecretDomain2Path} is missing; skipping konflate Claude MCP config" >&2
          fi
        '';

        home.activation.meminiCodexPlugin =
          lib.hm.dag.entryAfter
            [
              "retrieveOpnixSecrets"
              "writeBoundary"
            ]
            ''
              if [ -n "''${DRY_RUN_CMD:-}" ]; then
                echo "Skipping Memini Codex plugin config during dry run"
              elif [ ! -r ${lib.escapeShellArg homeopsMcpSecretDomainPath} ]; then
                echo "ERROR: ${homeopsMcpSecretDomainPath} is missing; cannot configure Memini for Codex" >&2
                exit 1
              else
                domain="$(${pkgs.coreutils}/bin/tr -d '\r\n' < ${lib.escapeShellArg homeopsMcpSecretDomainPath})"
                if [ -z "$domain" ]; then
                  echo "ERROR: ${homeopsMcpSecretDomainPath} is empty; cannot configure Memini for Codex" >&2
                  exit 1
                fi

                get_memini_install_path() {
                  ${pkgs.claude-code}/bin/claude plugin list --json 2>/dev/null \
                    | ${pkgs.jq}/bin/jq -r '.[] | select(.id == "memini@memini") | .installPath' \
                    | ${pkgs.coreutils}/bin/head -n1
                }

                if [ -z "$(get_memini_install_path || true)" ]; then
                  ${pkgs.claude-code}/bin/claude plugin marketplace add https://github.com/eleboucher/memini >/dev/null
                  ${pkgs.claude-code}/bin/claude plugin install memini >/dev/null
                fi

                memini_install_path="$(get_memini_install_path || true)"
                if [ -z "$memini_install_path" ] || [ ! -d "$memini_install_path" ]; then
                  echo "ERROR: Claude Code Memini plugin is not installed; cannot mount it for Codex" >&2
                  exit 1
                fi

                ${codexPackage}/bin/codex mcp remove homeops_memini >/dev/null 2>&1 || true
                ${codexPackage}/bin/codex mcp remove memini >/dev/null 2>&1 || true
                ${codexPackage}/bin/codex plugin remove memini --marketplace memini-upstream >/dev/null 2>&1 || true
                ${codexPackage}/bin/codex plugin marketplace remove memini-upstream >/dev/null 2>&1 || true
                ${codexPackage}/bin/codex plugin remove memini --marketplace claude-memini >/dev/null 2>&1 || true
                ${codexPackage}/bin/codex plugin marketplace remove claude-memini >/dev/null 2>&1 || true

                ${pkgs.coreutils}/bin/mkdir -p ${lib.escapeShellArg claudeMeminiCodexMarketplaceDir}/.agents/plugins
                ${pkgs.coreutils}/bin/mkdir -p ${lib.escapeShellArg claudeMeminiCodexMarketplaceDir}/plugins
                bridge_plugin_dir=${lib.escapeShellArg claudeMeminiCodexMarketplaceDir}/plugins/memini
                if [ -e "$bridge_plugin_dir" ] || [ -L "$bridge_plugin_dir" ]; then
                  ${pkgs.coreutils}/bin/rm -rf "$bridge_plugin_dir"
                fi
                ${pkgs.coreutils}/bin/cp -a "$memini_install_path" "$bridge_plugin_dir"

                for plugin_json in "$bridge_plugin_dir/hooks/hooks.json" "$bridge_plugin_dir/.mcp.json"; do
                  if [ -f "$plugin_json" ]; then
                    tmp_json="$plugin_json.tmp"
                    ${pkgs.jq}/bin/jq 'del(.["//"])' "$plugin_json" > "$tmp_json"
                    ${pkgs.coreutils}/bin/mv "$tmp_json" "$plugin_json"
                  fi
                done

                ${pkgs.coreutils}/bin/install -Dm0644 \
                  ${lib.escapeShellArg claudeMeminiCodexMarketplaceJson} \
                  ${lib.escapeShellArg claudeMeminiCodexMarketplaceDir}/.agents/plugins/marketplace.json

                ${codexPackage}/bin/codex plugin marketplace add ${lib.escapeShellArg claudeMeminiCodexMarketplaceDir} >/dev/null
                ${codexPackage}/bin/codex plugin add memini@claude-memini >/dev/null
                ${codexPackage}/bin/codex mcp remove memini >/dev/null 2>&1 || true
                ${codexPackage}/bin/codex mcp add memini --url "https://memini.$domain/mcp" --bearer-token-env-var MEMINI_TOKEN
              fi
            '';

        home.activation.nixosMcpCodexConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          if [ -n "''${DRY_RUN_CMD:-}" ]; then
            echo "Skipping NixOS Codex MCP config during dry run"
          else
            ${codexPackage}/bin/codex mcp remove nixos >/dev/null 2>&1 || true
            ${codexPackage}/bin/codex mcp add nixos -- ${lib.escapeShellArg mcpNixosCommand}
          fi
        '';

        home.activation.nixosMcpClaudeConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          if [ -n "''${DRY_RUN_CMD:-}" ]; then
            echo "Skipping NixOS Claude MCP config during dry run"
          else
            ${pkgs.claude-code}/bin/claude mcp remove --scope user nixos >/dev/null 2>&1 || true
            ${pkgs.claude-code}/bin/claude mcp add --scope user --transport stdio nixos -- ${lib.escapeShellArg mcpNixosCommand}
          fi
        '';

        home.activation.playwrightMcpClaudeConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          if [ -n "''${DRY_RUN_CMD:-}" ]; then
            echo "Skipping Playwright Claude MCP config during dry run"
          else
            ${pkgs.claude-code}/bin/claude mcp remove --scope user playwright >/dev/null 2>&1 || true
            ${pkgs.claude-code}/bin/claude mcp add --scope user --transport stdio playwright -- ${lib.escapeShellArg playwrightMcpCommand}
          fi
        '';

        xdg.configFile."opencode/opencode.json".text = builtins.toJSON {
          "$schema" = "https://opencode.ai/config.json";
          mcp = {
            homeops_toolhive = {
              type = "remote";
              url = "https://mcp.{env:HOMEOPS_SECRET_DOMAIN}/mcp";
              enabled = true;
              timeout = 30000;
            };
            konflate = {
              type = "remote";
              url = "https://konflate.{env:HOMEOPS_SECRET_DOMAIN_2}/mcp";
              enabled = true;
              timeout = 30000;
            };
            memini = {
              type = "remote";
              url = "{env:MEMINI_MCP_URL}";
              enabled = true;
              oauth = false;
              timeout = 30000;
              headers = {
                Authorization = "Bearer {env:MEMINI_TOKEN}";
                "X-Memini-Namespace" = "{env:MEMINI_NAMESPACE}";
              };
            };
            nixos = {
              type = "local";
              command = [ mcpNixosCommand ];
              enabled = true;
              timeout = 30000;
            };
          };
        };
        xdg.configFile."opencode/package.json" = {
          force = true;
          text = builtins.toJSON {
            dependencies = {
              "@eleboucher/opencode-memini" = "latest";
            };
          };
        };
        xdg.configFile."opencode/plugins/memini.js" = {
          force = true;
          text = ''
            import { createRequire } from "node:module";

            const require = createRequire(`''${process.env.HOME}/.config/opencode/package.json`);
            const { default: MeminiPlugin } = await import(require.resolve("@eleboucher/opencode-memini"));

            export const Memini = MeminiPlugin;
          '';
        };

        home.packages = with pkgs; [
          claudeCodeWrapped
          codexWrapped
          codexDesktopRemoteMobileControlWrapped
          opencodeMeminiUpdate
          opencodeWrapped
          mcp-nixos
        ];
      };
  };
}

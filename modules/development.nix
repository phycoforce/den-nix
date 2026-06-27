{ den, inputs, ... }:
{
  den.aspects.development = {
    includes = [
      (den.batteries.unfree [
        "1password-cli"
        "claude-code"
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
        mcpNixosCommand = lib.getExe pkgs.mcp-nixos;
        codexHookPath = lib.makeBinPath [ pkgs.nodejs_22 ];
        codexPackage = inputs.nixpkgs-codex.legacyPackages.${pkgs.stdenv.hostPlatform.system}.codex;
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
        codexMeminiBridgeConfig = pkgs.writeText "codex-memini-bridge.mjs" ''
          import crypto from "node:crypto";
          import fs from "node:fs";
          import path from "node:path";

          const pluginDir = process.argv[2];
          const configPath = process.argv[3];

          if (!pluginDir) {
            console.error("usage: codex-memini-bridge.mjs PLUGIN_DIR [CODEX_CONFIG]");
            process.exit(2);
          }

          const eventLabels = {
            PreToolUse: "pre_tool_use",
            PermissionRequest: "permission_request",
            PostToolUse: "post_tool_use",
            PreCompact: "pre_compact",
            PostCompact: "post_compact",
            SessionStart: "session_start",
            UserPromptSubmit: "user_prompt_submit",
            SubagentStart: "subagent_start",
            SubagentStop: "subagent_stop",
            Stop: "stop",
          };

          function readJson(file) {
            return JSON.parse(fs.readFileSync(file, "utf8"));
          }

          function writeJson(file, value) {
            fs.writeFileSync(file, JSON.stringify(value, null, 2) + "\n");
          }

          function sanitizeRootJson(file, key) {
            if (!fs.existsSync(file)) {
              return;
            }
            const value = readJson(file);
            if (!Object.hasOwn(value, key)) {
              throw new Error(file + " is missing required key " + key);
            }
            writeJson(file, { [key]: value[key] });
          }

          function canonicalJson(value) {
            if (Array.isArray(value)) {
              return "[" + value.map(canonicalJson).join(",") + "]";
            }
            if (value && typeof value === "object") {
              return "{" + Object.keys(value).sort().map((key) => {
                return JSON.stringify(key) + ":" + canonicalJson(value[key]);
              }).join(",") + "}";
            }
            return JSON.stringify(value);
          }

          function hookHash(eventLabel, group, hook) {
            const command = String(hook.command || "");
            const timeout = Math.max(1, Number(hook.timeout ?? hook.timeoutSec ?? 600));
            const normalizedHook = {
              type: "command",
              command,
              timeout,
              async: Boolean(hook.async),
            };
            if (Object.hasOwn(hook, "statusMessage")) {
              normalizedHook.statusMessage = hook.statusMessage;
            }

            const identity = {
              event_name: eventLabel,
              hooks: [normalizedHook],
            };
            if (Object.hasOwn(group, "matcher")) {
              identity.matcher = group.matcher;
            }

            return "sha256:" + crypto
              .createHash("sha256")
              .update(canonicalJson(identity))
              .digest("hex");
          }

          function hookStateEntries(hooksPath) {
            const hooks = readJson(hooksPath).hooks;
            const entries = [];

            for (const [eventName, groups] of Object.entries(hooks)) {
              const eventLabel = eventLabels[eventName];
              if (!eventLabel || !Array.isArray(groups)) {
                continue;
              }

              groups.forEach((group, groupIndex) => {
                const handlers = Array.isArray(group.hooks) ? group.hooks : [];
                handlers.forEach((hook, handlerIndex) => {
                  if (hook.type !== "command" || hook.async === true) {
                    return;
                  }
                  if (!String(hook.command || "").trim()) {
                    return;
                  }
                  const key = "memini@claude-memini:hooks/hooks.json:"
                    + eventLabel + ":" + groupIndex + ":" + handlerIndex;
                  entries.push([key, hookHash(eventLabel, group, hook)]);
                });
              });
            }

            if (entries.length === 0) {
              throw new Error("no Codex-compatible Memini hooks found in " + hooksPath);
            }

            return entries;
          }

          const tableHeaderRe = /^\s*\[.*\]\s*$/;

          function removeTables(lines, shouldRemove) {
            const kept = [];
            for (let index = 0; index < lines.length;) {
              const line = lines[index];
              if (tableHeaderRe.test(line) && shouldRemove(line.trim())) {
                index += 1;
                while (index < lines.length && !tableHeaderRe.test(lines[index])) {
                  index += 1;
                }
                continue;
              }
              kept.push(line);
              index += 1;
            }
            return kept;
          }

          function findTable(lines, header) {
            return lines.findIndex((line) => line.trim() === header);
          }

          function tableEnd(lines, start) {
            for (let index = start + 1; index < lines.length; index += 1) {
              if (tableHeaderRe.test(lines[index])) {
                return index;
              }
            }
            return lines.length;
          }

          function setTable(lines, header, values) {
            let start = findTable(lines, header);
            if (start === -1) {
              if (lines.length > 0 && lines[lines.length - 1].trim()) {
                lines.push("");
              }
              lines.push(header);
              for (const [key, value] of Object.entries(values)) {
                lines.push(key + " = " + value);
              }
              return lines;
            }

            let end = tableEnd(lines, start);
            for (const [key, value] of Object.entries(values)) {
              const keyRe = new RegExp("^\\s*" + key.replace(/[.*+?^{}()|[\]\\]/g, "\\$&") + "\\s*=");
              let updated = false;
              for (let index = start + 1; index < end; index += 1) {
                if (keyRe.test(lines[index])) {
                  lines[index] = key + " = " + value;
                  updated = true;
                  break;
                }
              }
              if (!updated) {
                lines.splice(end, 0, key + " = " + value);
                end += 1;
              }
            }
            return lines;
          }

          function updateCodexConfig(file, entries) {
            let lines = [];
            if (fs.existsSync(file)) {
              lines = fs.readFileSync(file, "utf8").split(/\r?\n/);
              if (lines.length > 0 && lines[lines.length - 1] === "") {
                lines.pop();
              }
            } else {
              fs.mkdirSync(path.dirname(file), { recursive: true });
            }

            lines = removeTables(lines, (header) => {
              return header.startsWith("[hooks.state.\"memini@claude-memini:hooks/hooks.json:");
            });
            lines = setTable(lines, "[mcp_servers.memini]", {
              default_tools_approval_mode: "\"approve\"",
            });

            for (const [key, trustedHash] of entries) {
              lines = setTable(lines, "[hooks.state.\"" + key + "\"]", {
                trusted_hash: "\"" + trustedHash + "\"",
              });
            }

            fs.writeFileSync(file, lines.join("\n") + "\n");
          }

          const hooksPath = path.join(pluginDir, "hooks", "hooks.json");
          sanitizeRootJson(hooksPath, "hooks");
          sanitizeRootJson(path.join(pluginDir, ".mcp.json"), "mcpServers");

          if (configPath) {
            updateCodexConfig(configPath, hookStateEntries(hooksPath));
          }
        '';
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
              ${codexPackage}/bin/codex mcp remove homeops_toolhive >/dev/null 2>&1 || true
              ${codexPackage}/bin/codex mcp remove homeops_memini >/dev/null 2>&1 || true
              ${codexPackage}/bin/codex mcp add homeops_toolhive --url "https://mcp.$domain/mcp"
            fi
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

                ${pkgs.claude-code}/bin/claude plugin marketplace add https://github.com/eleboucher/memini >/dev/null
                if [ -n "$(get_memini_install_path || true)" ]; then
                  ${pkgs.claude-code}/bin/claude plugin update memini >/dev/null \
                    || ${pkgs.claude-code}/bin/claude plugin install memini >/dev/null
                else
                  ${pkgs.claude-code}/bin/claude plugin install memini >/dev/null
                fi

                memini_install_path="$(get_memini_install_path || true)"

                if [ -z "$memini_install_path" ] || [ ! -d "$memini_install_path" ]; then
                  echo "ERROR: Claude Code Memini plugin is not installed; cannot mount it for Codex" >&2
                  exit 1
                fi

                memini_version="$(${pkgs.jq}/bin/jq -r '.version // empty' "$memini_install_path/.claude-plugin/plugin.json")"
                if [ -z "$memini_version" ]; then
                  echo "ERROR: Claude Code Memini plugin version could not be determined" >&2
                  exit 1
                fi

                oldest_version="$(printf '%s\n%s\n' "0.4.19" "$memini_version" | ${pkgs.coreutils}/bin/sort -V | ${pkgs.coreutils}/bin/head -n1)"
                if [ "$oldest_version" != "0.4.19" ]; then
                  echo "ERROR: Claude Code Memini plugin is $memini_version; expected at least 0.4.19" >&2
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
                ${pkgs.nodejs_22}/bin/node ${lib.escapeShellArg codexMeminiBridgeConfig} "$bridge_plugin_dir"
                ${pkgs.coreutils}/bin/install -Dm0644 \
                  ${lib.escapeShellArg claudeMeminiCodexMarketplaceJson} \
                  ${lib.escapeShellArg claudeMeminiCodexMarketplaceDir}/.agents/plugins/marketplace.json

                ${codexPackage}/bin/codex plugin marketplace add ${lib.escapeShellArg claudeMeminiCodexMarketplaceDir} >/dev/null
                ${codexPackage}/bin/codex mcp add memini --url "https://memini.$domain/mcp" --bearer-token-env-var MEMINI_TOKEN
                ${codexPackage}/bin/codex plugin add memini@claude-memini >/dev/null
                ${pkgs.nodejs_22}/bin/node ${lib.escapeShellArg codexMeminiBridgeConfig} \
                  "$bridge_plugin_dir" \
                  ${lib.escapeShellArg "${config.home.homeDirectory}/.codex/config.toml"}
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
          _1password-cli
          age
          claudeCodeWrapped
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
          mcp-nixos
          minijinja
          moreutils
          nodejs_22
          nixd
          opencodeMeminiUpdate
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

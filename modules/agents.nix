{ den, ... }:
{
  den.aspects.agents = {
    includes = [
      den.aspects.foundation
      (den.batteries.unfree [
        "claude-code"
      ])
    ];

    provides.to-hosts.nixos = {
      # forceLoginMethod is only honored via managed settings, not
      # ~/.claude/settings.json. "claudeai" = subscription, "console" = API;
      # a backstop against silently falling back to API billing.
      environment.etc."claude-code/managed-settings.json".text = builtins.toJSON {
        forceLoginMethod = "claudeai";
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
        homeopsMcp = import ./_home/homeops-mcp-paths.nix config;
        homeopsMcpSecretDomainPath = homeopsMcp.secretDomain;
        homeopsMcpSecretDomain2Path = homeopsMcp.secretDomain2;
        homeopsMcpMeminiApiKeyPath = homeopsMcp.meminiApiKey;

        claudeCode = pkgs.claude-code;
        claudeBin = "${claudeCode}/bin/claude";
        opencodeBin = "${pkgs.opencode}/bin/opencode";

        # Sourced by every agent wrapper and by the activation steps below, so
        # MCP secrets stay out of the Nix store and out of the session
        # environment while wrappers and generated config still agree.
        agentEnvLoader = pkgs.writeText "agent-mcp-env" ''
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
        sourceAgentEnv = ". ${agentEnvLoader}";

        # Node on PATH for agent plugin/hook runtimes that shell out to it.
        agentRuntimePath = lib.makeBinPath [ pkgs.nodejs_22 ];

        mcpNixosCommand = lib.getExe pkgs.mcp-nixos;
        # playwright-mcp otherwise tries to download chrome-for-testing into its
        # read-only /nix/store PLAYWRIGHT_BROWSERS_PATH; point it at the
        # version-matched Chromium already in playwright-driver.browsers.
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

        # Agent-agnostic MCP registry; the adapters below render each entry
        # into per-agent shape. Fields:
        #   transport  "http" or "stdio"
        #   command    stdio argv list
        #   url        shell string, expanded at activation from loader vars
        #   urlEnv     same URL in OpenCode's `{env:VAR}` syntax
        #   needs      loader vars that must be non-empty, else skip with a
        #              warning rather than register a half-resolved URL
        #   headers    OpenCode only (the Claude Code jq adapter renders just
        #              type+url and asserts no headers sneak past it)
        #   agents     front-ends to register with; default all
        allAgents = [
          "claude-code"
          "opencode"
        ];
        mcpServers = {
          homeops_toolhive = {
            transport = "http";
            needs = [ "HOMEOPS_SECRET_DOMAIN" ];
            url = "https://mcp.$HOMEOPS_SECRET_DOMAIN/mcp";
            urlEnv = "https://mcp.{env:HOMEOPS_SECRET_DOMAIN}/mcp";
          };
          konflate = {
            transport = "http";
            needs = [ "HOMEOPS_SECRET_DOMAIN_2" ];
            url = "https://konflate.$HOMEOPS_SECRET_DOMAIN_2/mcp";
            urlEnv = "https://konflate.{env:HOMEOPS_SECRET_DOMAIN_2}/mcp";
          };
          memini = {
            # Claude Code gets Memini from the plugin below (which ships its
            # own MCP server), so only other front-ends register it here.
            agents = [ "opencode" ];
            transport = "http";
            needs = [
              "MEMINI_MCP_URL"
              "MEMINI_TOKEN"
            ];
            url = "$MEMINI_MCP_URL";
            urlEnv = "{env:MEMINI_MCP_URL}";
            headers = {
              Authorization = "Bearer {env:MEMINI_TOKEN}";
              "X-Memini-Namespace" = "{env:MEMINI_NAMESPACE}";
            };
          };
          nixos = {
            transport = "stdio";
            command = [ mcpNixosCommand ];
          };
          playwright = {
            transport = "stdio";
            command = [ playwrightMcpCommand ];
          };
        };
        mcpServersFor =
          agent: lib.filterAttrs (_: srv: lib.elem agent (srv.agents or allAgents)) mcpServers;

        # Plugins are installed by the agent's own CLI, so this is an
        # install-if-missing list rather than declarative state.
        agentPlugins = [
          {
            id = "memini@memini";
            plugin = "memini";
            marketplace = "https://github.com/eleboucher/memini";
          }
        ];

        mkAgentWrapper =
          {
            name,
            program,
            env ? { },
            preExec ? "",
          }:
          pkgs.writeShellScriptBin name ''
            ${sourceAgentEnv}
            export PATH=${lib.escapeShellArg agentRuntimePath}:$PATH
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}") env)}
            ${preExec}
            exec ${program} "$@"
          '';

        claudeCodeWrapper = mkAgentWrapper {
          name = "claude";
          program = claudeBin;
          env.FORCE_AUTOUPDATE_PLUGINS = "1";
        };

        opencodeWrapper = mkAgentWrapper {
          name = "opencode";
          program = opencodeBin;
          # `opencode auth` runs plugin-free so a broken plugin cannot block
          # re-authentication.
          preExec = ''
            if [ "''${1-}" = "auth" ]; then
              shift
              exec ${opencodeBin} --pure auth "$@"
            fi
          '';
        };

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

        # Claude Code MCP wiring is declarative: a jq merge into the top-level
        # (user-scope) mcpServers of ~/.claude.json. Launching the claude CLI
        # from boot-time activation is what caused the daily re-login (OAuth
        # refresh against a not-yet-reachable API loses the refresh token).
        claudeMcpServers = mcpServersFor "claude-code";
        claudeMcpNamesJson = builtins.toJSON (lib.attrNames claudeMcpServers);
        claudeMcpStdioJson = builtins.toJSON (
          lib.mapAttrs (_: srv: {
            type = "stdio";
            command = builtins.head srv.command;
            args = builtins.tail srv.command;
            env = { };
          }) (lib.filterAttrs (_: srv: srv.transport == "stdio") claudeMcpServers)
        );
        # The jq adapter renders only {type, url}; assert rather than silently
        # drop auth headers on a future claude-code http server.
        claudeMcpHttp =
          let
            http = lib.filterAttrs (_: srv: srv.transport == "http") claudeMcpServers;
          in
          assert lib.all (srv: !(srv ? headers)) (lib.attrValues http);
          http;
        # Registry names become shell/jq identifiers; constrain the charset
        # (and, below, uniqueness after s/-/_/) at eval time.
        claudeMcpJqVar =
          name:
          assert builtins.match "[A-Za-z0-9_-]+" name != null;
          "url_${lib.replaceStrings [ "-" ] [ "_" ] name}";
        claudeMcpJqRef = name: "$" + claudeMcpJqVar name;
        claudeMcpUrlGuard =
          name: srv:
          let
            needs = srv.needs or [ ];
            # Double quotes, not escapeShellArg: the shell must expand the
            # loader variables inside the URL.
            assign = ''${claudeMcpJqVar name}="${srv.url}"'';
          in
          if needs == [ ] then
            assign
          else
            ''
              ${claudeMcpJqVar name}=""
              if ${lib.concatMapStringsSep " && " (v: "[ -n \"\${${v}:-}\" ]") needs}; then
                ${assign}
              else
                echo "WARNING: skipping ${name} MCP for Claude Code (unset ${lib.concatStringsSep ", " needs})" >&2
              fi
            '';
        # A skipped http server (needs unmet) keeps its old entry; only keys we
        # previously managed AND that left the registry are pruned. Unmanaged
        # keys (user-added servers, oauth/project state) are never touched.
        claudeMcpJqProgram = ''
          ($prev - $names) as $stale
          | .mcpServers = (
              ((.mcpServers // {}) | with_entries(select(.key as $k | $stale | index($k) | not)))
              + $stdio${
                lib.concatStrings (
                  lib.mapAttrsToList (
                    name: _:
                    "\n    + (if ${claudeMcpJqRef name} == \"\" then {} else {${builtins.toJSON name}: {type: \"http\", url: ${claudeMcpJqRef name}}} end)"
                  ) claudeMcpHttp
                )
              }
            )
        '';
        claudeMcpJqArgs =
          let
            vars = lib.mapAttrsToList (name: _: claudeMcpJqVar name) claudeMcpHttp;
          in
          assert vars == lib.unique vars;
          lib.concatStringsSep " " (
            lib.mapAttrsToList (
              name: _: "--arg ${claudeMcpJqVar name} \"${claudeMcpJqRef name}\""
            ) claudeMcpHttp
          );
        claudeManagedStateFile = "${config.xdg.stateHome}/agent-mcp/claude-managed-servers.json";

        # Plugin install genuinely needs the network and the claude CLI; it
        # runs from a user service, exits before any CLI launch when nothing
        # is missing, and (since user units cannot order on the system
        # network-online.target) probes real API reachability first.
        claudePluginsInstall = pkgs.writeShellApplication {
          name = "claude-code-plugins-install";
          runtimeInputs = with pkgs; [
            coreutils
            curl
            git
            jq
          ];
          text =
            let
              pluginMissing =
                p:
                "! jq -e --arg id ${lib.escapeShellArg p.id} '.plugins | has($id)' \"$plugins_state\" >/dev/null 2>&1";
              install = p: ''
                if ${pluginMissing p}; then
                  ${claudeBin} plugin marketplace add ${lib.escapeShellArg p.marketplace} >/dev/null
                  ${claudeBin} plugin install ${lib.escapeShellArg p.plugin} >/dev/null
                fi
              '';
            in
            ''
              plugins_state="$HOME/.claude/plugins/installed_plugins.json"
              missing=0
              ${lib.concatMapStrings (p: ''
                if ${pluginMissing p}; then
                  missing=1
                fi
              '') agentPlugins}
              if [ "$missing" -eq 0 ]; then
                exit 0
              fi
              tries=24
              until curl -s -o /dev/null --max-time 5 https://api.anthropic.com/; do
                tries=$((tries - 1))
                if [ "$tries" -le 0 ]; then
                  echo "api.anthropic.com unreachable; leaving Claude Code plugin install for next login" >&2
                  exit 0
                fi
                sleep 5
              done
              ${lib.concatMapStrings install agentPlugins}
            '';
        };

        # OpenCode is fully declarative: the MCP block is a generated file.
        opencodeMcpConfig = lib.mapAttrs (
          _: srv:
          if srv.transport == "stdio" then
            {
              type = "local";
              inherit (srv) command;
              enabled = true;
              timeout = 30000;
            }
          else
            {
              type = "remote";
              url = srv.urlEnv;
              enabled = true;
              timeout = 30000;
            }
            // lib.optionalAttrs (srv ? headers) {
              oauth = false;
              inherit (srv) headers;
            }
        ) (mcpServersFor "opencode");
      in
      {
        home.activation.agentMcpClaudeCode =
          lib.hm.dag.entryAfter
            [
              "retrieveOpnixSecrets"
              "writeBoundary"
            ]
            ''
              if [ -n "''${DRY_RUN_CMD:-}" ]; then
                echo "Skipping Claude Code MCP wiring during dry run"
              else
                ${sourceAgentEnv}
                ${lib.concatStringsSep "\n" (lib.mapAttrsToList claudeMcpUrlGuard claudeMcpHttp)}
                # 0600 throughout: the file holds oauthAccount; a bare
                # redirect under the service's 022 umask would leave 0644.
                claude_json="$HOME/.claude.json"
                if [ ! -s "$claude_json" ]; then
                  ${pkgs.coreutils}/bin/install -m 600 /dev/null "$claude_json"
                  echo '{}' > "$claude_json"
                fi
                prev='[]'
                if [ -s ${lib.escapeShellArg claudeManagedStateFile} ]; then
                  prev="$(${pkgs.jq}/bin/jq -c 'if type == "array" then . else [] end' \
                    ${lib.escapeShellArg claudeManagedStateFile} 2>/dev/null || echo '[]')"
                fi
                tmp="$claude_json.tmp"
                ${pkgs.coreutils}/bin/install -m 600 /dev/null "$tmp"
                if ${pkgs.jq}/bin/jq \
                  --argjson stdio ${lib.escapeShellArg claudeMcpStdioJson} \
                  --argjson names ${lib.escapeShellArg claudeMcpNamesJson} \
                  --argjson prev "$prev" \
                  ${claudeMcpJqArgs} \
                  ${lib.escapeShellArg claudeMcpJqProgram} \
                  "$claude_json" > "$tmp"; then
                  # No-op merges leave the inode alone: the claude CLI rewrites
                  # this file itself, so replace it only when content changed.
                  if ${pkgs.diffutils}/bin/cmp -s "$tmp" "$claude_json"; then
                    ${pkgs.coreutils}/bin/rm -f "$tmp"
                  else
                    ${pkgs.coreutils}/bin/mv "$tmp" "$claude_json"
                  fi
                  ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname ${lib.escapeShellArg claudeManagedStateFile})"
                  printf '%s\n' ${lib.escapeShellArg claudeMcpNamesJson} > ${lib.escapeShellArg claudeManagedStateFile}
                else
                  echo "WARNING: could not update $claude_json (invalid JSON?); leaving it unchanged" >&2
                  ${pkgs.coreutils}/bin/rm -f "$tmp"
                fi
              fi
            '';

        systemd.user.services.claude-code-plugins = {
          Unit.Description = "Claude Code plugin install";
          Service = {
            Type = "oneshot";
            ExecStart = lib.getExe claudePluginsInstall;
          };
          Install.WantedBy = [ "default.target" ];
        };

        # Claude Code writes runtime state back into ~/.claude/settings.json, so
        # it cannot be a store symlink: merge only our keys and leave the rest
        # mutable. Empty attribution strings drop the commit/PR credit lines;
        # sessionUrl false is separate and drops the Claude-Session link.
        home.activation.agentSettingsClaudeCode = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          if [ -n "''${DRY_RUN_CMD:-}" ]; then
            echo "Skipping Claude Code settings.json attribution merge during dry run"
          else
            settings="$HOME/.claude/settings.json"
            ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$settings")"
            if [ ! -s "$settings" ]; then
              echo '{}' > "$settings"
            fi
            tmp="$settings.tmp"
            if ${pkgs.jq}/bin/jq '.attribution = { commit: "", pr: "", sessionUrl: false }' "$settings" > "$tmp"; then
              ${pkgs.coreutils}/bin/mv "$tmp" "$settings"
            else
              echo "WARNING: could not update $settings (invalid JSON?); leaving it unchanged" >&2
              ${pkgs.coreutils}/bin/rm -f "$tmp"
            fi
          fi
        '';

        xdg.configFile."opencode/opencode.json".text = builtins.toJSON {
          "$schema" = "https://opencode.ai/config.json";
          mcp = opencodeMcpConfig;
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
          claudeCodeWrapper
          opencodeWrapper
          opencodeMeminiUpdate
          mcp-nixos
        ];
      };
  };
}

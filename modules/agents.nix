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

        # Boot-time HM activation runs before network-online.target; launching
        # the claude CLI with DNS down fails its OAuth refresh and clobbers
        # ~/.claude.json (daily re-login, silent API billing). Gate on this.
        agentOnline = host: "${pkgs.getent}/bin/getent hosts ${host} >/dev/null 2>&1";

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
        #   headers    OpenCode only (`claude mcp add` bakes literal values)
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

        # `--scope user` so the servers follow the user across every project.
        claudeMcpBlock =
          name: srv:
          let
            needs = srv.needs or [ ];
            add =
              if srv.transport == "stdio" then
                "${claudeBin} mcp add --scope user --transport stdio ${name} -- ${lib.escapeShellArgs srv.command}"
              else
                # Double quotes, not escapeShellArg: the shell must expand the
                # loader variables inside the URL.
                "${claudeBin} mcp add --scope user --transport http ${name} \"${srv.url}\"";
            register = ''
              ${claudeBin} mcp remove --scope user ${name} >/dev/null 2>&1 || true
              ${add}
            '';
          in
          if needs == [ ] then
            register
          else
            ''
              if ${lib.concatMapStringsSep " && " (v: "[ -n \"\${${v}:-}\" ]") needs}; then
              ${register}
              else
                echo "WARNING: skipping ${name} MCP for Claude Code (unset ${lib.concatStringsSep ", " needs})" >&2
              fi
            '';

        claudePluginBlock = p: ''
          if [ -z "$(${claudeBin} plugin list --json 2>/dev/null \
            | ${pkgs.jq}/bin/jq -r --arg id ${lib.escapeShellArg p.id} '.[] | select(.id == $id) | .installPath' \
            | ${pkgs.coreutils}/bin/head -n1)" ]; then
            ${claudeBin} plugin marketplace add ${lib.escapeShellArg p.marketplace} >/dev/null
            ${claudeBin} plugin install ${lib.escapeShellArg p.plugin} >/dev/null
          fi
        '';

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
              elif ! ${agentOnline "api.anthropic.com"}; then
                echo "Skipping Claude Code MCP wiring: api.anthropic.com unresolvable (offline)" >&2
              else
                ${sourceAgentEnv}
                ${lib.concatStringsSep "\n" (lib.mapAttrsToList claudeMcpBlock (mcpServersFor "claude-code"))}
              fi
            '';

        home.activation.agentPluginsClaudeCode =
          lib.hm.dag.entryAfter
            [
              "retrieveOpnixSecrets"
              "writeBoundary"
            ]
            ''
              if [ -n "''${DRY_RUN_CMD:-}" ]; then
                echo "Skipping Claude Code plugin install during dry run"
              elif ! ${agentOnline "api.anthropic.com"}; then
                echo "Skipping Claude Code plugin install: api.anthropic.com unresolvable (offline)" >&2
              else
                ${lib.concatStringsSep "\n" (map claudePluginBlock agentPlugins)}
              fi
            '';

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

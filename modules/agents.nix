{ den, inputs, ... }:
{
  flake-file.inputs = {
    # Bleeding-edge nixpkgs used only for agent CLIs that release faster than
    # nixos-unstable can carry them. Bump with: nix flake update nixpkgs-agents
    nixpkgs-agents.url = "github:NixOS/nixpkgs/master";
  };

  den.aspects.agents = {
    includes = [
      den.aspects.foundation
      (den.batteries.unfree [
        "claude-code"
      ])
    ];

    provides.to-hosts.nixos = {
      # Force the subscription (Claude Pro/Max OAuth) login method system-wide
      # as a backstop so claude-code never silently falls back to API billing.
      # forceLoginMethod is only honored via managed settings
      # (/etc/claude-code/managed-settings.json on Linux), not
      # ~/.claude/settings.json. "claudeai" = subscription; "console" = API.
      # The real fix for the daily re-login is the offline activation guard
      # (agentOnline) below; this is defense-in-depth.
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

        # ------------------------------------------------------------------
        # Agent packages
        # ------------------------------------------------------------------

        # claude-code from the master-tracking nixpkgs-agents input so the CLI
        # tracks the latest release (Opus 5 needs >= 2.1.219) independently of
        # the main nixos-unstable pin, which is held back by other packages
        # (e.g. niri vs libdisplay-info). legacyPackages carries the default
        # nixpkgs config (allowUnfree = false) and den.batteries.unfree only
        # configures the OS/HM pkgs set, so re-instantiate this input with an
        # allowlist predicate for claude-code.
        claudeCode =
          (import inputs.nixpkgs-agents {
            inherit (pkgs.stdenv.hostPlatform) system;
            config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "claude-code" ];
          }).claude-code;
        claudeBin = "${claudeCode}/bin/claude";
        opencodeBin = "${pkgs.opencode}/bin/opencode";

        # ------------------------------------------------------------------
        # Shared agent environment
        #
        # Every agent CLI launches through a thin wrapper that sources this
        # loader, so MCP secrets stay out of the Nix store and out of the
        # broad user session environment while still working from terminal
        # and desktop launches. Activation steps source it too, so the values
        # a wrapper sees and the values baked into agent config agree.
        # ------------------------------------------------------------------
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

        # DNS resolution check, used to gate activation steps that launch an
        # agent CLI. Boot-time home-manager activation runs before
        # network-online.target; launching the claude CLI while DNS is down
        # makes its short-lived (~7h) OAuth token refresh fail, which silently
        # drops the session to API billing and forces a daily re-login. Gating
        # on this makes those steps no-op when offline instead of clobbering
        # ~/.claude.json.
        agentOnline = host: "${pkgs.getent}/bin/getent hosts ${host} >/dev/null 2>&1";

        # ------------------------------------------------------------------
        # Local MCP server commands
        # ------------------------------------------------------------------
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

        # ------------------------------------------------------------------
        # MCP registry (agent-agnostic)
        #
        # Declare each MCP server once; the per-agent adapters below render it
        # into whatever shape that agent wants. Adding a server, or pointing an
        # existing one somewhere else, is a single edit here.
        #
        #   transport  "http" (remote URL) or "stdio" (local command)
        #   command    stdio argv, as a list
        #   url        remote URL as a *shell* string, expanded at activation
        #              time from variables exported by the env loader
        #   urlEnv     the same URL in OpenCode's `{env:VAR}` template syntax
        #   needs      loader variables that must be non-empty, otherwise the
        #              server is skipped with a warning instead of registered
        #              with a half-resolved URL
        #   headers    extra HTTP headers, OpenCode template syntax
        #              (OpenCode only: `claude mcp add` bakes literal values)
        #   agents     front-ends that get this server; default is all of them
        # ------------------------------------------------------------------
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
            # Claude Code gets Memini from the plugin below (which brings its
            # own MCP server as plugin:memini:memini), so only front-ends
            # without that plugin register the bare server here.
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

        # ------------------------------------------------------------------
        # Plugin registry (agent-agnostic)
        #
        # Plugins are installed imperatively by the agent's own CLI, so this is
        # an install-if-missing list rather than declarative state. Front-ends
        # without a plugin CLI ignore it.
        # ------------------------------------------------------------------
        agentPlugins = [
          {
            id = "memini@memini";
            plugin = "memini";
            marketplace = "https://github.com/eleboucher/memini";
          }
        ];

        # ------------------------------------------------------------------
        # Wrappers: one shape for every agent
        # ------------------------------------------------------------------
        mkAgentWrapper =
          {
            name, # command name on PATH
            program, # absolute path to the real binary
            env ? { }, # extra environment for this agent
            preExec ? "", # shell run before exec (argument dispatch, ...)
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

        # ------------------------------------------------------------------
        # Adapter: Claude Code
        #
        # Registers MCP servers with `claude mcp add --scope user`, so the
        # servers follow the user across every project.
        # ------------------------------------------------------------------
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

        # ------------------------------------------------------------------
        # Adapter: OpenCode
        #
        # Fully declarative: the whole MCP block is a generated config file.
        # ------------------------------------------------------------------
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

        # Claude Code writes runtime state (theme, model, /config toggles) back into
        # ~/.claude/settings.json, so it cannot be a read-only Nix-store symlink. Merge
        # only the keys we want to own with jq and leave the rest mutable. Empty
        # attribution strings drop the "Co-Authored-By: Claude" commit trailer and the
        # "Generated with Claude Code" PR line (the non-deprecated successor to
        # includeCoAuthoredBy).
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
            if ${pkgs.jq}/bin/jq '.attribution = { commit: "", pr: "" }' "$settings" > "$tmp"; then
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

# Single source of truth for HomeOps MCP secret locations: written by
# modules/foundation.nix (opnix), read by modules/agents.nix.
config: rec {
  configDir = "${config.xdg.configHome}/homeops-mcp";
  secretDomain = "${configDir}/secret-domain";
  secretDomain2 = "${configDir}/secret-domain-2";
  meminiApiKey = "${configDir}/memini-api-key";
}

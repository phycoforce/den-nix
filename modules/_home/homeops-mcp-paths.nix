# Single source of truth for HomeOps MCP secret locations.
# Producer: modules/foundation.nix (opnix writes the secrets here).
# Consumer: modules/agents.nix (env loader and MCP activation scripts).
config: rec {
  configDir = "${config.xdg.configHome}/homeops-mcp";
  secretDomain = "${configDir}/secret-domain";
  secretDomain2 = "${configDir}/secret-domain-2";
  meminiApiKey = "${configDir}/memini-api-key";
}

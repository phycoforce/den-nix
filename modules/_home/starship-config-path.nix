# Shared between core.nix (writes/merges the config) and niri.nix
# (STARSHIP_CONFIG env for the compositor session).
config: "${config.xdg.configHome}/noctalia/starship.toml"

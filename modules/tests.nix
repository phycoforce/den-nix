# Cheap eval-time checks asserting Den aspect wiring; run via `nix flake check`.
{ inputs, ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      temperantia = inputs.self.nixosConfigurations.temperantia.config;
      temperantiaPkgs = inputs.self.nixosConfigurations.temperantia.pkgs;
      aaron-at-temperantia = temperantia.home-manager.users.aaron;
      checkCond = name: cond: pkgs.runCommandLocal name { } (if cond then "touch $out" else "");
    in
    {
      # host aspect -> _nixos import path (desktop.nix -> _nixos/niri.nix)
      checks.temperantia-niri = checkCond "temperantia-niri" temperantia.programs.niri.enable;
      # user aspect homeManager class -> _home import path (aaron.nix -> _home/core.nix)
      checks.aaron-hm-bash = checkCond "aaron-hm-bash" aaron-at-temperantia.programs.bash.enable;
      # user aspect provides.to-hosts.nixos cross-provider path (aaron-linux -> host)
      checks.aaron-provides-1password = checkCond "aaron-provides-1password" temperantia.programs._1password.enable;

      # Multiple desynchronized nixpkgs universes were the update-pain root
      # cause: no root input may drag a private nixpkgs into the lock. Allowed
      # nodes are the root's own, nixpkgs-lib (flake-parts, lib-only), and
      # nix-cachyos-kernel's pin (plain "nixpkgs"; its cache depends on it).
      checks.lock-no-private-nixpkgs =
        let
          lock = builtins.fromJSON (builtins.readFile ../flake.lock);
          rootNixpkgs = lock.nodes.root.inputs.nixpkgs;
          allowed = [
            rootNixpkgs
            "nixpkgs-lib"
            "nixpkgs"
          ];
          offenders = builtins.filter (
            n: (builtins.match "nixpkgs.*" n != null) && !(builtins.elem n allowed)
          ) (builtins.attrNames lock.nodes);
        in
        checkCond "lock-no-private-nixpkgs" (offenders == [ ]);

      # Opus 5 needs claude-code >= 2.1.219; a nixpkgs hold or downgrade must
      # not silently reintroduce an incompatible CLI.
      checks.claude-code-floor = checkCond "claude-code-floor" (
        pkgs.lib.versionAtLeast temperantiaPkgs.claude-code.version "2.1.219"
      );

      # The noctalia flake input exists only for its HM module; an import
      # reshuffle restoring its own mkDefault package would resurrect the
      # private-universe/local-compile problem, and (since the nixpkgs attr is
      # v5-only) a v4 comeback whose IPC syntax breaks every keybind.
      checks.noctalia-package-from-nixpkgs = checkCond "noctalia-package-from-nixpkgs" (
        aaron-at-temperantia.programs.noctalia.package.outPath == temperantiaPkgs.noctalia.outPath
      );

      # Root cause of the daily re-login: the claude CLI launched from
      # boot-path HM activation (OAuth refresh against an unreachable API
      # loses the refresh token). MCP wiring must stay a declarative jq merge.
      checks.claude-no-cli-in-activation = checkCond "claude-no-cli-in-activation" (
        !builtins.any (entry: pkgs.lib.hasInfix "bin/claude" entry.data) (
          builtins.attrValues aaron-at-temperantia.home.activation
        )
      );

      # The one remaining CLI caller (plugin install) lives in a
      # reachability-gated user service, not activation.
      checks.claude-plugins-user-service = checkCond "claude-plugins-user-service" (
        aaron-at-temperantia.systemd.user.services ? claude-code-plugins
      );

      # communication.nix / development.nix hold the client-side halves (see
      # _home/noctalia.nix); dropping an id here breaks nothing at build time.
      checks.noctalia-community-templates =
        let
          ids = aaron-at-temperantia.programs.noctalia.settings.theme.templates.community_ids;
        in
        checkCond "noctalia-community-templates" (
          builtins.elem "discord" ids && builtins.elem "vscode" ids
        );
    };
}

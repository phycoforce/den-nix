# Cheap eval-time checks asserting Den aspect wiring; run via `nix flake check`.
# Modeled on Den's templates/example/modules/tests.nix.
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

      # Consolidation invariants (2026-08): the update-pain root cause was
      # multiple desynchronized nixpkgs universes. Keep them from creeping back.
      #
      # No root input may drag a private nixpkgs into the lock. Allowed nodes:
      # the root's own (whatever alias it resolves to), nixpkgs-lib
      # (flake-parts, lib-only), and nix-cachyos-kernel's pin (named plain
      # "nixpkgs" here; intentional - its binary cache depends on it).
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

      # claude-code now comes from the ordinary nixpkgs (the master-tracking
      # nixpkgs-agents input is gone); Opus 5 needs >= 2.1.219, so a nixpkgs
      # hold/downgrade must not silently reintroduce an incompatible CLI.
      checks.claude-code-floor = checkCond "claude-code-floor" (
        pkgs.lib.versionAtLeast temperantiaPkgs.claude-code.version "2.1.219"
      );

      # noctalia must stay the nixpkgs v5 build (attr `noctalia`,
      # Hydra-cached); the flake input exists only for its HM module, and a
      # future import reshuffle restoring its own mkDefault package would
      # silently resurrect the private-universe/local-compile problem. The
      # nixpkgs attr is v5-only, so this also guards against a quickshell
      # noctalia-shell 4.x comeback (v4 IPC syntax would break every keybind).
      checks.noctalia-package-from-nixpkgs = checkCond "noctalia-package-from-nixpkgs" (
        aaron-at-temperantia.programs.noctalia.package.outPath == temperantiaPkgs.noctalia.outPath
      );

      # The client-side halves of those templates live away from the noctalia
      # module: communication.nix creates the directory the discord template
      # needs to render into at all, development.nix installs the extension the
      # vscode template rewrites, and browsers.nix installs the Zen whose
      # profile the zen-browser template patches. Dropping a community id here
      # would leave each of them preparing for files nothing writes, with no
      # eval or build error to show for it.
      checks.noctalia-community-templates =
        let
          ids = aaron-at-temperantia.programs.noctalia.settings.theme.templates.community_ids;
        in
        checkCond "noctalia-community-templates" (
          builtins.all (id: builtins.elem id ids) [
            "discord"
            "vscode"
            "zen-browser"
          ]
        );
    };
}

# Cheap eval-time checks asserting Den aspect wiring; run via `nix flake check`.
# Modeled on Den's templates/example/modules/tests.nix.
{ inputs, ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      temperantia = inputs.self.nixosConfigurations.temperantia.config;
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
    };
}

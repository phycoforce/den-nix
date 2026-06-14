{ den, ... }:
{
  den.aspects.development = {
    includes = [ (den.batteries.unfree [ "vscode" ]) ];

    homeManager = { pkgs, ... }: {
      programs.gh.enable = true;

      programs.vscode = {
        enable = true;
        package = pkgs.vscode;
      };

      home.packages = with pkgs; [
        opencode
      ];
    };
  };
}

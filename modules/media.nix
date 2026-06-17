{ den, ... }:
{
  den.aspects.media = {
    includes = [
      (den.batteries.unfree [
        "plex-desktop"
        "spotify"
        "plexamp"
      ])
    ];

    homeManager =
      { pkgs, ... }:
      let
        plexDesktop = pkgs.plex-desktop.override {
          buildFHSEnv = args: pkgs.buildFHSEnv (args // { dieWithParent = false; });
        };
      in
      {
        home.packages = with pkgs; [
          plexDesktop
          plexamp
          spotify
        ];
      };
  };
}

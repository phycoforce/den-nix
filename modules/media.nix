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
      {
        home.packages = with pkgs; [
          plex-desktop
          plexamp
          spotify
        ];
      };
  };
}

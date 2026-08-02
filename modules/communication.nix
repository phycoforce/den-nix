{
  den.aspects.communication = {
    homeManager =
      {
        config,
        lib,
        pkgs,
        ...
      }:
      {
        home.packages = with pkgs; [
          element-desktop
          thunderbird
          vesktop
        ];

        # Seeds the parent dir noctalia's `discord` template needs (the engine
        # skips ids whose output parent is missing — see _home/noctalia.nix).
        # Not home.file: that would drop a marker file into the dir Vesktop
        # reads as its theme list. Picking a variant stays manual; Vencord
        # rewrites settings.json wholesale, so that file is left alone.
        home.activation.vesktopThemesDir = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          ${pkgs.coreutils}/bin/mkdir -p ${lib.escapeShellArg "${config.xdg.configHome}/vesktop/themes"}
        '';
      };
  };
}

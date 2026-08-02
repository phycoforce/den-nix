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
        # The electron-40.10.5 permittedInsecurePackages workaround (vesktop
        # 1.6.5, 2026-07-17) was verified inert and removed 2026-08-01: the
        # closure now carries only electron 41/42/43.
        home.packages = with pkgs; [
          element-desktop
          thunderbird
          vesktop
        ];

        # noctalia's `discord` community template (enabled in
        # _home/noctalia.nix) renders only where the output directory's parent
        # already exists, so on a machine that has never launched Vesktop no
        # theme is written at all and nothing reports it. Created here rather
        # than with home.file, which would need a marker file inside a
        # directory the client reads as its theme list.
        #
        # Turning one on stays manual: Vencord rewrites settings.json wholesale
        # on every change made in its UI, so that file is left alone. The
        # template renders three variants — Noctalia Midnight
        # (noctalia.theme.css), Noctalia Material and system24 — and any of
        # them can be ticked under Vesktop > Settings > Themes.
        home.activation.vesktopThemesDir = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          ${pkgs.coreutils}/bin/mkdir -p ${lib.escapeShellArg "${config.xdg.configHome}/vesktop/themes"}
        '';
      };
  };
}

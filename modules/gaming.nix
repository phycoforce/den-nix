{ den, inputs, ... }:
{
  den.aspects.gaming = {
    includes = [
      (den.batteries.unfree [
        "steam"
        "steam-original"
        "steam-run"
        "steam-unwrapped"
      ])
    ];

    provides.to-hosts.nixos =
      { pkgs, ... }:
      {
        imports = [ inputs.nix-flatpak.nixosModules.nix-flatpak ];

        boot.kernel.sysctl."kernel.split_lock_mitigate" = 0;

        programs.steam = {
          enable = true;
          gamescopeSession.enable = true;
          protontricks.enable = true;

          extraCompatPackages = [ pkgs.proton-ge-bin ];

          extraPackages = with pkgs; [
            alsa-plugins
            giflib
            glfw
            gst_all_1.gst-plugins-base
            libjpeg_turbo
            libva
            libxslt
            mpg123
            ocl-icd
            openal
            vulkan-tools

            pkgsi686Linux.alsa-plugins
            pkgsi686Linux.giflib
            pkgsi686Linux.gtk3
            pkgsi686Linux.libjpeg_turbo
            pkgsi686Linux.libva
            pkgsi686Linux.mpg123
            pkgsi686Linux.ocl-icd
            pkgsi686Linux.openal
            pkgsi686Linux.mangohud
          ];

          fontPackages = with pkgs; [
            liberation_ttf
            wqy_zenhei
          ];
        };

        services.flatpak = {
          enable = true;
          uninstallUnmanaged = true;

          packages = [ "org.firestormviewer.FirestormViewer" ];

          update.auto = {
            enable = true;
            onCalendar = "weekly";
          };
        };
      };

    homeManager =
      { pkgs, ... }:
      {
        home.packages = with pkgs; [
          faugus-launcher
          gamescope
          goverlay
          heroic
          lutris
          mangohud
          umu-launcher
          wineWow64Packages.wayland
          winetricks
          xivlauncher
        ];
      };
  };
}

{
  den.aspects.communication = {
    homeManager = { pkgs, ... }: {
      # vesktop 1.6.5 pins electron 40, which nixpkgs marks insecure (EOL).
      # Its derivation hard-asserts the electron major matches upstream, so a
      # newer-electron override fails to build. Allowlist the exact version
      # until vesktop bumps electron upstream, then drop this line.
      nixpkgs.config.permittedInsecurePackages = [ "electron-40.10.5" ];

      home.packages = with pkgs; [
        element-desktop
        thunderbird
        vesktop
      ];
    };
  };
}

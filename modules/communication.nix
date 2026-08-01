{
  den.aspects.communication = {
    homeManager = { pkgs, ... }: {
      # The electron-40.10.5 permittedInsecurePackages workaround (vesktop
      # 1.6.5, 2026-07-17) was verified inert and removed 2026-08-01: the
      # closure now carries only electron 41/42/43.
      home.packages = with pkgs; [
        element-desktop
        thunderbird
        vesktop
      ];
    };
  };
}

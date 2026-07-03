{
  den.aspects.communication = {
    homeManager = { pkgs, ... }: {
      home.packages = with pkgs; [
        element-desktop
        thunderbird
        vesktop
      ];
    };
  };
}

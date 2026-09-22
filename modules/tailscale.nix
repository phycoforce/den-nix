_: {
  den.aspects.tailscale =
    { user, ... }:
    {
      provides.to-hosts.nixos = {
        services.tailscale = {
          enable = true;
          # UDP 41641 inbound: direct paths instead of DERP relaying.
          openFirewall = true;
          # Loose reverse-path filtering, required to use an exit node.
          useRoutingFeatures = "client";
          # Lets the CLI and trayscale drive tailscaled without root.
          extraSetFlags = [ "--operator=${user.userName}" ];
        };
      };

      homeManager =
        { pkgs, ... }:
        {
          home.packages = [ pkgs.trayscale ];
        };
    };
}

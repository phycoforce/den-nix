{ den, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      formatter = pkgs.nixfmt-rfc-style;

      packages = den.lib.nh.denPackages { fromFlake = true; } pkgs;
    };
}

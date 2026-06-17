{ den, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      formatter = pkgs.nixfmt;

      packages = den.lib.nh.denPackages { fromFlake = true; } pkgs;
    };
}

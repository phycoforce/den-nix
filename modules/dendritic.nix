{ inputs, ... }:
{
  imports = [
    (inputs.flake-file.flakeModules.dendritic or { })
    (inputs.den.flakeModules.dendritic or { })
  ];

  flake-file = {
    description = "Den starter for Aaron's NixOS desktop";

    nixConfig = {
      extra-substituters = [
        "https://cache.xinux.uz"
        "https://attic.xuyh0120.win/lantian"
        "https://noctalia.cachix.org"
        "https://nix-community.cachix.org"
      ];
      extra-trusted-public-keys = [
        "cache.xinux.uz:BXCrtqejFjWzWEB9YuGB7X2MV4ttBur1N8BkwQRdH+0="
        "lantian:EeAUQ+W+6r7EtwnmYjeVwx5kOGEBpjlBfPlzGlTNvHc="
        "noctalia.cachix.org-1:pCOR47nnMEo5thcxNDtzWpOxNFQsBRglJzxWPp3dkU4="
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      ];
    };

    # Core framework inputs only. Concern-specific inputs are declared via
    # flake-file.inputs in the aspect module that consumes them.
    inputs = {
      nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

      import-tree.url = "github:denful/import-tree";
      flake-file.url = "github:denful/flake-file";
      den.url = "github:denful/den";

      home-manager = {
        url = "github:nix-community/home-manager/master";
        inputs.nixpkgs.follows = "nixpkgs";
      };
    };
  };
}

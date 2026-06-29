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

    inputs = {
      nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
      nixpkgs-lib.follows = "nixpkgs";
      nixpkgs-codex.url = "github:NixOS/nixpkgs/master";

      import-tree.url = "github:denful/import-tree";
      flake-file.url = "github:denful/flake-file";
      den.url = "github:denful/den";

      codex-desktop-linux = {
        url = "github:ilysenko/codex-desktop-linux";
        inputs.nixpkgs.follows = "nixpkgs";
      };

      home-manager = {
        url = "github:nix-community/home-manager/master";
        inputs.nixpkgs.follows = "nixpkgs";
      };

      nix-flatpak.url = "github:gmodena/nix-flatpak";

      opnix = {
        url = "github:brizzbuzz/opnix";
        inputs.nixpkgs.follows = "nixpkgs";
      };

      darwin = {
        url = "github:nix-darwin/nix-darwin";
        inputs.nixpkgs.follows = "nixpkgs";
      };

      disko = {
        url = "github:nix-community/disko";
        inputs.nixpkgs.follows = "nixpkgs";
      };

      # Provides x86_64-v4 CachyOS kernel packages. Do not make it follow
      # nixpkgs; its cache depends on its own pinned nixpkgs.
      nix-cachyos-kernel.url = "github:xddxdd/nix-cachyos-kernel/release";

      # Current CachyOS setup uses Noctalia Shell v4 via Quickshell.
      noctalia.url = "git+https://github.com/noctalia-dev/noctalia?ref=legacy-v4";

      qylock = {
        url = "github:Darkkal44/qylock";
        inputs.nixpkgs.follows = "nixpkgs";
      };
    };
  };
}

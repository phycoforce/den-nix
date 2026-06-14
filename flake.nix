{
  description = "Den starter for Aaron's NixOS desktop";

  nixConfig = {
    extra-substituters = [
      "https://nyx-cache.chaotic.cx/"
      "https://noctalia.cachix.org"
      "https://nix-community.cachix.org"
    ];
    extra-trusted-public-keys = [
      "nyx-cache.chaotic.cx:dJxTrgMC3V3cFfyIiBQDQorG6k1LsqurH/srpMSq7qk="
      "noctalia.cachix.org-1:pCOR47nnMEo5thcxNDtzWpOxNFQsBRglJzxWPp3dkU4="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
  };

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    import-tree.url = "github:denful/import-tree";
    den.url = "github:denful/den";

    home-manager = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Provides linuxPackages_cachyos and its binary cache. Do not make it
    # follow nixpkgs; Chaotic's cache depends on its own pinned nixpkgs.
    chaotic.url = "github:chaotic-cx/nyx/nyxpkgs-unstable";

    # Current CachyOS setup uses Noctalia Shell v4 via Quickshell.
    noctalia.url = "git+https://github.com/noctalia-dev/noctalia?ref=legacy-v4";
  };

  outputs = inputs:
    (inputs.nixpkgs.lib.evalModules {
      modules = [ (inputs.import-tree ./modules) ];
      specialArgs = { inherit inputs; };
    }).config.flake;
}

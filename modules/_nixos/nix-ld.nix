{ pkgs, ... }:
{
  # Allow running generic-Linux dynamically-linked binaries (e.g. tools
  # installed by mise: node, zizmor, oxfmt). Without this, NixOS points
  # /lib64/ld-linux-x86-64.so.2 at a stub loader that refuses to start them.
  # See https://nix.dev/permalink/stub-ld
  programs.nix-ld = {
    enable = true;
    libraries = with pkgs; [
      stdenv.cc.cc # libstdc++ / libgcc_s (node, native node addons)
      zlib
      openssl
      curl
      libxml2
      icu
    ];
  };
}

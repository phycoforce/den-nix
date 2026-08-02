{ pkgs, ... }:
{
  # Runs generic-Linux dynamically-linked binaries (mise-installed node etc.);
  # without it /lib64/ld-linux-x86-64.so.2 is a stub loader that refuses them.
  # See https://nix.dev/permalink/stub-ld
  programs.nix-ld = {
    enable = true;
    libraries = with pkgs; [
      stdenv.cc.cc # libstdc++ / libgcc_s
      zlib
      openssl
      curl
      libxml2
      icu
    ];
  };
}

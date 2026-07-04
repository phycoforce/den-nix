set positional-arguments

nix_flags := "--accept-flake-config"
host := "temperantia"
installed_flake := "/etc/nixos/den-desktop#temperantia"

default:
    @just --list

fmt:
    git ls-files -z '*.nix' | xargs -0 nix {{nix_flags}} fmt --

fmt-check:
    git ls-files -z '*.nix' | xargs -0 nix {{nix_flags}} fmt -- --check

write-flake:
    nix {{nix_flags}} run .#write-flake

write-inputs:
    nix {{nix_flags}} run .#write-inputs

update-lock:
    nix flake update {{nix_flags}}

update-input input:
    nix flake lock --update-input {{input}} {{nix_flags}}

check-generated:
    nix {{nix_flags}} run .#write-flake
    git diff --exit-code flake.nix

flake-check:
    nix flake check {{nix_flags}}

lint:
    nix build .#checks.x86_64-linux.pre-commit -L {{nix_flags}}

build-dry:
    nix build .#nixosConfigurations.{{host}}.config.system.build.toplevel --dry-run {{nix_flags}}

build:
    nix build .#nixosConfigurations.{{host}}.config.system.build.toplevel {{nix_flags}}

validate: fmt-check lint check-generated flake-check build-dry

switch:
    nix {{nix_flags}} run .#{{host}} -- switch

switch-installed:
    sudo nixos-rebuild switch --flake {{installed_flake}} {{nix_flags}}

# flake-gate: Go port of scripts/plan-gate.sh, shadowing it in flake-update.sh
# until verdicts agree. Repo rules live here; the engine (tools/flake-gate)
# only reads the rendered policy JSON.
{ config, ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      # Never tolerated, even if baselined: an unserved match means an
      # hours-long compile or a wedged boot. hint names the substituter that
      # OWNS it. Order matters (first-prefix-match wins) and BLOCK stays
      # checked before the trivial-builder carve-out: llvm-src/clang-src/
      # niri-<v>-vendor match that shape yet are the mid-toolchain-rebuild
      # tripwire.
      block = [
        {
          prefix = "linux-cachyos";
          hint = "attic.xuyh0120.win/lantian (bump nix-cachyos-kernel only when its release branch is cached; probe: curl -sI <attic>/<hash>.narinfo)";
        }
        # Deliberately NOT a bare "nvidia" prefix: nvidia-open and
        # nvidia-persistenced are never publicly cached for this kernel
        # (cheap, so baseline-tolerated); a bare prefix would hold every
        # kernel bump forever.
        {
          prefix = "nvidia-x11";
          hint = "attic.xuyh0120.win/lantian or phycoforce.cachix.org (unfree: cache.nixos.org never carries it)";
        }
        {
          prefix = "mesa";
          hint = "cache.nixos.org (Hydra; probe: just hydra-check mesa)";
        }
        {
          prefix = "niri";
          hint = "cache.nixos.org (Hydra, not in 'tested'; probe: just hydra-check niri)";
        }
        {
          prefix = "quickshell";
          hint = "cache.nixos.org (probe: just hydra-check quickshell)";
        }
        {
          prefix = "xwayland-satellite";
          hint = "cache.nixos.org (probe: just hydra-check xwayland-satellite)";
        }
        {
          prefix = "ghostty";
          hint = "cache.nixos.org (probe: just hydra-check ghostty)";
        }
        {
          prefix = "sddm-unwrapped";
          hint = "cache.nixos.org (probe: just hydra-check kdePackages.sddm)";
        }
        {
          prefix = "webkitgtk";
          hint = "cache.nixos.org (multi-hour build)";
        }
        {
          prefix = "qtwebengine";
          hint = "cache.nixos.org (multi-hour build)";
        }
        {
          prefix = "electron";
          hint = "cache.nixos.org (multi-hour build)";
        }
        {
          prefix = "chromium";
          hint = "cache.nixos.org (multi-hour build)";
        }
        {
          prefix = "thunderbird-unwrapped";
          hint = "cache.nixos.org (multi-hour build)";
        }
        {
          prefix = "firefox-unwrapped";
          hint = "cache.nixos.org (multi-hour build)";
        }
        {
          prefix = "llvm";
          hint = "cache.nixos.org (toolchain; a rebuild here means the tip is mid-rebuild - hold)";
        }
        {
          prefix = "clang";
          hint = "cache.nixos.org (toolchain; hold - also guards the i686 twin, which llvm/gcc prefixes miss)";
        }
        {
          prefix = "rustc";
          hint = "cache.nixos.org (toolchain; hold)";
        }
        {
          prefix = "gcc";
          hint = "cache.nixos.org (toolchain; hold)";
        }
      ];

      # Per-configuration artifacts: no cache can ever serve them and they
      # cost nothing to build, so they are dropped without consulting the
      # baseline. Keep the patterns structural - a real package must never
      # match.
      configArtifactRegex = "^(unit-.+[.](service|timer|socket|target|mount|automount|slice|path|scope)|initrd-|system-path$|home-manager-path$|home-manager-files$|home-manager-generation$|nixos-system-|etc$|etc-|graphics-drivers$|system-generators$|user-generators$|X-Restart-Triggers|options[.]json$|home-configuration-reference-manpage$|.+[.]conf$|sddm-wrapped$|security-wrapper($|-)|pam[.]d$|hm-modules-messages$|jack-libs$)";

      # Kernel-module closures: host-specific, matched on the FULL store name
      # because the pname version-strip would collapse them onto the
      # kernel's own pname and fire the BLOCK list above.
      kmodClosureRegex = "^linux-.+-modules(-shrunk)?$";

      # Derived from the flake nixConfig, cache.nixos.org first; order matters
      # (first 200 wins). An unreachable one makes "no one serves X"
      # unknowable, so the gate exits 2 instead of guessing.
      substituters = [ "https://cache.nixos.org" ] ++ config.flake-file.nixConfig.extra-substituters;

      policy = {
        toplevel = ".#nixosConfigurations.temperantia.config.system.build.toplevel";
        baseline = "scripts/plan-gate-baseline.txt";
        inherit substituters;
        # This repo's own CI cache: excluded while measuring the baseline
        # (it only proves what a PAST run pushed), authoritative everywhere
        # else.
        ownCache = "https://phycoforce.cachix.org";
        # Calibrated against a COLD plan (~600 candidates); guards against
        # an offline bootstrap-from-source explosion (thousands of builds).
        maxBuilds = 2000;
        # The usual unserved 32-bit leaf set (nvidia EGL stack + stragglers)
        # is ~10; past this cap the plan is an i686 mass rebuild no cache
        # will absorb - hold, don't tolerate.
        maxI686 = 25;
        hydra = {
          url = "https://hydra.nixos.org";
          jobset = "nixos/unstable";
          maxLookups = 10;
        };
        inherit configArtifactRegex kmodClosureRegex block;
      };

      policyFile = pkgs.writeText "flake-gate-policy.json" (builtins.toJSON policy);

      flakeGate = pkgs.buildGoModule {
        pname = "flake-gate";
        version = "0.1.0";
        src = ../tools/flake-gate;
        vendorHash = null; # stdlib only - go.mod has zero require lines.
        # No subPackages: it would also narrow checkPhase's go test to cmd/.
        doCheck = true;
        nativeBuildInputs = [ pkgs.makeWrapper ];
        postInstall = ''
          wrapProgram $out/bin/flake-gate --set-default FLAKE_GATE_POLICY ${policyFile}
        '';
        meta.mainProgram = "flake-gate";
      };
    in
    {
      packages.flake-gate = flakeGate;
      # Same derivation: `nix flake check` runs its go test via doCheck.
      checks.flake-gate = flakeGate;

      devShells.flake-gate = pkgs.mkShell {
        packages = [
          pkgs.go
          pkgs.gopls
        ];
      };
    };
}

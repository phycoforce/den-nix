package nixplan

import (
	"os"
	"testing"
)

const fakeSrc = "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-source/"

func TestClassifyEvalFailure(t *testing.T) {
	cases := []struct {
		name, plan            string
		class, detail, option string
		nextHasPrefix         string
	}{
		{
			name: "broken via consumer",
			plan: "error:\n" +
				"       … while evaluating the option `home-manager.users.aaron.home.packages':\n\n" +
				"       … from call site\n" +
				"         at «github:nixos/nixpkgs/0000»/pkgs/by-name/ba/bar/package.nix:10:3:\n\n" +
				"       error: Refusing to evaluate package 'foo-1.2.3' in " + fakeSrc + "pkgs/by-name/fo/foo/package.nix:40 because it has problems:\n" +
				"       - broken: This package is broken.\n" +
				"       See also https://nixos.org/manual/nixpkgs/unstable#sec-problems\n",
			class: "broken", detail: "foo-1.2.3 has problems: - broken: This package is broken., via bar",
			option: "home-manager.users.aaron.home.packages", nextHasPrefix: "hold - self-heals",
		},
		{
			name: "insecure, no consumer frame",
			plan: "error:\n" +
				"       … while evaluating the option `environment.systemPackages':\n\n" +
				"       error: Refusing to evaluate package 'olm-3.2.16' in " + fakeSrc + "pkgs/by-name/ol/olm/package.nix:47 because it is marked as insecure\n" +
				"       Known issues:\n",
			class: "insecure", detail: "olm-3.2.16 is marked as insecure",
			option: "environment.systemPackages", nextHasPrefix: `needs a repo change - permit "olm-3.2.16"`,
		},
		{
			name: "unsupported platform joins the colon header",
			plan: "error:\n" +
				"       error: Refusing to evaluate package 'foo-1' in «unknown-file» because it is not available on the requested hostPlatform:\n" +
				"         hostPlatform.system = \"x86_64-linux\"\n",
			class: "unsupported-platform", detail: `foo-1 is not available on the requested hostPlatform: hostPlatform.system = "x86_64-linux"`,
			nextHasPrefix: "needs a repo change - drop or replace",
		},
		{
			name:  "non-source",
			plan:  "error: Refusing to evaluate package 'blob-2' in " + fakeSrc + "pkgs/by-name/bl/blob/package.nix:5 because it contains elements not built from source (‘binaryNativeCode’)\n",
			class: "non-source", detail: "blob-2 contains elements not built from source (‘binaryNativeCode’)",
			nextHasPrefix: `needs a repo change - allow "blob" as non-source`,
		},
		{
			name:  "other refusal",
			plan:  "error: Refusing to evaluate package 'xx-1' in " + fakeSrc + "pkgs/by-name/xx/xx/package.nix:5 because it has a blocklisted license (‘gpl3Only’)\n",
			class: "refused", detail: "xx-1 has a blocklisted license (‘gpl3Only’)",
			nextHasPrefix: "needs a repo change - follow the remediation",
		},
		{
			name: "refused package's own frame is not its consumer",
			plan: "error:\n" +
				"       … from call site\n" +
				"         at «github:nixos/nixpkgs/0000»/pkgs/by-name/ls/lsfg-vk/package.nix:45:3:\n\n" +
				"       error: Refusing to evaluate package 'lsfg-vk-2.0.0' in " + fakeSrc + "pkgs/by-name/ls/lsfg-vk/package.nix:45 because it has an unfree license (‘unfree’)\n",
			class: "unfree", detail: "lsfg-vk-2.0.0 has an unfree license (‘unfree’)",
			nextHasPrefix: `needs a repo change - allowlist "lsfg-vk" as unfree`,
		},
		{
			name: "failed assertion behind a bare error header",
			plan: "error:\n" +
				"       … while evaluating the option `system.build.toplevel':\n\n" +
				"       error:\n" +
				"       Failed assertions:\n" +
				"       - The ‘fileSystems’ option does not specify your root file system.\n",
			class: "other", detail: "Failed assertions: - The ‘fileSystems’ option does not specify your root file system.",
			option: "system.build.toplevel", nextHasPrefix: "read the trace above",
		},
		{
			name: "missing attribute never reports a via",
			plan: "error:\n" +
				"       … while evaluating the option `home-manager.users.aaron.home.packages':\n\n" +
				"         at «github:nixos/nixpkgs/0000»/pkgs/by-name/ba/bar/package.nix:3:1:\n\n" +
				"       error: attribute 'faugus-launcher' missing\n" +
				"       at " + fakeSrc + "modules/gaming.nix:83:11:\n",
			class: "other", detail: "attribute 'faugus-launcher' missing",
			option: "home-manager.users.aaron.home.packages", nextHasPrefix: "read the trace above",
		},
		{
			name:  "no error line",
			plan:  "warning: Git tree '/tmp/x' is dirty\n",
			class: "other", detail: "nix printed no error message", nextHasPrefix: "read the trace above",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c := ClassifyEvalFailure(tc.plan)
			if c.Class != tc.class || c.Detail != tc.detail || c.Option != tc.option {
				t.Fatalf("got class=%q detail=%q option=%q\nwant class=%q detail=%q option=%q",
					c.Class, c.Detail, c.Option, tc.class, tc.detail, tc.option)
			}
			if len(c.Next) < len(tc.nextHasPrefix) || c.Next[:len(tc.nextHasPrefix)] != tc.nextHasPrefix {
				t.Fatalf("Next = %q, want prefix %q", c.Next, tc.nextHasPrefix)
			}
		})
	}
}

func TestClassifyEvalFailure_RealUnfreeTrace(t *testing.T) {
	data, err := os.ReadFile("../../testdata/real-eval-unfree.txt")
	if err != nil {
		t.Fatalf("reading fixture: %v", err)
	}
	c := ClassifyEvalFailure(string(data))
	if c.Class != "unfree" || c.Detail != "lsfg-vk-2.0.0 has an unfree license (‘cc-by-nc-nd-40’), via faugus-launcher" ||
		c.Option != "home-manager.users.aaron.home.activation.installPackages.data" {
		t.Fatalf("got %+v", c)
	}
}

func TestEvalCauseLinesOmitEmptyOption(t *testing.T) {
	got := EvalCause{Class: "other", Detail: "bar", Next: "n"}.Lines()
	if len(got) != 2 || got[0] != "   eval: other - bar" || got[1] != "   next: n" {
		t.Fatalf("Lines() = %#v", got)
	}
}

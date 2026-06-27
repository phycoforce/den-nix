{ den, inputs, ... }:
{
  den.aspects.foundation = {
    includes = [
      (den.batteries.unfree [
        "1password-cli"
      ])
    ];

    homeManager =
      {
        config,
        lib,
        pkgs,
        ...
      }:
      let
        homeopsMcpConfigDir = "${config.xdg.configHome}/homeops-mcp";
        homeopsMcpSecretDomainPath = "${homeopsMcpConfigDir}/secret-domain";
        homeopsMcpSecretDomain2Path = "${homeopsMcpConfigDir}/secret-domain-2";
        homeopsMcpMeminiApiKeyPath = "${homeopsMcpConfigDir}/memini-api-key";
        opnixTokenFile = "${config.xdg.configHome}/opnix/token";
        opnixPackage = inputs.opnix.packages.${pkgs.stdenv.hostPlatform.system}.default;
        homeopsMcpOpnixConfig = pkgs.writeText "homeops-mcp-opnix-secrets.json" (
          builtins.toJSON {
            secrets = [
              {
                path = ".config/homeops-mcp/secret-domain";
                reference = "op://kubernetes/cluster_secrets/SECRET_DOMAIN";
                owner = config.home.username;
                group = "aaron";
                mode = "0600";
              }
              {
                path = ".config/homeops-mcp/secret-domain-2";
                reference = "op://kubernetes/cluster_secrets/SECRET_DOMAIN_2";
                owner = config.home.username;
                group = "aaron";
                mode = "0600";
              }
              {
                path = ".config/homeops-mcp/memini-api-key";
                reference = "op://kubernetes/memini/MEMINI_API_KEY";
                owner = config.home.username;
                group = "aaron";
                mode = "0600";
              }
            ];
          }
        );
      in
      {
        imports = [ inputs.opnix.homeManagerModules.default ];

        programs.onepassword-secrets = {
          enable = true;
          tokenFile = opnixTokenFile;
          secrets = {
            secretDomain = {
              reference = "op://kubernetes/cluster_secrets/SECRET_DOMAIN";
              path = ".config/homeops-mcp/secret-domain";
              group = "aaron";
              mode = "0600";
            };
            secretDomain2 = {
              reference = "op://kubernetes/cluster_secrets/SECRET_DOMAIN_2";
              path = ".config/homeops-mcp/secret-domain-2";
              group = "aaron";
              mode = "0600";
            };
            meminiApiKey = {
              reference = "op://kubernetes/memini/MEMINI_API_KEY";
              path = ".config/homeops-mcp/memini-api-key";
              group = "aaron";
              mode = "0600";
            };
          };
        };

        home.activation.retrieveOpnixSecrets = lib.mkForce (
          lib.hm.dag.entryAfter [ "createOpnixDirs" ] ''
            have_homeops_mcp_secrets() {
              [ -s ${lib.escapeShellArg homeopsMcpSecretDomainPath} ] \
                && [ -s ${lib.escapeShellArg homeopsMcpSecretDomain2Path} ] \
                && [ -s ${lib.escapeShellArg homeopsMcpMeminiApiKeyPath} ]
            }

            if [ -n "''${DRY_RUN_CMD:-}" ]; then
              echo "Skipping OpNix secret retrieval during dry run"
            elif [ ! -f ${lib.escapeShellArg opnixTokenFile} ]; then
              echo "WARNING: Token file ${opnixTokenFile} does not exist!" >&2
              echo "INFO: Using existing HomeOps MCP secrets, skipping updates" >&2
              echo "INFO: Run 'opnix token set -path ${opnixTokenFile}' to configure the token" >&2
            elif [ ! -r ${lib.escapeShellArg opnixTokenFile} ]; then
              if have_homeops_mcp_secrets; then
                echo "WARNING: Token file ${opnixTokenFile} is not readable; using existing HomeOps MCP secrets" >&2
              else
                echo "ERROR: Cannot read OpNix token at ${opnixTokenFile}" >&2
                exit 1
              fi
            else
              echo "Processing config file: ${homeopsMcpOpnixConfig}"
              if ${opnixPackage}/bin/opnix secret \
                -token-file ${lib.escapeShellArg opnixTokenFile} \
                -config ${homeopsMcpOpnixConfig} \
                -output "$HOME"; then
                :
              elif have_homeops_mcp_secrets; then
                echo "WARNING: OpNix secret retrieval failed; using existing HomeOps MCP secrets" >&2
              else
                echo "ERROR: OpNix secret retrieval failed and no existing HomeOps MCP secrets are available" >&2
                exit 1
              fi
            fi
          ''
        );

        home.packages = with pkgs; [
          _1password-cli
          nodejs_22
        ];
      };
  };
}

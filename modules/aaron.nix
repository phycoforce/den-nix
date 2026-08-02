{ den, ... }:
{
  den.aspects.aaron = {
    includes = [
      den.batteries.define-user
      den.batteries.primary-user
    ];

    user = {
      description = "Aaron";
      group = "aaron";

      openssh.authorizedKeys.keys = [
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC7Mg+TFga/96tbbiMYsj/JMscDNl3N1aAVFQ3p827amq6C2gwE9DTKRofRxKJvGCXO4EuDMaFVgy3Myn52SgYPiIsa37m2wZrZWzCIFrf2eL1YVTrJnx2Qr0GKZPngc95mcAhvjxiQLkwMfRBMDj5n3A6dbIsupIyPhvtgB2v2YrFgdcjJcO37tGLZRcu8Ok5CMlpEW9KQJPGO5PX3sFZK5ybQon9bJDzsYUcYQMp/mnhA1+6CBvcQNOP2m8E4pi66Kg67olOZq0bPoZkoU98W+mwfPfPEUlK4zadX4uwOOyVoCBXBjIphK5+JD97tddhZIrsdALqxn7lDNsOucqD5 ssh-key-2023-12-26 aaron@aaron"
      ];
    };

    homeManager = {
      imports = [ ./_home/core.nix ];
    };

    provides.to-hosts.nixos = {
      nix.settings.trusted-users = [ "aaron" ];

      users.groups.aaron = {
        gid = 1000;
        members = [ "aaron" ];
      };
    };
  };

  den.aspects.aaron-linux = {
    includes = [
      den.aspects.aaron
      (den.batteries.unfree [ "1password" ])
      den.aspects.communication
      den.aspects.desktop
      den.aspects.development
      den.aspects.agents
      den.aspects.gaming
      den.aspects.media
    ];

    user.extraGroups = [
      "audio"
      "input"
      "render"
      "video"
    ];

    homeManager = {
      imports = [ ./_home/packages.nix ];
    };

    provides.to-hosts.nixos = {
      programs = {
        _1password.enable = true;
        _1password-gui = {
          enable = true;
          polkitPolicyOwners = [ "aaron" ];
        };
      };
    };
  };
}

{ den, inputs, ... }:
{
  den.aspects.aaron = {
    includes = [
      den.batteries.define-user
      den.batteries.primary-user
    ];

    user.description = "Aaron";

    homeManager = {
      imports = [ ./_home/core.nix ];
    };

    provides.to-hosts.nixos = {
      users.users.aaron = {
        description = "Aaron";

        openssh.authorizedKeys.keys = [
          "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC7Mg+TFga/96tbbiMYsj/JMscDNl3N1aAVFQ3p827amq6C2gwE9DTKRofRxKJvGCXO4EuDMaFVgy3Myn52SgYPiIsa37m2wZrZWzCIFrf2eL1YVTrJnx2Qr0GKZPngc95mcAhvjxiQLkwMfRBMDj5n3A6dbIsupIyPhvtgB2v2YrFgdcjJcO37tGLZRcu8Ok5CMlpEW9KQJPGO5PX3sFZK5ybQon9bJDzsYUcYQMp/mnhA1+6CBvcQNOP2m8E4pi66Kg67olOZq0bPoZkoU98W+mwfPfPEUlK4zadX4uwOOyVoCBXBjIphK5+JD97tddhZIrsdALqxn7lDNsOucqD5 ssh-key-2023-12-26 aaron@aaron"
        ];
      };
    };
  };

  den.aspects.aaron-linux = {
    includes = [
      den.aspects.aaron
      den.aspects.communication
      den.aspects.development
      den.aspects.media
    ];

    homeManager = {
      imports = [
        inputs.noctalia.homeModules.default

        ./_home/niri.nix
        ./_home/noctalia-shell.nix
        ./_home/packages.nix
      ];
    };

    provides.to-hosts.nixos = {
      users.users.aaron.extraGroups = [
        "audio"
        "input"
        "render"
        "video"
      ];
    };
  };
}

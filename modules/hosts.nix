{ den, ... }:
{
  den.hosts.x86_64-linux.temperantia = {
    hostName = "temperantia";
    users.aaron.aspect = den.aspects.aaron-linux;
  };
}

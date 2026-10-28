{
  description = "Alert a healthchecks.io check when a machine is stuck at the initrd LUKS passphrase prompt";

  # Deliberately input-less: this is one NixOS module, so there is nothing to
  # pin and nothing for consumers to deduplicate.
  outputs =
    { self }:
    {
      nixosModules = rec {
        luks-prompt-alert = ./module.nix;
        default = luks-prompt-alert;
      };
    };
}

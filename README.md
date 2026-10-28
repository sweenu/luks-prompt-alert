# luks-prompt-alert

A NixOS module that tells you when a machine is sitting in its initrd waiting
for the LUKS passphrase, instead of leaving you to notice that a server never
came back after a power cut.

The initrd itself does the reporting, so nothing has to poll from the outside
and no second machine has to be trusted to be up.

## How it works

[healthchecks.io] is a dead man's switch: it alerts on a *missing* ping, which
is backwards for an event you want to announce. Its `/fail` endpoint inverts
that and alerts immediately, so one check carries both signals:

- **The initrd pings `/fail`**, `delay` (3 minutes by default) after boot. That
  delay is what keeps ordinary reboots quiet: entering the passphrase switches
  root and kills the pending timer before it ever fires.
- **The booted system pings OK**, at boot and hourly. That resolves the alert,
  and because the pings keep coming it also catches the cases the initrd can't
  report at all — a machine that never reaches the prompt, or one whose
  internet is down.

## Usage

```nix
{
  inputs.luks-prompt-alert.url = "github:sweenu/luks-prompt-alert";

  # ... in your NixOS configuration:
  imports = [ inputs.luks-prompt-alert.nixosModules.default ];

  services.luksPromptAlert = {
    enable = true;
    # Optional, these are the defaults:
    urlFile = "/etc/secrets/healthchecks-luks-url";
    nameservers = [ "9.9.9.9" "1.1.1.1" ];
    delay = "3min";
  };
}
```

Then, once:

1. **Create the check** on healthchecks.io. Period **2h**, grace **15m** — the
   hourly pings keep it green, and one missed ping won't cry wolf.
2. **Write its ping URL** to `urlFile` on the machine itself, mode `0600`, with
   **no trailing slash** (the module appends `/fail`):

   ```
   printf 'https://hc-ping.com/<uuid>' > /etc/secrets/healthchecks-luks-url
   chmod 600 /etc/secrets/healthchecks-luks-url
   ```

   This file has to exist **before** `nixos-rebuild switch`, including when it
   regenerates the initrd of an older generation, or the switch fails.

### Why the URL lives in a file

The URL is read at runtime rather than interpolated into the config, so it
stays out of the world-readable nix store and out of git. A ping URL in a
public repository lets anyone suppress your alerts by pinging OK.

It can't be a [agenix]/[sops-nix] secret either: the initrd has no way to
decrypt one, since the host key lives on the encrypted root. `boot.initrd.secrets`
appends the file when the bootloader is installed instead.

Note that the initrd is unencrypted on the ESP regardless, so anyone holding
the disk can read whatever is in it. That is fine for a publish-only ping URL
and is exactly why this must not be an SMTP password or an API token.

### Testing it

```
systemctl start luks-prompt-alert-clear   # check turns green: URL, DNS and TLS work
```

The initrd half needs a reboot: reboot, leave the passphrase unentered for
longer than `delay`, and confirm the alert arrives.

## Requirements

- A systemd initrd with networking (`boot.initrd.systemd.network.enable`) —
  asserted.
- A bootloader that supports initrd secrets, i.e. systemd-boot or GRUB —
  asserted.

## Two initrd traps this module works around

Both of these fail silently, at the one moment you need the alert:

- **The systemd initrd has no systemd-resolved and no `/etc/resolv.conf`**, so
  the `dns` settings of a `boot.initrd.systemd.network` profile don't apply
  there and nothing resolves. The module writes a resolv.conf from
  `nameservers`.
- **`boot.initrd.systemd.storePaths` follows ELF dependencies, not the nix
  store references of a shell script.** A script listed there lands in the
  image while everything it calls by absolute path does not. The first working
  version of this module shipped an initrd containing `libcurl.so` — pulled in
  by systemd — but no `curl` binary. The shell, coreutils, curl and the CA
  bundle are all listed explicitly, and TLS additionally needs `SSL_CERT_FILE`
  pointing into `pkgs.cacert`.

To check an initrd for yourself:

```
zstdcat $(nix build --no-link --print-out-paths \
  .#nixosConfigurations.<host>.config.system.build.initialRamdisk)/initrd \
  | cpio -t | grep curl
```

[healthchecks.io]: https://healthchecks.io
[agenix]: https://github.com/ryantm/agenix
[sops-nix]: https://github.com/Mic92/sops-nix

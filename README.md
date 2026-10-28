# luks-prompt-alert

A NixOS module that tells you when a machine is sitting in its initrd waiting
for the LUKS passphrase, instead of leaving you to notice that a server never
came back after a power cut.

The initrd itself does the reporting, so nothing has to poll from the outside
and no second machine has to be trusted to be up.

## How it works

A heartbeat service is a dead man's switch: it alerts on a *missing* ping,
which is backwards for an event you want to announce. A failure endpoint
inverts that, so one check carries both signals:

- **The initrd reports failure**, `delay` (3 minutes by default) after boot.
  That delay is what keeps ordinary reboots quiet: entering the passphrase
  switches root and kills the pending timer before it ever fires.
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
    urlFile = "/etc/secrets/heartbeat-luks-url";
    delay = "3min";
    failSuffix = "/fail";
    okSuffix = "";
  };
}
```

Then, once:

1. **Create the check.** Set its period to **2h** and grace to **15m** — the
   hourly pings keep it green, and one missed ping won't cry wolf. On Better
   Stack those are "Expect a heartbeat every" and "Grace period".
2. **Write its ping URL** to `urlFile` on the machine itself, mode `0600`, with
   **no trailing slash** (the module appends `failSuffix`):

   ```
   printf 'https://hc-ping.com/<uuid>' > /etc/secrets/heartbeat-luks-url
   chmod 600 /etc/secrets/heartbeat-luks-url
   ```

   This file has to exist **before** `nixos-rebuild switch`, including when it
   regenerates the initrd of an older generation, or the switch fails.

### Supported services

The defaults suit any service whose bare ping URL means "ok" and which takes a
`/fail` path for an immediate failure:

| Service | `urlFile` | `failSuffix` | `okSuffix` |
| --- | --- | --- | --- |
| [healthchecks.io] | `https://hc-ping.com/<uuid>` | *default* | *default* |
| [Better Stack] | `https://incidents.betterstack.com/api/v1/heartbeat/<token>` | *default* | *default* |
| [Uptime Kuma] | `https://<host>/api/push/<token>` | `?status=down` | `?status=up` |

Anything else that takes an unauthenticated URL and distinguishes success from
failure by path or query string will work the same way.

### Why the URL lives in a file

The URL is read at runtime rather than interpolated into the config, so it
stays out of the world-readable nix store and out of git. A ping URL in a
public repository lets anyone suppress your alerts by pinging OK — and not
only deliberately: a URL in a public repo gets fetched by crawlers and link
checkers, and a stray success ping silently resolves a real alert.

It can't be an [agenix]/[sops-nix] secret either: the initrd has no way to
decrypt one, since the host key lives on the encrypted root.
`boot.initrd.secrets` appends the file when the bootloader is installed
instead.

Note that the initrd is unencrypted on the ESP regardless, so anyone holding
the disk can read whatever is in it. That is fine for a ping URL, whose token
can only report state for that one check, and is exactly why this must not be
an SMTP password or a management API token.

### Testing it

```
systemctl start luks-prompt-alert-clear   # check turns green: URL, DNS and TLS work
```

The initrd half needs a reboot: reboot, leave the passphrase unentered for
longer than `delay`, and confirm the alert arrives.

## Requirements

All three are asserted, so a missing one is an eval error rather than an alert
that never arrives:

- A systemd initrd with networking — `boot.initrd.systemd.network.enable`.
- A resolver in the initrd — `boot.initrd.services.resolved.enable`, which
  NixOS turns on by default whenever the initrd has networkd. Without it, set
  `nameservers` instead.
- A bootloader that supports initrd secrets, i.e. systemd-boot or GRUB.

## Two initrd traps this module works around

Both fail silently, at the one moment you need the alert:

- **The initrd carries no CA bundle.** NixOS gives the initrd a resolver and a
  network, but nothing to verify TLS against. For curl that means every HTTPS
  request fails verification; for resolved it means DNS-over-TLS fails, either
  silently downgrading to plaintext (`DNSOverTLS = "opportunistic"`) or
  breaking DNS entirely (`true`). The module installs
  `security.pki.caBundle` at `/etc/ssl/certs/ca-certificates.crt` and points
  `SSL_CERT_FILE` there.
- **`boot.initrd.systemd.storePaths` follows ELF dependencies, not the nix
  store references of a shell script.** This is by design — the initrd builder
  deliberately does not copy full closures; its
  [README](https://github.com/NixOS/nixpkgs/blob/master/pkgs/build-support/kernel/make-initrd-ng/README.md)
  says "it is the burden of the developer to ensure that all necessary
  dependencies are copied in, as closures won't be consulted". So a script
  listed there lands in the image while everything it calls by absolute path
  does not. The first working version of this module shipped an initrd
  containing `libcurl.so` — pulled in by systemd, which links it — but no
  `curl` binary, since curl's binary is in a separate output that nothing had
  rooted. The shell, coreutils and curl are therefore listed explicitly.

To check an initrd for yourself:

```
zstdcat $(nix build --no-link --print-out-paths \
  .#nixosConfigurations.<host>.config.system.build.initialRamdisk)/initrd \
  | cpio -t | grep curl
```

[healthchecks.io]: https://healthchecks.io
[Better Stack]: https://betterstack.com/docs/uptime/cron-and-heartbeat-monitor/
[Uptime Kuma]: https://github.com/louislam/uptime-kuma
[agenix]: https://github.com/ryantm/agenix
[sops-nix]: https://github.com/Mic92/sops-nix

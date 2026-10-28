# Alert when the machine is stuck in the initrd waiting for the LUKS
# passphrase, by failing a heartbeat check from the initrd itself.
#
# A heartbeat service is a dead man's switch: it alerts on a *missing* ping,
# which is backwards for an event we want to announce. A failure endpoint
# inverts it and alerts immediately. The booted system then pings the same
# check OK, both to resolve the alert and, since it keeps pinging hourly, to
# catch a machine that never reaches the prompt at all.
#
# The defaults suit any service whose ping URL means "ok" on its own and takes
# a `/fail` path for an immediate failure, which covers healthchecks.io and
# Better Stack. For one that puts the state in a query string instead, such as
# Uptime Kuma or Cronitor, set `failSuffix` and `okSuffix`.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.luksPromptAlert;

  ping = pkgs.writeShellScript "luks-prompt-alert-ping" ''
    set -eu
    url="$(${pkgs.coreutils}/bin/cat ${cfg.urlFile})"
    case "$1" in
    fail)
      suffix="${cfg.failSuffix}"
      body="${config.networking.hostName} is in the initrd, waiting for the LUKS passphrase"
      ;;
    ok)
      suffix="${cfg.okSuffix}"
      body="${config.networking.hostName} is up"
      ;;
    esac
    # Long retries so a router that boots slower than the server, which is the
    # normal case after a power cut, doesn't lose the alert.
    exec ${pkgs.curl}/bin/curl -fsS -m 30 \
      --retry 60 --retry-delay 10 --retry-connrefused --retry-all-errors \
      --data-raw "$body" "$url$suffix"
  '';
in
{
  options.services.luksPromptAlert = {
    enable = lib.mkEnableOption "the heartbeat alert for a pending LUKS passphrase prompt";

    urlFile = lib.mkOption {
      type = lib.types.str;
      default = "/etc/secrets/heartbeat-luks-url";
      description = ''
        File holding the heartbeat check's ping URL, without a trailing slash.

        It is read at runtime rather than interpolated, to keep the URL out of
        the world-readable nix store and out of git. It has to exist on the
        machine itself before {command}`nixos-rebuild switch` runs, including
        when regenerating the initrd of an older generation.
      '';
    };

    failSuffix = lib.mkOption {
      type = lib.types.str;
      default = "/fail";
      example = "?status=down";
      description = ''
        Appended to {option}`urlFile`'s URL to report that the passphrase is
        still pending. The default is what healthchecks.io and Better Stack
        expect; a service that carries the state in a query string, such as
        Uptime Kuma, needs its own.
      '';
    };

    okSuffix = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "?status=up";
      description = ''
        Appended to {option}`urlFile`'s URL to report the machine as up, which
        is also what resolves a pending alert. Services that treat the bare
        ping URL as success, such as healthchecks.io and Better Stack, want
        this empty.
      '';
    };

    nameservers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "9.9.9.9"
        "1.1.1.1"
      ];
      description = ''
        Resolvers to write to {file}`/etc/resolv.conf` in the initrd. The
        initrd runs no systemd-resolved, so the `dns` settings of a networkd
        profile don't apply there and nothing would resolve without this.
      '';
    };

    delay = lib.mkOption {
      type = lib.types.str;
      default = "3min";
      description = ''
        How long the passphrase may go unentered before alerting. Entering it
        at the console within this window switches root and kills the pending
        timer, so an ordinary reboot stays quiet.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Both of these would otherwise only show up as a missing alert during an
    # outage, which is the worst possible time to find out.
    assertions = [
      {
        assertion = config.boot.initrd.systemd.network.enable;
        message = ''
          services.luksPromptAlert needs networking in the initrd:
          set `boot.initrd.systemd.network.enable` and give it a network
          profile, otherwise nothing can be reported from there.
        '';
      }
      {
        assertion = config.boot.loader.supportsInitrdSecrets;
        message = ''
          services.luksPromptAlert reads its ping URL from a file appended to
          the initrd at bootloader-install time, which this bootloader does
          not support. systemd-boot and GRUB both do.
        '';
      }
    ];

    boot.initrd = {
      # Appended to the initrd when the bootloader is installed, so the URL
      # never enters the nix store. The initrd is unencrypted on the ESP
      # either way, which is why this has to be a publish-only credential.
      secrets.${cfg.urlFile} = null;

      systemd = {
        # `storePaths` follows ELF dependencies, not the store references of a
        # shell script, so everything the script calls has to be listed here
        # or it silently won't be in the image.
        storePaths = [
          ping
          pkgs.runtimeShellPackage
          pkgs.coreutils
          pkgs.curl
          pkgs.cacert
        ];

        contents."/etc/resolv.conf".text = lib.concatMapStrings (
          ns: "nameserver ${ns}\n"
        ) cfg.nameservers;

        services.luks-prompt-alert = {
          description = "Report a pending LUKS passphrase prompt";
          # Ordering on networkd alone, rather than network-online.target,
          # whose wait-online unit isn't wanted by anything in the initrd.
          after = [ "systemd-networkd.service" ];
          wants = [ "systemd-networkd.service" ];
          # Covers the passphrase being entered just as the timer expires: by
          # then the root is mounted and switch-root is on its way.
          unitConfig.ConditionPathIsMountPoint = "!/sysroot";
          serviceConfig = {
            Type = "oneshot";
            Environment = "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
            ExecStart = "${ping} fail";
          };
        };

        timers.luks-prompt-alert = {
          description = "Delay the pending LUKS passphrase report";
          wantedBy = [ "initrd.target" ];
          timerConfig = {
            OnActiveSec = cfg.delay;
            AccuracySec = "1s";
          };
        };
      };
    };

    systemd.services.luks-prompt-alert-clear = {
      description = "Resolve the pending LUKS passphrase alert";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      startAt = "hourly";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${ping} ok";
      };
    };
  };
}

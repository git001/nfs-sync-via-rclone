{ config, lib, pkgs, ... }:

let
  cfg = config.services.nfs-sync;
in
{
  options.services.nfs-sync = with lib; {
    enable = mkEnableOption "periodic NFS → Azure Blob sync via rclone";

    package = mkOption {
      type = types.package;
      default = pkgs.callPackage ./flake.nix { };
      defaultText = literalExpression "nfs-sync package from the flake";
      description = "nfs-sync package providing the wrapper scripts.";
    };

    source = mkOption {
      type = types.path;
      example = "/mnt/nfs/source";
      description = "NFS mountpoint to sync FROM.";
    };

    destination = mkOption {
      type = types.str;
      example = "azureblob:content";
      description = "rclone destination in <remote>:<container> form.";
    };

    rcloneConfig = mkOption {
      type = types.path;
      example = "/run/secrets/rclone.conf";
      description = ''
        Path to the rclone.conf with credentials. Should be 0600 root:root.
        Use sops-nix / agenix / similar to provision; do NOT check in.
      '';
    };

    interval = mkOption {
      type = types.str;
      default = "5min";
      description = "systemd OnUnitInactiveSec value between runs.";
    };

    transfers = mkOption {
      type = types.ints.positive;
      default = 32;
      description = "rclone --transfers (parallel uploads).";
    };

    checkers = mkOption {
      type = types.ints.positive;
      default = 32;
      description = "rclone --checkers (parallel stat/hash).";
    };

    minAge = mkOption {
      type = types.str;
      default = "30s";
      description = "Quiescence window. Skip files touched within this period.";
    };

    bwlimit = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "100M";
      description = "Bandwidth cap, null = unlimited.";
    };

    mountCheckFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = ".mount-ok";
      description = ''
        Optional sentinel file inside `source` to confirm the NFS mount
        isn't a silent empty fallback. Highly recommended.
      '';
    };

    excludePatterns = mkOption {
      type = types.listOf types.str;
      default = [ "*.tmp" "*.swp" ".~lock*" "*.partial" "*.crdownload"
                  ".DS_Store" "Thumbs.db" ];
      description = "rclone --exclude patterns.";
    };

    memoryMax = mkOption {
      type = types.str;
      default = "8G";
      description = "systemd MemoryMax for the service.";
    };

    user = mkOption {
      type = types.str;
      default = "nfs-sync";
      description = "System user to run the sync as.";
    };

    group = mkOption {
      type = types.str;
      default = "nfs-sync";
      description = "System group.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      description = "nfs-sync service";
      home = "/var/lib/nfs-sync";
      createHome = false;
    };
    users.groups.${cfg.group} = { };

    environment.systemPackages = [ cfg.package ];

    systemd.tmpfiles.rules = [
      "d /var/log/nfs-sync 0750 ${cfg.user} ${cfg.group} -"
      "d /var/lib/nfs-sync 0750 ${cfg.user} ${cfg.group} -"
    ];

    systemd.services.nfs-sync = {
      description = "NFS → Azure Blob reconcile sync";
      documentation = [ "https://rclone.org/azureblob/" ];
      after = [ "network-online.target" "remote-fs.target" ];
      wants = [ "network-online.target" "remote-fs.target" ];
      requires = [ ];

      environment = {
        SRC = toString cfg.source;
        DST = cfg.destination;
        RCLONE_CONFIG = toString cfg.rcloneConfig;
        TRANSFERS = toString cfg.transfers;
        CHECKERS = toString cfg.checkers;
        MIN_AGE = cfg.minAge;
        EXCLUDE_PATTERNS = lib.concatStringsSep "," cfg.excludePatterns;
        BWLIMIT = lib.optionalString (cfg.bwlimit != null) cfg.bwlimit;
        MOUNT_CHECK_FILE = lib.optionalString (cfg.mountCheckFile != null)
                            cfg.mountCheckFile;
        LOG_DIR = "/var/log/nfs-sync";
        LOCK_FILE = "/run/nfs-sync.lock";
      };

      unitConfig = {
        RequiresMountsFor = toString cfg.source;
      };

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${cfg.package}/bin/nfs-sync";
        SuccessExitStatus = [ 0 2 ];
        User = cfg.user;
        Group = cfg.group;
        MemoryMax = cfg.memoryMax;
        CPUWeight = 80;
        IOWeight = 80;
        # Hardening
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        RestrictRealtime = true;
        SystemCallArchitectures = "native";
        ReadOnlyPaths = [ (toString cfg.source) ];
        ReadWritePaths = [ "/var/log/nfs-sync" "/run" ];
      };
    };

    systemd.timers.nfs-sync = {
      description = "Trigger NFS sync periodically";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitInactiveSec = cfg.interval;
        AccuracySec = "10s";
        Unit = "nfs-sync.service";
      };
    };
  };
}

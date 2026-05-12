{
  description = "nfs-sync: periodic NFS → Azure Blob sync via rclone";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems
        (system: f (import nixpkgs { inherit system; }));

      version = "1.0.0";

      # The upstream source is two directories up — when consumed as a flake
      # from outside, point inputs at the repo and override `src` if needed.
      src = ../../rclone;
    in
    {
      packages = forAllSystems (pkgs: {
        default = self.packages.${pkgs.system}.nfs-sync;

        nfs-sync = pkgs.stdenvNoCC.mkDerivation {
          pname = "nfs-sync";
          inherit version src;

          nativeBuildInputs = [ pkgs.makeWrapper ];

          # Runtime deps that we PATH-inject into the wrappers — explicit so
          # the package works regardless of system PATH state.
          runtimeDeps = with pkgs; [
            rclone
            bash
            coreutils
            util-linux  # flock, mountpoint
          ];

          installPhase = ''
            runHook preInstall

            install -D -m 0755 nfs-sync.sh   $out/bin/nfs-sync
            install -D -m 0755 sync-bench.sh $out/bin/nfs-sync-bench

            install -D -m 0644 nfs-sync.defaults \
                $out/share/nfs-sync/defaults
            install -D -m 0644 rclone.conf \
                $out/share/nfs-sync/rclone.conf.template
            install -D -m 0644 nfs-sync-failure.service \
                $out/lib/systemd/system/nfs-sync-failure.service
            install -D -m 0644 nfs-sync.logrotate \
                $out/etc/logrotate.d/nfs-sync

            for bin in $out/bin/nfs-sync $out/bin/nfs-sync-bench; do
              wrapProgram "$bin" \
                --prefix PATH : ${pkgs.lib.makeBinPath self.packages.${pkgs.system}.nfs-sync.runtimeDeps}
            done

            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "Periodic NFS → Azure Blob sync via rclone";
            license = licenses.asl20;
            platforms = platforms.linux;
            maintainers = [ ];
          };
        };
      });

      nixosModules.default = import ./module.nix;
      nixosModules.nfs-sync = self.nixosModules.default;

      # Convenience: a runnable check
      checks = forAllSystems (pkgs: {
        package-builds = self.packages.${pkgs.system}.nfs-sync;
      });
    };
}

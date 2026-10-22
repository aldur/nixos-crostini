{ pkgs, smoke }:
pkgs.runCommand "baguette-root-guard"
  {
    nativeBuildInputs = [
      smoke.crosvm
      pkgs.coreutils
      pkgs.gnugrep
    ];
    requiredSystemFeatures = [ "kvm" ];
  }
  ''
    cp ${smoke.shipped.btrfsImage}/baguette_rootfs.img root.img
    chmod u+w root.img
    mkdir "$out"
    for mode in writable-root wrong-root; do
      if [ "$mode" = writable-root ]; then
        disks=(--block path=root.img,root=true --block path=${smoke.toolsDisk},ro=true)
      else
        disks=(--block path=${smoke.toolsDisk},ro=true --block path=root.img,ro=true,root=true)
      fi
      status=0
      timeout 45 crosvm run --disable-sandbox --cpus 2 --mem 512 \
        --serial type=stdout,hardware=virtio-console,num=1,console=true \
        --params 'panic=-1 init=/sbin/init console=hvc0 quiet' \
        "''${disks[@]}" ${smoke.kernel}/kernel > "$out/$mode.log" 2>&1 || status=$?
      test "$status" -ne 124
      grep -F 'Baguette requires /dev/vda as the read-only root' "$out/$mode.log"
    done
  ''

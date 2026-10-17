#! @shell@
set -euo pipefail

@utilLinux@/bin/mount -t proc proc /proc
@utilLinux@/bin/mount -t sysfs sysfs /sys
@utilLinux@/bin/mount -t devtmpfs devtmpfs /dev
@utilLinux@/bin/mount -t tmpfs -o mode=755 tmpfs /run
@utilLinux@/bin/mount --make-rprivate /
# The top-level mount below makes the shared Btrfs superblock read-write again.
# The lower mount's ro flag and the subvolume's ro property protect the root.
@utilLinux@/bin/mount -o remount,ro /

@coreutils@/bin/mkdir -p /run/ephemeral /run/newroot /run/btrfs
@utilLinux@/bin/mount -t tmpfs -o size=@tmpfsSize@,mode=755 tmpfs /run/ephemeral
@coreutils@/bin/mkdir /run/ephemeral/{upper,work,lower}
@utilLinux@/bin/mount --bind -o ro / /run/ephemeral/lower
@utilLinux@/bin/mount -t overlay overlay \
  -o @overlayOptions@ \
  /run/newroot

@utilLinux@/bin/mount -t btrfs -o rw,subvolid=5 /dev/vdb /run/btrfs
if [ ! -e /run/btrfs/state ]; then
  @btrfs@/bin/btrfs subvolume create /run/btrfs/state
fi

if @persistMachineId@; then
  machine_id_file=/run/btrfs/state/machine-id
  if [ ! -s "$machine_id_file" ]; then
    # Generate per state volume, never in the distributable root image.
    # Publish atomically so an interrupted write cannot leave a partial ID.
    machine_id_tmp=$(@coreutils@/bin/mktemp /run/btrfs/state/.machine-id.XXXXXX)
    @systemd@/bin/systemd-id128 new > "$machine_id_tmp"
    @coreutils@/bin/chmod 0444 "$machine_id_tmp"
    @coreutils@/bin/sync -f "$machine_id_tmp"
    @coreutils@/bin/mv -T "$machine_id_tmp" "$machine_id_file"
  fi
  machine_id=$(@coreutils@/bin/cat "$machine_id_file")
  if [[ ! "$machine_id" =~ ^[0-9a-f]{32}$ || "$machine_id" == 00000000000000000000000000000000 ]]; then
    echo 'Invalid machine-id in the persistent state subvolume' >&2
    exit 1
  fi
  # This must precede stage 2: systemd caches the ID at startup.
  @coreutils@/bin/install -D -m 0444 "$machine_id_file" /run/newroot/etc/machine-id
fi
@utilLinux@/bin/umount /run/btrfs

# Mount NixOS's early filesystems here so stage 2 does not hide
# /run/ephemeral with a new /run tmpfs. Stage 2 skips this if /proc/1 exists.
specialMount() {
  @coreutils@/bin/install -m 0755 -d "/run/newroot$2"
  @utilLinux@/bin/mount -n -t "$4" -o "$3" "$1" "/run/newroot$2"
}
source @earlyMountScript@

@coreutils@/bin/mkdir -p /run/newroot/run/ephemeral /run/newroot/oldroot
@utilLinux@/bin/mount --move /run/ephemeral /run/newroot/run/ephemeral

cd /run/newroot
# switch_root deletes the old root's contents; it must never be used here.
@utilLinux@/bin/pivot_root . oldroot
@utilLinux@/bin/umount -l /oldroot
@coreutils@/bin/rmdir /oldroot
# Stage 2 uses process substitution for its log tee, which needs /dev/fd.
@coreutils@/bin/ln -sfn /proc/self/fd /dev/fd

exec @systemConfig@/@stage2@ "$@"

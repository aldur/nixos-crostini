# Baguette ephemeral root

Set [`baguette.ephemeralRoot.enable`][ephemeral-root] to `true` to use a
read-only base and a separate writable state disk. Root changes use RAM. Leave
this option disabled for a writable root and in-place NixOS upgrades.

Build the image after you enable this option:

```bash
nix build .#baguette-zimage
```

The `baguette-zimage` output contains `baguette_rootfs.img.zst` and
`baguette_state.img.zst`. The base uses seekable zstd with 128 KiB frames.
ChromeOS reads it directly. Copy both compressed files to a `baguette` folder
in ChromeOS Downloads. Create a new VM with the required state disk size:

```text
vmc create --vm-type BAGUETTE --size 15G \
  --source \
    /home/chronos/user/MyFiles/Downloads/baguette/baguette_state.img.zst \
  baguette
vmc start --vm-type BAGUETTE \
  --rootfs \
    /home/chronos/user/MyFiles/Downloads/baguette/baguette_rootfs.img.zst \
  baguette
```

**Important**: Use the full start command after each VM stop or ChromeOS login.

### Limitations

1. Do not launch the VM from the app launcher, which does not retain
   `--rootfs`; use it only after the VM starts.
1. Guest root can make the state disk bootable. A start without `--rootfs` can
   then run code from that disk.
1. Keep the base image outside folders shared with Linux.
1. Back up the base image with the stopped state disk.
1. Do not use ChromeOS disk resizing with this layout: ChromeOS assumes its
   state disk is `/dev/vdb`; this layout uses `/dev/vdc`. Instead, export the
   state disk, then re-import with the new size.

[ephemeral-root]: baguette.md#baguetteephemeralrootenable

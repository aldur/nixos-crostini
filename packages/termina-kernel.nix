# A representative ChromeOS VM kernel for Baguette boot tests, built
# from the public ChromeOS tree with its termina configuration. The
# image ships no kernel. Keep the pin on the kernel branch used by the
# supported guests; it need not match an individual Chromebook's commit.
{
  lib,
  stdenv,
  fetchFromGitiles,
  bc,
  bison,
  cpio,
  elfutils,
  flex,
  gmp,
  libmpc,
  mpfr,
  openssl,
  pahole,
  perl,
  python3Minimal,
  zlib,
  zstd,
}:
let
  kernelVersion = "6.6.147";
  isX86 = stdenv.hostPlatform.isx86_64;
  arch = if isX86 then "x86_64" else "arm64";
  flavour = "container-vm-${arch}";
  image = if isX86 then "arch/x86/boot/bzImage" else "arch/arm64/boot/Image";
in
stdenv.mkDerivation {
  pname = "termina-kernel";
  # The head of chromeos-6.6 on 2026-09-09. To update: choose a commit
  # from that branch, set kernelVersion from its Makefile, clear hash,
  # and build .#termina-kernel to get the new source hash.
  version = "${kernelVersion}-chromeos";

  src = fetchFromGitiles {
    url = "https://chromium.googlesource.com/chromiumos/third_party/kernel";
    rev = "a91057729ac86a115c514334de6fde7f715ee8b7";
    hash = "sha256-wTz19Bly3o255VfDYaQWp1H+9vIJL7sEH5Ykkjxe5yk=";
  };

  nativeBuildInputs = [
    bc
    bison
    cpio
    elfutils
    flex
    gmp
    libmpc
    mpfr
    openssl
    pahole
    perl
    python3Minimal
    zlib
    zstd
  ];

  # The kernel sets its own compiler flags.
  hardeningDisable = [ "all" ];
  enableParallelBuilding = true;
  makeFlags = [
    "ARCH=${arch}"
    "KBUILD_BUILD_USER=nixbld"
    "KBUILD_BUILD_HOST=nixos"
  ];

  postPatch = ''
    patchShebangs scripts chromeos/scripts
  '';

  # prepareconfig concatenates the split configuration of ChromeOS:
  # chromeos/config/termina/{base,<arch>/common,<arch>/<flavour>.flavour}.config.
  configurePhase = ''
    runHook preConfigure
    source_version=$(make -s $makeFlags kernelversion)
    if [ "$source_version" != "${kernelVersion}" ]; then
      echo "Kernel version mismatch: source is $source_version, package expects ${kernelVersion}" >&2
      exit 1
    fi
    export KBUILD_BUILD_TIMESTAMP="$(date -u -d @$SOURCE_DATE_EPOCH)"
    CHROMEOS_KERNEL_FAMILY=termina bash chromeos/scripts/prepareconfig ${flavour} .config
    make $makeFlags olddefconfig
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    make $makeFlags -j$NIX_BUILD_CORES ${baseNameOf image}
    runHook postBuild
  '';

  # `kernel` whatever the architecture, so the caller needs no case.
  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp ${image} $out/kernel
    cp .config $out/config
    cp include/config/kernel.release $out/release
    runHook postInstall
  '';

  meta = {
    description = "The ChromeOS VM (termina) kernel that Baguette boots";
    homepage = "https://chromium.googlesource.com/chromiumos/third_party/kernel";
    license = lib.licenses.gpl2Only;
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
}

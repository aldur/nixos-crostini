# Measuring Baguette startup

Build a runner for the current native architecture, then run it outside the
Nix sandbox with KVM available:

```sh
nix build .#baguette-benchmark --out-link /tmp/baguette-runner
/tmp/baguette-runner/bin/baguette-benchmark --output /tmp/baguette-timings --runs 5
```

The output directory must be new. Each repetition decompresses a fresh copy of
the distributed image, grows its disk, boots it, then boots the same disk again
after a clean shutdown. `--warm-boots 0` omits the second boot. The runner never
modifies a deployed guest. Image extraction and hashing are outside the measured
boot; the host's page cache is not flushed. These are fresh-image and persistent-
disk tests, not claims about cold Chromebook storage caches.

Each boot must pass the smoke probes, including unassisted user-manager startup,
four notified display services, the garcon launch environment, filesystem resize,
the expected Termina kernel, no failed units, and successful VM shutdown. Logs,
input hashes, the exact system store path, per-boot results, and median/min/max
summaries are saved. A failure stops the run and preserves its logs and disk.

Times are seconds on the guest's monotonic clock since kernel startup. Use the
larger of `system/manager/FinishTimestampMonotonic` and
`user/garcon.service/ActiveEnterTimestampMonotonic` when comparing completion of
both system and guest-session startup. `systemd-analyze time` alone can finish
before the user services. A service's startup duration is its active-enter
timestamp minus its inactive-exit timestamp. The probe's polling and VM shutdown
duration are not included in those timestamps.

The tools disk, host compositor, and ChromeOS daemons are fixtures. The garcon
timestamp means its guest unit started with the required display environment;
it does **not** establish successful ChromeOS registration. Use identical CPU,
memory, kernel and harness settings for comparisons. Stop concurrent builds and
alternate baseline/candidate runs to reduce host-load and cache bias. The
`lib.mkBaguetteBenchmark { configuration = ...; }` function applies the same
runner to a downstream NixOS configuration. Pass `extraSystemUnits = [ "example.service" ];`
to include configuration-specific services in its timing records.

For a real Chromebook, start a separate test VM with
`vmc start --vm-type BAGUETTE --no-shell <name>`. Record elapsed host
time until that command succeeds and until an application/shell is usable.
Record first import separately from subsequent `vmc stop`/`vmc start` cycles.
After successful unassisted startup, collect the guest timing records as root:

```sh
user=aldur # the configured Crostini user
uid=$(id -u "$user")
as_user() {
  setpriv --reuid "$uid" --regid "$(id -g "$user")" --init-groups \
    env XDG_RUNTIME_DIR="/run/user/$uid" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" "$@"
}
. ./tests/boot-timing.sh
```

Collect ChromeOS version, guest image checksum, timestamps and failed units
alongside the host elapsed times. Repeat at least five times per image, including
ChromeOS reboot and suspend/resume. Do not enable lingering or manually start
services before deciding whether startup succeeded.

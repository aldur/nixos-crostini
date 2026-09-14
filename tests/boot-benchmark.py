"""Repeated fresh-image and persistent-disk guest boots; no ChromeOS RPC claims."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import socket
import statistics
import subprocess
import time


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def timings(log):
    result = {}
    prefix = None
    for line in log.read_text().splitlines():
        if line.startswith("TIMING "):
            prefix = line.removeprefix("TIMING ").replace(" ", "/")
        elif prefix and "=" in line:
            key, value = line.split("=", 1)
            if key.endswith("TimestampMonotonic") and value.isdecimal():
                result[f"{prefix}/{key}"] = int(value) / 1_000_000
    required = [
        "system/manager/FinishTimestampMonotonic",
        "system/maitred.service/ActiveEnterTimestampMonotonic",
        "user/garcon.service/ActiveEnterTimestampMonotonic",
    ]
    if any(result.get(key, 0) <= 0 for key in required):
        raise RuntimeError("Incomplete boot timing records")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True, help="New directory for logs and results")
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--warm-boots", type=int, default=1, help="Persistent-disk boots after each fresh boot")
    parser.add_argument("--cpus", type=int, default=2)
    parser.add_argument("--memory", type=int, default=4096, help="Guest MiB")
    parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()
    if min(args.runs, args.cpus, args.memory, args.timeout) < 1 or args.warm_boots < 0:
        parser.error("Counts must be positive; warm-boots may be zero")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    manifest = json.loads(args.manifest.read_text())
    provenance = {
        "manifest": manifest,
        "arguments": vars(args) | {"manifest": str(args.manifest), "output": str(output)},
        "sha256": {},
    }
    for key in ("image", "tools", "kernel"):
        with open(manifest[key], "rb") as source:
            provenance["sha256"][key] = hashlib.file_digest(source, "sha256").hexdigest()
    (output / "inputs.json").write_text(json.dumps(provenance, indent=2) + "\n")
    runtime = output / "run"
    runtime.mkdir(mode=0o700)
    ready = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    ready.bind(str(runtime / "weston-notify"))
    ready.settimeout(12)
    env = os.environ | {"XDG_RUNTIME_DIR": str(runtime), "XDG_CACHE_HOME": str(output / "cache")}
    weston_log = open(output / "weston.log", "w")
    weston = subprocess.Popen([
        "weston", "--backend=headless", "--fake-seat", "--socket=wayland-host",
        "--idle-time=0", "--shell=desktop", "--renderer=pixman", "--no-config",
        "--modules=systemd-notify.so",
    ], env=env | {"NOTIFY_SOCKET": str(runtime / "weston-notify")},
        stdout=weston_log, stderr=subprocess.STDOUT)
    records = []
    try:
        # The socket can exist before compositor initialization finishes.
        # Wait for Weston's explicit readiness signal, without polling.
        try:
            notification = ready.recv(4096).decode().splitlines()
        except TimeoutError as error:
            raise RuntimeError("Weston readiness timeout; see weston.log") from error
        if "READY=1" not in notification:
            raise RuntimeError(f"Unexpected Weston notification: {notification!r}")
        for repetition in range(args.runs):
            disk = output / "root.img"
            run("zstd", "-q", "-d", "-f", manifest["image"], "-o", str(disk))
            image_size = disk.stat().st_size
            disk.chmod(0o600)
            with disk.open("r+b") as image:
                image.truncate(image_size + 2 * 1024**3)
                # Do not charge pending writes from image extraction to
                # the guest's first fsync. The installed image is the input.
                os.fsync(image.fileno())
            for boot in range(1 + args.warm_boots):
                kind = "fresh" if boot == 0 else "persistent"
                directory = output / f"{repetition + 1:02d}-{boot:02d}-{kind}"
                directory.mkdir()
                for name in ("console.log", "probe.log"):
                    (directory / name).touch()
                command = [
                    "crosvm", "run", "--disable-sandbox", "--cpus", str(args.cpus), "--mem", str(args.memory),
                    "--serial", f"type=file,path={directory}/console.log,hardware=serial,num=1,console=true",
                    "--serial", f"type=file,path={directory}/probe.log,hardware=serial,num=2",
                    "--gpu", "backend=virglrenderer,context-types=cross-domain",
                    "--wayland-sock", str(runtime / "wayland-host"),
                    "--params", "root=/dev/vdb rw init=/sbin/init console=ttyS0",
                    "--block", f"path={manifest['tools']},ro=true", "--block", f"path={disk}", manifest["kernel"],
                ]
                started = time.monotonic()
                with (directory / "crosvm.log").open("w") as log:
                    completed = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=args.timeout)
                elapsed = time.monotonic() - started
                with (directory / "validation.log").open("w") as log:
                    run("bash", manifest["verifier"], str(completed.returncode), str(directory / "probe.log"),
                        manifest["checker"], manifest["kernelRelease"], str(image_size), stdout=log, stderr=subprocess.STDOUT)
                metrics = timings(directory / "probe.log")
                records.append({"run": repetition + 1, "boot": boot, "kind": kind,
                                "vm_lifetime_seconds": elapsed, "seconds": metrics})
                (output / "results.json").write_text(json.dumps(records, indent=2) + "\n")
                print(f"{directory.name}: garcon guest start {metrics['user/garcon.service/ActiveEnterTimestampMonotonic']:.3f}s, "
                      f"boot finished {metrics['system/manager/FinishTimestampMonotonic']:.3f}s", flush=True)
            disk.unlink()
    finally:
        ready.close()
        weston.terminate()
        try:
            weston.wait(timeout=10)
        except subprocess.TimeoutExpired:
            weston.kill()
            weston.wait()
        weston_log.close()
    summary = {}
    for kind in sorted({record["kind"] for record in records}):
        group = [record["seconds"] for record in records if record["kind"] == kind]
        summary[kind] = {
            key: {"median": statistics.median(values), "min": min(values), "max": max(values)}
            for key in group[0]
            for values in [[sample[key] for sample in group]]
        }
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")


if __name__ == "__main__":
    main()

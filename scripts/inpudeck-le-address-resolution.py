#!/usr/bin/env python3
"""Restore BlueZ's missing LE address-resolution flag for named InpuDeck peers.

BlueZ 5.87 does not push this flag for dual-mode devices with a stored IRK.
Run from bluetooth.service ExecStartPost, after bluetoothd has loaded its bonds.
Every target must be an explicit Bluetooth identity address. This only changes
that device's kernel management flags; it does not scan, connect, or edit bonds.
"""

import argparse
import configparser
import os
from pathlib import Path
import re
import stat
import subprocess
import sys


FLAG = 0x04
STORAGE = Path("/var/lib/bluetooth")
ADDRESS = re.compile(r"[0-9A-F]{2}(?::[0-9A-F]{2}){5}")


def run(*args):
    return subprocess.run(args, text=True, capture_output=True, timeout=5)


def controller_address(adapter, execute=run):
    result = execute("btmgmt", "-i", adapter, "info")
    if result.returncode:
        raise RuntimeError(f"btmgmt info failed: {result.stderr.strip()}")
    match = re.search(r"\baddr ([0-9A-Fa-f:]{17})\b", result.stdout)
    if not match:
        raise RuntimeError("Controller address missing from btmgmt info")
    return match.group(1).upper()


def eligible(info):
    config = configparser.ConfigParser(interpolation=None)
    try:
        config.read(info)
        technologies = set(config.get("General", "SupportedTechnologies").split(";"))
        kind = config.get("General", "AddressType", fallback="").lower()
    except (configparser.Error, OSError):
        return None
    if not {"BR/EDR", "LE"} <= technologies:
        return None
    if not (config.has_section("IdentityResolvingKey") and
            config.has_section("LinkKey") and
            (config.has_section("LongTermKey") or
             config.has_section("PeripheralLongTermKey"))):
        return None
    return "2" if kind in ("static", "random") else "1" if kind == "public" else None


def normalize_devices(values):
    devices = []
    for value in values:
        address = value.strip().upper()
        if not ADDRESS.fullmatch(address):
            raise ValueError(f"invalid Bluetooth identity address: {value!r}")
        if address not in devices:
            devices.append(address)
    if not devices:
        raise ValueError("at least one InpuDeck device address is required")
    return devices


def devices_from_file(path):
    path = Path(path)
    if path.is_symlink():
        raise ValueError(f"refusing a symlinked device file: {path}")
    try:
        metadata = path.stat()
    except OSError as error:
        raise ValueError(f"cannot read device file {path}: {error}") from error
    if not stat.S_ISREG(metadata.st_mode):
        raise ValueError(f"device file is not a regular file: {path}")
    if metadata.st_mode & 0o022:
        raise ValueError(f"device file must not be group/world writable: {path}")
    if os.geteuid() == 0 and metadata.st_uid != 0:
        raise ValueError(f"device file must be owned by root: {path}")
    try:
        values = [
            line for raw in path.read_text(encoding="utf-8").splitlines()
            if (line := raw.strip()) and not line.startswith("#")
        ]
    except (OSError, UnicodeError) as error:
        raise ValueError(f"cannot read device file {path}: {error}") from error
    return normalize_devices(values)


def apply(adapter, devices, storage=STORAGE, execute=run):
    devices = normalize_devices(devices)
    controller = controller_address(adapter, execute)
    directory = storage / controller
    if not directory.is_dir():
        raise RuntimeError(f"BlueZ bond directory missing: {directory}")
    targets = []
    for address in devices:
        info = directory / address / "info"
        if not info.is_file():
            raise RuntimeError(f"configured InpuDeck bond is missing: {info}")
        address_type = eligible(info)
        if address_type is None:
            raise RuntimeError(
                f"configured peer is not a bonded dual-mode device with an IRK: {address}"
            )
        targets.append((address, address_type))

    changed = 0
    failed = 0
    for address, address_type in targets:
        base = ("btmgmt", "-i", adapter)
        flags = execute(*base, "get-flags", "-t", address_type, address)
        if flags.returncode:
            detail = flags.stderr.strip() or flags.stdout.strip()
            # This is the exact BlueZ dual-mode bug we are repairing: the
            # device was never added to the kernel flag table, so Get Device
            # Flags returns Invalid Parameters. There are no existing flags to
            # preserve in that case; initialize the explicit bonded peer with
            # ADDRESS_RESOLUTION only. Every other read failure stays fatal.
            if re.search(r"(?:status\s+)?0x0d\b|Invalid Parameters", detail, re.I):
                current = 0
                print(f"No kernel device-flag record for {address}; initializing it")
            else:
                print(f"Cannot read current flags for {address}: {detail}", file=sys.stderr)
                failed += 1
                continue
        else:
            match = re.search(r"Current Flags:\s*0x([0-9a-fA-F]+)", flags.stdout)
            if not match:
                print(f"Cannot parse current flags for {address}; leaving it unchanged", file=sys.stderr)
                failed += 1
                continue
            current = int(match.group(1), 16)
        if current & FLAG:
            continue
        result = execute(*base, "set-flags", "-t", address_type,
                         "-f", str(current | FLAG), address)
        if result.returncode:
            print(f"Address-resolution flag failed for {address}: "
                  f"{result.stderr.strip() or result.stdout.strip()}", file=sys.stderr)
            failed += 1
            continue
        print(f"Address resolution enabled for configured InpuDeck peer {address}")
        changed += 1
    print(f"Address-resolution flags changed: {changed}")
    if failed:
        raise RuntimeError(f"address-resolution setup failed for {failed} configured peer(s)")
    return changed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adapter", default="hci0")
    targets = parser.add_mutually_exclusive_group(required=True)
    targets.add_argument(
        "--device",
        action="append",
        metavar="ADDRESS",
        help="exact bonded InpuDeck/iPhone identity address; may be repeated",
    )
    targets.add_argument(
        "--device-file",
        type=Path,
        metavar="PATH",
        help="root-owned, non-writable file containing one exact address per line",
    )
    args = parser.parse_args()
    try:
        devices = args.device if args.device is not None else devices_from_file(args.device_file)
        apply(args.adapter, devices)
    except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired) as error:
        print(f"Address-resolution setup failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "esptool>=5,<6",
# ]
# ///
"""Flash InpuDeck firmware and provision its persistent BLE bridge name."""

from __future__ import annotations

import argparse
import os
import shutil
import stat
import subprocess
import sys
import time
from pathlib import Path
from typing import Iterable


DEFAULT_BRIDGE_NAME = "InpuDeck Bridge"
MAX_BRIDGE_NAME_BYTES = 28
ESPRESSIF_USB_VID = 0x303A


class InstallerError(RuntimeError):
    pass


def normalized_bridge_name(value: str) -> str:
    name = value.strip(" \t\r\n")
    encoded = name.encode("utf-8")
    if not encoded:
        raise argparse.ArgumentTypeError("bridge name must not be empty")
    if len(encoded) > MAX_BRIDGE_NAME_BYTES:
        raise argparse.ArgumentTypeError(
            f"bridge name must be at most {MAX_BRIDGE_NAME_BYTES} UTF-8 bytes"
        )
    if any(byte < 0x20 or byte == 0x7F for byte in encoded):
        raise argparse.ArgumentTypeError("bridge name must not contain control characters")
    return name


def serial_set_name_command(name: str) -> bytes:
    return f"INPUDECK SET-NAME {normalized_bridge_name(name)}\n".encode("utf-8")


def _serial_modules():
    try:
        import serial
        from serial.tools import list_ports
    except ImportError as error:
        raise InstallerError(
            "pyserial is required; install the flashing dependency with "
            f"'{sys.executable} -m pip install esptool'"
        ) from error
    return serial, list_ports


def available_ports() -> list:
    _, list_ports = _serial_modules()
    return list(list_ports.comports())


def candidate_port_names(preferred: str, ports: Iterable, ports_before_flash: set[str]) -> list[str]:
    ports = list(ports)
    names: list[str] = []

    def add(name: str) -> None:
        if name and name not in names:
            names.append(name)

    if any(port.device == preferred for port in ports):
        add(preferred)
    for port in ports:
        if port.device not in ports_before_flash and getattr(port, "vid", None) == ESPRESSIF_USB_VID:
            add(port.device)
    for port in ports:
        if port.device not in ports_before_flash:
            add(port.device)
    for port in ports:
        if getattr(port, "vid", None) == ESPRESSIF_USB_VID:
            add(port.device)
    return names


def auto_detect_port(ports: Iterable) -> str:
    ports = list(ports)
    espressif = [port.device for port in ports if getattr(port, "vid", None) == ESPRESSIF_USB_VID]
    if len(espressif) == 1:
        return espressif[0]
    if len(espressif) > 1:
        raise InstallerError(
            "multiple Espressif serial ports found; rerun with --port: " + ", ".join(espressif)
        )

    likely = [
        port.device
        for port in ports
        if port.device.startswith(("/dev/ttyACM", "/dev/ttyUSB", "/dev/cu.usb", "COM"))
    ]
    if len(likely) == 1:
        return likely[0]

    visible = ", ".join(port.device for port in ports) or "none"
    raise InstallerError(
        "could not choose one ESP32 serial port automatically. "
        f"Visible ports: {visible}. Rerun with --port PORT."
    )


def trusted_system_tool(name: str) -> str | None:
    for directory in ("/usr/bin", "/bin", "/usr/sbin", "/sbin"):
        candidate = Path(directory) / name
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


def trusted_linux_serial_device(port: str) -> str | None:
    try:
        device = Path(port).resolve(strict=True)
        mode = device.stat().st_mode
    except (OSError, RuntimeError):
        return None
    if device.parent != Path("/dev") or not device.name.startswith(("ttyACM", "ttyUSB")):
        return None
    return str(device) if stat.S_ISCHR(mode) else None


def ensure_serial_port_access(port: str, allow_sudo: bool) -> None:
    if os.access(port, os.R_OK | os.W_OK):
        return
    if not allow_sudo:
        raise InstallerError(
            f"permission denied for {port}. Rerun the one-command installer, or grant temporary access with "
            f"'sudo setfacl -m u:$USER:rw {port}'."
        )
    if not sys.platform.startswith("linux"):
        raise InstallerError(f"permission denied for {port}; grant the current user read/write access and retry")

    trusted_port = trusted_linux_serial_device(port)
    if not trusted_port:
        raise InstallerError(
            f"refusing to elevate access for unexpected device path {port}; use a /dev/ttyACM* or /dev/ttyUSB* character device"
        )

    sudo = trusted_system_tool("sudo")
    if not sudo:
        raise InstallerError(f"permission denied for {port}, and sudo is not installed")

    setfacl = trusted_system_tool("setfacl")
    if setfacl:
        command = [sudo, setfacl, "-m", f"u:{os.getuid()}:rw", trusted_port]
        action = "a temporary ACL"
    else:
        chown = trusted_system_tool("chown")
        if not chown:
            raise InstallerError(f"permission denied for {port}; neither setfacl nor chown is available")
        command = [sudo, chown, f"{os.getuid()}:{os.getgid()}", trusted_port]
        action = "temporary device ownership"

    print(f"Permission is required for {port}; requesting sudo only to grant {action}.", flush=True)
    subprocess.run(command, check=True)
    if not os.access(port, os.R_OK | os.W_OK):
        raise InstallerError(f"read/write access to {port} is still unavailable after sudo")


def esptool_command() -> list[str]:
    try:
        import esptool  # noqa: F401
    except ImportError:
        executable = shutil.which("esptool")
        if executable:
            return [executable]
        raise InstallerError(
            "esptool is required; install it with "
            f"'{sys.executable} -m pip install esptool'"
        )
    return [sys.executable, "-m", "esptool"]


def flash_firmware(port: str, firmware: Path) -> None:
    if not firmware.is_file():
        raise InstallerError(f"firmware image not found: {firmware}")
    command = esptool_command() + [
        "--chip",
        "esp32s3",
        "--port",
        port,
        "--before",
        "no-reset",
        "--after",
        "no-reset",
        "write-flash",
        "0x0",
        str(firmware),
    ]
    subprocess.run(command, check=True)


def _open_serial(port: str):
    serial, _ = _serial_modules()
    connection = serial.Serial()
    connection.port = port
    connection.baudrate = 115200
    connection.timeout = 0.25
    connection.write_timeout = 1
    connection.dtr = False
    connection.rts = False
    connection.open()
    return connection


def provision_bridge_name(
    preferred_port: str,
    name: str,
    ports_before_flash: set[str],
    timeout: float,
    allow_sudo: bool = False,
) -> str:
    command = serial_set_name_command(name)
    expected_ack = f"INPUDECK OK NAME {name}"
    deadline = time.monotonic() + timeout
    last_error: Exception | None = None

    while time.monotonic() < deadline:
        candidates = candidate_port_names(preferred_port, available_ports(), ports_before_flash)
        for port in candidates:
            try:
                ensure_serial_port_access(port, allow_sudo)
                with _open_serial(port) as connection:
                    connection.reset_input_buffer()
                    connection.write(b"INPUDECK GET-NAME\n")
                    connection.flush()
                    ready_deadline = min(deadline, time.monotonic() + 1.5)
                    sent_name = False
                    while time.monotonic() < ready_deadline:
                        line = connection.readline().decode("utf-8", errors="replace").strip()
                        if line.startswith("INPUDECK NAME ") or line.startswith("INPUDECK READY NAME "):
                            connection.write(command)
                            connection.flush()
                            sent_name = True
                            ready_deadline = min(deadline, time.monotonic() + 2)
                            continue
                        if line == expected_ack:
                            return port
                        if line.startswith("INPUDECK ERROR "):
                            raise InstallerError(line)
                    if sent_name:
                        last_error = InstallerError("the bridge restarted before acknowledging the saved name")
            except InstallerError:
                raise
            except OSError as error:
                last_error = error
            except Exception as error:
                # pyserial exposes platform-specific SerialException subclasses.
                last_error = error
        time.sleep(0.4)

    detail = f" Last error: {last_error}" if last_error else ""
    raise InstallerError(
        "could not reach the running InpuDeck firmware over USB Serial. "
        "Press RESET, confirm the new serial port, and retry with --skip-flash."
        + detail
    )


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        description="Flash an ESP32-S3 InpuDeck bridge and set its persistent BLE name."
    )
    result.add_argument(
        "--port",
        default="auto",
        help="ROM/USB serial port, for example /dev/ttyACM0 or COM5 (default: auto-detect)",
    )
    result.add_argument("--name", required=True, type=normalized_bridge_name, help="BLE name (1-28 UTF-8 bytes)")
    result.add_argument("--firmware", type=Path, help="complete merged InpuDeck firmware image")
    result.add_argument(
        "--skip-flash",
        action="store_true",
        help="only configure a bridge that is already running compatible firmware",
    )
    result.add_argument("--timeout", type=float, default=90, help="seconds to wait for firmware USB Serial")
    result.add_argument(
        "--grant-port-access",
        action="store_true",
        help="on Linux, request sudo only for temporary read/write access to the detected serial device",
    )
    return result


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    if args.timeout <= 0:
        raise InstallerError("--timeout must be greater than zero")
    if args.skip_flash and args.firmware:
        raise InstallerError("--firmware cannot be combined with --skip-flash")
    if not args.skip_flash and not args.firmware:
        raise InstallerError("--firmware is required unless --skip-flash is used")

    ports = available_ports()
    port = auto_detect_port(ports) if args.port == "auto" else args.port
    if args.port == "auto":
        print(f"Detected ESP32 serial port: {port}", flush=True)
    ports_before_flash = {candidate.device for candidate in ports}
    if not args.skip_flash:
        ensure_serial_port_access(port, args.grant_port_access)
        print(f"Flashing {args.firmware} on {port}…", flush=True)
        flash_firmware(port, args.firmware)
        print("Firmware written. Press the ESP32 RESET button once if the port does not reconnect.", flush=True)

    print(f"Provisioning BLE name {args.name!r}…", flush=True)
    configured_port = provision_bridge_name(
        port,
        args.name,
        ports_before_flash,
        args.timeout,
        allow_sudo=args.grant_port_access,
    )
    print(f"Done. The bridge saved {args.name!r} and restarted ({configured_port}).")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (InstallerError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)

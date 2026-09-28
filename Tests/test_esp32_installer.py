import argparse
import importlib.util
import types
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).parents[1] / "scripts" / "install-esp32.py"
BOOTSTRAP = SCRIPT.with_suffix(".sh")
SPEC = importlib.util.spec_from_file_location("install_esp32", SCRIPT)
installer = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(installer)


class BridgeNameTests(unittest.TestCase):
    def test_accepts_and_trims_human_readable_name(self):
        self.assertEqual(installer.normalized_bridge_name("  InpuDeck Office  "), "InpuDeck Office")

    def test_limit_is_utf8_bytes_not_characters(self):
        self.assertEqual(installer.normalized_bridge_name("Ї" * 14), "Ї" * 14)
        with self.assertRaises(argparse.ArgumentTypeError):
            installer.normalized_bridge_name("Ї" * 15)

    def test_rejects_empty_and_control_characters(self):
        for value in ("", "   ", "Desk\x00Bridge", "Desk\nBridge"):
            with self.subTest(value=value), self.assertRaises(argparse.ArgumentTypeError):
                installer.normalized_bridge_name(value)

    def test_serial_command_preserves_utf8_name(self):
        self.assertEqual(
            installer.serial_set_name_command("Міст"),
            "INPUDECK SET-NAME Міст\n".encode("utf-8"),
        )

    def test_installer_protocol_matches_firmware_contract(self):
        firmware = (SCRIPT.parents[1] / "inpudeck_bridge" / "inpudeck_bridge.ino").read_text()
        self.assertIn(
            f"kMaxBridgeNameBytes = {installer.MAX_BRIDGE_NAME_BYTES};",
            firmware,
        )
        self.assertIn('"INPUDECK GET-NAME"', firmware)
        self.assertIn('"INPUDECK SET-NAME "', firmware)
        self.assertIn('"INPUDECK OK NAME %s\\n"', firmware)


class PortSelectionTests(unittest.TestCase):
    @staticmethod
    def port(device, vid=None):
        return types.SimpleNamespace(device=device, vid=vid)

    def test_prefers_requested_port_when_it_is_present(self):
        ports = [self.port("/dev/ttyACM1", installer.ESPRESSIF_USB_VID), self.port("/dev/ttyACM0")]
        self.assertEqual(
            installer.candidate_port_names("/dev/ttyACM0", ports, set()),
            ["/dev/ttyACM0", "/dev/ttyACM1"],
        )

    def test_falls_back_to_new_espressif_port_after_reenumeration(self):
        ports = [self.port("/dev/ttyACM2", installer.ESPRESSIF_USB_VID), self.port("/dev/ttyUSB0")]
        self.assertEqual(
            installer.candidate_port_names("/dev/ttyACM0", ports, {"/dev/ttyUSB0"}),
            ["/dev/ttyACM2"],
        )

    def test_auto_detects_one_espressif_port(self):
        ports = [self.port("/dev/ttyS0"), self.port("/dev/ttyACM3", installer.ESPRESSIF_USB_VID)]
        self.assertEqual(installer.auto_detect_port(ports), "/dev/ttyACM3")

    def test_auto_detects_one_likely_usb_serial_port(self):
        self.assertEqual(installer.auto_detect_port([self.port("/dev/ttyACM0")]), "/dev/ttyACM0")

    def test_auto_detection_refuses_ambiguous_ports(self):
        ports = [
            self.port("/dev/ttyACM0", installer.ESPRESSIF_USB_VID),
            self.port("/dev/ttyACM1", installer.ESPRESSIF_USB_VID),
        ]
        with self.assertRaises(installer.InstallerError):
            installer.auto_detect_port(ports)


class PortPermissionTests(unittest.TestCase):
    @mock.patch.object(installer.os, "access", return_value=False)
    def test_refuses_to_elevate_without_explicit_flag(self, _access):
        with self.assertRaisesRegex(installer.InstallerError, "permission denied"):
            installer.ensure_serial_port_access("/dev/ttyACM0", allow_sudo=False)

    @mock.patch.object(installer.subprocess, "run")
    @mock.patch.object(installer, "trusted_system_tool", side_effect=lambda name: f"/usr/bin/{name}")
    @mock.patch.object(installer, "trusted_linux_serial_device", return_value="/dev/ttyACM0")
    @mock.patch.object(installer.os, "access", side_effect=[False, True])
    def test_grants_only_a_temporary_acl_when_allowed(self, _access, _device, _tool, run):
        installer.ensure_serial_port_access("/dev/ttyACM0", allow_sudo=True)
        run.assert_called_once_with(
            [
                "/usr/bin/sudo",
                "/usr/bin/setfacl",
                "-m",
                f"u:{installer.os.getuid()}:rw",
                "/dev/ttyACM0",
            ],
            check=True,
        )

    @mock.patch.object(installer, "trusted_linux_serial_device", return_value=None)
    @mock.patch.object(installer.os, "access", return_value=False)
    def test_refuses_to_elevate_an_unexpected_path(self, _access, _device):
        with self.assertRaisesRegex(installer.InstallerError, "refusing to elevate"):
            installer.ensure_serial_port_access("/tmp/not-a-device", allow_sudo=True)


class BootstrapContractTests(unittest.TestCase):
    def test_bootstrap_downloads_release_assets_and_uses_uv_script_metadata(self):
        bootstrap = BOOTSTRAP.read_text()
        for asset in (
            "InpuDeck-ESP32-S3-Zero.bin",
            "InpuDeck-ESP32-S3-Zero.bin.sha256",
            "install-esp32.py",
        ):
            self.assertIn(asset, bootstrap)
        self.assertIn("releases/latest/download", bootstrap)
        self.assertIn('run --no-project --script "$workdir/install-esp32.py"', bootstrap)
        self.assertIn("UV_UNMANAGED_INSTALL", bootstrap)
        self.assertIn("--grant-port-access", bootstrap)


if __name__ == "__main__":
    unittest.main()

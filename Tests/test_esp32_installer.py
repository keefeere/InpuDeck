import argparse
import importlib.util
import types
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "scripts" / "install-esp32.py"
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


if __name__ == "__main__":
    unittest.main()

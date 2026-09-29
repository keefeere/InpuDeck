"""The boot workaround must touch only explicitly configured InpuDeck peers."""

import importlib.util
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/inpudeck-le-address-resolution.py"
spec = importlib.util.spec_from_file_location("le_address_resolution", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class Result:
    def __init__(self, stdout="", returncode=0, stderr=""):
        self.stdout = stdout
        self.stderr = stderr
        self.returncode = returncode


class AddressResolutionTest(unittest.TestCase):
    def test_only_configured_bond_and_preserve_other_flags(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            controller = root / "44:F7:9F:AC:CD:9C"
            dual = controller / "10:A2:D3:01:47:A1"
            le_only = controller / "FA:38:A6:61:23:7F"
            unknown_type = controller / "10:A2:D3:01:47:A2"
            dual.mkdir(parents=True)
            le_only.mkdir(parents=True)
            unknown_type.mkdir(parents=True)
            common = "[IdentityResolvingKey]\nKey=x\n[LinkKey]\nKey=x\n[LongTermKey]\nKey=x\n"
            (dual / "info").write_text(
                "[General]\nAddressType=public\nSupportedTechnologies=BR/EDR;LE;\n" + common)
            (le_only / "info").write_text(
                "[General]\nAddressType=static\nSupportedTechnologies=LE;\n" + common)
            (unknown_type / "info").write_text(
                "[General]\nSupportedTechnologies=BR/EDR;LE;\n" + common)
            calls = []

            def fake_run(*args):
                calls.append(args)
                if args[-1] == "info" and args[:2] == ("btmgmt", "-i"):
                    return Result("addr 44:F7:9F:AC:CD:9C version 13")
                if "get-flags" in args:
                    return Result("Current Flags: 0x00000003")
                return Result()

            changed = module.apply("hci0", ["10:a2:d3:01:47:a1"], root, fake_run)
            sets = [call for call in calls if "set-flags" in call]
            self.assertEqual(sets, [("btmgmt", "-i", "hci0", "set-flags", "-t", "1",
                                     "-f", "7", "10:A2:D3:01:47:A1")])
            self.assertEqual(changed, 1)
            self.assertFalse(any("FA:38:A6:61:23:7F" in call for call in calls))

    def test_refuses_configured_peer_without_required_bond_material(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            peer = root / "44:F7:9F:AC:CD:9C" / "FA:38:A6:61:23:7F"
            peer.mkdir(parents=True)
            (peer / "info").write_text(
                "[General]\nAddressType=static\nSupportedTechnologies=LE;\n"
                "[IdentityResolvingKey]\nKey=x\n[LongTermKey]\nKey=x\n"
            )
            calls = []

            def fake_run(*args):
                calls.append(args)
                return Result("addr 44:F7:9F:AC:CD:9C version 13")

            with self.assertRaisesRegex(RuntimeError, "not a bonded dual-mode"):
                module.apply("hci0", ["FA:38:A6:61:23:7F"], root, fake_run)
            self.assertFalse(any("set-flags" in call for call in calls))

    def test_never_overwrites_flags_when_current_value_is_unknown(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            peer = root / "44:F7:9F:AC:CD:9C" / "10:A2:D3:01:47:A1"
            peer.mkdir(parents=True)
            (peer / "info").write_text(
                "[General]\nAddressType=public\nSupportedTechnologies=BR/EDR;LE;\n"
                "[IdentityResolvingKey]\nKey=x\n[LinkKey]\nKey=x\n[LongTermKey]\nKey=x\n"
            )
            calls = []

            def fake_run(*args):
                calls.append(args)
                if args[-1] == "info":
                    return Result("addr 44:F7:9F:AC:CD:9C version 13")
                return Result(returncode=1, stderr="not available")

            self.assertEqual(
                module.apply("hci0", ["10:A2:D3:01:47:A1"], root, fake_run),
                0,
            )
            self.assertFalse(any("set-flags" in call for call in calls))

    def test_device_file_is_strict_and_rejects_writable_or_symlinked_input(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            devices = root / "devices"
            devices.write_text("# InpuDeck iPhone\n10:a2:d3:01:47:a1\n\n")
            devices.chmod(0o644)
            self.assertEqual(module.devices_from_file(devices), ["10:A2:D3:01:47:A1"])

            devices.chmod(0o666)
            with self.assertRaisesRegex(ValueError, "group/world writable"):
                module.devices_from_file(devices)

            devices.chmod(0o644)
            link = root / "devices-link"
            link.symlink_to(devices)
            with self.assertRaisesRegex(ValueError, "symlinked"):
                module.devices_from_file(link)

    def test_invalid_or_empty_target_list_fails_closed(self):
        with self.assertRaisesRegex(ValueError, "invalid Bluetooth identity"):
            module.normalize_devices(["not-an-address"])
        with self.assertRaisesRegex(ValueError, "at least one"):
            module.normalize_devices([])


if __name__ == "__main__":
    unittest.main()

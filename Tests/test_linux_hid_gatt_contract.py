"""Check the HOGP ATT contract the Linux host needs from the phone's GATT table.

Parses the app source without compiling Swift: BlueZ 5.87+ attaches HID over GATT
only when each characteristic advertises the ATT operations its profile uses.
The Report Protocol Mode write is a Write Request, so the app must publish
`.write` there; CoreBluetooth rejects a Write Request before the app's
`didReceiveWrite` runs when only `.writeWithoutResponse` is advertised.
"""
import re
import unittest
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[1] / "InpuDeck/DirectHIDTransport.swift"
VALUE = r"(\[[^\]]*\]|\.read\w*|\.write\w*)"


def call_bodies(text):
    """Yield (uuid, argument text) for every characteristic(...) builder call."""
    for start in re.finditer(r'characteristic\(\s*"([0-9A-Fa-f]{4})"', text):
        depth, index = 1, text.index("(", start.start()) + 1
        while index < len(text) and depth:
            depth += {"(": 1, ")": -1}.get(text[index], 0)
            index += 1
        yield start.group(1), text[start.end():index - 1]


def gatt_table(text):
    """Map each characteristic UUID to the ATT operations it advertises."""
    table = {}
    for uuid, body in call_bodies(text):
        entry = table.setdefault(uuid, {"properties": set(), "permissions": set()})
        for key in ("properties", "permissions"):
            found = re.search(key + r":\s*" + VALUE, body, re.DOTALL)
            if found:
                entry[key] |= {item.strip().lstrip(".")
                               for item in found.group(1).strip("[]").split(",")
                               if item.strip()}
    return table


class HOGPContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.table = gatt_table(SOURCE.read_text())

    def assert_advertised(self, uuid, operations, name):
        entry = self.table.get(uuid, {})
        advertised = set(entry.get("properties", set())) | set(entry.get("permissions", set()))
        missing = {op.lstrip(".") for op in operations} - advertised
        self.assertFalse(
            missing,
            f"{name} ({uuid}) must advertise {sorted(operations)}; missing {sorted(missing)}",
        )

    def test_protocol_mode_supports_a_write_request(self):
        # BlueZ writes Report Protocol Mode with bt_gatt_client_write_value(),
        # which is an ATT Write Request needing a response.
        self.assert_advertised("2A4E", {".read", ".write", ".writeEncryptionRequired"},
                               "Report Protocol Mode")

    def test_report_and_boot_characteristics_notify_with_encryption(self):
        self.assert_advertised("2A4D", {".read", ".notifyEncryptionRequired"}, "Report Input")
        self.assert_advertised("2A22", {".read", ".notifyEncryptionRequired"}, "Boot Keyboard Input")
        self.assert_advertised("2A33", {".read", ".notifyEncryptionRequired"}, "Boot Mouse Input")

    def test_output_report_supports_writes(self):
        self.assert_advertised("2A4D", {".write", ".writeEncryptionRequired"}, "Report Output")

    def test_control_point_and_information_are_readable_as_hogp_expects(self):
        self.assert_advertised("2A4A", {".read"}, "HID Information")
        self.assert_advertised("2A4B", {".read", ".readEncryptionRequired"}, "Report Map")
        self.assert_advertised("2A4C", {".writeWithoutResponse", ".writeEncryptionRequired"},
                               "HID Control Point")

    def test_report_reference_descriptors_exist_for_reports(self):
        text = SOURCE.read_text()
        self.assertGreaterEqual(
            text.count('Self.uuid("2908")'),
            2,
            "Report Reference descriptors are required so BlueZ can classify reports",
        )


if __name__ == "__main__":
    unittest.main()

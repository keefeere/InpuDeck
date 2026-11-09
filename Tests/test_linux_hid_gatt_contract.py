"""Check the HOGP ATT contract the Linux host needs from the phone's GATT table.

Parses the app source without compiling Swift: BlueZ 5.87+ attaches HID over GATT
only when each characteristic advertises the ATT operations its profile uses.
The Report Protocol Mode write is a Write Request, so the app must publish
`.write` there; CoreBluetooth answers a Write Request in its ATT layer when only
`.writeWithoutResponse` is advertised, so the app's `didReceiveWrite` handler
never runs for that request. Report Reference descriptors are checked per report,
not by a source-wide count, because BlueZ classifies reports from them.
"""
import re
import unittest
from pathlib import Path

APP = Path(__file__).resolve().parents[1]
SOURCE = APP / "InpuDeck/DirectHIDTransport.swift"
REPORTS = APP / "Shared/HIDReports.swift"
VALUE = r"(\[[^\]]*\]|\.read\w*|\.write\w*)"
REPORT_KINDS = {"keyboard": "1", "mouse": "2", "consumer": "3", "systemMicrophoneMute": "4"}


def call_bodies(text):
    """Yield (uuid, argument text) for every characteristic(...) builder call."""
    for start in re.finditer(r'characteristic\(\s*"([0-9A-Fa-f]{4})"', text):
        depth, index = 1, text.index("(", start.start()) + 1
        while index < len(text) and depth:
            depth += {"(": 1, ")": -1}.get(text[index], 0)
            index += 1
        yield start.group(1), text[start.end():index - 1]


def gatt_table(text):
    """Union of ATT operations advertised per characteristic UUID."""
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


def published_labels(text):
    """Return the characteristic expressions published in the HOGP 1812 service."""
    block = re.search(r"hid\.characteristics\s*=\s*\[(.*?)\]\s*\n\s*serviceQueue", text, re.DOTALL)
    assert block, "the HOGP 1812 publication list is missing"
    entries, current, depth = [], "", 0
    for char in block.group(1):
        depth += {"(": 1, "[": 1}.get(char, 0)
        depth -= {")": -1, "]": -1}.get(char, 0)
        depth = max(depth, 0)
        if char == "," and depth == 0:
            entries.append(current.strip())
            current = ""
        else:
            current += char
    entries.append(current.strip())
    return [entry for entry in entries if entry]


class HOGPContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = SOURCE.read_text()
        cls.table = gatt_table(cls.text)
        cls.published = "\n".join(published_labels(cls.text))

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

    def test_input_report_builder_is_published_and_self_contained(self):
        helper = re.search(r"private func report\(_ kind: HIDReportKind.*?\n    \}\n",
                           self.text, re.DOTALL)
        self.assertTrue(helper, "the input report builder is missing")
        body = helper.group(0)
        for needed in ('characteristic("2A4D"', ".read", ".notifyEncryptionRequired",
                       'permissions: .readEncryptionRequired', 'Self.uuid("2908")',
                       "Data([kind.rawValue, 1])"):
            self.assertIn(needed, body, f"input report builder must declare {needed}")
        for kind in ("keyboard", "mouse", "consumer"):
            self.assertIn(f"report(.{kind}, channel:",
                          "\n".join(published_labels(self.text)),
                          f"report kind {kind} is not published")

    def test_output_reports_are_published_with_write_and_output_reference(self):
        for name in ("output", "microphoneMuteOutput"):
            definition = re.search(rf"let {name} = characteristic\((.*?)\)\n", self.text, re.DOTALL)
            self.assertTrue(definition, f"{name} definition is missing")
            self.assertIn(".write", definition.group(1), f"{name} needs a write operation")
            self.assertIn(name, self.published, f"{name} is not published")
            descriptor = re.search(rf"{name}\.descriptors\s*=\s*\[(.*?)\]\n", self.text, re.DOTALL)
            self.assertTrue(descriptor, f"{name} needs a Report Reference descriptor")
            self.assertIn('Self.uuid("2908")', descriptor.group(1), f"{name} descriptor UUID")
            self.search_output_type(descriptor.group(1), name)

    def search_output_type(self, descriptor, name):
        # Report Reference is [Report ID, Report Type]; Output reports use type 2.
        self.assertIn(", 2]", descriptor, f"{name} must be Report Type Output (2)")

    def test_control_point_and_information_are_readable_as_hogp_expects(self):
        self.assert_advertised("2A4A", {".read"}, "HID Information")
        self.assert_advertised("2A4B", {".read", ".readEncryptionRequired"}, "Report Map")
        self.assert_advertised("2A4C", {".writeWithoutResponse", ".writeEncryptionRequired"},
                               "HID Control Point")

    def test_boot_and_led_characteristics_are_published(self):
        for label in ('"2A22"', '"2A33"', '"2A32"', ".bootKeyboard", ".bootMouse"):
            self.assertIn(label, self.published, f"{label} must stay published for Boot protocol hosts")

    def test_report_kinds_match_the_report_map(self):
        kinds = re.search(r"enum HIDReportKind: UInt8 \{(.*?)\n\}",
                          REPORTS.read_text(), re.DOTALL).group(1)
        found = dict(re.findall(r"case (\w+) = (\d+)", kinds))
        self.assertEqual({kind: value for kind, value in found.items() if kind in REPORT_KINDS},
                         REPORT_KINDS,
                         "Report Reference ids must match HIDReportKind")


if __name__ == "__main__":
    unittest.main()

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

    def test_secure_provisioning_command_preserves_utf8_name(self):
        self.assertEqual(
            installer.serial_provision_command("Телевізор", 483921),
            "INPUDECK PROVISION 483921 Телевізор\n".encode("utf-8"),
        )

    def test_installer_protocol_matches_firmware_contract(self):
        firmware = (SCRIPT.parents[1] / "inpudeck_bridge" / "inpudeck_bridge.ino").read_text()
        self.assertIn(
            f"kMaxBridgeNameBytes = {installer.MAX_BRIDGE_NAME_BYTES};",
            firmware,
        )
        self.assertIn('"INPUDECK GET-NAME"', firmware)
        self.assertIn('"INPUDECK GET-INFO"', firmware)
        self.assertIn('"INPUDECK SET-NAME "', firmware)
        self.assertIn('"INPUDECK PROVISION "', firmware)
        self.assertIn('"INPUDECK OK NAME %s\\n"', firmware)

    def test_firmware_requires_authenticated_bonded_writes(self):
        firmware = (SCRIPT.parents[1] / "inpudeck_bridge" / "inpudeck_bridge.ino").read_text()
        for contract in (
            "NIMBLE_PROPERTY::WRITE_ENC",
            "NIMBLE_PROPERTY::WRITE_AUTHEN",
            "NIMBLE_PROPERTY::READ_ENC",
            "NIMBLE_PROPERTY::READ_AUTHEN",
            "NimBLEDevice::setSecurityAuth(true, true, true)",
            "connInfo.isBonded()",
            "connInfo.isEncrypted()",
            "connInfo.isAuthenticated()",
            "connInfo.getSecKeySize() >= 16",
            "NimBLEDevice::deleteAllBonds()",
            "Rejected unknown BLE peer while the pairing window is closed.",
            "gHiddenPasskey = generatePasskey()",
            '"INPUDECK ERROR physical provisioning window is closed"',
        ):
            with self.subTest(contract=contract):
                self.assertIn(contract, firmware)

    def test_secure_provisioning_rotates_a_persisted_random_static_identity(self):
        firmware = (SCRIPT.parents[1] / "inpudeck_bridge" / "inpudeck_bridge.ino").read_text()
        for contract in (
            'kBleIdentityKey = "ble_identity"',
            "esp_fill_random(identity, kBleIdentityBytes)",
            "identity[5] = (identity[5] & 0x3F) | 0xC0",
            "preferences.putBytes(",
            "NimBLEDevice::setOwnAddr(gBleIdentity)",
            "NimBLEDevice::setOwnAddrType(BLE_OWN_ADDR_RANDOM)",
            '"INPUDECK INFO SECURITY 1 IDENTITY 1 NAME %s\\n"',
        ):
            with self.subTest(contract=contract):
                self.assertIn(contract, firmware)

    def test_ios_rejects_legacy_bridge_before_enabling_input(self):
        app = (SCRIPT.parents[1] / "InpuDeck" / "BLEKeyboardBridge.swift").read_text()
        self.assertIn("securityCharUUID", app)
        self.assertIn("requiredSecurityCapability", app)
        self.assertIn("peripheral.readValue(for: securityCharacteristic)", app)
        self.assertIn("didUpdateValueFor characteristic", app)
        self.assertIn("guard isReady, let peripheral, let writeChar", app)
        self.assertIn('localized("Незахищена прошивка ESP — онови її")', app)
        self.assertIn("firmwareSecurityIssue = .unsafeLegacy", app)
        self.assertIn("firmwareSecurityIssue = .unknownCapability", app)

    def test_firmware_exposes_authenticated_authoritative_name(self):
        firmware = (SCRIPT.parents[1] / "inpudeck_bridge" / "inpudeck_bridge.ino").read_text()
        app = (SCRIPT.parents[1] / "InpuDeck" / "BLEKeyboardBridge.swift").read_text()
        self.assertIn("kNameCharUUID", firmware)
        self.assertIn("pNameChar->setValue", firmware)
        self.assertIn("NIMBLE_PROPERTY::READ_ENC", firmware)
        self.assertIn("NIMBLE_PROPERTY::READ_AUTHEN", firmware)
        self.assertIn("nameCharUUID", app)
        self.assertIn("ESPBridgeNamePayload.decode", app)

    def test_waveshare_status_led_covers_each_connection_path(self):
        firmware = (SCRIPT.parents[1] / "inpudeck_bridge" / "inpudeck_bridge.ino").read_text()
        for contract in (
            "BridgeLedState::ready",
            "BridgeLedState::usbOnly",
            "BridgeLedState::bleOnly",
            "BridgeLedState::powerOnly",
            "BridgeLedState::pairing",
            "BridgeLedState::usbError",
            "writeStatusLed(0, 8, 14)",
            "const uint32_t phase = now % 1600",
            "phase * 18 / 500",
            "rgbLedWriteOrdered(",
            "LED_COLOR_ORDER_GRB",
            "static_cast<bool>(USB)",
        ):
            with self.subTest(contract=contract):
                self.assertIn(contract, firmware)

        loop = firmware.split("void loop()", 1)[1]
        self.assertLess(
            loop.index("synchronizeUsbMountState();"),
            loop.index("updateStatusLed(now);"),
        )

    def test_release_builds_enable_tinyusb_cdc_for_post_flash_provisioning(self):
        repository = SCRIPT.parents[1]
        for relative_path in (
            ".github/workflows/build-ios-ipa.yml",
            ".github/workflows/build-esp32-firmware.yml",
        ):
            with self.subTest(workflow=relative_path):
                workflow = (repository / relative_path).read_text()
                self.assertIn("USBMode=default,CDCOnBoot=default", workflow)
                self.assertNotIn("USBMode=default,CDCOnBoot=cdc", workflow)


class PortSelectionTests(unittest.TestCase):
    @staticmethod
    def port(device, vid=None, **details):
        return types.SimpleNamespace(device=device, vid=vid, **details)

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

    def test_waits_for_preferred_port_instead_of_probing_an_existing_espressif_device(self):
        ports = [self.port("/dev/ttyACM1", installer.ESPRESSIF_USB_VID)]
        self.assertEqual(
            installer.candidate_port_names(
                "/dev/ttyACM0",
                ports,
                {"/dev/ttyACM0", "/dev/ttyACM1"},
                include_existing_fallback=False,
            ),
            [],
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
            installer.auto_detect_port(
                ports,
                now=1000,
                stat_port=lambda _device: types.SimpleNamespace(st_ctime=100),
            )

    def test_auto_detection_prefers_the_recently_reconnected_espressif_port(self):
        ports = [
            self.port("/dev/ttyACM0", installer.ESPRESSIF_USB_VID),
            self.port("/dev/ttyACM1", installer.ESPRESSIF_USB_VID),
        ]
        changed_at = {"/dev/ttyACM0": 995, "/dev/ttyACM1": 100}

        self.assertEqual(
            installer.auto_detect_port(
                ports,
                now=1000,
                stat_port=lambda device: types.SimpleNamespace(st_ctime=changed_at[device]),
            ),
            "/dev/ttyACM0",
        )

    def test_auto_detection_does_not_guess_when_ports_reconnected_together(self):
        ports = [
            self.port("/dev/ttyACM0", installer.ESPRESSIF_USB_VID),
            self.port("/dev/ttyACM1", installer.ESPRESSIF_USB_VID),
        ]
        changed_at = {"/dev/ttyACM0": 995.0, "/dev/ttyACM1": 994.5}

        with self.assertRaises(installer.InstallerError):
            installer.auto_detect_port(
                ports,
                now=1000,
                stat_port=lambda device: types.SimpleNamespace(st_ctime=changed_at[device]),
            )

    def test_interactive_fallback_shows_usb_details_and_selects_without_rerun(self):
        ports = [
            self.port(
                "/dev/ttyACM0",
                installer.ESPRESSIF_USB_VID,
                product="USB JTAG/serial debug unit",
                serial_number="AABBCC",
                location="1-2.3",
            ),
            self.port("/dev/ttyACM1", installer.ESPRESSIF_USB_VID, product="Hub controller"),
        ]
        terminal = mock.Mock()
        terminal.readline.return_value = "2\n"

        selected = installer.auto_detect_port(
            ports,
            interactive=True,
            terminal=terminal,
            now=1000,
            stat_port=lambda _device: types.SimpleNamespace(st_ctime=100),
        )

        self.assertEqual(selected, "/dev/ttyACM1")
        output = "".join(call.args[0] for call in terminal.write.call_args_list)
        self.assertIn("USB JTAG/serial debug unit", output)
        self.assertIn("AABBCC", output)
        self.assertIn("1-2.3", output)
        self.assertIn("Hub controller", output)

    @mock.patch.object(installer.time, "sleep")
    @mock.patch.object(installer, "available_ports")
    def test_initial_detection_retries_a_transient_pyserial_scan_failure(self, available_ports, _sleep):
        port = self.port("/dev/ttyACM0", installer.ESPRESSIF_USB_VID)
        available_ports.side_effect = [TypeError("idVendor disappeared"), [port]]

        self.assertEqual(installer.wait_for_available_ports(1), [port])
        self.assertEqual(available_ports.call_count, 2)


class PasskeyTests(unittest.TestCase):
    def test_accepts_exactly_six_nonzero_leading_ascii_digits(self):
        self.assertEqual(installer.normalized_passkey("100000"), 100000)
        self.assertEqual(installer.normalized_passkey("999999"), 999999)

    def test_rejects_short_zero_leading_and_non_ascii_passkeys(self):
        for value in ("99999", "000001", "12345a", "１２３４５６"):
            with self.subTest(value=value), self.assertRaises(argparse.ArgumentTypeError):
                installer.normalized_passkey(value)

    @mock.patch.object(installer.secrets, "randbelow", return_value=383921)
    def test_generated_passkey_uses_cryptographic_rng(self, randbelow):
        self.assertEqual(installer.generate_passkey(), 483921)
        randbelow.assert_called_once_with(900000)


class PortPermissionTests(unittest.TestCase):
    @mock.patch.object(installer.os, "access", return_value=False)
    def test_refuses_to_elevate_without_explicit_flag(self, _access):
        with self.assertRaisesRegex(installer.InstallerError, "permission denied"):
            installer.ensure_serial_port_access("/dev/ttyACM0", allow_sudo=False)

    @mock.patch.object(installer.subprocess, "run")
    @mock.patch.object(installer, "trusted_system_tool", side_effect=lambda name: f"/usr/bin/{name}")
    @mock.patch.object(installer, "trusted_linux_serial_device", return_value="/dev/ttyACM0")
    @mock.patch.object(installer.Path, "exists", return_value=True)
    @mock.patch.object(installer.os, "access", side_effect=[False, True])
    def test_grants_only_a_temporary_acl_when_allowed(self, _access, _exists, _device, _tool, run):
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

    @mock.patch.object(installer.Path, "exists", return_value=False)
    @mock.patch.object(installer.os, "access", return_value=False)
    def test_treats_a_missing_expected_device_as_transient(self, _access, _exists):
        with self.assertRaisesRegex(installer.SerialPortUnavailableError, "reconnecting"):
            installer.ensure_serial_port_access("/dev/ttyACM0", allow_sudo=True)

    @mock.patch.object(installer.time, "sleep")
    @mock.patch.object(installer, "available_ports")
    @mock.patch.object(installer, "ensure_serial_port_access")
    @mock.patch.object(installer, "_open_serial")
    def test_provisioning_retries_when_the_detected_port_disappears(
        self, open_serial, ensure_access, available_ports, _sleep
    ):
        port = types.SimpleNamespace(device="/dev/ttyACM0", vid=installer.ESPRESSIF_USB_VID)
        available_ports.return_value = [port]
        ensure_access.side_effect = [installer.SerialPortUnavailableError("reconnecting"), None]
        connection = mock.MagicMock()
        connection.readline.side_effect = [
            b"INPUDECK INFO SECURITY 1 IDENTITY 1 NAME InpuDeck Bridge\n",
            "INPUDECK OK PROVISION Телевізор\n".encode(),
        ]
        connection.__enter__.return_value = connection
        open_serial.return_value = connection

        configured_port = installer.provision_bridge(
            "/dev/ttyACM0",
            "Телевізор",
            {"/dev/ttyACM0"},
            timeout=1,
            allow_sudo=True,
            passkey=483921,
        )

        self.assertEqual(configured_port, "/dev/ttyACM0")
        self.assertEqual(ensure_access.call_count, 2)

    @mock.patch.object(installer.time, "sleep")
    @mock.patch.object(installer, "available_ports")
    @mock.patch.object(installer, "ensure_serial_port_access")
    @mock.patch.object(installer, "_open_serial")
    def test_provisioning_does_not_touch_an_existing_decoy_while_preferred_port_reconnects(
        self, open_serial, ensure_access, available_ports, _sleep
    ):
        decoy = types.SimpleNamespace(device="/dev/ttyACM1", vid=installer.ESPRESSIF_USB_VID)
        target = types.SimpleNamespace(device="/dev/ttyACM0", vid=installer.ESPRESSIF_USB_VID)
        available_ports.side_effect = [[decoy], [decoy, target]]
        connection = mock.MagicMock()
        connection.readline.side_effect = [
            b"INPUDECK INFO SECURITY 1 IDENTITY 1 NAME InpuDeck Bridge\n",
            b"INPUDECK OK PROVISION Television\n",
        ]
        connection.__enter__.return_value = connection
        open_serial.return_value = connection

        configured_port = installer.provision_bridge(
            "/dev/ttyACM0",
            "Television",
            {"/dev/ttyACM0", "/dev/ttyACM1"},
            timeout=1,
            allow_sudo=True,
            passkey=483921,
        )

        self.assertEqual(configured_port, "/dev/ttyACM0")
        ensure_access.assert_called_once_with("/dev/ttyACM0", True)
        open_serial.assert_called_once_with("/dev/ttyACM0")

    @mock.patch.object(installer.time, "sleep")
    @mock.patch.object(installer, "available_ports")
    @mock.patch.object(installer, "ensure_serial_port_access")
    @mock.patch.object(installer, "_open_serial")
    def test_passkey_rotation_requires_identity_capable_firmware(
        self, open_serial, _ensure_access, available_ports, _sleep
    ):
        port = types.SimpleNamespace(device="/dev/ttyACM0", vid=installer.ESPRESSIF_USB_VID)
        available_ports.return_value = [port]
        connection = mock.MagicMock()
        connection.readline.side_effect = [
            b"INPUDECK INFO SECURITY 1 NAME InpuDeck Bridge\n",
        ]
        connection.__enter__.return_value = connection
        open_serial.return_value = connection

        with self.assertRaisesRegex(installer.InstallerError, "cannot rotate its BLE identity"):
            installer.provision_bridge(
                "/dev/ttyACM0",
                "Television",
                {"/dev/ttyACM0"},
                timeout=1,
                allow_sudo=True,
                passkey=483921,
            )

        connection.write.assert_any_call(b"INPUDECK GET-INFO\n")
        self.assertNotIn(
            installer.serial_provision_command("Television", 483921),
            [call.args[0] for call in connection.write.call_args_list],
        )

    @mock.patch.object(installer.time, "sleep")
    @mock.patch.object(installer, "available_ports")
    @mock.patch.object(installer, "ensure_serial_port_access")
    @mock.patch.object(installer, "_open_serial")
    def test_provisioning_retries_a_transient_pyserial_scan_failure(
        self, open_serial, _ensure_access, available_ports, _sleep
    ):
        port = types.SimpleNamespace(device="/dev/ttyACM0", vid=installer.ESPRESSIF_USB_VID)
        available_ports.side_effect = [TypeError("idVendor disappeared"), [port]]
        connection = mock.MagicMock()
        connection.readline.side_effect = [
            b"INPUDECK INFO SECURITY 1 NAME InpuDeck Bridge\n",
            b"INPUDECK OK NAME Television\n",
        ]
        connection.__enter__.return_value = connection
        open_serial.return_value = connection

        configured_port = installer.provision_bridge(
            "/dev/ttyACM0",
            "Television",
            {"/dev/ttyACM0"},
            timeout=1,
            allow_sudo=True,
        )

        self.assertEqual(configured_port, "/dev/ttyACM0")
        self.assertEqual(available_ports.call_count, 2)

    @mock.patch.object(installer.time, "sleep")
    @mock.patch.object(installer, "available_ports")
    @mock.patch.object(installer, "ensure_serial_port_access")
    @mock.patch.object(installer, "_open_serial")
    def test_skip_flash_rejects_unsafe_legacy_firmware(
        self, open_serial, _ensure_access, available_ports, _sleep
    ):
        port = types.SimpleNamespace(device="/dev/ttyACM0", vid=installer.ESPRESSIF_USB_VID)
        available_ports.return_value = [port]
        connection = mock.MagicMock()
        connection.readline.side_effect = [b"INPUDECK NAME InpuDeck Bridge\n", b""]
        connection.__enter__.return_value = connection
        open_serial.return_value = connection

        with self.assertRaisesRegex(installer.InstallerError, "unsafe legacy firmware"):
            installer.provision_bridge(
                "/dev/ttyACM0",
                "Television",
                {"/dev/ttyACM0"},
                timeout=0.01,
                allow_sudo=True,
            )


class SerialConnectionTests(unittest.TestCase):
    @mock.patch.object(installer.time, "sleep")
    @mock.patch.object(installer, "_serial_modules")
    def test_open_asserts_cdc_control_lines_before_provisioning(self, serial_modules, sleep):
        serial = mock.MagicMock()
        connection = mock.MagicMock()
        serial.Serial.return_value = connection
        serial_modules.return_value = (serial, mock.MagicMock())

        self.assertIs(installer._open_serial("/dev/ttyACM0"), connection)

        self.assertEqual(connection.port, "/dev/ttyACM0")
        self.assertEqual(connection.baudrate, 115200)
        self.assertIs(connection.dtr, True)
        self.assertIs(connection.rts, True)
        connection.open.assert_called_once_with()
        sleep.assert_called_once_with(0.15)


class BootstrapContractTests(unittest.TestCase):
    def test_bootstrap_downloads_release_assets_and_uses_uv_script_metadata(self):
        bootstrap = BOOTSTRAP.read_text()
        for asset in (
            "InpuDeck-ESP32-S3-Zero.bin",
            "InpuDeck-ESP32-S3-Zero.bin.sha256",
            "InpuDeck-ESP32-S3-Zero.bin.sigstore.json",
            "install-esp32.py",
            "install-esp32.py.sigstore.json",
        ):
            self.assertIn(asset, bootstrap)
        self.assertIn('"https://github.com/${repository}/releases/latest"', bootstrap)
        self.assertIn('release_tag="${latest_url##*/}"', bootstrap)
        self.assertIn('run --no-project --script "$workdir/install-esp32.py"', bootstrap)
        self.assertIn("UV_UNMANAGED_INSTALL", bootstrap)
        self.assertIn("uv_installer_sha256=", bootstrap)
        self.assertIn("--grant-port-access", bootstrap)
        self.assertIn("--wait-for-reset", bootstrap)
        self.assertIn("--skip-flash", bootstrap)
        self.assertIn("--rotate-passkey", bootstrap)
        self.assertIn("--passkey", bootstrap)

    def test_bootstrap_verifies_provenance_before_executing_downloaded_installer(self):
        bootstrap = BOOTSTRAP.read_text()
        self.assertIn('sigstore_version="4.1.0"', bootstrap)
        self.assertIn("sigstore verify identity", bootstrap)
        self.assertIn("--cert-identity", bootstrap)
        self.assertIn("--cert-oidc-issuer", bootstrap)
        verification = bootstrap.index(
            'verify_provenance \\\n  "$workdir/install-esp32.py"'
        )
        execution = bootstrap.index(
            'run --no-project --script "$workdir/install-esp32.py" --help'
        )
        self.assertLess(verification, execution)

    def test_release_workflow_attests_every_executable_esp_asset(self):
        workflow = (SCRIPT.parents[1] / ".github/workflows/build-ios-ipa.yml").read_text()
        self.assertIn("attestations: write", workflow)
        self.assertIn("id-token: write", workflow)
        self.assertEqual(
            workflow.count(
                "uses: actions/attest@1e69f48acb82d1966a394da916b4c1698aa569d6"
            ),
            3,
        )
        for asset in (
            "InpuDeck-ESP32-S3-Zero.bin.sigstore.json",
            "install-esp32.py.sigstore.json",
            "install-esp32.sh.sigstore.json",
        ):
            with self.subTest(asset=asset):
                self.assertIn(asset, workflow)

    def test_bootstrap_warns_that_full_provisioning_replaces_the_ios_bond(self):
        bootstrap = BOOTSTRAP.read_text()
        self.assertIn("IMPORTANT FOR A PREVIOUSLY PAIRED BOARD", bootstrap)
        self.assertIn("iPhone Settings > Bluetooth", bootstrap)
        self.assertIn("BLE passkey and identity", bootstrap)
        self.assertIn("Every mutation requires the physical BOOT", bootstrap)

    def test_bootstrap_user_interface_is_english(self):
        bootstrap = BOOTSTRAP.read_text()
        self.assertNotRegex(bootstrap, r"[А-Яа-яІіЇїЄєҐґ]")


if __name__ == "__main__":
    unittest.main()

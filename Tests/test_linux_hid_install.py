"""Run the installer against an isolated prefix, with systemctl calls recorded."""
import os
import signal
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/inpudeck-hid.sh"
LINUX_INSTALLER = Path(__file__).resolve().parents[1] / "scripts/install-linux.sh"


@unittest.skipIf(os.geteuid() == 0, "user installer intentionally refuses root")
class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.prefix = self.root / "prefix with spaces"
        self.config = self.root / "config"
        self.log = self.root / "systemctl.log"
        mockbin = self.root / "bin"
        mockbin.mkdir()
        mock = mockbin / "systemctl"
        mock.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$ESP_TEST_SYSTEMCTL_LOG"\n')
        mock.chmod(0o755)
        self.env = dict(os.environ, XDG_CONFIG_HOME=str(self.config),
                        ESP_TEST_SYSTEMCTL_LOG=str(self.log),
                        PATH=str(mockbin) + os.pathsep + os.environ["PATH"])

    def run_helper(self, *args, script=SCRIPT, ok=True):
        result = subprocess.run(["bash", str(script), "--prefix", str(self.prefix), *args],
                                env=self.env, text=True, capture_output=True)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def test_repeated_install_and_self_update_do_not_change_host_settings(self):
        self.run_helper("--install")
        files = sorted(path for path in self.prefix.rglob("*") if path.is_file())
        self.assertEqual(len(files), 3)
        times = {path: path.stat().st_mtime_ns for path in files}
        self.run_helper("--install")
        installed = self.prefix / "libexec/inpudeck/inpudeck-hid.sh"
        self.run_helper("--install", script=installed)
        self.assertEqual(times, {path: path.stat().st_mtime_ns for path in files})
        self.assertFalse(self.config.exists())
        self.assertFalse(self.log.exists(), "on-demand install must not call systemctl")
        launcher = self.prefix / "bin/inpudeck-hid"
        result = subprocess.run([str(launcher), "--help"], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_launcher_remembers_prefix_for_uninstall(self):
        self.run_helper("--install")
        launcher = self.prefix / "bin/inpudeck-hid"
        result = subprocess.run([str(launcher), "--uninstall"], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(path.is_file() for path in self.prefix.rglob("*")))
        self.run_helper("--uninstall")
        self.assertFalse(self.log.exists())

    def test_unrelated_launcher_is_preserved(self):
        launcher = self.prefix / "bin/inpudeck-hid"
        launcher.parent.mkdir(parents=True)
        launcher.write_text("personal command\n")
        self.run_helper("--install", ok=False)
        self.run_helper("--uninstall", ok=False)
        self.assertEqual(launcher.read_text(), "personal command\n")

    def test_unrelated_service_is_preserved(self):
        unit = self.config / "systemd/user/inpudeck-hid.service"
        unit.parent.mkdir(parents=True)
        unit.write_text("# personal service\n")
        self.run_helper("--uninstall-service", ok=False)
        self.assertEqual(unit.read_text(), "# personal service\n")
        self.assertFalse(self.log.exists())

    def test_install_removes_owned_esp_remote_install(self):
        launcher = self.prefix / "bin/esp-remote-hid"
        installed = self.prefix / "libexec/esp-remote-control/linux-hid-connect.sh"
        backend = self.prefix / "libexec/esp-remote-control/linux-bluez-le.py"
        unit = self.config / "systemd/user/esp-remote-hid.service"
        for path in (launcher, installed, backend, unit):
            path.parent.mkdir(parents=True, exist_ok=True)
        launcher.write_text("#!/bin/sh\n# Managed by ESP Remote\n")
        installed.write_text("legacy\n")
        backend.write_text("legacy\n")
        unit.write_text("# Managed by ESP Remote\n[Service]\n")

        self.run_helper("--install")

        self.assertFalse(launcher.exists())
        self.assertFalse(unit.exists())
        self.assertFalse(installed.exists())
        self.assertTrue((self.prefix / "bin/inpudeck-hid").exists())
        self.assertIn("disable --now esp-remote-hid.service", self.log.read_text())

    def test_install_refuses_unowned_esp_remote_launcher(self):
        launcher = self.prefix / "bin/esp-remote-hid"
        launcher.parent.mkdir(parents=True)
        launcher.write_text("personal command\n")
        self.run_helper("--install", ok=False)
        self.assertEqual(launcher.read_text(), "personal command\n")

    def stub_paired_phone_without_cached_hid(self):
        self.env['ESP_TEST_LE_READY'] = str(self.root / 'le-ready')
        mock = self.root / 'bin/python3'
        mock.write_text('''#!/bin/sh
if [ "$1" = "-c" ]; then exit 0; fi
case "$4" in
  adapter-info) printf 'Controller 44:F7:9F:AC:CD:9C\\n  Powered: yes\\n' ;;
  info) printf 'Device 10:A2:D3:01:47:A1\\n  Name: iPhone\\n  Paired: yes\\n  LEConnected: no\\n  BREDRConnected: no\\n  ServicesResolved: no\\n' ;;
  check) printf 'LE-only API available\\n' ;;
  hid-ready) test -e "$ESP_TEST_LE_READY" ;;
  discover) printf 'Refreshed LE HID discovery\\n' ;;
  connect) touch "$ESP_TEST_LE_READY" ;;
  *) exit 2 ;;
esac
''')
        mock.chmod(0o755)

    def stub_one_command_installer_host(self):
        self.stub_paired_phone_without_cached_hid()
        mockbin = self.root / 'bin'
        for command, content in {
            'bluetoothctl': '#!/bin/sh\nprintf "Device 10:A2:D3:01:47:A1 iPhone\\n"\n',
            'btmgmt': '#!/bin/sh\nexit 0\n',
            'sudo': '''#!/bin/sh
printf '%s\n' "$*" >> "$ESP_TEST_SUDO_LOG"
case "$1" in
  -v) exit 0 ;;
  test)
    shift
    if [ "$1" = "!" ] && [ "$2" = "-L" ]; then exit 0; fi
    if [ "$1" = "-e" ]; then exit 1; fi
    exit 0
    ;;
  install|systemctl|python3) exit 0 ;;
  cat) exit 1 ;;
esac
exit 2
''',
        }.items():
            path = mockbin / command
            path.write_text(content)
            path.chmod(0o755)
        self.env.update(
            HOME=str(self.root / 'home'),
            ESP_TEST_SUDO_LOG=str(self.root / 'sudo.log'),
        )

    def test_one_command_installer_configures_scoped_service_without_audio_changes(self):
        self.stub_one_command_installer_host()
        result = subprocess.run(
            ['bash', str(LINUX_INSTALLER), '--device', '10:a2:d3:01:47:a1', '--yes'],
            env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('Done. Linux Direct Bluetooth HID is installed', result.stdout)
        sudo_calls = (self.root / 'sudo.log').read_text()
        self.assertIn('inpudeck-le-setup.py enable', sudo_calls)
        self.assertIn('/etc/inpudeck/address-resolution-devices', sudo_calls)
        self.assertIn('/usr/local/libexec/inpudeck-le-address-resolution.py', sudo_calls)
        unit = self.config / 'systemd/user/inpudeck-hid.service'
        self.assertIn('--device 10:A2:D3:01:47:A1 --watch', unit.read_text())
        self.assertNotIn('audio', sudo_calls.lower())

        repeated = subprocess.run(
            ['bash', str(LINUX_INSTALLER), '--device', '10:A2:D3:01:47:A1', '--yes'],
            env=self.env, text=True, capture_output=True)
        self.assertEqual(repeated.returncode, 0, repeated.stdout + repeated.stderr)

    def test_explicit_status_reports_missing_hid_without_connecting(self):
        self.stub_paired_phone_without_cached_hid()
        result = self.run_helper('--device', '10:A2:D3:01:47:A1', '--status')
        self.assertIn('HID=not-ready', result.stdout)
        self.assertFalse((self.root / 'le-ready').exists())

    def test_resolve_device_prints_paired_address_without_connecting(self):
        self.stub_paired_phone_without_cached_hid()
        result = self.run_helper(
            '--device', '10:a2:d3:01:47:a1', '--resolve-device')
        self.assertEqual(result.stdout, '10:A2:D3:01:47:A1\n')
        self.assertFalse((self.root / 'le-ready').exists())

    def test_resolve_device_rejects_another_action(self):
        self.stub_paired_phone_without_cached_hid()
        result = self.run_helper(
            '--device', '10:A2:D3:01:47:A1', '--resolve-device', '--trust', ok=False)
        self.assertIn('cannot be combined', result.stderr)

    def test_explicit_connect_can_rediscover_uncached_hid(self):
        self.stub_paired_phone_without_cached_hid()
        result = self.run_helper('--device', '10:A2:D3:01:47:A1')
        self.assertIn('HID=attached', result.stdout)
        self.assertTrue((self.root / 'le-ready').exists())

    def test_failed_discovery_does_not_start_a_blind_connection(self):
        self.stub_paired_phone_without_cached_hid()
        mock = self.root / 'bin/python3'
        mock.write_text(mock.read_text().replace(
            "discover) printf 'Refreshed LE HID discovery\\n' ;;", "discover) exit 2 ;;"))
        result = self.run_helper('--device', '10:A2:D3:01:47:A1', ok=False)
        self.assertIn('HID=not-ready', result.stdout)
        self.assertFalse((self.root / 'le-ready').exists())

    def test_watcher_keeps_polling_but_backs_off_radio_requests_after_failure(self):
        self.stub_paired_phone_without_cached_hid()
        radio_log = self.root / 'backend.log'
        self.env['ESP_TEST_BACKEND_LOG'] = str(radio_log)
        mock = self.root / 'bin/python3'
        mock.write_text(mock.read_text().replace(
            'case "$4" in', 'printf "%s\\n" "$4" >> "$ESP_TEST_BACKEND_LOG"\ncase "$4" in'
        ).replace('connect) touch "$ESP_TEST_LE_READY" ;;', 'connect) exit 2 ;;'))
        process = subprocess.Popen(
            ['bash', str(SCRIPT), '--device', '10:A2:D3:01:47:A1', '--watch', '1'],
            env=self.env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            start_new_session=True)
        try:
            with self.assertRaises(subprocess.TimeoutExpired):
                process.communicate(timeout=2.2)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
            output, errors = process.communicate(timeout=5)
        calls = radio_log.read_text().splitlines()
        self.assertEqual(calls.count('connect'), 1, output + errors)
        self.assertEqual(calls.count('discover'), 1, output + errors)
        self.assertGreaterEqual(calls.count('hid-ready'), 3)
        self.assertIn('Next reconnect attempt in 30s', output)

    def test_service_install_accepts_explicit_paired_peer_without_cached_hid(self):
        self.stub_paired_phone_without_cached_hid()
        self.run_helper('--device', '10:A2:D3:01:47:A1', '--install-service')
        unit = self.config / 'systemd/user/inpudeck-hid.service'
        text = unit.read_text()
        self.assertIn('--device 10:A2:D3:01:47:A1 --watch', text)
        for directive in (
                'NoNewPrivileges=yes',
                'CapabilityBoundingSet=',
                'PrivateUsers=yes',
                'PrivateTmp=yes',
                'PrivateDevices=yes',
                'ProtectSystem=strict',
                'ProtectHome=read-only',
                'ProtectKernelTunables=yes',
                'ProtectKernelModules=yes',
                'ProtectControlGroups=yes',
                'RestrictNamespaces=yes',
                'RestrictAddressFamilies=AF_UNIX'):
            self.assertIn(directive + '\n', text)
        self.assertIn('enable --now inpudeck-hid.service', self.log.read_text())

    def test_installer_rejects_relative_xdg_config_home(self):
        self.env['XDG_CONFIG_HOME'] = 'relative-config'
        self.run_helper('--install', ok=False)
        self.assertFalse(self.prefix.exists())


if __name__ == "__main__":
    unittest.main()

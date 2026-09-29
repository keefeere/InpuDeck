#!/usr/bin/env bash
# Install the Linux Direct Bluetooth HID support from one coherent repo snapshot.
set -euo pipefail

repo="keefeere/InpuDeck"
source_ref="main"
adapter="hci0"
device=""
assume_yes=0
source_root=""
work_dir=""
address_tmp=""
validated_tmp=""
unit_tmp=""

usage() {
  cat <<'USAGE'
Usage: install-linux.sh [options]

Install/update everything used by InpuDeck Direct Bluetooth HID on Linux:
the BlueZ LE API setting, the device-scoped address-resolution hook, and the
sandboxed per-user reconnect service. Existing bonds and audio settings stay
unchanged.

  -d, --device <MAC>    Exact paired iPhone Bluetooth identity address.
  -a, --adapter <hciN>  Bluetooth adapter (default: hci0).
      --ref <git-ref>   Install scripts from this Git ref (default: main).
  -y, --yes             Restart Bluetooth when needed without prompting.
  -h, --help            Show this help.

Run as the signed-in desktop user, not with sudo. The installer requests sudo
only for its small system-wide BlueZ files and a Bluetooth restart when needed.
USAGE
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

require() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required but not installed"
}

cleanup() {
  [ -z "$unit_tmp" ] || rm -f -- "$unit_tmp"
  [ -z "$validated_tmp" ] || rm -f -- "$validated_tmp"
  [ -z "$address_tmp" ] || rm -f -- "$address_tmp"
  [ -z "$work_dir" ] || rm -rf -- "$work_dir"
}
trap cleanup EXIT

while [ $# -gt 0 ]; do
  case "$1" in
    -d|--device) device="${2:?--device requires a Bluetooth address}"; shift 2 ;;
    -a|--adapter) adapter="${2:?--adapter requires hciN}"; shift 2 ;;
    --ref) source_ref="${2:?--ref requires a Git ref}"; shift 2 ;;
    -y|--yes) assume_yes=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ "${EUID:-$(id -u)}" -ne 0 ] || die "run this installer as your desktop user, without sudo"
[[ "$adapter" =~ ^hci[0-9]+$ ]] || die "adapter must be hciN"
[[ "$source_ref" =~ ^[A-Za-z0-9._/-]+$ ]] || die "Git ref contains unsupported characters"
if [ -n "$device" ]; then
  device="$(printf '%s' "$device" | tr 'a-z' 'A-Z')"
  [[ "$device" =~ ^([0-9A-F]{2}:){5}[0-9A-F]{2}$ ]] \
    || die "device must be a Bluetooth MAC address"
fi

for command in bash curl install mktemp python3 sed sort sudo systemctl tar tr; do
  require "$command"
done
for command in bluetoothctl btmgmt; do
  require "$command"
done
python3 -c 'import dbus' 2>/dev/null || die \
  "python3-dbus is required (Fedora/Bazzite: python3-dbus; Debian/Ubuntu: python3-dbus)"
systemctl --user show-environment >/dev/null 2>&1 \
  || die "the current user systemd session is unavailable; run this after signing into the desktop"

# Direct execution from a checkout uses that checkout. curl | bash has no safe
# sibling path, so fetch one immutable commit and use every companion from it.
script_path="${BASH_SOURCE[0]:-}"
if [ -n "$script_path" ] && [ -f "$script_path" ] \
    && [ -f "$(dirname -- "$script_path")/inpudeck-hid.sh" ]; then
  source_root="$(cd -- "$(dirname -- "$script_path")/.." && pwd)"
else
  printf 'Downloading InpuDeck Linux installer (%s)…\n' "$source_ref"
  metadata="$(curl --proto '=https' --tlsv1.2 --retry 3 -fsSL \
    "https://api.github.com/repos/$repo/commits/$source_ref")" \
    || die "could not resolve Git ref: $source_ref"
  commit="$(printf '%s' "$metadata" | python3 -c \
    'import json,sys; value=json.load(sys.stdin).get("sha", ""); print(value)')" \
    || die "could not parse the GitHub response"
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die "GitHub returned an invalid commit"
  work_dir="$(mktemp -d -t inpudeck-linux.XXXXXXXX)"
  archive="$work_dir/source.tar.gz"
  curl --proto '=https' --tlsv1.2 --retry 3 -fsSL \
    "https://codeload.github.com/$repo/tar.gz/$commit" -o "$archive" \
    || die "could not download InpuDeck at $commit"
  mkdir "$work_dir/source"
  tar -xzf "$archive" --strip-components=1 -C "$work_dir/source"
  source_root="$work_dir/source"
  printf 'Using commit %.12s.\n' "$commit"
fi

helper="$source_root/scripts/inpudeck-hid.sh"
backend="$source_root/scripts/inpudeck-bluez-le.py"
le_setup="$source_root/scripts/inpudeck-le-setup.py"
resolution_hook="$source_root/scripts/inpudeck-le-address-resolution.py"
resolution_unit="$source_root/scripts/91-inpudeck-address-resolution.conf"
for file in "$helper" "$backend" "$le_setup" "$resolution_hook" "$resolution_unit"; do
  [ -f "$file" ] || die "installer companion is missing: $file"
done

if [ -z "$device" ]; then
  if ! device="$(bash "$helper" --adapter "$adapter" --resolve-device)"; then
    printf '\nPaired Bluetooth devices:\n' >&2
    bluetoothctl devices Paired >&2 || true
    if [ ! -r /dev/tty ]; then
      die "device detection was ambiguous; rerun with --device AA:BB:CC:DD:EE:FF"
    fi
    printf 'Paired iPhone identity address: ' >/dev/tty
    IFS= read -r device </dev/tty || die "could not read the device address"
  fi
fi
device="$(printf '%s' "$device" | tr 'a-z' 'A-Z')"
[[ "$device" =~ ^([0-9A-F]{2}:){5}[0-9A-F]{2}$ ]] \
  || die "device must be a Bluetooth MAC address"
bash "$helper" --adapter "$adapter" --device "$device" --resolve-device >/dev/null

printf 'Installing Direct Bluetooth HID for %s on %s…\n' "$device" "$adapter"
sudo -v
sudo python3 "$le_setup" enable

if ! python3 "$backend" --adapter "$adapter" check "$device" >/dev/null 2>&1; then
  if [ "$assume_yes" -eq 0 ]; then
    [ -r /dev/tty ] || die \
      "Bluetooth must restart to activate the LE API; rerun interactively or add --yes"
    printf '\nBluetooth must restart once; current Bluetooth devices will disconnect. Continue? [Y/n] ' >/dev/tty
    IFS= read -r answer </dev/tty || die "could not read restart confirmation"
    case "$answer" in n|N|no|NO|No) die "Bluetooth restart declined; configuration is saved for the next reboot" ;; esac
  fi
  sudo python3 "$le_setup" enable --restart
fi
python3 "$backend" --adapter "$adapter" check "$device" >/dev/null \
  || die "BlueZ restarted, but its experimental LE bearer API is still unavailable"

device_file="/etc/inpudeck/address-resolution-devices"
installed_hook="/usr/local/libexec/inpudeck-le-address-resolution.py"
installed_unit="/etc/systemd/system/bluetooth.service.d/91-inpudeck-address-resolution.conf"
for target in "$device_file" "$installed_hook" "$installed_unit"; do
  sudo test ! -L "$target" || die "refusing a symlinked installer target: $target"
done
address_tmp="$(mktemp -t inpudeck-devices.XXXXXXXX)"
if sudo test -e "$device_file"; then
  sudo test -f "$device_file" || die "device list is not a regular file: $device_file"
  sudo cat "$device_file" >"$address_tmp"
fi

validated_tmp="${address_tmp}.validated"
while IFS= read -r value || [ -n "$value" ]; do
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  [ -n "$value" ] || continue
  [[ "$value" == \#* ]] && continue
  value="$(printf '%s' "$value" | tr 'a-z' 'A-Z')"
  [[ "$value" =~ ^([0-9A-F]{2}:){5}[0-9A-F]{2}$ ]] \
    || die "invalid existing address in $device_file: $value"
  printf '%s\n' "$value" >>"$validated_tmp"
done <"$address_tmp"
printf '%s\n' "$device" >>"$validated_tmp"
LC_ALL=C sort -u "$validated_tmp" -o "$validated_tmp"
mv -- "$validated_tmp" "$address_tmp"
validated_tmp=""

unit_tmp="$(mktemp -t inpudeck-unit.XXXXXXXX)"
sed "s/--adapter hci0/--adapter $adapter/" "$resolution_unit" >"$unit_tmp"
grep -q -- "--adapter $adapter" "$unit_tmp" \
  || die "could not configure the address-resolution unit for $adapter"

sudo install -Dm644 "$address_tmp" "$device_file"
sudo install -Dm755 "$resolution_hook" "$installed_hook"
sudo install -Dm644 "$unit_tmp" "$installed_unit"
sudo systemctl daemon-reload
sudo python3 "$installed_hook" --adapter "$adapter" --device-file "$device_file"

bash "$helper" --adapter "$adapter" --device "$device" --install-service

cat <<EOF

Done. Linux Direct Bluetooth HID is installed for $device.
The reconnect service is enabled; BlueZ bonds and audio settings were preserved.

Status:
  ~/.local/bin/inpudeck-hid --device $device --status
EOF

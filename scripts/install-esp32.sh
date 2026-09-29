#!/usr/bin/env bash

set -Eeuo pipefail

repository="keefeere/InpuDeck"
version="${INPUDECK_VERSION:-latest}"
bridge_name=""
passkey=""
serial_port="auto"
skip_flash=false
rotate_passkey=false
uv_version="0.12.19"
uv_installer_sha256="61b349611f1b6e1ba33645f30c36da5287df2609dd7af8605d96a031435eb35b"
sigstore_version="4.1.0"
sigstore_oidc_issuer="https://token.actions.githubusercontent.com"

usage() {
  cat <<'EOF'
Usage: install-esp32.sh [--name NAME] [--passkey 123456] [--port PORT]
                        [--version VERSION] [--skip-flash] [--rotate-passkey]

Downloads and verifies the released ESP32-S3-Zero firmware, then flashes and
securely provisions the bridge with a unique BLE passkey and identity. Use
--skip-flash to rename compatible firmware, or add --rotate-passkey to replace
its passkey, BLE identity, and bonds. Every mutation requires the physical BOOT
window. Without arguments it prompts on the controlling terminal.
EOF
}

sha256_digest() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

verify_sha256_value() {
  local expected="$1"
  local path="$2"
  local actual
  actual="$(sha256_digest "$path")"
  if [[ "$actual" != "$expected" ]]; then
    echo "error: SHA-256 mismatch for $(basename "$path")" >&2
    echo "expected: $expected" >&2
    echo "actual:   $actual" >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      [[ $# -ge 2 ]] || { echo "error: --name needs a value" >&2; exit 2; }
      bridge_name="$2"
      shift 2
      ;;
    --port)
      [[ $# -ge 2 ]] || { echo "error: --port needs a value" >&2; exit 2; }
      serial_port="$2"
      shift 2
      ;;
    --passkey)
      [[ $# -ge 2 ]] || { echo "error: --passkey needs a value" >&2; exit 2; }
      passkey="$2"
      shift 2
      ;;
    --version)
      [[ $# -ge 2 ]] || { echo "error: --version needs a value" >&2; exit 2; }
      version="$2"
      shift 2
      ;;
    --skip-flash)
      skip_flash=true
      shift
      ;;
    --rotate-passkey)
      rotate_passkey=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$rotate_passkey" == true && "$skip_flash" == false ]]; then
  echo "error: --rotate-passkey is only valid together with --skip-flash" >&2
  exit 2
fi
if [[ -n "$passkey" && "$skip_flash" == true && "$rotate_passkey" == false ]]; then
  echo "error: --passkey with --skip-flash requires --rotate-passkey" >&2
  exit 2
fi

command -v curl >/dev/null 2>&1 || { echo "error: curl is required" >&2; exit 1; }
[[ -r /dev/tty ]] || {
  echo "error: an interactive terminal is required; download this script and use --name/--port for non-interactive use" >&2
  exit 1
}

workdir="$(mktemp -d "${TMPDIR:-/tmp}/inpudeck-installer.XXXXXX")"
trap 'rm -rf -- "$workdir"' EXIT

release_tag=""
if [[ -n "${INPUDECK_RELEASE_BASE:-}" ]]; then
  if [[ "$version" == "latest" ]]; then
    echo "error: INPUDECK_RELEASE_BASE requires an explicit --version" >&2
    exit 2
  fi
  version="${version#ios-v}"
  release_base="$INPUDECK_RELEASE_BASE"
elif [[ "$version" == "latest" ]]; then
  latest_url="$(
    curl --fail --location --silent --show-error --retry 3 \
      --output /dev/null --write-out '%{url_effective}' \
      "https://github.com/${repository}/releases/latest"
  )"
  release_tag="${latest_url##*/}"
  if [[ ! "$release_tag" =~ ^ios-v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: latest release did not resolve to an InpuDeck iOS tag: $latest_url" >&2
    exit 1
  fi
  version="${release_tag#ios-v}"
  release_base="https://github.com/${repository}/releases/download/${release_tag}"
else
  version="${version#ios-v}"
fi
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: VERSION must use the numeric X.Y.Z form" >&2
  exit 2
fi
release_tag="${release_tag:-ios-v${version}}"
if [[ -z "${release_base:-}" ]]; then
  release_base="https://github.com/${repository}/releases/download/${release_tag}"
fi

assets=(install-esp32.py install-esp32.py.sigstore.json)
if [[ "$skip_flash" == false ]]; then
  echo "Downloading InpuDeck firmware (${version})…"
  assets=(
    InpuDeck-ESP32-S3-Zero.bin
    InpuDeck-ESP32-S3-Zero.bin.sha256
    InpuDeck-ESP32-S3-Zero.bin.sigstore.json
    "${assets[@]}"
  )
else
  echo "Downloading the InpuDeck installer (${version}); firmware will not be reflashed…"
fi
for asset in "${assets[@]}"; do
  curl --fail --location --silent --show-error --retry 3 \
    "${release_base}/${asset}" --output "${workdir}/${asset}"
done

if [[ "$skip_flash" == false ]]; then
  IFS=' ' read -r published_digest published_name extra \
    <"$workdir/InpuDeck-ESP32-S3-Zero.bin.sha256"
  if [[ ! "$published_digest" =~ ^[0-9a-f]{64}$ \
        || "$published_name" != "InpuDeck-ESP32-S3-Zero.bin" \
        || -n "${extra:-}" ]]; then
    echo "error: malformed firmware checksum file" >&2
    exit 1
  fi
  verify_sha256_value \
    "$published_digest" "$workdir/InpuDeck-ESP32-S3-Zero.bin"
fi

# Establish a trusted verifier before executing any downloaded release code.
# The versioned Astral installer embeds hashes for the uv binaries; pinning the
# installer itself here keeps that bootstrap independent from the release being
# verified.
if command -v uv >/dev/null 2>&1; then
  uv_command="$(command -v uv)"
else
  echo "uv was not found; downloading a temporary copy of ${uv_version}…"
  mkdir -p "$workdir/uv"
  curl --fail --location --silent --show-error \
    "https://astral.sh/uv/${uv_version}/install.sh" \
    --output "$workdir/uv-install.sh"
  verify_sha256_value "$uv_installer_sha256" "$workdir/uv-install.sh"
  env UV_UNMANAGED_INSTALL="$workdir/uv" sh "$workdir/uv-install.sh"
  uv_command="$workdir/uv/uv"
fi

certificate_identity="https://github.com/${repository}/.github/workflows/build-ios-ipa.yml@refs/tags/${release_tag}"
verify_provenance() {
  local asset="$1"
  local bundle="$2"
  echo "Verifying signed provenance for $(basename "$asset")…"
  UV_CACHE_DIR="$workdir/uv-cache" \
    "$uv_command" run --no-project --with "sigstore==${sigstore_version}" \
      sigstore verify identity \
      --bundle "$bundle" \
      --cert-identity "$certificate_identity" \
      --cert-oidc-issuer "$sigstore_oidc_issuer" \
      "$asset" >/dev/null
}

verify_provenance \
  "$workdir/install-esp32.py" \
  "$workdir/install-esp32.py.sigstore.json"
if [[ "$skip_flash" == false ]]; then
  verify_provenance \
    "$workdir/InpuDeck-ESP32-S3-Zero.bin" \
    "$workdir/InpuDeck-ESP32-S3-Zero.bin.sigstore.json"
fi

# Only the authenticated Python installer may now be parsed or executed.
UV_CACHE_DIR="$workdir/uv-cache" \
  "$uv_command" run --no-project --script "$workdir/install-esp32.py" --help >/dev/null

if [[ -z "$bridge_name" ]]; then
  printf 'Adapter name [InpuDeck Bridge]: ' >/dev/tty
  IFS= read -r bridge_name </dev/tty
  bridge_name="${bridge_name:-InpuDeck Bridge}"
fi

if [[ "$skip_flash" == false ]]; then
  cat >/dev/tty <<'EOF'

Put ESP32-S3-Zero into flashing mode:
  0. Disconnect any other ESP32 boards from this computer.
  1. Hold the BOOT button.
  2. Press and release RESET while holding BOOT.
  3. Release BOOT.
EOF
else
  cat >/dev/tty <<'EOF'

Make sure ESP32-S3-Zero is connected and is not in BOOT mode.
If it was just flashed, press RESET once and wait 2–3 seconds.
EOF
fi

if [[ "$skip_flash" == false ]]; then
  if [[ "$serial_port" == "auto" ]]; then
    printf 'Press Enter when ready; the USB port will be detected automatically. ' >/dev/tty
  else
    printf 'Press Enter when ready; %s will be used. ' "$serial_port" >/dev/tty
  fi
  IFS= read -r _ </dev/tty
elif [[ "$skip_flash" == true ]]; then
  cat >/dev/tty <<'EOF'

Open the physical provisioning window: hold BOOT for 3–7 seconds while the
firmware is running, then release it.
EOF
  printf 'Press Enter after releasing BOOT. ' >/dev/tty
  IFS= read -r _ </dev/tty
fi

echo
if [[ "$skip_flash" == false ]]; then
  echo "After flashing, press RESET once when the installer asks you to."
fi
if [[ "$(uname -s)" == "Linux" ]]; then
  echo "If the serial port is not accessible, sudo will be requested only to grant temporary access."
fi

installer_args=(--name "$bridge_name")
if [[ "$skip_flash" == true ]]; then
  installer_args+=(--skip-flash)
  if [[ "$rotate_passkey" == true ]]; then
    installer_args+=(--rotate-passkey)
  fi
else
  installer_args+=(
    --firmware "$workdir/InpuDeck-ESP32-S3-Zero.bin"
    --wait-for-reset
  )
fi
if [[ -n "$passkey" ]]; then
  installer_args+=(--passkey "$passkey")
fi
if [[ "$serial_port" != "auto" ]]; then
  installer_args+=(--port "$serial_port")
fi
if [[ "$(uname -s)" == "Linux" ]]; then
  installer_args+=(--grant-port-access)
fi

UV_CACHE_DIR="$workdir/uv-cache" \
  "$uv_command" run --no-project --script "$workdir/install-esp32.py" "${installer_args[@]}"

echo
echo "Done. The ESP now advertises as '${bridge_name}'."
if [[ "$skip_flash" == false || "$rotate_passkey" == true ]]; then
  echo "Pairing is open temporarily. In InpuDeck, select this ESP and enter the security passkey shown above."
  cat <<'EOF'

IMPORTANT FOR A PREVIOUSLY PAIRED BOARD:
This operation replaced its BLE passkey and identity and erased its bonds.
Forget the old adapter in iPhone Settings > Bluetooth and in InpuDeck before
pairing it again.
An old cached name or a pairing prompt that repeatedly disappears means the
previous iOS bond still needs to be removed.
EOF
else
  cat <<'EOF'

The existing BLE identity and bonds were preserved. iOS may retain the previous
name in its system Bluetooth list. To replace that system identity as well, run
again with --skip-flash --rotate-passkey and pair the adapter as a new device.
EOF
fi

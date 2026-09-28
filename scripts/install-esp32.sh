#!/usr/bin/env bash

set -Eeuo pipefail

repository="keefeere/InpuDeck"
version="${INPUDECK_VERSION:-latest}"
bridge_name=""
serial_port="auto"
skip_flash=false
uv_version="0.12.19"

usage() {
  cat <<'EOF'
Usage: install-esp32.sh [--name NAME] [--port PORT] [--version VERSION] [--skip-flash]

Downloads and verifies the released ESP32-S3-Zero firmware, then flashes and
names the bridge. Use --skip-flash to rename compatible firmware that is already
installed. Without arguments it prompts on the controlling terminal.
EOF
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
    --version)
      [[ $# -ge 2 ]] || { echo "error: --version needs a value" >&2; exit 2; }
      version="$2"
      shift 2
      ;;
    --skip-flash)
      skip_flash=true
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

command -v curl >/dev/null 2>&1 || { echo "error: curl is required" >&2; exit 1; }
[[ -r /dev/tty ]] || {
  echo "error: an interactive terminal is required; download this script and use --name/--port for non-interactive use" >&2
  exit 1
}

workdir="$(mktemp -d "${TMPDIR:-/tmp}/inpudeck-installer.XXXXXX")"
trap 'rm -rf -- "$workdir"' EXIT

if [[ -n "${INPUDECK_RELEASE_BASE:-}" ]]; then
  release_base="$INPUDECK_RELEASE_BASE"
elif [[ "$version" == "latest" ]]; then
  release_base="https://github.com/${repository}/releases/latest/download"
else
  version="${version#ios-v}"
  release_base="https://github.com/${repository}/releases/download/ios-v${version}"
fi

assets=(install-esp32.py)
if [[ "$skip_flash" == false ]]; then
  echo "Завантажую firmware InpuDeck (${version})…"
  assets=(InpuDeck-ESP32-S3-Zero.bin InpuDeck-ESP32-S3-Zero.bin.sha256 "${assets[@]}")
else
  echo "Завантажую інсталятор InpuDeck (${version}); firmware не перепрошиватиметься…"
fi
for asset in "${assets[@]}"; do
  curl --fail --location --silent --show-error --retry 3 \
    "${release_base}/${asset}" --output "${workdir}/${asset}"
done

if [[ "$skip_flash" == false ]]; then
  (
    cd "$workdir"
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum --check InpuDeck-ESP32-S3-Zero.bin.sha256
    else
      shasum -a 256 --check InpuDeck-ESP32-S3-Zero.bin.sha256
    fi
  )
fi

if [[ -z "$bridge_name" ]]; then
  printf 'Імʼя адаптера [InpuDeck Bridge]: ' >/dev/tty
  IFS= read -r bridge_name </dev/tty
  bridge_name="${bridge_name:-InpuDeck Bridge}"
fi

if [[ "$skip_flash" == false ]]; then
  cat >/dev/tty <<'EOF'

Переведи ESP32-S3-Zero у режим прошивки:
  0. Відʼєднай інші ESP32, якщо вони підключені до цього компʼютера.
  1. Затисни кнопку BOOT.
  2. Натисни й відпусти RESET, не відпускаючи BOOT.
  3. Відпусти BOOT.
EOF
else
  cat >/dev/tty <<'EOF'

Переконайся, що ESP32-S3-Zero підключена й працює не в BOOT mode.
Якщо вона щойно прошита, натисни RESET один раз і зачекай 2–3 секунди.
EOF
fi

if [[ "$serial_port" == "auto" ]]; then
  printf 'Коли зробиш — натисни Enter; USB-порт буде знайдено автоматично. ' >/dev/tty
else
  printf 'Коли зробиш — натисни Enter; використаємо %s. ' "$serial_port" >/dev/tty
fi
IFS= read -r _ </dev/tty

if command -v uv >/dev/null 2>&1; then
  uv_command="$(command -v uv)"
else
  echo "uv не знайдено; завантажую тимчасову копію ${uv_version}…"
  mkdir -p "$workdir/uv"
  curl --fail --location --silent --show-error \
    "https://astral.sh/uv/${uv_version}/install.sh" \
    | env UV_UNMANAGED_INSTALL="$workdir/uv" sh
  uv_command="$workdir/uv/uv"
fi

echo
if [[ "$skip_flash" == false ]]; then
  echo "Після запису firmware натисни RESET один раз, коли інсталятор попросить."
fi
if [[ "$(uname -s)" == "Linux" ]]; then
  echo "Якщо бракує прав на serial-порт, sudo буде запитано лише для тимчасового доступу до нього."
fi

installer_args=(--name "$bridge_name")
if [[ "$skip_flash" == true ]]; then
  installer_args+=(--skip-flash)
else
  installer_args+=(
    --firmware "$workdir/InpuDeck-ESP32-S3-Zero.bin"
    --wait-for-reset
  )
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
echo "Готово. ESP рекламується як «${bridge_name}»."

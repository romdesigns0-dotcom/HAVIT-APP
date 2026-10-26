#!/usr/bin/env bash
set -euo pipefail
source_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work_root="${HAVIT_WSL_WORK_ROOT:-$HOME/Havit}"
swift_bin="${HAVIT_REAL_SWIFT:-$(command -v swift || true)}"
if [[ -z "$swift_bin" || ! -x "$swift_bin" ]]; then
    echo "Instala Swift en WSL o configura HAVIT_REAL_SWIFT con la ruta al compilador." >&2
    exit 2
fi
export HAVIT_REAL_SWIFT="$swift_bin"
export PATH="$(dirname -- "$swift_bin"):/usr/local/bin:/usr/bin:/bin:$PATH"
if [[ "$source_root" != "$work_root" ]]; then
    rsync -a --exclude .build --exclude .git --exclude xtool --exclude backend --exclude .local-toolchain "$source_root/" "$work_root/"
fi
cd "$work_root"
if [[ "${1:-build}" == "run" ]]; then
    if [[ -z "${USBMUXD_SOCKET_ADDRESS:-}" ]]; then
        echo "Configura USBMUXD_SOCKET_ADDRESS con el host y puerto usbmuxd accesibles desde WSL." >&2
        exit 2
    fi
fi
exec ./Scripts/build.sh "${1:-build}"

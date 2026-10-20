#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
action="${1:-build}"
case "$action" in
  build|run) ;;
  *) echo "Uso: $0 [build|run]" >&2; exit 2 ;;
esac
real_swift="${HAVIT_REAL_SWIFT:-$(command -v swift)}"
wrapper_dir="$project_root/.local-toolchain/bin"
if [[ "$real_swift" == "$wrapper_dir/swift" ]]; then
  echo "Configura HAVIT_REAL_SWIFT con la ruta al compilador Swift original." >&2
  exit 2
fi
mkdir -p "$wrapper_dir"
ln -sf "$project_root/Scripts/swift-widget-bootstrap.py" "$wrapper_dir/swift"
export HAVIT_REAL_SWIFT="$real_swift"
export PATH="$wrapper_dir:$PATH"
cd "$project_root"
exec xtool dev "$action"

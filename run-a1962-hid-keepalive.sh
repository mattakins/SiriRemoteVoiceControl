#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
SOURCE="$ROOT_DIR/Tools/A1962HIDKeepalive.m"
BINARY="$ROOT_DIR/Tools/a1962_hid_keepalive"

if [[ ! -x "$BINARY" || "$SOURCE" -nt "$BINARY" ]]; then
  clang -fobjc-arc -framework Foundation -framework AppKit -framework IOKit "$SOURCE" -o "$BINARY"
fi

exec "$BINARY" "$@"

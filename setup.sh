#!/usr/bin/env bash
#
# setup.sh - dynamic dispatcher: picks the right installer for this machine.
#   macOS  -> setup-macos.sh  (client: ssh forward + wrapper install)
#   Ubuntu -> setup-ubuntu.sh (server: netns + openvpn + proxy + units)
#
# All flags are passed through. Start with: ./setup.sh --help
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$(uname -s)" in
    Darwin)
        exec "$SCRIPT_DIR/setup-macos.sh" "$@"
        ;;
    Linux)
        exec "$SCRIPT_DIR/setup-ubuntu.sh" "$@"
        ;;
    *)
        echo "[!!] unsupported OS: $(uname -s) (want Darwin or Linux)" >&2
        exit 2
        ;;
esac

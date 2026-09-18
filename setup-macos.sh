#!/bin/bash
# setup-macos.sh - Set up this Mac as an opencode-vpn CLIENT.
#
# What it does (idempotent, safe to re-run):
#   1. Checks macOS + required tools (ssh, curl, ssh-keygen).
#   2. Verifies SSH key auth to the Hetzner server.
#   3. Verifies a local `opencode` binary exists (never auto-installs).
#   4. Installs the `opencode-vpn-macos` wrapper into $PREFIX.
#   5. Probes server-side readiness (openvpn-netns + vpn-proxy active).
#   6. Runs an end-to-end proxy test (proxy exit IP == namespace exit IP)
#      plus a non-interactive run of the installed wrapper as proof.
#
# Run as a NORMAL user (no sudo). Only `--prefix /usr/local/bin` may need
# sudo for the install step. Run from the repo checkout:
#   ./setup-macos.sh [--yes] [--check] [--prefix DIR] [--server u@h] [--port N]
#
# Helpers (log, ok, warn, die, need_cmd, confirm) come from lib/common.sh.
# There are no credentials in this flow (SSH key auth only); print none.

set -euo pipefail

# --------------------------------------------------------------------------
# Defaults + argument parsing
# --------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/common.sh"

PREFIX="$HOME/.local/bin"
SERVER="root@88.99.250.99"
PORT="8888"
CHECK=0
ASSUME_YES="${ASSUME_YES:-0}"

usage() {
    echo "usage: setup-macos.sh [-y|--yes] [--check] [--prefix DIR]"
    echo "                      [--server user@host] [--port N] [-h|--help]"
    echo ""
    echo "  -y, --yes       non-interactive (never generate keys; die w/ instructions)"
    echo "  --check         verify-only: run all checks, change nothing"
    echo "  --prefix DIR    install dir for wrapper (default: \$HOME/.local/bin)"
    echo "  --server U@H    ssh target (default: root@88.99.250.99)"
    echo "  --port N        local forward port (default: 8888)"
}

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes) ASSUME_YES=1; shift ;;
        --check) CHECK=1; shift ;;
        --prefix) PREFIX="${2:?--prefix needs a directory}"; shift 2 ;;
        --server) SERVER="${2:?--server needs user@host}"; shift 2 ;;
        --port) PORT="${2:?--port needs a number}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown flag: $1 (see -h|--help)" ;;
    esac
done

case "$PORT" in
    ''|*[!0-9]*) die "--port must be a number (got: $PORT)" ;;
esac

REMOTE="10.200.1.2:8888"
PROXY="http://127.0.0.1:$PORT"
WRAPPER_SRC="$SCRIPT_DIR/opencode-vpn-macos"
WRAPPER_DST="$PREFIX/opencode-vpn-macos"

echo "[..] opencode-vpn macOS client setup (server=$SERVER port=$PORT prefix=$PREFIX)"
[ "$CHECK" -eq 1 ] && echo "[..] --check mode: verifying only, changing nothing"

# --------------------------------------------------------------------------
# 1. Preconditions: must be macOS; need ssh, curl, ssh-keygen
# --------------------------------------------------------------------------
echo "[..] step 1/6: preconditions"
if [ "$(uname -s)" != "Darwin" ]; then
    die "not macOS (uname: $(uname -s)); for the Linux server use setup-ubuntu.sh"
fi
need_cmd ssh
need_cmd curl
need_cmd ssh-keygen
MACOS_VER="$(sw_vers -productVersion 2>/dev/null || echo unknown)"
ARCH="$(uname -m)"
log "macOS $MACOS_VER ($ARCH)"

# --------------------------------------------------------------------------
# 2. SSH readiness: key auth to the server must already work
# --------------------------------------------------------------------------
echo "[..] step 2/6: ssh readiness ($SERVER)"
if ssh -o BatchMode=yes -o ConnectTimeout=8 "$SERVER" true 2>/dev/null; then
    ok "ssh key auth works: $SERVER"
else
    warn "ssh key auth failed: $SERVER"
    if [ ! -f "$HOME/.ssh/id_ed25519" ] && [ ! -f "$HOME/.ssh/id_ed25519.pub" ]; then
        if [ "$CHECK" -eq 1 ]; then
            die "no ~/.ssh/id_ed25519 found; generate one (ssh-keygen -t ed25519), then run: ssh-copy-id $SERVER"
        fi
        if [ "$ASSUME_YES" -eq 1 ]; then
            die "no ~/.ssh/id_ed25519 found; generate one first: ssh-keygen -t ed25519 ; then ssh-copy-id $SERVER"
        fi
        if confirm "No ed25519 key found. Generate one now (ssh-keygen -t ed25519)?"; then
            ssh-keygen -t ed25519
        else
            die "no ssh key; generate one (ssh-keygen -t ed25519), then run: ssh-copy-id $SERVER"
        fi
    fi
    echo "[!!] fix: copy your key to the server, then re-run this script:"
    echo "[!!]   ssh-copy-id $SERVER"
    echo "[!!] (or append ~/.ssh/id_ed25519.pub to ~/.ssh/authorized_keys on the server)"
    die "ssh key auth to $SERVER is not working yet"
fi

# --------------------------------------------------------------------------
# 3. opencode binary must exist locally (never auto-install it)
# --------------------------------------------------------------------------
echo "[..] step 3/6: opencode binary"
if command -v opencode >/dev/null 2>&1; then
    ok "opencode found: $(command -v opencode)"
elif [ -x "$HOME/.opencode/bin/opencode" ]; then
    ok "opencode found: $HOME/.opencode/bin/opencode"
else
    warn "opencode binary not found on PATH or at \$HOME/.opencode/bin/opencode"
    echo "[..] upstream install hint (run it yourself, then re-run this script):"
    echo "[..]   curl -fsSL https://opencode.ai/install | bash"
fi

# --------------------------------------------------------------------------
# 4. Install the wrapper into $PREFIX (verify-only under --check)
# --------------------------------------------------------------------------
echo "[..] step 4/6: install wrapper -> $WRAPPER_DST"
[ -f "$WRAPPER_SRC" ] || die "wrapper source missing: $WRAPPER_SRC (run from the repo checkout)"
if [ "$CHECK" -eq 1 ]; then
    if [ -x "$WRAPPER_DST" ]; then
        ok "wrapper present and executable: $WRAPPER_DST"
    else
        warn "wrapper not installed yet: $WRAPPER_DST (run without --check to install)"
    fi
else
    mkdir -p "$PREFIX"
    cp "$WRAPPER_SRC" "$WRAPPER_DST"
    chmod +x "$WRAPPER_DST"
    ok "installed: $WRAPPER_DST"
fi
case ":$PATH:" in
    *":$PREFIX:"*) ok "prefix on PATH: $PREFIX" ;;
    *)
        PROFILE_FILE="$HOME/.zprofile"
        case "${SHELL:-}" in
            *bash*) PROFILE_FILE="$HOME/.bash_profile" ;;
        esac
        warn "$PREFIX is not on PATH; add it via $PROFILE_FILE:"
        echo "[..]   export PATH=\"$PREFIX:\$PATH\""
        ;;
esac

# --------------------------------------------------------------------------
# 5. Server-side readiness (read-only probes over ssh)
# --------------------------------------------------------------------------
echo "[..] step 5/6: server-side readiness ($SERVER)"
VPN_SVC="$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$SERVER" 'systemctl is-active openvpn-netns' 2>/dev/null || true)"
PROXY_SVC="$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$SERVER" 'systemctl is-active vpn-proxy' 2>/dev/null || true)"
CURRENT="$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$SERVER" 'cat /etc/openvpn/client/current' 2>/dev/null || true)"
[ -n "$CURRENT" ] && log "server profile state: $CURRENT (from /etc/openvpn/client/current)"
if [ "$VPN_SVC" = "active" ] && [ "$PROXY_SVC" = "active" ]; then
    ok "server services active: openvpn-netns + vpn-proxy"
else
    echo "[!!] server not ready: openvpn-netns=$VPN_SVC vpn-proxy=$PROXY_SVC (want: active/active)"
    echo "[!!] fix on the server: sudo ./setup-ubuntu.sh (or: systemctl status openvpn-netns vpn-proxy)"
    if [ "$CHECK" -eq 1 ]; then
        die "FAIL: server-side services are not active"
    fi
    die "server-side services are not active; fix the server, then re-run"
fi

# --------------------------------------------------------------------------
# 6. End-to-end verify: proxy exit IP must equal namespace exit IP.
#    Replicates wrapper logic WITHOUT launching opencode interactively.
# --------------------------------------------------------------------------
echo "[..] step 6/6: end-to-end proxy test"

proxy_ip() { curl -s --max-time 8 -x "$PROXY" https://ifconfig.me 2>/dev/null || true; }

BEFORE_PIDS=""
STARTED_FORWARD=0
# Tear down ONLY a forward this script started, on ANY exit path.
# Never touches pre-existing forwards.
cleanup_forward() {
    [ "$STARTED_FORWARD" -eq 1 ] || return 0
    local after pid
    after="$(pgrep -f "ssh.*-L 127.0.0.1:$PORT:" 2>/dev/null || true)"
    # shellcheck disable=SC2086
    for pid in $after; do
        case " $BEFORE_PIDS " in
            *" $pid "*) ;; # pre-existing; leave it alone
            *) kill "$pid" 2>/dev/null || true; log "stopped test forward (pid $pid)" ;;
        esac
    done
}
trap cleanup_forward EXIT

BEFORE_PIDS="$(pgrep -f "ssh.*-L 127.0.0.1:$PORT:" 2>/dev/null || true)"
PROXY_IP="$(proxy_ip)"
if [ -z "$PROXY_IP" ]; then
    echo "[..] no live forward on 127.0.0.1:$PORT; starting a test forward ..."
    ssh -f -N -o ExitOnForwardFailure=yes -o BatchMode=yes -o ConnectTimeout=10 \
        -L "127.0.0.1:$PORT:$REMOTE" "$SERVER"
    sleep 2
    STARTED_FORWARD=1
    PROXY_IP="$(proxy_ip)"
fi
[ -n "$PROXY_IP" ] || die "FAIL: proxy unreachable; is vpn-proxy + openvpn-netns active on $SERVER?"

NS_IP="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$SERVER" 'ip netns exec vpn curl -s --max-time 10 https://ifconfig.me' 2>/dev/null || true)"
[ -n "$NS_IP" ] || die "FAIL: could not read namespace exit IP from $SERVER"

if [ "$PROXY_IP" = "$NS_IP" ]; then
    ok "PASS: proxy exit IP ($PROXY_IP) == namespace exit IP ($NS_IP)"
else
    die "FAIL: proxy exit ($PROXY_IP) != namespace exit ($NS_IP); refusing to proceed"
fi

# Proof: run the wrapper non-interactively (opencode --version must succeed
# after the wrapper prints its `vpn exit IP:` line to stderr).
WRAPPER_RUN="$WRAPPER_DST"
if [ "$CHECK" -eq 1 ] && [ ! -x "$WRAPPER_DST" ]; then
    WRAPPER_RUN="$WRAPPER_SRC"
    warn "--check: installed wrapper missing; proving with the repo copy instead"
fi
WRAPPER_OUT="$(VPN_SERVER="$SERVER" VPN_PROXY_PORT="$PORT" "$WRAPPER_RUN" --version 2>&1 || true)"
if echo "$WRAPPER_OUT" | grep -q "vpn exit IP:"; then
    ok "wrapper proof ok: $WRAPPER_RUN --version printed a vpn exit IP line"
else
    echo "$WRAPPER_OUT" | head -5
    die "FAIL: wrapper did not print a vpn exit IP line"
fi

# Forward lifecycle is handled by the EXIT trap (cleanup_forward):
# pre-existing forwards are left alone, test forwards are stopped.
# --------------------------------------------------------------------------
# 7. Done: usage
# --------------------------------------------------------------------------
echo ""
echo "[ok] macOS client setup complete."
echo "[..] usage: opencode-vpn-macos [args]   # any opencode args are passed through"
echo "[..] env overrides: VPN_SERVER (now: $SERVER)  VPN_PROXY_PORT (now: $PORT)"
echo "[..] proxy env (HTTP_PROXY/HTTPS_PROXY + lower case) is set child-only"
echo "[..] inside the wrapper; NO_PROXY covers localhost,127.0.0.1,::1."

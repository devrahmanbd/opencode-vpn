#!/bin/bash
# setup-macos.sh - Set up this Mac with its OWN local OpenVPN tunnel.
#
# What it does (idempotent, safe to re-run):
#   1. Checks macOS + required tools (curl, bash).
#   2. Verifies a local `opencode` binary exists (never auto-installs).
#   3. Installs openvpn via Homebrew if missing.
#   4. Installs VPN profiles to ~/.config/opencode-vpn/profiles/.
#   5. Saves NordVPN credentials to ~/.config/opencode-vpn/auth.txt (0600).
#   6. Installs vpn-macos + opencode-vpn-macos into $PREFIX.
#   7. Optional: starts a test tunnel to verify end-to-end.
#
# Run as a NORMAL user (no sudo). Only --prefix outside \$HOME needs sudo.
# Run from the repo checkout:
#   ./setup-macos.sh [--yes] [--check] [--prefix DIR]
#
# Helpers (log, ok, warn, die, need_cmd, confirm, secret_prompt) come from
# lib/common.sh.

set -euo pipefail

# --------------------------------------------------------------------------
# Defaults + argument parsing
# --------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/common.sh"

PREFIX="$HOME/.local/bin"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode-vpn"
PROFILES_DST="$CONFIG_DIR/profiles"
AUTH_FILE="$CONFIG_DIR/auth.txt"
FAILURES=0
CHECK=0
ASSUME_YES="${ASSUME_YES:-0}"

usage() {
    echo "usage: setup-macos.sh [-y|--yes] [--check] [--prefix DIR] [-h|--help]"
    echo ""
    echo "  -y, --yes       non-interactive (credentials must already exist)"
    echo "  --check         verify-only: run all checks, change nothing"
    echo "  --prefix DIR    install dir for wrappers (default: \$HOME/.local/bin)"
}

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes) ASSUME_YES=1; shift ;;
        --check) CHECK=1; shift ;;
        --prefix) PREFIX="${2:?--prefix needs a directory}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown flag: $1 (see -h|--help)" ;;
    esac
done

VPN_MACOS_SRC="$SCRIPT_DIR/vpn-macos"
WRAPPER_SRC="$SCRIPT_DIR/opencode-vpn-macos"
VPN_MACOS_DST="$PREFIX/vpn-macos"
WRAPPER_DST="$PREFIX/opencode-vpn-macos"

echo "[..] opencode-vpn macOS local-VPN setup (prefix=$PREFIX)"
[ "$CHECK" -eq 1 ] && echo "[..] --check mode: verifying only, changing nothing"

# --------------------------------------------------------------------------
# 1. Preconditions: must be macOS; need curl
# --------------------------------------------------------------------------
echo "[..] step 1/7: preconditions"
if [ "$(uname -s)" != "Darwin" ]; then
    die "not macOS (uname: $(uname -s)); for the Linux server use setup-ubuntu.sh"
fi
need_cmd curl
MACOS_VER="$(sw_vers -productVersion 2>/dev/null || echo unknown)"
ARCH="$(uname -m)"
log "macOS $MACOS_VER ($ARCH)"

# --------------------------------------------------------------------------
# 2. opencode binary must exist locally (never auto-install it)
# --------------------------------------------------------------------------
echo "[..] step 2/7: opencode binary"
if command -v opencode >/dev/null 2>&1; then
    ok "opencode found: $(command -v opencode)"
elif [ -x "$HOME/.opencode/bin/opencode" ]; then
    ok "opencode found: $HOME/.opencode/bin/opencode"
else
    warn "opencode binary not found on PATH or at \$HOME/.opencode/bin/opencode"
    [ "$CHECK" -eq 1 ] && FAILURES=$((FAILURES + 1))
    echo "[..] upstream install hint (run it yourself, then re-run this script):"
    echo "[..]   curl -fsSL https://opencode.ai/install | bash"
fi

# --------------------------------------------------------------------------
# 3. Install openvpn via Homebrew if missing
# --------------------------------------------------------------------------
echo "[..] step 3/7: openvpn"
find_openvpn() {
    if command -v openvpn >/dev/null 2>&1; then
        command -v openvpn
    elif [ -x /opt/homebrew/sbin/openvpn ]; then
        echo /opt/homebrew/sbin/openvpn
    elif [ -x /opt/homebrew/bin/openvpn ]; then
        echo /opt/homebrew/bin/openvpn
    elif [ -x /usr/local/sbin/openvpn ]; then
        echo /usr/local/sbin/openvpn
    elif [ -x /usr/local/bin/openvpn ]; then
        echo /usr/local/bin/openvpn
    else
        return 1
    fi
}
if OPENVPN_BIN="$(find_openvpn)"; then
    ok "openvpn found: $OPENVPN_BIN"
elif ! command -v brew >/dev/null 2>&1; then
    die "openvpn and brew both missing; install Homebrew first: https://brew.sh"
else
    if [ "$CHECK" -eq 1 ]; then
        warn "openvpn not installed (run without --check to install via brew)"
        FAILURES=$((FAILURES + 1))
    elif [ "$ASSUME_YES" -eq 1 ] || confirm "openvpn missing. Install via 'brew install openvpn'?"; then
        log "brew install openvpn ..."
        brew install openvpn
        OPENVPN_BIN="$(find_openvpn)" || die "brew install finished but openvpn still not found"
        ok "openvpn installed: $OPENVPN_BIN"
    else
        die "openvpn is required; install it: brew install openvpn"
    fi
fi

# --------------------------------------------------------------------------
# 4. Install VPN profiles to ~/.config/opencode-vpn/profiles/
# --------------------------------------------------------------------------
echo "[..] step 4/7: VPN profiles -> $PROFILES_DST"
if [ ! -d "$SCRIPT_DIR/profiles" ]; then
    die "profiles/ not found in repo (run from the repo checkout)"
fi
if [ "$CHECK" -eq 1 ]; then
    if [ -d "$PROFILES_DST" ] && ls "$PROFILES_DST"/vpn* >/dev/null 2>&1; then
        ok "profiles present: $(ls "$PROFILES_DST" | tr '\n' ' ')"
    else
        warn "profiles not installed yet (run without --check to install)"
        FAILURES=$((FAILURES + 1))
    fi
else
    mkdir -p "$PROFILES_DST"
    cp -R "$SCRIPT_DIR/profiles/"vpn* "$PROFILES_DST/" 2>/dev/null || true
    if ls "$PROFILES_DST"/vpn* >/dev/null 2>&1; then
        ok "profiles installed: $(ls "$PROFILES_DST" | tr '\n' ' ')"
    else
        die "no profiles copied from $SCRIPT_DIR/profiles"
    fi
fi

# --------------------------------------------------------------------------
# 5. Credentials (create only, never print)
# --------------------------------------------------------------------------
echo "[..] step 5/7: credentials -> $AUTH_FILE"
if [ -f "$AUTH_FILE" ]; then
    ok "credentials already present: $AUTH_FILE"
else
    if [ "$CHECK" -eq 1 ]; then
        warn "credentials missing: $AUTH_FILE (run without --check to create)"
        FAILURES=$((FAILURES + 1))
    elif [ "$ASSUME_YES" -eq 1 ]; then
        die "credentials missing; create manually: printf 'USER\\nPASS\\n' > $AUTH_FILE && chmod 600 $AUTH_FILE"
    else
        log "NordVPN credentials (service username/password, NOT your account login)"
        secret_prompt "VPN username" VPN_USER
        secret_prompt "VPN password" VPN_PASS
        mkdir -p "$CONFIG_DIR"
        _old_umask="$(umask)"
        umask 077
        printf '%s\n%s\n' "$VPN_USER" "$VPN_PASS" > "$AUTH_FILE"
        umask "$_old_umask"
        unset _old_umask
        chmod 600 "$AUTH_FILE"
        unset VPN_USER VPN_PASS
        ok "credentials saved (chmod 600): $AUTH_FILE"
    fi
fi

# --------------------------------------------------------------------------
# 6. Install vpn-macos + opencode-vpn-macos into $PREFIX
# --------------------------------------------------------------------------
echo "[..] step 6/7: install scripts -> $PREFIX"
for src in "$VPN_MACOS_SRC" "$WRAPPER_SRC"; do
    [ -f "$src" ] || die "source missing: $src (run from the repo checkout)"
done
if [ "$CHECK" -eq 1 ]; then
    for dst in "$VPN_MACOS_DST" "$WRAPPER_DST"; do
        if [ -x "$dst" ]; then
            ok "present and executable: $dst"
        else
            warn "not installed yet: $dst (run without --check to install)"
            FAILURES=$((FAILURES + 1))
        fi
    done
else
    mkdir -p "$PREFIX"
    cp "$VPN_MACOS_SRC" "$VPN_MACOS_DST"
    cp "$WRAPPER_SRC" "$WRAPPER_DST"
    chmod +x "$VPN_MACOS_DST" "$WRAPPER_DST"
    ok "installed: $VPN_MACOS_DST"
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
# 7. Optional end-to-end: start a test tunnel (interactive only)
# --------------------------------------------------------------------------
echo "[..] step 7/7: tunnel test"
if [ "$CHECK" -eq 1 ]; then
    log "--check: skipping tunnel start (verify manually: sudo vpn-macos --vpn1)"
elif [ ! -x "$VPN_MACOS_DST" ]; then
    warn "vpn-macos not installed; skipping tunnel test"
elif [ ! -f "$AUTH_FILE" ]; then
    warn "credentials missing; skipping tunnel test"
else
    if [ "$ASSUME_YES" -eq 1 ]; then
        log "non-interactive: skipping tunnel start (start manually: sudo vpn-macos --vpn1)"
    elif confirm "Start a test tunnel now on vpn1? (requires sudo)"; then
        if sudo "$VPN_MACOS_DST" --vpn1; then
            ok "test tunnel is UP"
            "$WRAPPER_DST" --ip || true
        else
            warn "tunnel test failed; see $CONFIG_DIR/openvpn.log"
            echo "[..] troubleshoot: sudo vpn-macos --vpn1 ; tail -f $CONFIG_DIR/openvpn.log"
        fi
    else
        log "skipped; start one later: sudo vpn-macos --vpn1"
    fi
fi

# --------------------------------------------------------------------------
# Done: usage
# --------------------------------------------------------------------------
echo ""
if [ "$CHECK" -eq 1 ]; then
    if [ "$FAILURES" -gt 0 ]; then
        echo "[!!] check found $FAILURES missing item(s) — see warnings above."
        exit 1
    fi
    echo "[ok] check passed: everything is in place."
else
    echo "[ok] macOS local-VPN setup complete."
fi
echo "[..] start/switch tunnel:   sudo vpn-macos --vpn2        (independent profile)"
echo "[..] tunnel status:         vpn-macos --status"
echo "[..] stop tunnel:           vpn-macos --stop"
echo "[..] launch opencode:       opencode-vpn-macos           (uses running tunnel)"
echo "[..] launch + switch:       opencode-vpn-macos --vpn3    (switch local profile first)"
echo "[..] profiles available:    vpn-macos --list"
echo "[..] logs:                  tail -f $CONFIG_DIR/openvpn.log"
echo "[..] NOTE: this Mac's tunnel is fully local and independent — no other"
echo "[..]       machine is contacted at any point."

#!/usr/bin/env bash
#
# setup-ubuntu.sh - turn a FRESH Ubuntu 22.04/24.04 server (Hetzner-like)
# into a working opencode-vpn host.
#
# Run AS ROOT from a checkout of the opencode-vpn repo:
#   sudo ./setup-ubuntu.sh [--profile vpn1] [-y]
#   sudo ./setup-ubuntu.sh --check
#
# Idempotent: safe to re-run. Never touches ufw or Docker rules.
# Secrets are never printed (no set -x, no echo of credentials).
set -euo pipefail

ASSUME_YES="${ASSUME_YES:-0}"
CHECK=0
PROFILE="vpn1"

usage() {
    cat <<'EOF'
usage: setup-ubuntu.sh [-y|--yes] [--check] [--profile vpnN] [-h|--help]

  -y, --yes        non-interactive; VPN creds REQUIRED from env
                   VPN_AUTH_USER / VPN_AUTH_PASS (dies if missing)
  --check          verify-only: run all checks, change nothing, exit 0/1
  --profile vpnN   profile for initial state file + first test (default vpn1)
  -h, --help       show this help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes) ASSUME_YES=1; shift ;;
        --check) CHECK=1; shift ;;
        --profile)
            [ $# -ge 2 ] || { echo "[!!] --profile needs a value" >&2; exit 2; }
            PROFILE="$2"; shift 2 ;;
        --profile=*) PROFILE="${1#--profile=}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "[!!] unknown flag: $1" >&2; usage; exit 2 ;;
    esac
done

case "$PROFILE" in
    vpn[0-9]*) ;;
    *) echo "[!!] bad --profile '$PROFILE' (want vpnN)" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/common.sh"
cd "$SCRIPT_DIR"

SRC=/root/vpn-netns
BIN=/usr/local/bin
AUTH_FILE=/etc/openvpn/client/auth.txt
STATE_FILE=/etc/openvpn/client/current

# --- verify (also used by --check): PASS/FAIL lines, nonzero on any fail ----
verify_all() {
    local fail=0 tun="" ns_ip="" host_ip="" proxy_ip="" policy=""
    echo "[..] verify: tun0 present in vpn namespace"
    tun="$(ip netns exec vpn ip -brief addr show tun0 2>/dev/null || true)"
    case "$tun" in
        tun0*) echo "[ok] PASS: tun0 present ($tun)" ;;
        *) echo "[!!] FAIL: no tun0 in vpn namespace"; fail=1 ;;
    esac

    echo "[..] verify: namespace exit IP differs from host exit IP"
    ns_ip="$(ip netns exec vpn curl -s --max-time 12 https://ifconfig.me 2>/dev/null || true)"
    host_ip="$(curl -4 -s --max-time 10 https://ifconfig.me 2>/dev/null || true)"
    if [ -n "$ns_ip" ] && [ -n "$host_ip" ] && [ "$ns_ip" != "$host_ip" ]; then
        echo "[ok] PASS: ns exit $ns_ip != host exit $host_ip"
    else
        echo "[!!] FAIL: ns exit '${ns_ip:-empty}' vs host exit '${host_ip:-empty}'"; fail=1
    fi

    echo "[..] verify: kill-switch OUTPUT policy is DROP in ns"
    policy="$(ip netns exec vpn iptables -S OUTPUT 2>/dev/null | head -n 1 || true)"
    case "$policy" in
        "-P OUTPUT DROP") echo "[ok] PASS: OUTPUT policy DROP" ;;
        *) echo "[!!] FAIL: OUTPUT policy is '${policy:-unknown}'"; fail=1 ;;
    esac

    echo "[..] verify: proxy exit equals ns exit"
    proxy_ip="$(curl -s --max-time 10 -x http://10.200.1.2:8888 https://ifconfig.me 2>/dev/null || true)"
    if [ -n "$proxy_ip" ] && [ -n "$ns_ip" ] && [ "$proxy_ip" = "$ns_ip" ]; then
        echo "[ok] PASS: proxy exit $proxy_ip matches ns exit"
    else
        echo "[!!] FAIL: proxy exit '${proxy_ip:-empty}' vs ns exit '${ns_ip:-empty}'"; fail=1
    fi
    return "$fail"
}

print_next_steps() {
    echo "[..] next steps:"
    echo "  vpn-start --list                 # available profiles"
    echo "  sudo vpn-start --vpn2 --daemon   # switch profile (example)"
    echo "  opencode-vpn                     # launch OpenCode inside the VPN"
    if [ -x /root/.opencode/bin/opencode ]; then
        echo "[ok] opencode binary found at /root/.opencode/bin/opencode"
    else
        warn "no /root/.opencode/bin/opencode found; adjust opencode-vpn to your install path"
    fi
}

# --- 1. preconditions: Ubuntu + root + tools + real NIC ----------------------
echo "[..] 1/11 preconditions"
[ "$(id -u)" -eq 0 ] || die "run as root"
grep -qi 'ubuntu' /etc/os-release 2>/dev/null || die "not an Ubuntu host"
VER="$(grep '^VERSION_ID=' /etc/os-release | cut -d'"' -f2)"
case "$VER" in
    22.04|24.04) log "Ubuntu $VER" ;;
    *) warn "untested Ubuntu $VER (expect 22.04/24.04), continuing" ;;
esac
need_cmd ip
need_cmd iptables
need_cmd sysctl
need_cmd systemctl
NIC="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
if [ -n "$NIC" ]; then
    log "default-route NIC: $NIC"
else
    warn "no default route found; skipping NIC adaptation later"
fi

if [ "$CHECK" = 1 ]; then
    echo "[..] --check: verify-only, changing nothing"
    verify_all
    exit $?
fi

confirm "Install opencode-vpn on this host (profile=$PROFILE)?"

# --- 2. packages: update + install only what is missing ---------------------
echo "[..] 2/11 packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update
for pkg in openvpn iptables iproute2 curl tinyproxy; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
        log "$pkg already installed"
    else
        log "installing $pkg"
        apt-get install -y "$pkg"
    fi
done
echo "[ok] packages ready (ufw/Docker untouched)"

# --- 3. lay out files (merge, never delete server-only extras) --------------
echo "[..] 3/11 files"
[ -f ./vpn-create ] || die "missing ./vpn-create (run from repo checkout)"
[ -f ./vpn-start ] || die "missing ./vpn-start (run from repo checkout)"
[ -f ./vpn-killswitch ] || die "missing ./vpn-killswitch (run from repo checkout)"
[ -f ./opencode-vpn ] || die "missing ./opencode-vpn (run from repo checkout)"
[ -f ./openvpn-netns.service ] || die "missing ./openvpn-netns.service"
[ -f ./vpn-proxy.service ] || die "missing ./vpn-proxy.service"
[ -f ./tinyproxy-netns.conf ] || die "missing ./tinyproxy-netns.conf"
[ -d "./profiles/$PROFILE" ] || die "missing ./profiles/$PROFILE"
mkdir -p /root/vpn-netns/profiles /etc/openvpn/client /etc/netns/vpn \
    /var/log/tinyproxy /run/tinyproxy
for f in vpn-create vpn-start vpn-killswitch opencode-vpn; do
    cp "./$f" "$SRC/$f"
done
chmod +x "$SRC/vpn-create" "$SRC/vpn-start" "$SRC/vpn-killswitch" "$SRC/opencode-vpn"
cp ./openvpn-netns.service ./vpn-proxy.service ./tinyproxy-netns.conf "$SRC/"
cp -a ./profiles/. "$SRC/profiles/"
for doc in AGENTS.md README.md; do
    [ -f "./$doc" ] && cp "./$doc" "$SRC/$doc"
done
ln -sf "$SRC/vpn-create" "$BIN/vpn-create"
ln -sf "$SRC/vpn-start" "$BIN/vpn-start"
ln -sf "$SRC/vpn-killswitch" "$BIN/vpn-killswitch"
ln -sf "$SRC/opencode-vpn" "$BIN/opencode-vpn"
echo "[ok] files in place, symlinks linked"

# --- 4. adapt installed vpn-create HOST_IF to detected NIC ------------------
echo "[..] 4/11 NIC adaptation"
if [ -n "$NIC" ]; then
    CUR="$(grep -E '^HOST_IF=' "$SRC/vpn-create" | cut -d= -f2)"
    if [ "$CUR" = "$NIC" ]; then
        log "HOST_IF already $NIC, skipping"
    else
        sed -i "s/^HOST_IF=.*/HOST_IF=$NIC/" "$SRC/vpn-create"
        log "HOST_IF: ${CUR:-empty} -> $NIC"
    fi
else
    warn "no default-route NIC; leaving HOST_IF as-is"
fi

# --- 5. namespace DNS (create only, never overwrite) -------------------------
echo "[..] 5/11 DNS"
if [ -f /etc/netns/vpn/resolv.conf ]; then
    log "/etc/netns/vpn/resolv.conf exists, leaving untouched"
else
    printf 'nameserver 185.12.64.1\nnameserver 185.12.64.2\nnameserver 1.1.1.1\n' \
        > /etc/netns/vpn/resolv.conf
    log "wrote /etc/netns/vpn/resolv.conf"
fi

# --- 6. credentials (create only, never print) -------------------------------
echo "[..] 6/11 credentials"
if [ -f "$AUTH_FILE" ]; then
    log "$AUTH_FILE exists, touching nothing"
else
    if [ "$ASSUME_YES" = 1 ]; then
        [ -n "${VPN_AUTH_USER:-}" ] || die "missing env VPN_AUTH_USER (-y mode)"
        [ -n "${VPN_AUTH_PASS:-}" ] || die "missing env VPN_AUTH_PASS (-y mode)"
        VPN_USER="$VPN_AUTH_USER"
        VPN_PASS="$VPN_AUTH_PASS"
    else
        secret_prompt "VPN username" VPN_USER
        secret_prompt "VPN password" VPN_PASS
        [ -n "${VPN_USER:-}" ] || die "empty username"
        [ -n "${VPN_PASS:-}" ] || die "empty password"
    fi
    printf '%s\n' "$VPN_USER" "$VPN_PASS" > "$AUTH_FILE"
    chmod 600 "$AUTH_FILE"
    chown root:root "$AUTH_FILE"
    unset VPN_USER VPN_PASS
    echo "[ok] wrote $AUTH_FILE (0600 root:root)"
fi

# --- 7. initial state file (create only) -------------------------------------
echo "[..] 7/11 state file"
if [ -f "$STATE_FILE" ]; then
    log "$STATE_FILE exists ($(cat "$STATE_FILE")), leaving untouched"
else
    printf '%s tcp\n' "$PROFILE" > "$STATE_FILE"
    log "initialized $STATE_FILE to '$PROFILE tcp'"
fi

# --- 8. sanity: absolute iptables path + tinyproxy dirs ----------------------
echo "[..] 8/11 sanity"
[ -x /usr/sbin/iptables ] || die "missing /usr/sbin/iptables (vpn-killswitch needs it)"
getent passwd nobody >/dev/null || die "no 'nobody' user (needed by tinyproxy conf)"
getent group nogroup >/dev/null || die "no 'nogroup' group (needed by tinyproxy conf)"
install -d -o nobody -g nogroup /var/log/tinyproxy /run/tinyproxy
echo "[ok] sanity passed"

# --- 9. units + enable + wait for tunnel, then proxy -------------------------
echo "[..] 9/11 services"
cp "$SRC/openvpn-netns.service" /etc/systemd/system/openvpn-netns.service
cp "$SRC/vpn-proxy.service" /etc/systemd/system/vpn-proxy.service
systemctl daemon-reload
systemctl enable --now openvpn-netns
echo "[..] waiting for tunnel (up to 90s)"
TUN_UP=0
for i in $(seq 1 90); do
    if systemctl is-active --quiet openvpn-netns 2>/dev/null \
        && ip netns exec vpn ip -brief addr show tun0 2>/dev/null | grep -q "tun0"; then
        TUN_UP=1
        break
    fi
    sleep 1
done
if [ "$TUN_UP" = 1 ]; then
    echo "[ok] tunnel is up"
else
    warn "tunnel not up after 90s (check: systemctl status openvpn-netns)"
    if [ -x "$SRC/opencode-bypass" ]; then
        warn "temp fallback present: $SRC/opencode-bypass works without openvpn; use it until the tunnel is back"
    fi
fi
systemctl enable --now vpn-proxy
echo "[ok] services enabled"

# --- 10. verify --------------------------------------------------------------
echo "[..] 10/11 verify"
RC=0
verify_all || RC=$?

# --- 11. next steps ----------------------------------------------------------
echo "[..] 11/11 done"
print_next_steps
exit "$RC"

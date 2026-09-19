#!/usr/bin/env bash
set -euo pipefail

# Deploy the opencode-vpn repo to the Hetzner server and install it there.
# Idempotent: safe to re-run. Run from the repo checkout (local machine):
#   ./deploy.sh
#
# What it does:
#   1. rsyncs the repo (scripts, profiles, unit, docs) to /root/vpn-netns/
#      WITHOUT --delete, so server-only files survive:
#      - profiles/backup-2026-08-12/ (old configs)
#      - opencode-bypass (temporary proxy wrapper, holds creds — never in repo)
#   2. chmod +x scripts, installs /usr/local/bin symlinks
#   3. installs the systemd unit, daemon-reload, enable --now
#      (no-op when the service is already active -> no restart)
#   4. verifies the whole deployment

SERVER=root@88.99.250.99
SRC=/root/vpn-netns
BIN=/usr/local/bin

echo "== 1/4 syncing repo to $SERVER:$SRC/"
rsync -az --no-perms \
    --exclude '.git' --exclude 'deploy.sh' \
    ./ "$SERVER:$SRC/"

echo "== 2/4 remote: chmod + symlinks + unit + enable"
ssh "$SERVER" "set -e
  chmod +x $SRC/vpn-start $SRC/vpn-create $SRC/vpn-killswitch $SRC/opencode-vpn $SRC/vpn-rotate $SRC/vpn-add
  ln -sf $SRC/vpn-start      $BIN/vpn-start
  ln -sf $SRC/vpn-create     $BIN/vpn-create
  ln -sf $SRC/vpn-killswitch $BIN/vpn-killswitch
  ln -sf $SRC/opencode-vpn   $BIN/opencode-vpn
  ln -sf $SRC/vpn-rotate     $BIN/vpn-rotate
  ln -sf $SRC/vpn-add        $BIN/vpn-add
  [ -e $SRC/opencode-bypass ] && ln -sf $SRC/opencode-bypass $BIN/opencode-bypass || true
  cp $SRC/openvpn-netns.service /etc/systemd/system/openvpn-netns.service
  cp $SRC/vpn-proxy.service /etc/systemd/system/vpn-proxy.service
  command -v tinyproxy >/dev/null || (apt-get update -qq && apt-get install -y -qq tinyproxy)
  systemctl daemon-reload
  systemctl enable --now openvpn-netns
  systemctl enable --now vpn-proxy"

echo "== 3/4 remote: deployment state"
ssh "$SERVER" '
  echo "--- /usr/local/bin symlinks:"
  ls -l '"$BIN"'/vpn-start '"$BIN"'/vpn-create '"$BIN"'/vpn-killswitch '"$BIN"'/opencode-vpn '"$BIN"'/vpn-rotate '"$BIN"'/vpn-add
  echo "--- unit identical to repo:"
  cmp -s /etc/systemd/system/openvpn-netns.service '"$SRC"'/openvpn-netns.service && echo OK
  echo "--- service:"
  systemctl is-enabled openvpn-netns; systemctl is-active openvpn-netns
  systemctl is-enabled vpn-proxy; systemctl is-active vpn-proxy
  echo "--- state file: $(cat /etc/openvpn/client/current 2>/dev/null || echo missing)"'

echo "== 4/4 remote: health"
ssh "$SERVER" "
  echo -n 'ns exit IP: '; ip netns exec vpn curl -s --max-time 12 ifconfig.me; echo
  echo -n 'host exit : '; curl -4 -s --max-time 10 ifconfig.me; echo
  echo -n 'tun0      : '; ip netns exec vpn ip -brief addr show tun0 2>&1 | head -1
  echo 'killswitch OUTPUT policy:'; ip netns exec vpn iptables -L OUTPUT -n | head -2
  echo -n 'proxy exit : '; curl -s --max-time 8 -x http://10.200.1.2:8888 ifconfig.me 2>/dev/null; echo ' (must match ns exit IP)'"

echo "== deploy complete"
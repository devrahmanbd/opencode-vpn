# OpenCode over OpenVPN via Network Namespace (no Docker)

## Goal

Run **only OpenCode** through a NordVPN tunnel, while everything else on the
host (SSH, nginx, Docker containers, etc.) keeps using Hetzner's normal
network. The SSH session can never end up inside the VPN.

**No Docker is involved.** OpenCode runs as a plain process inside a Linux
network namespace. It keeps full, unrestricted access to the host filesystem
(/opt, /etc, /root, ...) — only its *network* is isolated. This avoids all
the file-mount pain of containerizing OpenCode.

## Idea (from the original proposal)

```
                 Hetzner Public Internet
                         │
                  enp0s31f6 (host)
                         │
        ┌────────────────┴────────────────┐
        │                                 │
   SSH / nginx / Docker              veth-host (10.200.1.1)
   normal routing                        │
                                   veth-vpn (10.200.1.2)
                                        │
                             Network Namespace "vpn"
                                        │
                                 OpenVPN (tun0)
                                        │
                                   OpenCode
```

- A veth pair bridges the host to a network namespace.
- The namespace's default route points at the host (10.200.1.1), which
  NATs/MASQUERADEs non-VPN traffic out the real interface.
- OpenVPN runs *inside* the namespace and creates tun0 there. Once the
  tunnel is up, all namespace traffic (except the OpenVPN control channel)
  exits via tun0 → VPN server.
- The host namespace is completely untouched: no routes, no default gateway
  changes, SSH and everything else keep working normally.

## Server-specific facts (Ubuntu 24.04, Hetzner dedicated)

- Host interface: **`enp0s31f6`** (guide said eth0 — wrong for this box).
- Host IP: 88.99.250.99, gateway 88.99.250.65 (onlink).
- `net.ipv4.ip_forward` already = 1.
- **Docker is active** on the host (many bridges). It sets `FORWARD` policy
  to DROP and installs `DOCKER-USER` / `DOCKER-FORWARD` / ufw chains. Our
  rules are appended at the end of `FORWARD`/`POSTROUTING`, so packets fall
  through Docker/ufw chains and hit ours before the DROP policy. Verified
  working.
- **ufw is active** (SSH allowed only). No changes to ufw needed.
- `resolvconf` package is **not needed** on 24.04 — `/etc/netns/vpn/resolv.conf`
  is honored by glibc directly.

## NordVPN configs / profiles (in /root/vpn-netns/profiles/)

| Profile | Location | tcp config | udp config |
|---|---|---|---|
| vpn1 | US us13883 | vpn1/tcp.ovpn (187.15.91.5:80, tls-crypt) | vpn1/udp.ovpn (187.15.91.5:53, tls-crypt) |
| vpn2 | UK uk2613 | vpn2/tcp.ovpn (194.35.235.170:80, tls-crypt) | vpn2/udp.ovpn (194.35.235.170:53, tls-crypt) |
| vpn3 | BD bd3 | vpn3/tcp.ovpn (187.14.255.1:80, tls-crypt) | vpn3/udp.ovpn (187.14.255.1:53, tls-crypt) |

- 2026-08-12: profiles replaced with NordVPN 2.6-generation configs
  (tls-crypt inline, verify-x509-name) — `vpn-start` auto-parses `remote`
  for the kill switch, no script changes needed. Previous configs (us11612
  tls-auth, uk6071/bd4) backed up in `/root/vpn-netns/profiles/backup-2026-08-12/`.
- Old /root/*.ovpn files (us11612/us13889/us13893 UDP) are dead on this
  network (outbound UDP blocked) — kept only as reference.
- All use `auth-user-pass` → credentials supplied via `--auth-user-pass
  /etc/openvpn/client/auth.txt`.
- CA cert + tls-crypt/tls-auth key are **inline** in the .ovpn → no separate
  ca.crt/client.crt/client.key files needed.
- No IPv6 in the configs; the namespace is IPv4-only. Fine for our use.

## Credentials (user-supplied, kept root-only)

- Username: `8L5BioUH4Pkk54rSVwz8xxCz`
- Password: `akyG3hwN3LsLfXi3rP3xRr1R`

Stored in `/etc/openvpn/client/auth.txt` (chmod 600). **Never commit or log
this file.**

## Files & layout

| Path | Purpose |
|---|---|
| `/root/vpn-netns/AGENTS.md` | This document (the idea) |
| `/root/vpn-netns/profiles/` | Per-VPN configs: `vpnN.tcp.ovpn` + `vpnN.udp.ovpn` (see table above) |
| `/etc/openvpn/client/client.ovpn` | Original NordVPN UDP config (kept as reference, unusable here) |
| `/etc/openvpn/client/client-tcp.ovpn` | Original working TCP config (vpn1, ports 1231-1234) |
| `/etc/openvpn/client/auth.txt` | Credentials (0600) |
| `/etc/openvpn/client/current` | State file: `vpnN tcp\|udp` of the last working connection |
| `/etc/netns/vpn/resolv.conf` | DNS for the vpn namespace (Hetzner resolvers + 1.1.1.1) |
| `/usr/local/bin/vpn-create` | Idempotent netns + veth + NAT/forwarding setup |
| `/usr/local/bin/vpn-start` | Pick profile, fallback tcp→udp, run openvpn inside the ns (foreground) |
| `/usr/local/bin/vpn-killswitch` | Kill-switch iptables rules *inside* the ns (auto via --up) |
| `/usr/local/bin/opencode-vpn` | `sudo ip netns exec vpn opencode "$@"` (absolute path) |
| `/etc/systemd/system/openvpn-netns.service` | Auto-start unit (active); re-reads state file |
| `/etc/systemd/system/vpn-proxy.service` | tinyproxy inside the ns for macOS clients (BindsTo tunnel) |
| `/root/vpn-netns/tinyproxy-netns.conf` | Proxy listens 10.200.1.2:8888, Allow veth subnet only |
| `opencode-vpn-macos` (repo + `~/.local/bin` on Mac) | SSH-forward proxy to local opencode, fail-closed exit-IP check; flags: `--vpnN` (switch server profile + wait), `--ip` (print exits), `--list` |
| `setup.sh` / `setup-ubuntu.sh` / `setup-macos.sh` / `lib/common.sh` | Dynamic installer: dispatcher + Ubuntu server + macOS client + shared helpers |

## Execution log

- 2026-08-02: folder + this doc created; openvpn installed; config copied;
  scripts written; namespace started; tunnel verified
  (namespace curl → VPN exit IP, host curl → 88.99.250.99).
- 2026-08-03..05: multi-profile switching (vpn1/vpn2/vpn3), tcp→udp fallback,
  `--daemon` + systemd unit, exit-IP checks for all profiles, 2.6-config
  switch prep (NordVPN config deprecations), unused-service cleanup planning
  removed from scope (user: no dup scripts).
- 2026-08-12..13: profiles swapped to 2.6-generation configs
  (us13883/uk2613/bd3; old ones in backup-2026-08-12/); root-caused
  self-sustaining AUTH_FAILED loop → AUTH_RETRY_DELAY 10→60s; temporary
  opencode-bypass wrapper created while auth settled; all three profiles
  re-verified over TCP, default vpn1.
- See below for the current verification output when it exists.

## Findings during bring-up (2026-08-02) — READ BEFORE CHANGING THINGS

1. **Outbound UDP is blocked from this server's network** (verified: UDP to
   1.1.1.1:12345 and to the NordVPN server:53 both time out; UDP to Hetzner's
   own DNS 213.133.98.98:53 works). Therefore the stock NordVPN **UDP**
   configs (`proto udp`, `remote <ip> 53`) can never connect. Also note
   NordVPN's UDP configs use port 53, which is doubly dead here.
2. **Use the official NordVPN TCP config** (ports 1231-1234, `remote-random`):
   `/etc/openvpn/client/client-tcp.ovpn` was downloaded from
   `https://downloads.nordcdn.com/configs/files/ovpn_tcp/servers/us11612.nordvpn.com.tcp.ovpn`.
   It uses `<tls-auth>` + `key-direction 1` (older-generation config), NOT
   tls-crypt like the UDP files. Port 443 on those server IPs is NOT an
   OpenVPN endpoint (connects then RSTs).
3. **`--script-security 2` is mandatory** on the command line, otherwise
   OpenVPN 2.6 refuses the `--up` kill-switch script and dies right after
   configuring tun0 ("disallowed by script-security setting").
4. **DNS for the namespace**: `/etc/netns/vpn/resolv.conf` currently lists
   Hetzner resolvers (185.12.64.1/2, UDP-reachable) plus 1.1.1.1. Once the
   tunnel is up, DNS goes via tun0 anyway. `resolvconf` package is NOT
   needed on Ubuntu 24.04.
5. **Kill switch** (applied by `--up`): OUTPUT policy DROP; allow lo, tun0,
   the current profile's server (read from `/etc/openvpn/client/killswitch.env`,
   written by vpn-start — OpenVPN does NOT forward custom env vars to --up
   scripts), and 10.200.1.1. INPUT policy DROP; allow lo, ESTABLISHED,
   10.200.1.0/24→tcp/443 (edge OpenResty) and 10.200.1.0/24→tcp/8888
   (tinyproxy for macOS clients — without this the SSH-forwarded proxy is
   unreachable). It runs inside the namespace (OpenVPN child
   processes inherit the netns). **Leftover rules from a previous connection
   block the next switch** — vpn-start flushes the namespace firewall before
   each attempt.
6. **NordVPN AUTH_FAILED on quick switches**: killing a live tunnel and
   reconnecting immediately gets `AUTH_FAILED` because the server holds the
   old session for up to ~1 min. vpn-start detects it and retries the same
   proto (8 attempts, 10s apart) before falling back to the other proto.
7. **Docker coexistence**: host FORWARD policy is DROP (Docker); our rules
   are appended and packets fall through Docker/ufw chains to them. Verified
   working — do not `-I` our rules ahead of DOCKER-USER.
8. **`pkill -f "openvpn"` kills your own shell** if the shell command line
   contains the pattern — use `pkill -x openvpn` instead.
9. **opencode-vpn** uses the absolute binary path
   (`/root/.opencode/bin/opencode`) because sudo's secure_path does not
   include /root/.opencode/bin.

## Current status (2026-08-13)

- Tunnel: UP via systemd (`openvpn-netns`), auto-starts on boot,
  `Restart=always`.
- ALL THREE profiles verified working with the 2.6 configs (2026-08-13):
  vpn1 → 187.15.91.x (US), vpn2 → 194.35.235.x (UK), vpn3 → 187.14.255.x (BD);
  all connect over TCP within seconds. Default = vpn1.
- Multi-profile switching: `vpn-start --vpn1|--vpn2|--vpn3`; tcp→udp fallback;
  the proto that connects is saved to `/etc/openvpn/client/current` and
  re-read by the service on boot/restart.
- Namespace exit IP: 187.15.91.x (NordVPN US), host exit IP: 88.99.250.99.
- **AUTH_RETRY_DELAY=60** (was 10): each rejected attempt itself creates a
  new session NordVPN holds ~1 min, so fast retries NEVER work — the loop
  keeps failing. 60s lets the old session expire first.
- **Restart storm lesson**: rapid-fire `vpn-start --vpnN --daemon` +
  `systemctl restart` from parallel SSH commands, plus a foreground vpn-start
  left orphaned by an aborted terminal (triggering its PPID guard that stops
  the service), caused repeated restarts with state-file flips. Harmless to
  the host, but wait for one attempt to finish before issuing the next.
- **Temporary proxy bypass**: user-supplied proxy creds live in
  `/root/vpn-netns/opencode-bypass` (chmod 700; symlinked as
  `opencode-bypass`) so LLM traffic works while NordVPN auth settles. DELETE
  once the VPN is the only path.
- **Why**: LLM providers see the egress IP of OpenCode's API connections;
  the Hetzner datacenter IP can trigger trial restrictions. The VPN exit IP
  avoids that.
- **Decision (user, 2026-08-02)**: keep `opencode-vpn` as a SEPARATE binary;
  plain `opencode` stays untouched (the user may need the original
  non-VPN launcher sometimes). No alias, no binary replacement.

## Verification procedure

```bash
# 1. tunnel up?
ip netns exec vpn ip -brief addr show tun0      # tun0 with 10.100.0.2/20
ip netns exec vpn ip route get 1.1.1.1          # → via 10.100.0.1 dev tun0

# 2. isolation (the money test)
ip netns exec vpn curl -s ifconfig.me            # → NordVPN exit IP
curl -4 -s ifconfig.me                           # → 88.99.250.99 (host)

# 3. profile switch
vpn-start --list                                # available profiles
vpn-start --vpn2                                # switch to UK, foreground
ip netns exec vpn curl -s ifconfig.me           # → UK exit IP
cat /etc/openvpn/client/current                 # e.g. "vpn2 tcp"

# 4. SSH unaffected
ss -tlnp | grep :22                              # still listening on host

# 5. kill switch (present automatically after --up)
ip netns exec vpn iptables -L OUTPUT -n -v       # policy DROP, only lo/tun0/<server>/10.200.1.1
```

Current verified state (2026-08-02): ns curl → 94.156.149.200,
host curl → 88.99.250.99, SSH OK, opencode-vpn OK.

## Operate

```bash
sudo vpn-start --vpn2       # switch to profile vpn2, foreground; falls back
                            # tcp→udp; saves the working proto as default
sudo vpn-start --vpn2 --daemon   # switch AND keep running detached via systemd
opencode-vpn                # launch OpenCode inside the VPN
```

- Foreground `vpn-start` dies with the terminal (`nohup ... &` keeps it alive
  but with no auto-restart). Use `--daemon` for a persistent tunnel:
  saves the choice to `/etc/openvpn/client/current`, restarts the
  `openvpn-netns` service (Restart=always, survives crash/reboot).
- `--daemon` delegates to systemd, so it also works from a script/ssh
  one-liner without holding the session.

## Notes / pitfalls

- `vpn-create` is idempotent (safe to re-run; `|| true` everywhere).
- If the veth pair name already exists from a previous run it is reused.
- The MASQUERADE rule targets `-o enp0s31f6` — adapt if the host NIC name
  changes.
- Restarting OpenVPN later: kill the old process, re-run `vpn-start`.
- `ip netns exec` requires root → wrapper uses sudo; scripts must be root.

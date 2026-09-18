# OpenCode over OpenVPN via Network Namespace (no Docker)

Run **only OpenCode** through a NordVPN tunnel while everything else on the
host (SSH, nginx, Docker containers, etc.) keeps using Hetzner's normal
network. The SSH session can never end up inside the VPN.

OpenCode runs as a plain process inside a Linux network namespace. It keeps
full, unrestricted access to the host filesystem (`/opt`, `/etc`, `/root`,
...), only its *network* is isolated. No Docker, no file-mount pain.

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

## Profiles

Each profile is a folder with a TCP and UDP config. Swap dead configs by
dropping new `.ovpn` files in — no code changes needed.

| Profile | Location | Server (tcp) |
|---|---|---|
| `vpn1` | US us13883 | 187.15.91.5:80 |
| `vpn2` | UK uk2613 | 194.35.235.170:80 |
| `vpn3` | BD bd3 | 187.14.255.1:80 |

Files live in `/root/vpn-netns/profiles/vpnN/{tcp.ovpn,udp.ovpn}`.
Credentials are in `/etc/openvpn/client/auth.txt` (chmod 600, never commit).

## Setup (dynamic installer)

One entry point, detects the OS and runs the right installer:

```bash
./setup.sh              # macOS -> client setup, Ubuntu -> server setup
./setup.sh --check      # verify-only, changes nothing
./setup.sh --help       # all flags
```

- **Ubuntu 22.04/24.04, as root**: installs packages, lays out files, adapts
  to the real NIC, writes resolv.conf, prompts for VPN creds (`auth.txt`,
  0600), enables both units, waits for the tunnel, verifies exit IPs +
  killswitch + proxy. `-y` needs `VPN_AUTH_USER`/`VPN_AUTH_PASS` in env.
- **macOS 13+**: checks ssh key auth + local opencode, installs
  `opencode-vpn-macos` to `~/.local/bin`, probes server services, runs an
  end-to-end proxy test (proxy exit IP == namespace exit IP, fail-closed).

## Deploy (one-time, from the repo checkout)

```bash
./deploy.sh    # sync repo -> server, symlinks, systemd unit, verify
```

Equivalent manual steps (for reference):

```bash
sudo apt install -y openvpn iptables

# scripts -> /usr/local/bin (symlink to /root/vpn-netns)
ln -sf /root/vpn-netns/vpn-start       /usr/local/bin/vpn-start
ln -sf /root/vpn-netns/vpn-create      /usr/local/bin/vpn-create
ln -sf /root/vpn-netns/vpn-killswitch  /usr/local/bin/vpn-killswitch
ln -sf /root/vpn-netns/opencode-vpn    /usr/local/bin/opencode-vpn

# systemd service (auto-start + auto-restart)
cp /root/vpn-netns/openvpn-netns.service /etc/systemd/system/openvpn-netns.service
systemctl daemon-reload
systemctl enable --now openvpn-netns
```

## Usage

```bash
vpn-start                     # foreground, saved profile (default vpn1 tcp)
vpn-start --vpn2              # switch to UK, foreground (tcp preferred, udp fallback)
vpn-start --vpn3 --udp        # force udp for vpn3
vpn-start --vpn2 --daemon     # switch AND keep running detached via systemd
vpn-start --list              # show available profiles
vpn-start                     # foreground dies with the terminal

opencode-vpn                  # launch OpenCode inside the VPN (on the server)
```

### macOS client (this Mac)

```bash
opencode-vpn-macos              # local opencode, API traffic via the VPN (fail-closed)
opencode-vpn-macos --ip         # just print proxy/tunnel exit IPs, no launch
opencode-vpn-macos --list       # list server profiles (vpn1 US, vpn2 UK, vpn3 BD)
opencode-vpn-macos --vpn2       # switch server to UK, wait for tunnel, then launch
```

Only opencode's traffic goes through the SSH-forwarded proxy
(`127.0.0.1:8888` → `10.200.1.2:8888` in the server netns → tunnel);
everything else on the Mac uses its normal network. The wrapper refuses to
run unless the proxy exit IP matches the namespace exit IP.

The proto that actually connects is saved to `/etc/openvpn/client/current`
(`vpnN tcp|udp`) and re-read by the systemd service on boot/restart.

### Foreground vs daemon

- **Foreground** (`vpn-start --vpn3`): openvpn runs as your process; closes
  when the terminal does. Good for testing a profile.
- **`--daemon`**: saves the choice and delegates to the `openvpn-netns`
  systemd service (`Restart=always`), so the tunnel survives SSH
  disconnects, crashes, and reboots.

## Verify

```bash
ip netns exec vpn curl -s ifconfig.me   # NordVPN exit IP (e.g. 187.13.135.180)
curl -4 -s ifconfig.me                  # host IP, must stay 88.99.250.99
systemctl is-active openvpn-netns       # active
ip netns exec vpn iptables -L OUTPUT -n # killswitch: DROP except lo/tun0/<server>
```

## How it works

- A veth pair bridges the host (10.200.1.1) to the `vpn` namespace
  (10.200.1.2). The namespace's default route points at the host, which
  MASQUERADEs non-VPN traffic out the real NIC.
- OpenVPN runs *inside* the namespace and creates `tun0` there; once up, all
  namespace traffic except the control channel exits via the tunnel.
- A kill switch (iptables inside the namespace, applied via `--up`) drops
  everything except `lo`, `tun0`, the active profile's server, and
  `10.200.1.1` — no fallback to host NAT if the tunnel dies.
- The host namespace is untouched: SSH, nginx, Docker keep working normally.

## Design notes / gotchas

- Outbound UDP is blocked from this server's network — TCP configs are the
  primary; UDP is a fallback.
- NordVPN returns `AUTH_FAILED` for ~1 minute after killing a live session;
  `vpn-start` detects it and retries the same proto before trying the other.
- Stale kill-switch rules from a previous connection would block the next
  server — `vpn-start` flushes the namespace firewall before each attempt.
- OpenVPN does not forward custom env vars to `--up` scripts, so the server
  IP/port for the kill switch is passed via `/etc/openvpn/client/killswitch.env`.
- Use `pkill -x openvpn`, never `pkill -f openvpn` (it matches your own shell).

## Troubleshooting

```bash
systemctl status openvpn-netns          # service state
journalctl -u openvpn-netns -n 50       # openvpn logs
cat /etc/openvpn/client/current         # saved profile + proto
ip netns exec vpn ip route              # tun0 routes present?
```

## Why?

LLM providers see the egress IP of OpenCode's API connections; the Hetzner
datacenter IP can trigger trial restrictions. The VPN exit IP avoids that.

## Author

@devrahmanbd
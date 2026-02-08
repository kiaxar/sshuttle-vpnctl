# sshuttle-vpnctl

A tiny CLI tool that turns an SSH server into a "VPN-like" tunnel using **sshuttle**.

It provides a `vpn` command to:
- start / stop / restart sshuttle in the background
- prevent duplicate runs
- show status
- optionally save and view logs
- install bash completion for subcommands

## How it works

`sshuttle` sets temporary firewall (iptables/nft) redirect rules on your machine so that
outgoing TCP traffic is transparently sent through an SSH connection to your server.
This is why it behaves like a VPN for many applications.

Key points:
- sshuttle needs **root privileges** to manage firewall rules (via `sudo`).
- SSH authentication uses **your user** (so your SSH key works).
- The tool auto-excludes the SSH server IP(s) to prevent the SSH session from being redirected into itself.

## Requirements

- Ubuntu 22.04 (GNOME on X11/Wayland is fine)
- `sshuttle`
- `bash-completion` (optional but recommended)
- SSH access to a server (key-based recommended)

## Install / Setup

Run:

```bash
chmod +x setup.sh
./setup.sh
```

The setup will:
- install sshuttle if missing
- install bash-completion if missing
- create a config file at: `/etc/sshuttle-vpnctl.conf`
- install the `vpn` command to: `/usr/local/bin/vpn`
- install bash completion to: `/etc/bash_completion.d/vpn`

Then open a new terminal (or `source /etc/bash_completion`).

## Configuration

System config:
- `/etc/sshuttle-vpnctl.conf`

Optional user override:
- `~/.config/sshuttle-vpnctl.conf` (same keys, overrides system config)

Example config keys:

- `REMOTE_USER="vpn"`
- `REMOTE_HOST="servers.europe"`
- `SSH_PORT="22"` (optional)
- `SSH_IDENTITY="$HOME/.ssh/id_ed25519"` (optional)
- `SSH_EXTRA_OPTS=""` (optional, e.g. `-o ServerAliveInterval=30 -o ServerAliveCountMax=3`)
- `SUBNETS="0.0.0.0/0"`
- `DNS_FLAG="--dns"` (or empty to disable dns forwarding)
- `STATE_DIR="$HOME/.local/state/vpn-sshuttle"`

## Usage

Start in background:
```bash
vpn start
```

Start and save logs:
```bash
vpn start --force-log
```

Status:
```bash
vpn status
```

Stop:
```bash
vpn stop
```

Restart:
```bash
vpn restart
```

Show log (if enabled):
```bash
vpn log
vpn log -f
```

## Notes / Troubleshooting

### "ssh connection broken pipe"
That usually happens when the tunnel redirects the SSH connection itself.
This tool auto-excludes the server IP(s) by resolving the host via `getent ahosts`.

### "sudo password prompt"
sshuttle must adjust firewall rules. You will be prompted for your local sudo password unless
your sudo is cached.

## Uninstall
```bash
sudo rm -f /usr/local/bin/vpn
sudo rm -f /etc/bash_completion.d/vpn
sudo rm -f /etc/sshuttle-vpnctl.conf
rm -rf ~/.local/state/vpn-sshuttle
```

## Suggested upgrades (optional)
- Add `SSH_EXTRA_OPTS="-o ServerAliveInterval=30 -o ServerAliveCountMax=3"` for stability.
- Add LAN excludes if you want local subnets not to be tunneled.
- Add multi-profile support (e.g., office/home) via multiple config files.

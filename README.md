# gns3-remote-install-redux

Drop-in replacement for the [upstream GNS3 remote installer](https://github.com/GNS3/gns3-server/blob/master/scripts/remote-install.sh). Same job, fewer footguns.

## Why

The original script installs GNS3 on Ubuntu Server. It works. It also:

- Calls `apt` five or six times instead of once
- Fails on one problem at a time (fix, re-run, fix, re-run)
- Doesn't retry anything
- Doesn't verify anything after install
- Uses a system Python wrapper that crashes with `ModuleNotFoundError` on newer packages
- Installs nginx to serve one file
- Has no WireGuard support
- Ships RSA-2048 + DH params (slow, legacy) with `comp-lzo` (deprecated, vulnerable)
- Opens all firewall ports or none

This script fixes all of that.

## What's different

- **Single apt pass** — packages, repos, and groups rolled up from flags before any install runs
- **Preflight** — checks root, OS, commands, ports, modules, CPU virt. Reports everything at once
- **Auto-loads KVM** — `modprobe` + persist to `/etc/modules-load.d/`, unless `--without-kvm`
- **Retry + verify** — apt retries 3x with backoff; services verified with `systemctl is-active`; GNS3 API curled post-install
- **Venv-aware** — detects and uses `/usr/share/gns3/gns3-server/bin/gns3server` instead of the broken `/usr/bin` wrapper
- **WireGuard** — first-class VPN option alongside OpenVPN
- **EC crypto** — P-384 by default for OpenVPN (instant keygen, no DH params). `--legacy-rsa` if you need it
- **Encrypted configs** — VPN configs served encrypted with a one-time passphrase. `--unsafe-configs` to skip
- **Scoped firewall** — UFW rules allow VPN from anywhere, everything else scoped to SSH source + local subnets
- **Sysctl hardening** — rp_filter, syncookies, ICMP redirect rejection, source route disable
- **Landing page** — ephemeral web page with server info, version-matched client downloads, VPN configs, warnings, and resources. Auto-expires via systemd timer
- **Reconfigure mode** — detects prior install, stops services, re-runs cleanly
- **Testable** — `main()` guarded so functions can be sourced for BATS or plain bash tests

## Usage

```
sudo ./gns3-remote-install-redux.sh [OPTIONS]
```

## Flags

| Flag | Default | Description |
|---|---|---|
| `--with-openvpn` | off | Install and configure OpenVPN |
| `--with-wireguard` | off | Install and configure WireGuard |
| `--with-welcome` | off | Install GNS3-VM welcome console UI |
| `--without-kvm` | KVM on | Disable KVM hardware acceleration |
| `--without-docker` | Docker on | Skip Docker CE installation |
| `--without-firewall` | UFW on | Skip automatic UFW rule configuration |
| `--without-system-upgrade` | upgrade on | Skip `apt upgrade` |
| `--unsafe-configs` | encrypted | Serve VPN configs unencrypted |
| `--legacy-rsa` | EC P-384 | Use RSA-2048 + DH for OpenVPN |
| `--unstable` | stable PPA | Use the GNS3 unstable PPA |
| `--custom-repository REPO` | `ppa` | Use a custom GNS3 PPA name |
| `-h`, `--help` | | Show help |

## Requirements

Ubuntu Server 24.04 LTS (amd64). Run as root or with `sudo`.

## License

Based on the original GNS3 remote installer (GPLv3).

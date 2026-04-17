# gns3-remote-install-redux

Revised version of the OG [upstream GNS3 remote installer](https://github.com/GNS3/gns3-server/blob/master/scripts/remote-install.sh). 

## What's different

- **Single primary apt pass**: packages, repos, and groups rolled up from flags before install runs (as much as possible)
- **Preflight**: checks root, OS, needed commands, ports, modules, CPU virt extensions. Reports every error condition at once 
- **Auto-loads KVM**: `modprobe` + persist to `/etc/modules-load.d/`, unless `--without-kvm`
- **Retry + verify**: apt retries 3x with backoff; services verified with `systemctl is-active`; GNS3 API curled post-install
- **WireGuard**: adds modern VPN option
- **EC crypto**: P-384 by default for OpenVPN (faster keygen, no DH params). `--legacy-rsa` if needed
- **Encrypted configs**: VPN configs are encrypted with one-time passphrase. A copy+paste one-liner is printed to console to curl and decrypt the file at once. `--unsafe-configs` to skip
- **Scoped firewall**: UFW rules allow VPN from 0.0.0.0/0, others scoped to SSH source + local subnets
- **Sysctl hardening**: rp_filter, syncookies, ICMP redirect rejection, source route disable
- **Landing page**: ephemeral web page gives server info, version-matched client downloads, VPN configs, warnings, and resources. Auto-expires via systemd timer. Uses Python httpd.server module, instead of installing nginx package.
- **Reconfigure**: enhanced idempotence. detects prior install, stops services, re-runs cleanly
- **Testable**: `main()` guarded so functions can be sourced for BATS or plain bash tests

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

# zeroport

Bootstrap a fresh Debian 13 VPS so it accepts **no public TCP connections**.
You administer it over Tailscale; public traffic reaches it through Cloudflare Tunnel.

```text
you ── Tailscale ──> tailscale0:22 ──> sshd
users ── HTTPS ──> Cloudflare ── Tunnel (outbound) ──> 127.0.0.1:<app>

internet ──> VPS
             ├─ ICMP           allowed (ufw default)
             ├─ UDP 41641      allowed (Tailscale direct connections)
             └─ everything else denied
```

One Bash script, no dependencies beyond a stock Debian 13 image. It installs no
applications, databases or Docker. The base system is all it touches.

## What it sets up

| Area | Result |
|---|---|
| Updates | Full upgrade, then unattended **security** updates; services using a patched library restart automatically (needrestart); the machine never reboots on its own |
| Base | Timezone UTC, journald kept 14 days / 200 MB, 2 GB swap if none exists |
| Kernel | No ICMP redirects or source routing, SYN cookies, restricted kernel pointers, dmesg and ptrace; loose `rp_filter` so Tailscale routing works |
| Admin user | Named by you, in `sudo`, with a generated sudo password shown once |
| SSH | Public keys only; root login, password login and X11 forwarding disabled |
| Tailscale | Official signed apt repo, joined with a tagged auth key, auto-update on |
| Cloudflare Tunnel | Official signed apt repo, token-based connector, daily update with rollback |
| Firewall | ufw: deny incoming, allow `tailscale0` and `41641/udp` |

## Before you start

1. **Out-of-band access.** Confirm your provider's web/VNC console works, and
   store the root password in your password manager. That console is how you
   recover if Tailscale ever fails. Enable MFA on the provider account.
2. **SSH key on the server.** Most providers let you add a public key at
   order time. zeroport copies root's `authorized_keys` to your admin user,
   or asks you to paste a key.
3. **Tailscale auth key.** In the admin console, create a key that is
   *pre-approved*, *not reusable*, and tagged `tag:server`. Tagged devices do not
   expire, so the server will not drop off your tailnet. A minimal policy:

   ```json
   {
     "tagOwners": { "tag:server": ["autogroup:admin"] },
     "grants": [
       { "src": ["autogroup:admin"], "dst": ["tag:server"], "ip": ["tcp:22", "icmp:*"] }
     ]
   }
   ```

4. **Cloudflare Tunnel token** (optional). Create a tunnel in Zero Trust →
   Networks → Tunnels, choose Debian, and copy the token (`eyJ...`) from the
   install command.

## Usage

Download a release, check it, then run it as root:

```bash
V=v0.1.0
curl -fsSLO https://github.com/imaw9/zeroport/releases/download/$V/zeroport.sh
curl -fsSLO https://github.com/imaw9/zeroport/releases/download/$V/zeroport.sh.sha256
sha256sum -c zeroport.sh.sha256

bash zeroport.sh bootstrap   # shows the plan, asks, then applies and reboots
```

Pin a release tag rather than `main`. The script runs as root, so you should
know exactly which version you are running.

The checksum only proves the download is intact. To confirm the file was built
from this repository by its release workflow, verify its provenance from any
machine with the GitHub CLI:

```bash
gh attestation verify zeroport.sh --repo imaw9/zeroport
```

### The three commands

```text
bootstrap   update → base → sysctl → swap → auto-updates → user → tailscale → cloudflared → ssh → reboot
lockdown    enable ufw; refuses unless this SSH session arrives over Tailscale
audit       read-only report; exits 1 if anything fails
```

A full run on a new machine:

1. `bash zeroport.sh bootstrap` over the provider's public IP, as root.
   - Read the plan it prints. Nothing changes until you answer `Apply this plan?`.
   - Save the sudo password it shows you.
   - Before SSH hardening, open a **second terminal**, log in as your new
     user with your key, and run `sudo -v`. Type `yes` only when both work.
   - Let it reboot so the patched kernel is running.
2. Reconnect over Tailscale: `ssh <user>@<tailscale-ip>`.
3. `sudo bash zeroport.sh lockdown`, then from a machine **outside** your
   tailnet confirm that `nc -vz -w 5 <public-ip> 22` times out.
4. Run `sudo bash zeroport.sh audit` whenever you want to check for drift.

### Options

| Option | Meaning |
|---|---|
| `--dry-run` | Print the plan and stop. Asks nothing, changes nothing |
| `--yes` | Accept prompts whose default is yes. Dangerous steps still need you to type `yes` |
| `--only=user,ssh` | Run selected bootstrap steps |
| `--user=NAME` | Admin username |
| `--hostname=NAME` | Tailscale device name |
| `--swap-size=4G` | Swap size when none exists (default 2G) |

## Safety rails

- **Plan first.** `bootstrap` runs every step in dry-run mode, prints the plan,
  and asks once before changing anything. Declining leaves the machine as it was.
- **Two kinds of confirmation.** Ordinary prompts take `y` or `n`, and `--yes`
  accepts only those whose default is yes. Steps that can cut your connection
  (disabling password and root login, closing public ports) need you to type
  `yes`, and `--yes` never skips them.
- **Fresh machines only.** `bootstrap` stops if it finds Docker, a database,
  active ufw, nftables rules or public TCP listeners. On a machine that runs
  services, a firewall or SSH change could cut them off. Re-runs on a machine
  zeroport already set up are allowed, and unchanged files are left alone.
- **No lockout.** Password and root login are disabled only after you confirm
  key login and sudo in a second session. `sshd -t` validates the config before
  reload, and a failure restores the previous file. `lockdown` only runs over a
  Tailscale session, which proves that path works before public SSH closes.
- **No secrets on disk or in logs.** Keys and tokens are read from the terminal.
  The Tailscale key goes through a temporary `0600` file in `/run` that is
  deleted afterwards. The tunnel token lives only in `/etc/cloudflared/tunnel.env`
  (`root`, `0600`). Logs in `/var/log/zeroport` record commands, never secrets.
- **Backups.** Every file zeroport replaces is copied to
  `/var/backups/zeroport/<run-id>/` first.

## Updates and redundancy

The two access paths update independently:

- **Tailscale** (admin access) updates itself through its built-in auto-update.
  If an update ever breaks it, use the provider console.
- **cloudflared** (public traffic) is upgraded daily around 10:30 UTC by
  `zeroport-cloudflared-update.timer`. Before upgrading, the timer saves the
  current binary. If the tunnel was healthy and has no connections a minute after
  the upgrade, the timer restores the old binary and holds the package.
  `audit` reports the hold. Once you have looked into it:

  ```bash
  journalctl -u zeroport-cloudflared-update
  sudo apt-mark unhold cloudflared && sudo apt-get install --reinstall cloudflared
  ```

  Cloudflare's apt repository keeps only the latest version, so the rollback
  restores the saved binary instead of downgrading through apt.

Debian security updates install automatically, and needrestart restarts the
services that were using the old libraries. A few core services such as dbus
are never restarted automatically. `audit` lists any still running old code.
Kernel updates take effect only after a reboot. `audit` reports a pending one,
and you choose when to reboot.

## Not included

Docker, applications, databases, backups, monitoring, fail2ban or SSH
two-factor (there is no public SSH to protect) and changing the SSH port.
`MaxAuthTries` stays at the default 6. An SSH agent with several keys offers
them in turn and would hit a lower limit before reaching the right key. Add them in your own deployment
layer. If you add Docker later, note that published container ports bypass ufw's
input rules: bind them to `127.0.0.1` and expose them through the tunnel.

## Development

```bash
bash tests/smoke.sh                 # no root, no server needed
shellcheck -x zeroport.sh tests/smoke.sh
```

Test real runs on a throwaway Debian 13 VM, for example with OrbStack:
`orb create debian:trixie zp-test`. To release, bump `ZEROPORT_VERSION` and push a
matching `v*` tag. The release workflow attaches `zeroport.sh` and its checksum.

## License

MIT

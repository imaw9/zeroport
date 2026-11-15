#!/usr/bin/env bash
# zeroport — bootstrap a fresh Debian 13 VPS with zero public TCP ports.
#
# Admin access goes through Tailscale, public traffic through Cloudflare Tunnel.
# Subcommands:
#   audit      read-only report of the baseline
#   bootstrap  patch the system, create the admin user, install Tailscale and
#              cloudflared, harden SSH, then reboot
#   lockdown   enable the firewall (run over Tailscale SSH after the reboot)
#
# Secrets (Tailscale auth key, Cloudflare Tunnel token, the generated sudo
# password) are read from the terminal and never written to the log.
set -Eeuo pipefail

ZEROPORT_VERSION="0.1.0"

DRY_RUN=0
ASSUME_YES=0
ONLY_STEPS=""
ADMIN_USER=""
TS_HOSTNAME=""
SWAP_SIZE="2G"
COMMAND=""

BOOTSTRAP_STEPS=(update base swap auto-updates user tailscale cloudflared ssh reboot)

STATE_DIR="/var/lib/zeroport"
LOG_DIR="/var/log/zeroport"
RUN_ID="$(date -u +%Y%m%d-%H%M%S)"
LOG_FILE=""
BACKUP_DIR="/var/backups/zeroport/${RUN_ID}"
SSHD_DROPIN="/etc/ssh/sshd_config.d/00-zeroport.conf"
CLOUDFLARED_ENV="/etc/cloudflared/tunnel.env"
CLOUDFLARED_METRICS="127.0.0.1:20241"

# ── Output ────────────────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
  RED=$'\033[0;31m' GREEN=$'\033[0;32m' YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m' BOLD=$'\033[1m' DIM=$'\033[2m' NC=$'\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' BOLD='' DIM='' NC=''
fi

to_log() {
  [[ -n "$LOG_FILE" ]] || return 0
  printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >>"$LOG_FILE"
}
info()    { printf '  %s→%s %s\n' "$BLUE" "$NC" "$*"; to_log "INFO  $*"; }
ok()      { printf '  %s✔%s %s\n' "$GREEN" "$NC" "$*"; to_log "OK    $*"; }
warn()    { printf '  %s⚠%s %s\n' "$YELLOW" "$NC" "$*"; to_log "WARN  $*"; }
err()     { printf '  %s✖%s %s\n' "$RED" "$NC" "$*" >&2; to_log "ERROR $*"; }
die()     { err "$*"; exit 1; }
section() { printf '\n%s▸ %s%s\n' "$BOLD" "$*" "$NC"; to_log "STEP  $*"; }

ERROR_REPORTED=0
on_error() {
  ((ERROR_REPORTED)) && return 0
  ERROR_REPORTED=1
  err "Failed at line $1 (exit $2). Log: ${LOG_FILE:-none}"
}
trap 'on_error $LINENO $?' ERR

# run "description" cmd args... — never pass secrets through here.
run() {
  local desc="$1"
  shift
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '  %s◦%s %s %s(dry-run)%s\n' "$YELLOW" "$NC" "$desc" "$DIM" "$NC"
    return 0
  fi
  to_log "RUN   ${desc} :: $*"
  if "$@" </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1; then
    ok "$desc"
  else
    local rc=$?
    err "$desc (exit $rc, see $LOG_FILE)"
    return "$rc"
  fi
}

# write_file PATH MODE < content — backs up a differing file, skips identical.
write_file() {
  local path="$1" mode="${2:-644}" tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  if [[ -f "$path" ]] && cmp -s "$tmp" "$path"; then
    rm -f "$tmp"
    ok "unchanged ${path}"
    return 0
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    rm -f "$tmp"
    printf '  %s◦%s write %s %s(dry-run)%s\n' "$YELLOW" "$NC" "$path" "$DIM" "$NC"
    return 0
  fi
  if [[ -f "$path" ]]; then
    install -d -m 700 /var/backups/zeroport
    install -d -m 700 "$BACKUP_DIR$(dirname "$path")"
    cp -p "$path" "$BACKUP_DIR$path"
    info "backed up ${path} to ${BACKUP_DIR}${path}"
  fi
  install -d -m 755 "$(dirname "$path")"
  install -o root -g root -m "$mode" "$tmp" "$path"
  rm -f "$tmp"
  ok "wrote ${path}"
}

# ── Prompts (always read from the terminal, never from a pipe) ───────────────

require_tty() {
  [[ -r /dev/tty ]] || die "An interactive terminal is required. Download the script and run it with bash."
}

# confirm PROMPT [Y|N] — --yes accepts only questions whose default is Y.
confirm() {
  local prompt="$1" default="${2:-Y}" reply hint="[Y/n]"
  [[ "$default" == "N" ]] && hint="[y/N]"
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    printf '  %s?%s %s %s %s(--yes)%s\n' "$BOLD" "$NC" "$prompt" "$hint" "$DIM" "$NC"
    if [[ "$default" == "Y" ]]; then return 0; fi
    return 1
  fi
  require_tty
  while true; do
    read -r -p "  ${BOLD}?${NC} ${prompt} ${hint} " reply </dev/tty
    reply="${reply:-$default}"
    case "$reply" in
      [Yy]|[Yy][Ee][Ss]) return 0 ;;
      [Nn]|[Nn][Oo]) return 1 ;;
      *) warn "Please answer y or n." ;;
    esac
  done
}

# confirm_danger PROMPT — requires typing "yes"; --yes does not skip it.
confirm_danger() {
  local reply
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '  %s◦%s would ask: %s %s(dry-run)%s\n' "$YELLOW" "$NC" "$1" "$DIM" "$NC"
    return 0
  fi
  require_tty
  printf '  %s!%s %s\n' "$RED" "$NC" "$1"
  read -r -p "    Type 'yes' to continue: " reply </dev/tty
  [[ "$reply" == "yes" ]]
}

ask() {
  local prompt="$1" default="${2:-}" reply
  require_tty
  if [[ -n "$default" ]]; then
    read -r -p "  ${BOLD}?${NC} ${prompt} [${default}] " reply </dev/tty
  else
    read -r -p "  ${BOLD}?${NC} ${prompt} " reply </dev/tty
  fi
  printf '%s' "${reply:-$default}"
}

ask_secret() {
  local reply
  require_tty
  read -r -s -p "  ${BOLD}?${NC} $1 " reply </dev/tty
  printf '\n' >/dev/tty
  printf '%s' "$reply"
}

# ── Helpers ───────────────────────────────────────────────────────────────────

require_root() {
  [[ "$EUID" -eq 0 ]] || die "Run as root (sudo bash $0 $COMMAND)."
}

require_debian13() {
  [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release."
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "debian" && "${VERSION_ID:-}" == "13" ]] \
    || die "zeroport supports Debian 13 only (found ${PRETTY_NAME:-unknown})."
}

init_log() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    LOG_FILE=""
    return
  fi
  install -d -m 700 "$LOG_DIR" "$STATE_DIR"
  LOG_FILE="${LOG_DIR}/${COMMAND}-${RUN_ID}.log"
  : >"$LOG_FILE"
  chmod 600 "$LOG_FILE"
}

should_run() {
  [[ -z "$ONLY_STEPS" ]] && return 0
  [[ ",${ONLY_STEPS}," == *",$1,"* ]]
}

is_tailscale_ip() {
  local ip="$1" a b
  if [[ "$ip" =~ ^([0-9]+)\.([0-9]+)\.[0-9]+\.[0-9]+$ ]]; then
    a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}"
    [[ "$a" -eq 100 && "$b" -ge 64 && "$b" -le 127 ]]
    return
  fi
  ip="$(printf '%s' "$ip" | tr 'A-F' 'a-f')"
  [[ "$ip" == fd7a:115c:a1e0:* ]]
}

# Find the SSH client address of this session, even under sudo, by walking
# up the process tree until an environment carries SSH_CONNECTION.
ssh_client_ip() {
  local pid="$$" conn ppid
  while [[ "$pid" -gt 1 ]]; do
    conn="$(tr '\0' '\n' <"/proc/${pid}/environ" 2>/dev/null \
      | sed -n '/^SSH_CONNECTION=/{s/^SSH_CONNECTION=//;p;q;}')" || conn=""
    if [[ -n "$conn" ]]; then
      printf '%s' "${conn%% *}"
      return 0
    fi
    ppid="$(awk '/^PPid:/{print $2}' "/proc/${pid}/status" 2>/dev/null)" || ppid=1
    pid="${ppid:-1}"
  done
  return 1
}

public_ip() {
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}'
}

tailscale_running() {
  command -v tailscale >/dev/null 2>&1 || return 1
  local status
  status="$(tailscale status --json 2>/dev/null)" || return 1
  [[ "$status" =~ \"BackendState\":[[:space:]]*\"Running\" ]]
}

cloudflared_connections() {
  curl -fsS --max-time 5 "http://${CLOUDFLARED_METRICS}/metrics" 2>/dev/null \
    | awk '/^cloudflared_tunnel_ha_connections /{v=int($2)} END{print v+0}'
}

# Public TCP listeners other than SSH; loopback and Tailscale addresses excluded.
public_tcp_listeners() {
  command -v ss >/dev/null 2>&1 || return 0
  ss -Hltn 2>/dev/null | awk '{print $4}' | while read -r addr; do
    local host="${addr%:*}" port="${addr##*:}"
    host="${host#[}" host="${host%]}" host="${host%%%*}"
    [[ "$port" == "22" ]] && continue
    [[ "$host" == 127.* || "$host" == "::1" ]] && continue
    is_tailscale_ip "$host" && continue
    printf '%s\n' "$addr"
  done
}

add_apt_repo() {
  local name="$1" key_url="$2" keyring="$3" list_line="$4"
  local list="/etc/apt/sources.list.d/${name}.list"
  if [[ -f "$keyring" && -f "$list" ]]; then
    ok "${name} apt repository present"
    return 0
  fi
  run "Fetch ${name} signing key" sh -c "curl -fsSL '$key_url' -o '$keyring.tmp' && install -m 644 '$keyring.tmp' '$keyring' && rm -f '$keyring.tmp'"
  printf '%s\n' "$list_line" | write_file "$list" 644
  run "Refresh apt index" apt-get update -qq
}

# ── Preflight ─────────────────────────────────────────────────────────────────

# A fresh machine has none of these. zeroport refuses to modify a machine that
# already runs services, because enabling SSH or firewall changes could cut them off.
existing_services() {
  local found=()
  command -v docker >/dev/null 2>&1 && found+=("docker")
  local units
  units="$(systemctl list-unit-files --no-legend 2>/dev/null || true)"
  grep -Eq '^(postgresql|mysql|mariadb|redis|redis-server|mongod)[^ ]*\.service' <<<"$units" \
    && found+=("database service")
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    found+=("active ufw")
  fi
  if command -v nft >/dev/null 2>&1 && [[ -n "$(nft list ruleset 2>/dev/null)" ]]; then
    found+=("existing nftables rules")
  fi
  local listeners
  listeners="$(public_tcp_listeners | tr '\n' ' ' || true)"
  [[ -n "$listeners" ]] && found+=("public TCP listeners: ${listeners}")
  ((${#found[@]})) && printf '%s\n' "${found[@]}"
  return 0
}

preflight_bootstrap() {
  section "Preflight"
  require_debian13
  ok "Debian 13 (${VERSION_CODENAME:-trixie})"
  if [[ -f "${STATE_DIR}/bootstrapped" ]]; then
    info "Re-run on a zeroport machine. Preview changes first with --dry-run."
    return 0
  fi
  local blockers line
  blockers="$(existing_services)"
  if [[ -n "$blockers" ]]; then
    err "This does not look like a fresh machine:"
    while IFS= read -r line; do printf '      - %s\n' "$line" >&2; done <<<"$blockers"
    die "Refusing to modify a machine that already runs services. Run 'audit' instead."
  fi
  ok "No existing services, firewall rules or public listeners"
}

# ── Bootstrap steps ───────────────────────────────────────────────────────────

step_update() {
  section "System update"
  export DEBIAN_FRONTEND=noninteractive
  run "Refresh apt index" apt-get update -qq
  run "Install all pending upgrades" apt-get -y -qq -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold full-upgrade
  run "Install base packages" apt-get install -y -qq ca-certificates curl gnupg sudo \
    ufw unattended-upgrades iproute2 openssh-server
}

step_base() {
  section "Timezone and journald"
  if [[ "$(timedatectl show -p Timezone --value 2>/dev/null)" == "UTC" ]]; then
    ok "Timezone is UTC"
  else
    run "Set timezone to UTC" timedatectl set-timezone UTC
  fi
  write_file /etc/systemd/journald.conf.d/10-zeroport.conf 644 <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=200M
MaxRetentionSec=14day
EOF
  run "Restart journald" systemctl restart systemd-journald
}

step_swap() {
  section "Swap"
  if [[ -n "$(swapon --show --noheadings 2>/dev/null)" ]]; then
    ok "Swap present: $(swapon --show --noheadings | awk '{print $1" "$3}' | tr '\n' ' ')"
    return 0
  fi
  confirm "No swap found. Create a ${SWAP_SIZE} /swapfile?" Y || { warn "Skipped swap"; return 0; }
  run "Allocate /swapfile (${SWAP_SIZE})" fallocate -l "$SWAP_SIZE" /swapfile
  run "Restrict /swapfile permissions" chmod 600 /swapfile
  run "Format swap" mkswap /swapfile
  run "Enable swap" swapon /swapfile
  if ! grep -q '^/swapfile ' /etc/fstab; then
    run "Persist swap in /etc/fstab" sh -c "printf '/swapfile none swap sw 0 0\n' >>/etc/fstab"
  fi
}

step_auto_updates() {
  section "Automatic security updates (no automatic reboot)"
  write_file /etc/apt/apt.conf.d/52zeroport-unattended-upgrades 644 <<'EOF'
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern {
        "origin=Debian,codename=${distro_codename},label=Debian-Security";
        "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
};
Unattended-Upgrade::Automatic-Reboot "false";
EOF
  write_file /etc/apt/apt.conf.d/20auto-upgrades 644 <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  run "Enable unattended-upgrades" systemctl enable --now unattended-upgrades
}

step_user() {
  section "Admin user (sudo with password)"
  local user="$ADMIN_USER"
  if [[ -z "$user" ]]; then
    [[ "$DRY_RUN" -eq 1 ]] && { info "would ask for the admin username"; return 0; }
    user="$(ask "Admin username:" "")"
  fi
  [[ "$user" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$user" != "root" ]] \
    || die "Invalid username '${user}' (lowercase letters, digits, - and _; not root)."
  ADMIN_USER="$user"

  if id "$user" >/dev/null 2>&1; then
    ok "User ${user} exists"
  else
    run "Create user ${user}" useradd -m -s /bin/bash "$user"
    if [[ "$DRY_RUN" -eq 0 ]]; then
      local password
      password="$(head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-24)"
      printf '%s:%s\n' "$user" "$password" | chpasswd
      to_log "INFO  sudo password set for ${user} (not logged)"
      printf '\n  %sSudo password for %s (shown once, save it to your password manager):%s\n' "$BOLD" "$user" "$NC" >/dev/tty
      printf '\n      %s\n\n' "$password" >/dev/tty
      unset password
      read -r -p "  Press Enter after saving it... " _ </dev/tty
      printf '\033[2J\033[3J\033[H' >/dev/tty  # clear screen and scrollback
    fi
  fi
  run "Add ${user} to sudo group" usermod -aG sudo "$user"

  local home keys
  home="$(getent passwd "$user" | cut -d: -f6 || true)"
  home="${home:-/home/${user}}"
  keys="${home}/.ssh/authorized_keys"
  if [[ -s "$keys" ]]; then
    ok "${keys} present"
  elif [[ -s /root/.ssh/authorized_keys ]]; then
    run "Create ${home}/.ssh" install -d -m 700 -o "$user" -g "$user" "${home}/.ssh"
    run "Copy root's SSH public keys to ${user}" install -m 600 -o "$user" -g "$user" \
      /root/.ssh/authorized_keys "$keys"
  else
    [[ "$DRY_RUN" -eq 1 ]] && { info "would ask for an SSH public key"; return 0; }
    local key
    key="$(ask "Paste the SSH public key for ${user}:" "")"
    printf '%s\n' "$key" | ssh-keygen -l -f - >/dev/null 2>&1 || die "Not a valid SSH public key."
    install -d -m 700 -o "$user" -g "$user" "${home}/.ssh"
    printf '%s\n' "$key" | install -m 600 -o "$user" -g "$user" /dev/stdin "$keys"
    ok "Installed SSH public key for ${user}"
  fi
}

step_tailscale() {
  section "Tailscale (admin access)"
  add_apt_repo tailscale \
    "https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg" \
    /usr/share/keyrings/tailscale-archive-keyring.gpg \
    "deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/debian trixie main"
  if command -v tailscale >/dev/null 2>&1; then
    ok "tailscale installed"
  else
    run "Install tailscale" apt-get install -y -qq tailscale
  fi

  if [[ "$DRY_RUN" -eq 0 ]] && tailscale_running; then
    ok "Tailscale connected as $(tailscale ip -4 2>/dev/null | head -n1)"
  elif [[ "$DRY_RUN" -eq 1 ]]; then
    info "would ask for the hostname and a tagged, pre-approved auth key"
  else
    local host key keyfile
    host="${TS_HOSTNAME:-$(ask "Tailscale hostname:" "$(hostname -s)")}"
    info "Use a one-off, pre-approved auth key tagged tag:server (key expiry stays disabled for tagged nodes)."
    while true; do
      key="$(ask_secret "Tailscale auth key (tskey-auth-..., empty to skip):")"
      [[ -z "$key" || "$key" =~ ^tskey-auth-[A-Za-z0-9-]+$ ]] && break
      warn "That does not look like a Tailscale auth key."
    done
    if [[ -z "$key" ]]; then
      warn "Skipped Tailscale login; 'lockdown' will refuse until Tailscale is connected."
    else
      keyfile="$(mktemp -p /run zeroport-tskey.XXXXXX)"
      chmod 600 "$keyfile"
      printf '%s' "$key" >"$keyfile"
      unset key
      to_log "RUN   tailscale up --hostname=${host} --auth-key=file:<redacted>"
      if tailscale up --auth-key="file:${keyfile}" --hostname="$host" >>"$LOG_FILE" 2>&1; then
        ok "Tailscale connected as $(tailscale ip -4 | head -n1)"
      else
        rm -f "$keyfile"
        die "tailscale up failed (see $LOG_FILE)."
      fi
      rm -f "$keyfile"
    fi
  fi
  if [[ "$DRY_RUN" -eq 1 ]] || tailscale_running; then
    run "Enable Tailscale auto-update" tailscale set --auto-update=true
  fi
}

write_cloudflared_units() {
  write_file /etc/systemd/system/cloudflared.service 644 <<EOF
[Unit]
Description=Cloudflare Tunnel (zeroport)
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
EnvironmentFile=${CLOUDFLARED_ENV}
ExecStart=/usr/bin/cloudflared --no-autoupdate --metrics ${CLOUDFLARED_METRICS} tunnel run
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

  write_file /usr/local/sbin/zeroport-cloudflared-update 755 <<EOF
#!/usr/bin/env bash
# Upgrade cloudflared; if the tunnel has no connections afterwards, restore the
# previous binary and hold the package until someone investigates.
set -Euo pipefail
STATE="${STATE_DIR}"
METRICS="http://${CLOUDFLARED_METRICS}/metrics"
log() { logger -t zeroport-cloudflared-update "\$*"; printf '%s\n' "\$*"; }
connections() { curl -fsS --max-time 5 "\$METRICS" 2>/dev/null | awk '/^cloudflared_tunnel_ha_connections /{v=int(\$2)} END{print v+0}'; }
healthy() { local i c; for i in \$(seq 1 12); do c="\$(connections)"; [[ "\${c:-0}" -gt 0 ]] && return 0; sleep 5; done; return 1; }

if apt-mark showhold | grep -qx cloudflared; then
  log "cloudflared is held after a failed update; skipping. Run 'apt-mark unhold cloudflared' once resolved."
  exit 0
fi
before="\$(dpkg-query -W -f='\${Version}' cloudflared)"
# Only a tunnel that is healthy now can tell us whether the new version broke it.
was_healthy=0
[[ "\$(connections)" -gt 0 ]] && was_healthy=1
install -D -m 755 /usr/bin/cloudflared "\$STATE/cloudflared.prev"
apt-get update -qq -o Dir::Etc::sourcelist=sources.list.d/cloudflared.list -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --only-upgrade cloudflared
after="\$(dpkg-query -W -f='\${Version}' cloudflared)"
if [[ "\$before" == "\$after" ]]; then
  log "cloudflared \$before is current"
  exit 0
fi
systemctl restart cloudflared
if [[ "\$was_healthy" -eq 0 ]]; then
  log "cloudflared upgraded \$before -> \$after; tunnel was already down before the upgrade, so no rollback"
  exit 0
fi
if healthy; then
  log "cloudflared upgraded \$before -> \$after; tunnel healthy"
  exit 0
fi
log "cloudflared \$after has no tunnel connections; restoring \$before"
install -m 755 "\$STATE/cloudflared.prev" /usr/bin/cloudflared
apt-mark hold cloudflared
systemctl restart cloudflared
if healthy; then log "rollback to \$before healthy; cloudflared held"; else log "rollback to \$before also unhealthy"; fi
exit 1
EOF

  write_file /etc/systemd/system/zeroport-cloudflared-update.service 644 <<'EOF'
[Unit]
Description=Upgrade cloudflared with health check and rollback (zeroport)
After=network-online.target cloudflared.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/zeroport-cloudflared-update
EOF

  # 10:30 UTC daily; Tailscale updates itself on its own schedule, so the two
  # access paths do not change at the same moment.
  write_file /etc/systemd/system/zeroport-cloudflared-update.timer 644 <<'EOF'
[Unit]
Description=Daily cloudflared upgrade check (zeroport)

[Timer]
OnCalendar=*-*-* 10:30:00 UTC
RandomizedDelaySec=30m
Persistent=false

[Install]
WantedBy=timers.target
EOF
}

ask_tunnel_token() {
  local token
  while true; do
    token="$(ask_secret "Cloudflare Tunnel token (eyJ..., empty to skip):")"
    if [[ -z "$token" || "$token" =~ ^eyJ[A-Za-z0-9+/=_-]{40,}$ ]]; then
      printf '%s' "$token"
      return 0
    fi
    warn "That does not look like a Cloudflare Tunnel token." >&2  # stdout is the return value
  done
}

step_cloudflared() {
  section "Cloudflare Tunnel (public traffic)"
  local token=""
  if [[ -s "$CLOUDFLARED_ENV" ]]; then
    ok "Tunnel token present in ${CLOUDFLARED_ENV}"
    if [[ "$DRY_RUN" -eq 0 ]] && confirm "Replace the existing tunnel token?" N; then
      token="$(ask_tunnel_token)"
    fi
  elif [[ "$DRY_RUN" -eq 1 ]]; then
    info "would ask for the Cloudflare Tunnel token"
  else
    token="$(ask_tunnel_token)"
    if [[ -z "$token" ]]; then
      warn "Skipped Cloudflare Tunnel"
      return 0
    fi
  fi

  add_apt_repo cloudflared \
    "https://pkg.cloudflare.com/cloudflare-main.gpg" \
    /usr/share/keyrings/cloudflare-main.gpg \
    "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main"
  if command -v cloudflared >/dev/null 2>&1; then
    ok "cloudflared installed ($(cloudflared --version 2>/dev/null | head -n1))"
  else
    run "Install cloudflared" apt-get install -y -qq cloudflared
  fi

  if [[ -n "$token" ]]; then
    install -d -m 700 /etc/cloudflared
    (umask 077 && printf 'TUNNEL_TOKEN=%s\n' "$token" >"$CLOUDFLARED_ENV")
    unset token
    ok "Wrote ${CLOUDFLARED_ENV} (root, 600)"
  fi

  write_cloudflared_units
  run "Reload systemd" systemctl daemon-reload
  run "Enable daily cloudflared update with rollback" systemctl enable --now zeroport-cloudflared-update.timer
  # The tunnel carries public traffic, not admin access: a failure here is
  # reported but does not stop SSH hardening.
  if ! run "Start cloudflared" systemctl enable cloudflared \
    || ! run "Restart cloudflared" systemctl restart cloudflared; then
    warn "cloudflared did not start; check the token and 'journalctl -u cloudflared'"
    return 0
  fi

  [[ "$DRY_RUN" -eq 1 ]] && return 0
  local c=0 _
  for _ in $(seq 1 12); do
    c="$(cloudflared_connections || true)"
    [[ "${c:-0}" -gt 0 ]] && break
    sleep 5
  done
  if [[ "${c:-0}" -gt 0 ]]; then
    ok "Tunnel up with ${c} connections"
  else
    warn "Tunnel has no connections yet; check 'journalctl -u cloudflared'"
  fi
}

step_ssh() {
  section "SSH: keys only, no root login"
  local user="$ADMIN_USER"
  if [[ -z "$user" ]]; then
    user="$(getent group sudo | cut -d: -f4 | cut -d, -f1)"
  fi
  if [[ "$DRY_RUN" -eq 0 ]]; then
    [[ -n "$user" ]] || die "No sudo user found; run the 'user' step first."
    local home
    home="$(getent passwd "$user" | cut -d: -f6 || true)"
    [[ -n "$home" && -s "${home}/.ssh/authorized_keys" ]] || die "${user} has no authorized_keys; refusing to disable root login."
  fi

  local desired
  desired="$(cat <<'EOF'
# Managed by zeroport. Loaded before other drop-ins, so these values win.
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF
)"
  if [[ -f "$SSHD_DROPIN" ]] && [[ "$(cat "$SSHD_DROPIN")" == "$desired" ]]; then
    ok "unchanged ${SSHD_DROPIN}"
    return 0
  fi

  info "Keep this session open. In a NEW terminal, verify:"
  info "  ssh -o PreferredAuthentications=publickey ${user:-<user>}@$(public_ip)"
  info "  sudo -v    # enter the sudo password you saved"
  confirm_danger "Disable password and root SSH login now? Only continue if both checks passed." \
    || { warn "Skipped SSH hardening"; return 0; }

  printf '%s\n' "$desired" | write_file "$SSHD_DROPIN" 644
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  if ! sshd -t 2>>"$LOG_FILE"; then
    if [[ -f "${BACKUP_DIR}${SSHD_DROPIN}" ]]; then
      cp -p "${BACKUP_DIR}${SSHD_DROPIN}" "$SSHD_DROPIN"
    else
      rm -f "$SSHD_DROPIN"
    fi
    die "sshd -t rejected the configuration; restored the previous state."
  fi
  run "Reload sshd" systemctl reload ssh
  local effective
  effective="$(sshd -T 2>/dev/null | grep -Ei '^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication) ' | tr '\n' ' ')"
  ok "Effective: ${effective}"
}

step_reboot() {
  section "Reboot"
  [[ "$DRY_RUN" -eq 1 ]] && { info "would offer to reboot"; return 0; }
  install -d -m 700 "$STATE_DIR"
  date -u +%FT%TZ >"${STATE_DIR}/bootstrapped"
  local ts_ip
  ts_ip="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
  info "After the reboot, connect over Tailscale and enable the firewall:"
  info "  ssh ${ADMIN_USER:-<user>}@${ts_ip:-<tailscale-ip>}"
  info "  sudo bash zeroport.sh lockdown"
  if confirm "Reboot now to load the patched kernel?" Y; then
    to_log "INFO  rebooting"
    systemctl reboot
  else
    warn "Reboot skipped; run 'systemctl reboot' before lockdown."
  fi
}

cmd_bootstrap() {
  require_root
  init_log
  preflight_bootstrap
  if [[ "$DRY_RUN" -eq 0 && "$ASSUME_YES" -eq 0 ]]; then
    printf '\n  Steps: %s\n' "${ONLY_STEPS:-${BOOTSTRAP_STEPS[*]}}"
    confirm "Start bootstrap?" Y || exit 0
  fi
  export DEBIAN_FRONTEND=noninteractive
  should_run update && step_update
  should_run base && step_base
  should_run swap && step_swap
  should_run auto-updates && step_auto_updates
  should_run user && step_user
  should_run tailscale && step_tailscale
  should_run cloudflared && step_cloudflared
  should_run ssh && step_ssh
  should_run reboot && step_reboot
  return 0
}

# ── Lockdown ──────────────────────────────────────────────────────────────────

cmd_lockdown() {
  require_root
  require_debian13
  init_log
  section "Lockdown: deny all public inbound TCP"

  tailscale_running || die "Tailscale is not connected."
  ip link show tailscale0 >/dev/null 2>&1 || die "Interface tailscale0 not found."
  ok "Tailscale connected as $(tailscale ip -4 | head -n1)"

  local client
  client="$(ssh_client_ip)" || die "Not in an SSH session. Run lockdown over Tailscale SSH."
  is_tailscale_ip "$client" \
    || die "This session comes from ${client}, not Tailscale. Reconnect with ssh <user>@$(tailscale ip -4 | head -n1)."
  ok "This session arrives over Tailscale (${client})"

  command -v ufw >/dev/null 2>&1 || die "ufw is not installed; run 'bootstrap --only=update' first."
  if ufw status | grep -q '^Status: active'; then
    if ufw status | grep -q 'zeroport'; then
      ok "ufw already active with zeroport rules"
      ufw status verbose
      return 0
    fi
    die "ufw is active with rules zeroport did not write; refusing to change them."
  fi

  info "Rules: deny incoming, allow outgoing, allow all on tailscale0, allow 41641/udp (Tailscale direct connections)."
  confirm_danger "Enable the firewall and close every public TCP port, including SSH?" \
    || { warn "Lockdown cancelled"; return 0; }

  run "Default deny incoming" ufw default deny incoming
  run "Default allow outgoing" ufw default allow outgoing
  run "Allow tailnet traffic" ufw allow in on tailscale0 comment 'zeroport: tailnet'
  run "Allow Tailscale direct connections" ufw allow 41641/udp comment 'zeroport: tailscale direct'
  run "Enable ufw" ufw --force enable
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  ufw status verbose
  ok "Locked down. From a machine outside your tailnet, 'nc -vz -w 5 $(public_ip) 22' should time out."
}

# ── Audit ─────────────────────────────────────────────────────────────────────

AUDIT_FAIL=0
AUDIT_WARN=0
pass() { ok "$*"; }
fail() { printf '  %s✖%s %s\n' "$RED" "$NC" "$*"; AUDIT_FAIL=$((AUDIT_FAIL + 1)); }
note() { warn "$*"; AUDIT_WARN=$((AUDIT_WARN + 1)); }

check_service() {
  local unit="$1" required="${2:-1}" active enabled
  active="$(systemctl is-active "$unit" 2>/dev/null || true)"
  enabled="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
  if [[ "$active" == "active" && "$enabled" == "enabled" ]]; then
    pass "${unit}: active, enabled"
  elif [[ "$required" -eq 1 ]]; then
    fail "${unit}: ${active:-unknown}, ${enabled:-unknown}"
  else
    note "${unit}: ${active:-unknown}, ${enabled:-unknown}"
  fi
}

cmd_audit() {
  require_root
  # shellcheck disable=SC1091
  . /etc/os-release
  section "System"
  if [[ "${ID:-}" == "debian" && "${VERSION_ID:-}" == "13" ]]; then
    pass "${PRETTY_NAME}, kernel $(uname -r)"
  else
    fail "Unsupported OS: ${PRETTY_NAME:-unknown}"
  fi
  if [[ -f /var/run/reboot-required ]]; then
    note "Reboot required: $(tr '\n' ' ' </var/run/reboot-required.pkgs 2>/dev/null || true)"
  else
    pass "No reboot pending"
  fi
  [[ "$(timedatectl show -p Timezone --value 2>/dev/null)" == "UTC" ]] && pass "Timezone UTC" || note "Timezone is not UTC"
  [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == "yes" ]] && pass "Clock synchronized" || note "Clock not synchronized"
  if [[ -n "$(swapon --show --noheadings 2>/dev/null)" ]]; then
    pass "Swap: $(swapon --show --noheadings | awk '{print $3" used "$4}' | tr '\n' ' ')"
  else
    note "No swap"
  fi
  pass "Memory: $(free -h | awk '/^Mem:/{print $3" used of "$2}'); disk /: $(df -h / | awk 'NR==2{print $3" used of "$2}')"

  section "Updates"
  check_service unattended-upgrades
  [[ -f /etc/apt/apt.conf.d/52zeroport-unattended-upgrades ]] && pass "Security-only origins configured" || fail "zeroport unattended-upgrades config missing"
  local pending
  pending="$(apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null | grep -c '^Inst ' || true)"
  [[ "$pending" -eq 0 ]] && pass "No pending upgrades (cached index)" || note "${pending} packages upgradable (cached index)"

  section "SSH"
  local sshd_t
  sshd_t="$(sshd -T 2>/dev/null || true)"
  grep -qi '^permitrootlogin no$' <<<"$sshd_t" && pass "Root login disabled" || fail "Root login allowed ($(grep -i '^permitrootlogin ' <<<"$sshd_t"))"
  grep -qi '^passwordauthentication no$' <<<"$sshd_t" && pass "Password login disabled" || fail "Password login enabled"
  grep -qi '^kbdinteractiveauthentication no$' <<<"$sshd_t" && pass "Keyboard-interactive disabled" || fail "Keyboard-interactive enabled"
  local sudoers
  sudoers="$(getent group sudo | cut -d: -f4)"
  [[ -n "$sudoers" ]] && pass "sudo group: ${sudoers}" || fail "No sudo user"
  if grep -rqs 'NOPASSWD' /etc/sudoers /etc/sudoers.d; then
    note "Passwordless sudo present: $(grep -rls 'NOPASSWD' /etc/sudoers /etc/sudoers.d | tr '\n' ' ')"
  else
    pass "sudo requires a password"
  fi

  section "Firewall"
  if ufw status 2>/dev/null | grep -q '^Status: active'; then
    pass "ufw active"
    ufw status verbose | grep -q 'Default: deny (incoming)' && pass "Default deny incoming" || fail "Incoming policy is not deny"
    local extra
    extra="$(ufw status | awk 'NR>4 && NF' | grep -v -e 'on tailscale0' -e '^41641/udp' || true)"
    [[ -z "$extra" ]] && pass "Only tailscale0 and 41641/udp allowed" || note "Extra rules: $(tr -s ' ' <<<"$extra" | tr '\n' ';')"
  else
    fail "ufw inactive (run lockdown)"
  fi
  local listeners
  listeners="$(public_tcp_listeners | tr '\n' ' ' || true)"
  [[ -z "$listeners" ]] && pass "No public TCP listeners besides SSH" || note "Public TCP listeners (blocked by ufw if active): ${listeners}"

  section "Tailscale"
  check_service tailscaled
  if tailscale_running; then
    pass "Connected as $(tailscale ip -4 | head -n1)"
    tailscale debug prefs 2>/dev/null | grep -Eq '"Apply":[[:space:]]*true' && pass "Auto-update on" || note "Auto-update not confirmed"
  else
    fail "Tailscale not connected"
  fi

  section "Cloudflare Tunnel"
  if [[ -s "$CLOUDFLARED_ENV" ]]; then
    check_service cloudflared
    local c
    c="$(cloudflared_connections || true)"
    [[ "${c:-0}" -gt 0 ]] && pass "${c} tunnel connections ($(cloudflared --version 2>/dev/null | awk '{print $3}'))" || fail "No tunnel connections"
    check_service zeroport-cloudflared-update.timer
    apt-mark showhold 2>/dev/null | grep -qx cloudflared && note "cloudflared held after a failed update" || pass "cloudflared not held"
  else
    note "Cloudflare Tunnel not configured"
  fi

  section "Logs"
  [[ -f /etc/systemd/journald.conf.d/10-zeroport.conf ]] && pass "journald: 14 days, 200M" || note "journald retention not configured"
  pass "journal size: $(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMG]' | head -n1)"

  printf '\n  %s%d failed, %d warnings%s\n' "$BOLD" "$AUDIT_FAIL" "$AUDIT_WARN" "$NC"
  if ((AUDIT_FAIL)); then exit 1; fi
}

# ── CLI ───────────────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
zeroport ${ZEROPORT_VERSION} — fresh Debian 13 VPS with zero public TCP ports

Usage: sudo bash zeroport.sh <command> [options]

Commands:
  audit       Read-only report of the baseline
  bootstrap   Patch, admin user, Tailscale, cloudflared, SSH hardening, reboot
  lockdown    Enable ufw; run over Tailscale SSH after bootstrap

Options:
  --dry-run          Show what would change without changing anything
  --yes              Accept prompts that default to yes (dangerous steps still ask)
  --only=STEPS       Comma-separated bootstrap steps: ${BOOTSTRAP_STEPS[*]}
  --user=NAME        Admin username
  --hostname=NAME    Tailscale hostname
  --swap-size=SIZE   Swap file size when none exists (default ${SWAP_SIZE})
  -h, --help         Show this help
  --version          Show the version
EOF
}

parse_args() {
  local arg step steps
  for arg in "$@"; do
    case "$arg" in
      audit|bootstrap|lockdown)
        [[ -z "$COMMAND" ]] || { usage >&2; exit 2; }
        COMMAND="$arg" ;;
      --dry-run) DRY_RUN=1 ;;
      --yes) ASSUME_YES=1 ;;
      --only=*) ONLY_STEPS="${arg#--only=}" ;;
      --user=*) ADMIN_USER="${arg#--user=}" ;;
      --hostname=*) TS_HOSTNAME="${arg#--hostname=}" ;;
      --swap-size=*) SWAP_SIZE="${arg#--swap-size=}" ;;
      -h|--help) usage; exit 0 ;;
      --version) printf 'zeroport %s\n' "$ZEROPORT_VERSION"; exit 0 ;;
      *) printf 'Unknown argument: %s\n\n' "$arg" >&2; usage >&2; exit 2 ;;
    esac
  done
  [[ -n "$COMMAND" ]] || { usage >&2; exit 2; }
  if [[ -n "$ONLY_STEPS" ]]; then
    IFS=',' read -r -a steps <<<"$ONLY_STEPS"
    for step in "${steps[@]}"; do
      [[ " ${BOOTSTRAP_STEPS[*]} " == *" ${step} "* ]] \
        || { printf 'Unknown step: %s (valid: %s)\n' "$step" "${BOOTSTRAP_STEPS[*]}" >&2; exit 2; }
    done
  fi
  [[ "$SWAP_SIZE" =~ ^[0-9]+[MG]$ ]] || { printf 'Invalid --swap-size: %s\n' "$SWAP_SIZE" >&2; exit 2; }
}

main() {
  parse_args "$@"
  printf '%szeroport %s%s · %s%s\n' "$BOLD" "$ZEROPORT_VERSION" "$NC" "$COMMAND" \
    "$([[ "$DRY_RUN" -eq 1 ]] && printf ' (dry-run)')"
  case "$COMMAND" in
    audit) cmd_audit ;;
    bootstrap) cmd_bootstrap ;;
    lockdown) cmd_lockdown ;;
  esac
}

# Last line on purpose: a truncated download never reaches it.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
